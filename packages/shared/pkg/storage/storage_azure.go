package storage

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net/url"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/streaming"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/to"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/blob"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/bloberror"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/blockblob"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/container"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/sas"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/service"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/shared/pkg/limit"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
)

const (
	azureOperationTimeout        = 5 * time.Second
	azureWriteTimeout            = 30 * time.Second
	azureReadTimeout             = 15 * time.Second
	azureMultipartUploadPartSize = 10 * 1024 * 1024

	// azureDefaultEndpointSuffix is the public-cloud Blob endpoint suffix used
	// when the spec/env supplies a bare account name rather than a full URL.
	azureDefaultEndpointSuffix = "blob.core.windows.net"
)

type azureStorage struct {
	service       *service.Client
	container     *container.Client
	containerName string

	// sharedKey is non-nil only when the account was configured with an account
	// key (AZURE_STORAGE_KEY or a connection string). When nil, SAS URLs are
	// minted via a User Delegation SAS backed by the Managed Identity / default
	// credential.
	sharedKey *azblob.SharedKeyCredential

	// Proxy-upload endpoint (WithLocalUpload). When set, UploadSignedURL
	// returns an HMAC-signed URL to this endpoint instead of a blob SAS: the
	// e2b SDK performs a bare PUT against upload URLs, but Azure's Put Blob
	// REQUIRES an x-ms-blob-type request header that a SAS cannot pre-sign,
	// so a bare PUT to a SAS URL always fails with 400 MissingRequiredHeader.
	// The proxy (localupload.NewProviderHandler) accepts the bare PUT and
	// writes through this provider instead.
	uploadURL string
	hmacKey   []byte

	limiter *limit.Limiter
}

var _ StorageProvider = (*azureStorage)(nil)

type azureObject struct {
	container     *container.Client
	containerName string
	path          string
	limiter       *limit.Limiter
}

var (
	_ Seekable       = (*azureObject)(nil)
	_ Blob           = (*azureObject)(nil)
	_ RangeOpener    = (*azureObject)(nil)
	_ MetadataReader = (*azureObject)(nil)
)

// newAzureStorage constructs an Azure Blob Storage provider. Auth resolution,
// in precedence order:
//
//	AZURE_STORAGE_CONNECTION_STRING → shared-key from connection string
//	AZURE_STORAGE_KEY (+ account)   → shared-key credential
//	otherwise                       → azidentity.DefaultAzureCredential
//	                                  (Managed Identity in prod, env/CLI in dev)
//
// spec.Bucket is the container name and spec.Endpoint carries the account name
// (from az://<account>/<container>) or a full service URL; AZURE_STORAGE_ACCOUNT
// is the environment fallback for the account.
func newAzureStorage(_ context.Context, spec Spec, limiter *limit.Limiter) (*azureStorage, error) {
	containerName := spec.Bucket
	if containerName == "" {
		return nil, fmt.Errorf("azure storage: container name is required (set via az://<account>/<container>)")
	}

	// A connection string carries both the endpoint and the account key, so it
	// takes precedence over everything else.
	if connStr := os.Getenv("AZURE_STORAGE_CONNECTION_STRING"); connStr != "" {
		svc, err := service.NewClientFromConnectionString(connStr, nil)
		if err != nil {
			return nil, fmt.Errorf("azure storage: parse connection string: %w", err)
		}

		return newAzureStorageFromService(svc, sharedKeyFromConnectionString(connStr), containerName, limiter), nil
	}

	account := spec.Endpoint
	if account == "" {
		account = os.Getenv("AZURE_STORAGE_ACCOUNT")
	}
	serviceURL, err := azureServiceURL(account)
	if err != nil {
		return nil, err
	}

	// Explicit account key → shared-key auth (works in dev / S3-compatible
	// emulators like Azurite without a Managed Identity).
	if key := os.Getenv("AZURE_STORAGE_KEY"); key != "" {
		cred, err := azblob.NewSharedKeyCredential(azureAccountName(account), key)
		if err != nil {
			return nil, fmt.Errorf("azure storage: shared key credential: %w", err)
		}
		svc, err := service.NewClientWithSharedKeyCredential(serviceURL, cred, nil)
		if err != nil {
			return nil, fmt.Errorf("azure storage: create service client (shared key): %w", err)
		}

		return newAzureStorageFromService(svc, cred, containerName, limiter), nil
	}

	// Managed Identity in prod, environment / Azure CLI in dev.
	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, fmt.Errorf("azure storage: default azure credential: %w", err)
	}
	svc, err := service.NewClient(serviceURL, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("azure storage: create service client: %w", err)
	}

	return newAzureStorageFromService(svc, nil, containerName, limiter), nil
}

