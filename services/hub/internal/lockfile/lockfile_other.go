//go:build !(darwin || dragonfly || freebsd || illumos || linux || netbsd || openbsd || windows)

package lockfile

import (
	"errors"
	"os"
)

// lock falls back to an exclusive create. A crash leaves the file behind;
// remove it once no process uses the directory.
func lock(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		return nil, ErrLocked
	}
	return f, err
}

func unlock(f *os.File, path string) error {
	err := f.Close()
	if rerr := os.Remove(path); err == nil {
		err = rerr
	}
	return err
}
