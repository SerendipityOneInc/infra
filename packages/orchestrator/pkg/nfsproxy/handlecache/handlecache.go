// Package handlecache provides the NFS file-handle <-> path cache for the
// NFS proxy. It replaces go-nfs's helpers.CachingHandler, whose FromHandle
// iterated the ENTIRE handle LRU on every hit to keep ancestor directory
// handles warm — O(cache size) per NFS request, which forbids raising the
// cache limit. This implementation bumps ancestors through the existing
// path->handle reverse index instead, making a hit O(path depth), so the
// cache can be sized to hold the node's realistic working set.
//
// Handles are still random UUIDs held only in process memory: an evicted or
// unknown handle returns NFSStatusStale, and a process restart invalidates
// every handle guests have cached. Sizing the cache large enough makes
// eviction rare; making handles survive restarts (stable, path-derived
// handles) is a separate planned change.
package handlecache

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"io/fs"
	"sync"

	"github.com/go-git/go-billy/v5"
	"github.com/google/uuid"
	lru "github.com/hashicorp/golang-lru/v2"
	"github.com/willscott/go-nfs"
)

// New wraps a handler with a handle cache of the given size. verifierLimit
// bounds the READDIR cookie-verifier cache separately: verifier entries hold
// full directory listings, so it must stay small even when the handle cache
// is large.
func New(h nfs.Handler, limit int, verifierLimit int) nfs.Handler {
	if limit < 2 || verifierLimit < 2 {
		nfs.Log.Warnf("handle cache created with insufficient size", "size", limit, "verifiers", verifierLimit)
	}
	cache, _ := lru.New[uuid.UUID, entry](limit)
	verifiers, _ := lru.New[uint64, verifier](verifierLimit)

	return &CachingHandler{
		Handler:         h,
		activeHandles:   cache,
		reverseHandles:  make(map[string][]uuid.UUID),
		activeVerifiers: verifiers,
		cacheLimit:      limit,
	}
}

// CachingHandler implements to/from handle via an LRU cache.
type CachingHandler struct {
	nfs.Handler

	activeHandles    *lru.Cache[uuid.UUID, entry]
	reverseHandles   map[string][]uuid.UUID
	reverseHandlesMu sync.RWMutex
	activeVerifiers  *lru.Cache[uint64, verifier]
	cacheLimit       int
}

type entry struct {
	f billy.Filesystem
	p []string
}

// ToHandle takes a file and represents it with an opaque handle to reference it.
// In stateless nfs (when it's serving a unix fs) this can be the device + inode
// but we can generalize with a stateful local cache of handed out IDs.
func (c *CachingHandler) ToHandle(_ context.Context, f billy.Filesystem, path []string) []byte {
	joinedPath := f.Join(path...)

	if handle := c.searchReverseCache(f, joinedPath); handle != nil {
		return handle
	}

	id := uuid.New()

	newPath := make([]string, len(path))

	copy(newPath, path)
	evictedKey, evictedPath, ok := c.activeHandles.GetOldest()
	if evicted := c.activeHandles.Add(id, entry{f, newPath}); evicted && ok {
		rk := evictedPath.f.Join(evictedPath.p...)
		c.evictReverseCache(rk, evictedKey)
	}

	c.appendReverseHandle(joinedPath, id)
	b, _ := id.MarshalBinary()

	return b
}

// FromHandle converts from an opaque handle to the file it represents
func (c *CachingHandler) FromHandle(_ context.Context, fh []byte) (billy.Filesystem, []string, error) {
	id, err := uuid.FromBytes(fh)
	if err != nil {
		return nil, []string{}, err
	}

	f, ok := c.activeHandles.Get(id)
	if !ok {
		return nil, []string{}, &nfs.NFSStatusError{NFSStatus: nfs.NFSStatusStale}
	}

	// Keep the handles of this path's ancestor directories (including the
	// mount root) recently-used, so a deep traversal cannot evict the
	// directory handles the client is standing on. Resolved through the
	// path->handle reverse index: O(path depth), not O(cache size).
	c.touchAncestors(f)

	newP := make([]string, len(f.p))
	copy(newP, f.p)

	return f.f, newP, nil
}