func newAzureStorageFromService(svc *service.Client, sharedKey *azblob.SharedKeyCredential, containerName string, limiter *limit.Limiter) *azureStorage {
	return &azureStorage{
		service:       svc,
		container:     svc.NewContainerClient(containerName),
		containerName: containerName,
		sharedKey:     sharedKey,
		limiter:       limiter,
	}
}

// SetProxyUpload enables HMAC proxy-upload URLs (see the struct comment).
func (s *azureStorage) SetProxyUpload(uploadBaseURL string, hmacKey []byte) {
	s.uploadURL = strings.TrimSuffix(uploadBaseURL, "/")
	s.hmacKey = hmacKey
}

// azureServiceURL resolves an account name or full service URL into a blob
// service URL. A value containing "://" is treated as an already-formed URL.
func azureServiceURL(account string) (string, error) {
	if account == "" {
		return "", fmt.Errorf("azure storage: account not configured (set az://<account>/<container>, AZURE_STORAGE_ACCOUNT, or AZURE_STORAGE_CONNECTION_STRING)")
	}
	if strings.Contains(account, "://") {
		return strings.TrimSuffix(account, "/"), nil
	}

	return fmt.Sprintf("https://%s.%s", account, azureDefaultEndpointSuffix), nil
}

// azureAccountName extracts the bare account name from either a bare name or a
// full service URL (https://<account>.blob.core.windows.net).
func azureAccountName(account string) string {
	if strings.Contains(account, "://") {
		if u, err := url.Parse(account); err == nil && u.Host != "" {
			return strings.SplitN(u.Host, ".", 2)[0]
		}
	}

	return account
}

// sharedKeyFromConnectionString reconstructs a SharedKeyCredential from a
// connection string so SAS URLs can be signed without a User Delegation round
// trip. Returns nil when the string lacks an account name/key (e.g. a
// SAS-based connection string), in which case SAS falls back to user
// delegation.
func sharedKeyFromConnectionString(connStr string) *azblob.SharedKeyCredential {
	var name, key string
	for _, part := range strings.Split(connStr, ";") {
		k, v, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		switch strings.TrimSpace(k) {
		case "AccountName":
			name = strings.TrimSpace(v)
		case "AccountKey":
			key = strings.TrimSpace(v)
		}
	}
	if name == "" || key == "" {
		return nil
	}
	cred, err := azblob.NewSharedKeyCredential(name, key)
	if err != nil {
		return nil
	}

	return cred
}

func (s *azureStorage) DeleteObjectsWithPrefix(ctx context.Context, prefix string) error {
	ctx, cancel := context.WithTimeout(ctx, azureOperationTimeout)
	defer cancel()

	pager := s.container.NewListBlobsFlatPager(&container.ListBlobsFlatOptions{Prefix: &prefix})

	var names []string
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return fmt.Errorf("failed to list Azure blobs with prefix %q: %w", prefix, err)
		}
		if page.Segment == nil {
			continue
		}
		for _, item := range page.Segment.BlobItems {
			if item != nil && item.Name != nil {
				names = append(names, *item.Name)
			}
		}
	}

	if len(names) == 0 {
		logger.L().Warn(ctx, "No objects found to delete with the given prefix", zap.String("prefix", prefix), zap.String("container", s.containerName))

		return nil
	}

	for _, name := range names {
		if _, err := s.container.NewBlobClient(name).Delete(ctx, nil); err != nil {
			// A blob deleted concurrently is not an error for a prefix wipe.
			if bloberror.HasCode(err, bloberror.BlobNotFound) {
				continue
			}

			return fmt.Errorf("failed to delete Azure blob %q: %w", name, err)
		}
	}

	return nil
}

