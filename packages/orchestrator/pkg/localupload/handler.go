package localupload

import (
	"context"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"

	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
)

// maxUploadBytes caps a single proxied upload (template copy-files / build
// cache entries). Provider-backed stores buffer the body in memory (Blob.Put
// takes []byte), so the cap also bounds memory use per request.
const maxUploadBytes = 1 << 30 // 1 GiB

// Handler serves signed file uploads for storage backends whose native signed
// URLs the e2b SDK cannot use directly. It validates HMAC-signed tokens before
// accepting PUT requests.
//
// Two backends:
//   - filesystem (STORAGE_PROVIDER=Local): writes under basePath (dev setups).
//   - provider-proxy (e.g. Azure): streams the body into the StorageProvider.
//     Needed because Azure Blob's Put Blob REQUIRES an x-ms-blob-type request
//     header that cannot be pre-signed into a SAS URL, while the SDK performs
//     a bare PUT against whatever upload URL it is given.
type Handler struct {
	hmacKey []byte
	store   func(ctx context.Context, path string, body io.Reader) error
}

// NewHandler creates an upload handler that stores files on the local
// filesystem under basePath (STORAGE_PROVIDER=Local).
func NewHandler(basePath string, hmacKey []byte) *Handler {
	return &Handler{
		hmacKey: hmacKey,
		store: func(_ context.Context, path string, body io.Reader) error {
			return storeToFilesystem(basePath, path, body)
		},
	}
}

// NewProviderHandler creates an upload handler that stores files through the
// given StorageProvider (used for providers like Azure where the SDK cannot
// PUT to a native signed URL).
func NewProviderHandler(provider storage.StorageProvider, hmacKey []byte) *Handler {
	return &Handler{
		hmacKey: hmacKey,
		store: func(ctx context.Context, path string, body io.Reader) error {
			data, err := io.ReadAll(body)
			if err != nil {
				return err
			}

			blob, err := provider.OpenBlob(ctx, path)
			if err != nil {
				return err
			}

			return blob.Put(ctx, data)
		},
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)

		return
	}

	path := r.URL.Query().Get("path")
	expiresStr := r.URL.Query().Get("expires")
	token := r.URL.Query().Get("token")

	if path == "" || expiresStr == "" || token == "" {
		http.Error(w, "missing required query parameters: path, expires, token", http.StatusBadRequest)

		return
	}

	expires, err := strconv.ParseInt(expiresStr, 10, 64)
	if err != nil {
		http.Error(w, "invalid expires value", http.StatusBadRequest)

		return
	}

	// Validate the HMAC token and check expiry
	if !storage.ValidateUploadToken(h.hmacKey, path, expires, token) {
		http.Error(w, "invalid or expired token", http.StatusForbidden)

		return
	}

	// Prevent path traversal
	if !filepath.IsLocal(path) {
		http.Error(w, "invalid path", http.StatusBadRequest)

		return
	}

	body := http.MaxBytesReader(w, r.Body, maxUploadBytes)
	if err := h.store(r.Context(), path, body); err != nil {
		http.Error(w, "failed to store file", http.StatusInternalServerError)

		return
	}

	w.WriteHeader(http.StatusOK)
}

// storeToFilesystem writes the body under basePath/path: temp file in the same
// directory, then atomic rename, so failed writes (client disconnect, disk
// full) never leave partial files behind.
func storeToFilesystem(basePath, path string, body io.Reader) error {
	fullPath := filepath.Join(basePath, path)

	dir := filepath.Dir(fullPath)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	tmpFile, err := os.CreateTemp(dir, ".upload-*")
	if err != nil {
		return err
	}

	stored := false
	defer func() {
		if !stored {
			os.Remove(tmpFile.Name())
		}
	}()

	if _, err := io.Copy(tmpFile, body); err != nil {
		tmpFile.Close()

		return err
	}

	if err := tmpFile.Close(); err != nil {
		return err
	}

	if err := os.Chmod(tmpFile.Name(), 0o644); err != nil {
		return err
	}

	if err := os.Rename(tmpFile.Name(), fullPath); err != nil {
		return err
	}

	stored = true

	return nil
}
