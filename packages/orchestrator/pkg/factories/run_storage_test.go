//go:build linux

package factories

import (
	"bytes"
	"testing"
	"time"

	"github.com/e2b-dev/infra/packages/orchestrator/pkg/cfg"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
)

func TestLocalUploadHMACKeyUsesConfiguredSharedSecret(t *testing.T) {
	t.Parallel()

	config := cfg.Config{
		LocalUploadBaseURL: "https://api.example.test",
		LocalUploadHMACKey: "deployment-secret",
	}
	first, err := localUploadHMACKey(config)
	if err != nil {
		t.Fatalf("first key: %v", err)
	}
	second, err := localUploadHMACKey(config)
	if err != nil {
		t.Fatalf("second key: %v", err)
	}
	if len(first) != 32 {
		t.Fatalf("key length = %d, want 32", len(first))
	}
	if !bytes.Equal(first, second) {
		t.Fatal("same configured secret produced different keys")
	}
	if bytes.Equal(first, []byte(config.LocalUploadHMACKey)) {
		t.Fatal("configured secret was used directly instead of domain-separated derivation")
	}
	expires := time.Now().Add(time.Minute).Unix()
	token := storage.ComputeUploadHMAC(first, "uploads/build-context.tar.gz", expires)
	if !storage.ValidateUploadToken(second, "uploads/build-context.tar.gz", expires, token) {
		t.Fatal("a second allocation could not verify the first allocation's upload token")
	}
}

func TestLocalUploadHMACKeyRejectsExternalProxyWithoutSharedSecret(t *testing.T) {
	t.Parallel()

	_, err := localUploadHMACKey(cfg.Config{LocalUploadBaseURL: "https://api.example.test"})
	if err == nil {
		t.Fatal("expected missing shared key to fail")
	}
}

func TestLocalUploadHMACKeyAllowsRandomLocalFallback(t *testing.T) {
	t.Parallel()

	first, err := localUploadHMACKey(cfg.Config{})
	if err != nil {
		t.Fatalf("first key: %v", err)
	}
	second, err := localUploadHMACKey(cfg.Config{})
	if err != nil {
		t.Fatalf("second key: %v", err)
	}
	if len(first) != 32 || len(second) != 32 {
		t.Fatalf("key lengths = %d, %d; want 32, 32", len(first), len(second))
	}
	if bytes.Equal(first, second) {
		t.Fatal("local fallback unexpectedly reused a random key")
	}
}