func (s *azureStorage) GetDetails() string {
	return fmt.Sprintf("[Azure Storage, container set to %s]", s.containerName)
}

func (s *azureStorage) UploadSignedURL(ctx context.Context, path string, ttl time.Duration) (string, error) {
	// Proxy mode: hand out an HMAC-signed URL to our upload endpoint (the e2b
	// SDK cannot bare-PUT to an Azure SAS URL — see the struct comment).
	if s.uploadURL != "" && s.hmacKey != nil {
		expiresSec := time.Now().Add(ttl).Unix()
		token := ComputeUploadHMAC(s.hmacKey, path, expiresSec)

		return fmt.Sprintf("%s/upload?path=%s&expires=%d&token=%s",
			s.uploadURL, url.QueryEscape(path), expiresSec, token), nil
	}

	now := time.Now().UTC()
	// A small clock-skew allowance on the start time avoids the SAS being
	// rejected as not-yet-valid by the service.
	start := now.Add(-10 * time.Second)
	expiry := now.Add(ttl)

	sigValues := sas.BlobSignatureValues{
		Protocol:      sas.ProtocolHTTPS,
		Version:       sas.Version,
		StartTime:     start,
		ExpiryTime:    expiry,
		Permissions:   (&sas.BlobPermissions{Create: true, Write: true, Add: true}).String(),
		ContainerName: s.containerName,
		BlobName:      path,
	}

	var (
		qp  sas.QueryParameters
		err error
	)
	if s.sharedKey != nil {
		qp, err = sigValues.SignWithSharedKey(s.sharedKey)
	} else {
		// User Delegation SAS: signs with a key delegated by the Managed
		// Identity / default credential, so no account key is required.
		info := service.KeyInfo{
			Start:  to.Ptr(start.Format(sas.TimeFormat)),
			Expiry: to.Ptr(expiry.Format(sas.TimeFormat)),
		}
		udc, dErr := s.service.GetUserDelegationCredential(ctx, info, nil)
		if dErr != nil {
			return "", fmt.Errorf("azure storage: get user delegation credential: %w", dErr)
		}
		qp, err = sigValues.SignWithUserDelegation(udc)
	}
	if err != nil {
		return "", fmt.Errorf("azure storage: sign SAS for %q: %w", path, err)
	}

	// NewBlobClient produces a correctly percent-encoded blob URL for the path.
	return s.container.NewBlobClient(path).URL() + "?" + qp.Encode(), nil
}

func (s *azureStorage) OpenSeekable(_ context.Context, path string) (Seekable, error) {
	return &azureObject{
		container:     s.container,
		containerName: s.containerName,
		path:          path,
		limiter:       s.limiter,
	}, nil
}

func (s *azureStorage) OpenBlob(_ context.Context, path string) (Blob, error) {
	return &azureObject{
		container:     s.container,
		containerName: s.containerName,
		path:          path,
		limiter:       s.limiter,
	}, nil
}

func (o *azureObject) blobClient() *blob.Client {
	return o.container.NewBlobClient(o.path)
}

func (o *azureObject) blockBlobClient() *blockblob.Client {
	return o.container.NewBlockBlobClient(o.path)
}