func (c *CachingHandler) touchAncestors(e entry) {
	c.reverseHandlesMu.RLock()
	defer c.reverseHandlesMu.RUnlock()

	// Proper prefixes only ([:0] is the mount root); the full path's own
	// handle was already bumped by the activeHandles.Get that found it.
	for i := range e.p {
		joined := e.f.Join(e.p[:i]...)
		for _, id := range c.reverseHandles[joined] {
			if cand, ok := c.activeHandles.Peek(id); ok && cand.f == e.f {
				_, _ = c.activeHandles.Get(id)
			}
		}
	}
}

func (c *CachingHandler) searchReverseCache(f billy.Filesystem, path string) []byte {
	// Hold RLock for entire iteration to prevent races with appendReverseHandle
	// and evictReverseCache which modify the slice. This is safe because
	// activeHandles.Get() has its own internal synchronization (LRU cache).
	c.reverseHandlesMu.RLock()
	defer c.reverseHandlesMu.RUnlock()

	for _, id := range c.reverseHandles[path] {
		if candidate, ok := c.activeHandles.Get(id); ok {
			// Interface comparison (==) only compares type and pointer, which
			// is sufficient for checking it is the same filesystem instance
			// (DeepEqual would race on the filesystem's mutable internals).
			if candidate.f == f {
				return id[:]
			}
		}
	}

	return nil
}

func (c *CachingHandler) evictReverseCache(path string, handle uuid.UUID) {
	c.reverseHandlesMu.Lock()
	defer c.reverseHandlesMu.Unlock()

	uuids, ok := c.reverseHandles[path]
	if !ok {
		return
	}
	for i, u := range uuids {
		if u == handle {
			c.reverseHandles[path] = append(uuids[:i], uuids[i+1:]...)
			if len(c.reverseHandles[path]) == 0 {
				delete(c.reverseHandles, path)
			}

			return
		}
	}
}

func (c *CachingHandler) appendReverseHandle(path string, id uuid.UUID) {
	c.reverseHandlesMu.Lock()
	defer c.reverseHandlesMu.Unlock()
	c.reverseHandles[path] = append(c.reverseHandles[path], id)
}

// InvalidateHandle removes an entry from the cache.
func (c *CachingHandler) InvalidateHandle(_ context.Context, _ billy.Filesystem, handle []byte) error {
	id, _ := uuid.FromBytes(handle)
	entry, ok := c.activeHandles.Get(id)
	if ok {
		rk := entry.f.Join(entry.p...)
		c.evictReverseCache(rk, id)
	}
	c.activeHandles.Remove(id)

	return nil
}

// HandleLimit exports how many file handles can be safely stored by this cache.
func (c *CachingHandler) HandleLimit() int {
	return c.cacheLimit
}

type verifier struct {
	path     string
	contents []fs.FileInfo
}

func hashPathAndContents(path string, contents []fs.FileInfo) uint64 {
	// calculate a cookie-verifier.
	vHash := sha256.New()

	// Add the path to avoid collisions of directories with the same content
	vHash.Write(binary.BigEndian.AppendUint64([]byte{}, uint64(len(path))))
	vHash.Write([]byte(path))

	for _, c := range contents {
		vHash.Write([]byte(c.Name())) // Never fails according to the docs
	}

	verify := vHash.Sum(nil)[0:8]

	return binary.BigEndian.Uint64(verify)
}

// VerifierFor returns a cookie-verifier for a directory listing.
func (c *CachingHandler) VerifierFor(path string, contents []fs.FileInfo) uint64 {
	id := hashPathAndContents(path, contents)
	c.activeVerifiers.Add(id, verifier{path, contents})

	return id
}

// DataForVerifier returns the directory listing a verifier was issued for.
func (c *CachingHandler) DataForVerifier(_ string, id uint64) []fs.FileInfo {
	if cache, ok := c.activeVerifiers.Get(id); ok {
		return cache.contents
	}

	return nil
}
