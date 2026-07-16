//go:build linux

package chrooted

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/google/uuid"

	"github.com/e2b-dev/infra/packages/orchestrator/pkg/cfg"
)

var ErrVolumeTypeNotFound = errors.New("volume type not found")

type Builder struct {
	config cfg.Config
}

func NewBuilder(config cfg.Config) *Builder {
	return &Builder{config: config}
}

func (b *Builder) Chroot(ctx context.Context, volumeType string, teamID, volumeID uuid.UUID, source string) (*Chrooted, error) {
	fullPath, err := b.BuildVolumePath(volumeType, teamID, volumeID, source)
	if err != nil {
		return nil, err
	}

	fs, err := Chroot(ctx, fullPath, WithMetadata("volume-id", volumeID.String()))
	if err != nil {
		return nil, err
	}

	return fs, nil
}

// ErrInvalidVolumeSource is returned when a subtree-export source path is empty
// after cleaning or attempts to escape the volume type root.
var ErrInvalidVolumeSource = errors.New("invalid volume source")

// BuildVolumePath resolves the host path an NFS export is chrooted to.
//
//   - source == "": default per-volume UUID path <root>/team-<teamID>/vol-<volumeID>
//     (unchanged legacy behavior).
//   - source != "": subtree-export. Returns <root>/<source> after validating the
//     source is a clean relative path that stays under root (rejects "..",
//     absolute paths, and any traversal that would escape the root).
func (b *Builder) BuildVolumePath(volumeType string, teamID, volumeID uuid.UUID, source string) (string, error) {
	volumeTypeRoot, ok := b.config.PersistentVolumeMounts[volumeType]
	if !ok {
		return "", fmt.Errorf("%w: %q", ErrVolumeTypeNotFound, volumeType)
	}

	if source == "" {
		return filepath.Join(
			volumeTypeRoot,
			fmt.Sprintf("team-%s", teamID),
			fmt.Sprintf("vol-%s", volumeID),
		), nil
	}

	// Reject any '..' segment outright (matches the engine mount-spec contract),
	// then clean relative to root and verify the result stays under root.
	if strings.Contains(source, "..") {
		return "", fmt.Errorf("%w: %q contains %q", ErrInvalidVolumeSource, source, "..")
	}
	// Clean as an absolute path to collapse leading slashes / redundant separators,
	// then re-anchor under the volume type root.
	rel := strings.TrimPrefix(filepath.Clean("/"+source), "/")
	if rel == "" || rel == "." {
		return "", fmt.Errorf("%w: %q resolves to empty path", ErrInvalidVolumeSource, source)
	}

	full := filepath.Join(volumeTypeRoot, rel)
	cleanRoot := filepath.Clean(volumeTypeRoot)
	if full != cleanRoot && !strings.HasPrefix(full, cleanRoot+string(os.PathSeparator)) {
		return "", fmt.Errorf("%w: %q escapes volume root", ErrInvalidVolumeSource, source)
	}

	return full, nil
}