func (o *azureObject) WriteTo(ctx context.Context, dst io.Writer) (n int64, err error) {
	start := time.Now()
	defer func() { RecordReadBlob(ctx, time.Since(start), n, o.path, SourceAzure, err) }()

	ctx, cancel := context.WithTimeout(ctx, azureReadTimeout)
	defer cancel()

	resp, err := o.blobClient().DownloadStream(ctx, nil)
	if err != nil {
		if bloberror.HasCode(err, bloberror.BlobNotFound) {
			return 0, ErrObjectNotExist
		}

		return 0, err
	}

	defer resp.Body.Close()

	n, err = io.Copy(dst, resp.Body)

	return n, err
}

func (o *azureObject) StoreFile(ctx context.Context, path string, opts ...PutOption) (*FullFrameTable, [32]byte, error) {
	p := ApplyPutOptions(opts)

	release, err := o.limiter.AcquireUploadSlot(ctx)
	if err != nil {
		return nil, [32]byte{}, err
	}
	defer release()

	cfg := CompressConfigFromOpts(p)
	if cfg.IsCompressionEnabled() {
		return storeFileCompressed(ctx, path, cfg, o.limiter.MaxUploadTasks(ctx), p, func(metadata ObjectMetadata) (partUploader, error) {
			return &azurePartUploader{client: o.blockBlobClient(), objectName: o.path, metadata: metadata}, nil
		})
	}

	// Inherit the caller's context for the parallel block upload, matching the
	// AWS/GCP paths: the caller (pkg/server/sandboxes.go) already scopes a
	// per-attempt deadline with a retry budget, and a tight static timeout here
	// would cancel an in-flight multi-GB snapshot upload.
	f, err := os.Open(path)
	if err != nil {
		return nil, [32]byte{}, fmt.Errorf("failed to open file %s: %w", path, err)
	}
	defer f.Close()

	//nolint:gosec // MaxUploadTasks is a small bounded concurrency value.
	_, err = o.blockBlobClient().UploadFile(ctx, f, &blockblob.UploadFileOptions{
		BlockSize:   azureMultipartUploadPartSize,
		Concurrency: uint16(o.limiter.MaxUploadTasks(ctx)),
		Metadata:    azureMetadata(p.Metadata),
	})
	if err == nil {
		fi, _ := f.Stat()
		var size int64
		if fi != nil {
			size = fi.Size()
		}

		logger.L().Debug(ctx, "Uploaded file to Azure Blob Storage",
			zap.String("container", o.containerName),
			zap.String("object", o.path),
			zap.String("source", path),
			zap.Int64("size_uncompressed", size),
			zap.String("compression", "none"),
		)
	}

	return nil, [32]byte{}, err
}

func (o *azureObject) Put(ctx context.Context, data []byte, opts ...PutOption) error {
	ctx, cancel := context.WithTimeout(ctx, azureWriteTimeout)
	defer cancel()

	_, err := o.blockBlobClient().UploadBuffer(ctx, data, &blockblob.UploadBufferOptions{
		Metadata: azureMetadata(ApplyPutOptions(opts).Metadata),
	})

	return err
}

func (o *azureObject) OpenRangeReader(ctx context.Context, off, length int64, frameTable *FrameTable) (_ RangeReader, _ Source, err error) {
	start := time.Now()
	objType, _ := seekableObjectType(o.path)
	defer func() {
		RecordReadOpen(ctx, time.Since(start), objType, SourceAzure, frameTable.CompressionType(), err)
	}()

	if !frameTable.IsCompressed() {
		rc, err := o.openRangeReader(ctx, off, length)
		if err != nil {
			return nil, SourceAzure, err
		}

		return rc, SourceAzure, nil
	}

	r, err := frameTable.LocateCompressed(off)
	if err != nil {
		return nil, SourceAzure, fmt.Errorf("get frame for offset %d, Azure:%s: %w", off, o.path, err)
	}

	raw, err := o.openRangeReader(ctx, r.Offset, int64(r.Length))
	if err != nil {
		return nil, SourceAzure, err
	}

	dec, err := NewDecompressReader(raw, frameTable.CompressionType(), SourceAzure, objType)
	if err != nil {
		raw.Close(ctx)

		return nil, SourceAzure, err
	}

	return dec, SourceAzure, nil
}

