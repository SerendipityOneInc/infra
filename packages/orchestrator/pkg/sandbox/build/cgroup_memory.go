//go:build linux

package build

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	procSelfCgroupPath = "/proc/self/cgroup"
	cgroupRootPath     = "/sys/fs/cgroup"
)

type cgroupMemoryStats struct {
	Current int64
	Max     int64
	Anon    int64
	File    int64
	Shmem   int64
}

func readSelfCgroupMemory() (cgroupMemoryStats, error) {
	return readCgroupMemory(procSelfCgroupPath, cgroupRootPath)
}

func readCgroupMemory(procCgroupPath, cgroupRoot string) (cgroupMemoryStats, error) {
	cgroupFile, err := os.Open(procCgroupPath)
	if err != nil {
		return cgroupMemoryStats{}, fmt.Errorf("open cgroup membership: %w", err)
	}
	defer cgroupFile.Close()

	var relativePath string
	scanner := bufio.NewScanner(cgroupFile)
	for scanner.Scan() {
		parts := strings.SplitN(scanner.Text(), ":", 3)
		if len(parts) == 3 && parts[0] == "0" && parts[1] == "" {
			relativePath = parts[2]

			break
		}
	}
	if err := scanner.Err(); err != nil {
		return cgroupMemoryStats{}, fmt.Errorf("read cgroup membership: %w", err)
	}
	if relativePath == "" {
		return cgroupMemoryStats{}, fmt.Errorf("cgroup v2 membership not found")
	}

	// Prefix with a slash before cleaning so paths containing ".." cannot
	// escape the cgroup root supplied by the host (or by a test).
	cleanPath := strings.TrimPrefix(filepath.Clean("/"+relativePath), "/")
	memoryPath := filepath.Join(cgroupRoot, cleanPath)

	current, err := readCgroupInt(filepath.Join(memoryPath, "memory.current"))
	if err != nil {
		return cgroupMemoryStats{}, fmt.Errorf("read memory.current: %w", err)
	}

	maxValue, err := os.ReadFile(filepath.Join(memoryPath, "memory.max"))
	if err != nil {
		return cgroupMemoryStats{}, fmt.Errorf("read memory.max: %w", err)
	}
	maxText := strings.TrimSpace(string(maxValue))
	if maxText == "max" {
		return cgroupMemoryStats{Current: current}, nil
	}
	max, err := strconv.ParseInt(maxText, 10, 64)
	if err != nil {
		return cgroupMemoryStats{}, fmt.Errorf("parse memory.max %q: %w", maxText, err)
	}

	stats := cgroupMemoryStats{Current: current, Max: max}
	statFile, err := os.Open(filepath.Join(memoryPath, "memory.stat"))
	if err != nil {
		return cgroupMemoryStats{}, fmt.Errorf("open memory.stat: %w", err)
	}
	defer statFile.Close()

	scanner = bufio.NewScanner(statFile)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) != 2 {
			continue
		}

		value, parseErr := strconv.ParseInt(fields[1], 10, 64)
		if parseErr != nil {
			return cgroupMemoryStats{}, fmt.Errorf("parse memory.stat %s value %q: %w", fields[0], fields[1], parseErr)
		}

		switch fields[0] {
		case "anon":
			stats.Anon = value
		case "file":
			stats.File = value
		case "shmem":
			stats.Shmem = value
		}
	}
	if err := scanner.Err(); err != nil {
		return cgroupMemoryStats{}, fmt.Errorf("read memory.stat: %w", err)
	}

	return stats, nil
}

func readCgroupInt(path string) (int64, error) {
	value, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}

	result, err := strconv.ParseInt(strings.TrimSpace(string(value)), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse %q: %w", strings.TrimSpace(string(value)), err)
	}

	return result, nil
}
