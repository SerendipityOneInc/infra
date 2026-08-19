//go:build linux

package build

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestReadCgroupMemory(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	procPath := filepath.Join(root, "proc-self-cgroup")
	cgroupRoot := filepath.Join(root, "cgroup")
	memoryPath := filepath.Join(cgroupRoot, "nomad", "alloc", "task")
	require.NoError(t, os.MkdirAll(memoryPath, 0o755))
	require.NoError(t, os.WriteFile(procPath, []byte("0::/nomad/alloc/task\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(memoryPath, "memory.current"), []byte("900\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(memoryPath, "memory.max"), []byte("1000\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(memoryPath, "memory.stat"), []byte("anon 100\nfile 700\nshmem 50\n"), 0o600))

	stats, err := readCgroupMemory(procPath, cgroupRoot)
	require.NoError(t, err)
	assert.Equal(t, cgroupMemoryStats{Current: 900, Max: 1000, Anon: 100, File: 700, Shmem: 50}, stats)
}

func TestReadCgroupMemoryUnbounded(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	procPath := filepath.Join(root, "proc-self-cgroup")
	cgroupRoot := filepath.Join(root, "cgroup")
	require.NoError(t, os.MkdirAll(cgroupRoot, 0o755))
	require.NoError(t, os.WriteFile(procPath, []byte("0::/\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(cgroupRoot, "memory.current"), []byte("123\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(cgroupRoot, "memory.max"), []byte("max\n"), 0o600))

	stats, err := readCgroupMemory(procPath, cgroupRoot)
	require.NoError(t, err)
	assert.Equal(t, cgroupMemoryStats{Current: 123}, stats)
}

func TestReadCgroupMemoryRequiresV2(t *testing.T) {
	t.Parallel()

	procPath := filepath.Join(t.TempDir(), "proc-self-cgroup")
	require.NoError(t, os.WriteFile(procPath, []byte("5:memory:/nomad/task\n"), 0o600))

	_, err := readCgroupMemory(procPath, t.TempDir())
	require.ErrorContains(t, err, "cgroup v2 membership not found")
}