func (o *azureObject) openRangeReader(ctx context.Context, off, length int64) (RangeReader, error) {
	resp, err := o.blobClient().DownloadStream(ctx, &blob.DownloadStreamOptions{
		Range: blob.HTTPRange{Offset: off, Count: length},
	})
	if err != nil {
		if bloberror.HasCode(err, bloberror.BlobNotFound) {
			return nil, ErrObjectNotExist
		}

		return nil, fmt.Errorf("failed to create Azure range reader for %q: %w", o.path, err)
	}

	return NewRangeReader(resp.Body), nil
}

func (o *azureObject) Size(ctx context.Context) (_ int64, err error) {
	start := time.Now()
	objType, _ := seekableObjectType(o.path)
	defer func() { RecordReadSize(ctx, time.Since(start), objType, SourceAzure, err) }()

	ctx, cancel := context.WithTimeout(ctx, azureOperationTimeout)
	defer cancel()

	props, err := o.blobClient().GetProperties(ctx, nil)
	if err != nil {
		if bloberror.HasCode(err, bloberror.BlobNotFound) {
			return 0, ErrObjectNotExist
		}

		return 0, err
	}

	if size, ok := azureObjectMetadata(props.Metadata).UncompressedSize(); ok {
		return size, nil
	}

	if props.ContentLength != nil {
		return *props.ContentLength, nil
	}

	return 0, nil
}

func (o *azureObject) Exists(ctx context.Context) (bool, error) {
	_, err := o.Size(ctx)

	return err == nil, ignoreNotExists(err)
}

// Metadata implements MetadataReader via GetProperties (always hits Azure).
func (o *azureObject) Metadata(ctx context.Context) (ObjectMetadata, error) {
	ctx, cancel := context.WithTimeout(ctx, azureOperationTimeout)
	defer cancel()

	props, err := o.blobClient().GetProperties(ctx, nil)
	if err != nil {
		if bloberror.HasCode(err, bloberror.BlobNotFound) {
			return nil, ErrObjectNotExist
		}

		return nil, err
	}

	return azureObjectMetadata(props.Metadata), nil
}

func (o *azureObject) Delete(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, azureOperationTimeout)
	defer cancel()

	_, err := o.blobClient().Delete(ctx, nil)

	return err
}

// azureMetadata converts the shared ObjectMetadata (map[string]string) into the
// pointer-valued map Azure's SDK expects, sanitizing keys on the way.
//
// Azure Blob metadata keys must be valid C# identifiers (letters, digits,
// underscore; no hyphens), but the shared keys are a MIX: some use hyphens
// ("uncompressed-size", "logical-size", "storage-index-soft-deleted"), which
// Azure rejects, while others already use underscores ("team_id", "template_id",
// "build_origin"), which must survive untouched. A blanket hyphen→underscore is
// therefore NOT reversible (it would turn "team_id" into "team-id" on read).
// encodeAzureKey uses a reversible escape ("_"→"__", then "-"→"_"); decodeAzureKey
// reverses it, so the round-trip is exact for both key styles. Values are
// unrestricted and pass through verbatim.
func azureMetadata(m ObjectMetadata) map[string]*string {
	if len(m) == 0 {
		return nil
	}
	out := make(map[string]*string, len(m))
	for k, v := range m {
		out[encodeAzureKey(k)] = to.Ptr(v)
	}

	return out
}

// azureObjectMetadata converts Azure's pointer-valued metadata map back into the
// shared ObjectMetadata type, decoding the sanitized keys.
func azureObjectMetadata(m map[string]*string) ObjectMetadata {
	if len(m) == 0 {
		return nil
	}
	out := make(ObjectMetadata, len(m))
	for k, v := range m {
		if v != nil {
			out[decodeAzureKey(k)] = *v
		}
	}

	return out
}

