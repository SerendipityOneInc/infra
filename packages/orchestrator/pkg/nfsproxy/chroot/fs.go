//go:build linux

package chroot

import (
	"os"
	"syscall"

	"github.com/go-git/go-billy/v5"

	"github.com/e2b-dev/infra/packages/orchestrator/pkg/chrooted"
)

type wrappedFS struct {
	chroot *chrooted.Chrooted
	// readOnly enforces read-only at the host NFS proxy, independent of the
	// guest's mount flags. All mutating operations return EROFS.
	readOnly bool
}

func (f *wrappedFS) Create(filename string) (billy.File, error) {
	if f.readOnly {
		return nil, syscall.EROFS
	}

	result, err := f.chroot.Create(filename)

	return maybeWrap(result), err
}

func (f *wrappedFS) Open(filename string) (billy.File, error) {
	result, err := f.chroot.Open(filename)

	return maybeWrap(result), err
}

func (f *wrappedFS) OpenFile(filename string, flag int, perm os.FileMode) (billy.File, error) {
	if f.readOnly && flag&(os.O_WRONLY|os.O_RDWR|os.O_CREATE|os.O_TRUNC|os.O_APPEND) != 0 {
		return nil, syscall.EROFS
	}

	result, err := f.chroot.OpenFile(filename, flag, perm)

	return maybeWrap(result), err
}

func (f *wrappedFS) Stat(filename string) (os.FileInfo, error) {
	return f.chroot.Stat(filename)
}

func (f *wrappedFS) Rename(oldpath, newpath string) error {
	if f.readOnly {
		return syscall.EROFS
	}

	return f.chroot.Rename(oldpath, newpath)
}

func (f *wrappedFS) Remove(filename string) error {
	if f.readOnly {
		return syscall.EROFS
	}

	return f.chroot.Remove(filename)
}

func (f *wrappedFS) Join(elem ...string) string {
	return f.chroot.Join(elem...)
}

func (f *wrappedFS) TempFile(dir, prefix string) (billy.File, error) {
	if f.readOnly {
		return nil, syscall.EROFS
	}

	result, err := f.chroot.TempFile(dir, prefix)

	return maybeWrap(result), err
}

func (f *wrappedFS) ReadDir(path string) ([]os.FileInfo, error) {
	return f.chroot.ReadDir(path)
}

func (f *wrappedFS) MkdirAll(filename string, perm os.FileMode) error {
	if f.readOnly {
		return syscall.EROFS
	}

	return f.chroot.MkdirAll(filename, perm)
}

func (f *wrappedFS) Lstat(filename string) (os.FileInfo, error) {
	return f.chroot.Lstat(filename)
}

func (f *wrappedFS) Symlink(target, link string) error {
	if f.readOnly {
		return syscall.EROFS
	}

	return f.chroot.Symlink(target, link)
}

func (f *wrappedFS) Readlink(link string) (string, error) {
	return f.chroot.Readlink(link)
}

func (f *wrappedFS) Chroot(_ string) (billy.Filesystem, error) {
	return nil, os.ErrPermission
}

func (f *wrappedFS) Root() string {
	return f.chroot.Root()
}

var _ billy.Filesystem = (*wrappedFS)(nil)

func wrapChrooted(chroot *chrooted.Chrooted, readOnly bool) *wrappedFS {
	return &wrappedFS{chroot: chroot, readOnly: readOnly}
}
