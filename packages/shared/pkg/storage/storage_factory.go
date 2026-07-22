package storage

import (
	"context"
	"fmt"

	"github.com/e2b-dev/infra/packages/shared/pkg/limit"
)

// Option configures provider construction (see NewProvider).
type Option func(*providerOptions)

type providerOptions struct {
	limiter       *limit.Limiter
	uploadBaseURL string
	hmacKey       []byte
}

// WithLimiter sets the concurrent-upload limiter used by the cloud providers.
func WithLimiter(limiter *limit.Limiter) Option {
	return func(o *providerOptions) { o.limiter = limiter }
}

// WithLocalUpload configures HMAC proxy-upload URL signing. Used by the
// filesystem provider (dev) and by Azure (the e2b SDK cannot bare-PUT to an
// Azure SAS URL — mandatory x-ms-blob-type header — so uploads route through
// the localupload proxy handler instead).
func WithLocalUpload(uploadBaseURL string, hmacKey []byte) Option {
	return func(o *providerOptions) {
		o.uploadBaseURL = uploadBaseURL
		o.hmacKey = hmacKey
	}
}

// NewProvider constructs the storage provider for a resolved destination.
func NewProvider(ctx context.Context, spec Spec, opts ...Option) (StorageProvider, error) {
	var o providerOptions
	for _, opt := range opts {
		opt(&o)
	}

	switch spec.Provider {
	case LocalStorageProvider:
		return newFileSystemStorage(spec.BasePath, o.uploadBaseURL, o.hmacKey), nil
	case AWSStorageProvider:
		return newAWSStorage(ctx, spec, o.limiter)
	case AzureStorageProvider:
		azureProvider, err := newAzureStorage(ctx, spec, o.limiter)
		if err != nil {
			return nil, err
		}
		if o.uploadBaseURL != "" && o.hmacKey != nil {
			azureProvider.SetProxyUpload(o.uploadBaseURL, o.hmacKey)
		}

		return azureProvider, nil
	case GCPStorageProvider:
		return NewGCP(ctx, spec.Bucket, o.limiter)
	}

	return nil, fmt.Errorf("unknown storage provider: %s", spec.Provider)
}