// encodeAzureKey makes a metadata key a valid Azure identifier reversibly.
// Alphanumerics pass through; every other byte (including "_" and "-") is
// escaped as "_XX" (underscore + two lowercase hex digits). Using a uniform
// escape — rather than mapping "-"→"_" and "_"→"__" — avoids the collision
// where "--" and "_" would both encode to "__". decodeAzureKey inverts it.
func encodeAzureKey(k string) string {
	var b strings.Builder
	b.Grow(len(k))
	for i := 0; i < len(k); i++ {
		c := k[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			b.WriteByte(c)

			continue
		}
		fmt.Fprintf(&b, "_%02x", c)
	}

	return b.String()
}

// decodeAzureKey inverts encodeAzureKey: a "_" is always the start of a two-hex
// escape (the encoder never emits a bare "_"); anything else passes through.
func decodeAzureKey(k string) string {
	var b strings.Builder
	b.Grow(len(k))
	for i := 0; i < len(k); i++ {
		if k[i] == '_' && i+2 < len(k) {
			if v, err := strconv.ParseUint(k[i+1:i+3], 16, 8); err == nil {
				b.WriteByte(byte(v))
				i += 2

				continue
			}
		}
		b.WriteByte(k[i])
	}

	return b.String()
}

// azureBlockID encodes a part index as a fixed-width, base64-encoded block ID.
// Azure requires every block ID committed together to be the same length; an
// 8-byte big-endian encoding of the index guarantees that regardless of the
// index magnitude.
func azureBlockID(partIndex int) string {
	var raw [8]byte
	//nolint:gosec // partIndex is always a small positive part number.
	binary.BigEndian.PutUint64(raw[:], uint64(partIndex))

	return base64.StdEncoding.EncodeToString(raw[:])
}

type azurePartUploader struct {
	client     *blockblob.Client
	objectName string
	metadata   ObjectMetadata

	mu     sync.Mutex
	blocks map[int]string // partIndex -> base64 block ID
	// completed needs no lock: compressStream calls Complete and the deferred
	// Close sequentially from one goroutine, after all UploadPart calls finish.
	completed bool
}

var _ partUploader = (*azurePartUploader)(nil)

func (m *azurePartUploader) Start(_ context.Context) error {
	m.mu.Lock()
	m.blocks = make(map[int]string)
	m.mu.Unlock()

	// Block blobs need no explicit create: staged blocks are committed by
	// CommitBlockList and, until then, live in the uncommitted block list.
	return nil
}

// UploadPart stages a single block. Multiple data slices are streamed without
// copying into a contiguous buffer; the section reader's Seek lets the SDK
// compute the payload length and rewind on retries.
func (m *azurePartUploader) UploadPart(ctx context.Context, partIndex int, data ...[]byte) error {
	blockID := azureBlockID(partIndex)
	body := streaming.NopCloser(newMultiSliceReader(data))

	if _, err := m.client.StageBlock(ctx, blockID, body, nil); err != nil {
		return fmt.Errorf("failed to stage block %d: %w", partIndex, err)
	}

	m.mu.Lock()
	m.blocks[partIndex] = blockID
	m.mu.Unlock()

	return nil
}

func (m *azurePartUploader) Complete(ctx context.Context) error {
	m.mu.Lock()
	indices := make([]int, 0, len(m.blocks))
	for idx := range m.blocks {
		indices = append(indices, idx)
	}
	slices.Sort(indices)
	blockIDs := make([]string, 0, len(indices))
	for _, idx := range indices {
		blockIDs = append(blockIDs, m.blocks[idx])
	}
	m.mu.Unlock()

	_, err := m.client.CommitBlockList(ctx, blockIDs, &blockblob.CommitBlockListOptions{
		Metadata: azureMetadata(m.metadata),
	})
	if err != nil {
		return err
	}

	m.completed = true

	return nil
}

func (m *azurePartUploader) Close() error {
	// Block blobs have no multipart upload to abort: uncommitted staged blocks
	// are garbage-collected by Azure Storage if CommitBlockList is never called.
	return nil
}
