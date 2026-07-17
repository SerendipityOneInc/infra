package storage

import (
	"regexp"
	"testing"

	"github.com/e2b-dev/infra/packages/shared/pkg/storage/storageopts"
)

// azureIdentifier matches a valid Azure Blob metadata key (C# identifier:
// starts with a letter/underscore, then letters/digits/underscores; no hyphen).
var azureIdentifier = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// TestAzureKeyEncoding_WhenRoundTripped_ShouldPreserveKeyAndBeValidIdentifier
// guards the reversible hyphen/underscore escape: shared metadata keys are a mix
// of hyphenated ("uncompressed-size") and underscored ("team_id") styles, so a
// naive hyphen<->underscore swap is NOT reversible. encodeAzureKey must yield a
// valid Azure identifier, and decodeAzureKey must recover the original exactly.
func TestAzureKeyEncoding_WhenRoundTripped_ShouldPreserveKeyAndBeValidIdentifier(t *testing.T) {
	keys := []string{
		// Real shared metadata keys (both styles).
		storageopts.ObjectMetadataTeamID,          // team_id
		storageopts.ObjectMetadataTemplateID,      // template_id
		storageopts.ObjectMetadataBuildOrigin,     // build_origin
		storageopts.ObjectMetadataUncompressedSize, // uncompressed-size
		storageopts.ObjectMetadataLogicalSize,     // logical-size
		storageopts.ObjectMetadataMappedSize,      // mapped-size
		storageopts.ObjectMetadataDiffSize,        // diff-size
		storageopts.ObjectMetadataSoftDeleted,     // storage-index-soft-deleted
		// Edge cases that must survive round-trip unambiguously.
		"a-b_c",
		"already_underscored",
		"already-hyphened",
		"_leading",
		"trailing_",
		"a--b",
		"a__b",
		"x",
	}

	for _, k := range keys {
		enc := encodeAzureKey(k)
		if !azureIdentifier.MatchString(enc) {
			t.Errorf("encodeAzureKey(%q) = %q is not a valid Azure metadata identifier", k, enc)
		}
		if got := decodeAzureKey(enc); got != k {
			t.Errorf("round-trip mismatch: decodeAzureKey(encodeAzureKey(%q)) = %q, want %q", k, got, k)
		}
	}
}

// TestAzureMetadata_WhenRoundTripped_ShouldPreserveEntries verifies the full
// ObjectMetadata <-> Azure map conversion (keys sanitized, values verbatim).
func TestAzureMetadata_WhenRoundTripped_ShouldPreserveEntries(t *testing.T) {
	in := ObjectMetadata{
		storageopts.ObjectMetadataUncompressedSize: "12345",
		storageopts.ObjectMetadataTeamID:           "team-with-hyphen-value",
		storageopts.ObjectMetadataSoftDeleted:      "gc:action_42",
	}

	got := azureObjectMetadata(azureMetadata(in))
	if len(got) != len(in) {
		t.Fatalf("length mismatch: got %d, want %d", len(got), len(in))
	}
	for k, v := range in {
		if got[k] != v {
			t.Errorf("key %q: got value %q, want %q", k, got[k], v)
		}
	}
}
