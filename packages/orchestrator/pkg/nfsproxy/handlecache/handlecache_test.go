package handlecache

import (
	"context"
	"fmt"
	"testing"

	"github.com/go-git/go-billy/v5"
	"github.com/go-git/go-billy/v5/memfs"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/willscott/go-nfs"
)

func newCache(t *testing.T, limit int) *CachingHandler {
	t.Helper()

	h, ok := New(nil, limit, 16).(*CachingHandler)
	require.True(t, ok)

	return h
}

func TestHandleCache_WhenRoundTripping_ShouldReturnSamePath(t *testing.T) {
	c := newCache(t, 16)
	fs := memfs.New()
	ctx := context.Background()

	fh := c.ToHandle(ctx, fs, []string{"a", "b", "c"})
	gotFS, path, err := c.FromHandle(ctx, fh)

	require.NoError(t, err)
	assert.Equal(t, fs, gotFS)
	assert.Equal(t, []string{"a", "b", "c"}, path)
}

func TestHandleCache_WhenHandleEvicted_ShouldReturnStale(t *testing.T) {
	c := newCache(t, 4)
	fs := memfs.New()
	ctx := context.Background()

	fh := c.ToHandle(ctx, fs, []string{"victim"})
	for i := 0; i < 8; i++ {
		c.ToHandle(ctx, fs, []string{fmt.Sprintf("filler-%d", i)})
	}

	_, _, err := c.FromHandle(ctx, fh)

	var status *nfs.NFSStatusError
	require.ErrorAs(t, err, &status)
	assert.Equal(t, nfs.NFSStatusStale, status.NFSStatus)
}

func TestHandleCache_WhenDescendantAccessed_ShouldKeepAncestorsWarm(t *testing.T) {
	c := newCache(t, 4)
	fs := memfs.New()
	ctx := context.Background()

	rootFH := c.ToHandle(ctx, fs, []string{})
	dirFH := c.ToHandle(ctx, fs, []string{"dir"})
	leafFH := c.ToHandle(ctx, fs, []string{"dir", "leaf"})

	// Each leaf access must bump root and dir, so the fillers evict the
	// idle unrelated entries instead of the ancestors in active use.
	for i := 0; i < 8; i++ {
		_, _, err := c.FromHandle(ctx, leafFH)
		require.NoError(t, err)
		c.ToHandle(ctx, fs, []string{fmt.Sprintf("filler-%d", i)})
	}

	for name, fh := range map[string][]byte{"root": rootFH, "dir": dirFH, "leaf": leafFH} {
		_, _, err := c.FromHandle(ctx, fh)
		assert.NoError(t, err, "%s handle must survive churn while its subtree is active", name)
	}
}

func TestHandleCache_WhenSamePathOnOtherFilesystem_ShouldNotShareHandles(t *testing.T) {
	c := newCache(t, 16)
	fsA := memfs.New()
	fsB := memfs.New()
	ctx := context.Background()

	fhA := c.ToHandle(ctx, fsA, []string{"same", "path"})
	fhB := c.ToHandle(ctx, fsB, []string{"same", "path"})

	assert.NotEqual(t, fhA, fhB)

	gotA, _, err := c.FromHandle(ctx, fhA)
	require.NoError(t, err)
	gotB, _, err := c.FromHandle(ctx, fhB)
	require.NoError(t, err)
	assert.Equal(t, billy.Filesystem(fsA), gotA)
	assert.Equal(t, billy.Filesystem(fsB), gotB)
}

func TestHandleCache_WhenInvalidated_ShouldReturnStaleAndDropReverseEntry(t *testing.T) {
	c := newCache(t, 16)
	fs := memfs.New()
	ctx := context.Background()

	fh := c.ToHandle(ctx, fs, []string{"x"})
	require.NoError(t, c.InvalidateHandle(ctx, fs, fh))

	_, _, err := c.FromHandle(ctx, fh)
	var status *nfs.NFSStatusError
	require.ErrorAs(t, err, &status)
	assert.Equal(t, nfs.NFSStatusStale, status.NFSStatus)

	// A fresh ToHandle for the same path must mint a new handle, not resurrect
	// the invalidated one through the reverse cache.
	fh2 := c.ToHandle(ctx, fs, []string{"x"})
	assert.NotEqual(t, fh, fh2)
	_, _, err = c.FromHandle(ctx, fh2)
	assert.NoError(t, err)
}
