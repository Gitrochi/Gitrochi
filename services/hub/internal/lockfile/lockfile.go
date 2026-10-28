// Package lockfile holds an exclusive lock on a data directory, so only one
// process at a time owns its journal. The operating system releases the lock
// when the process exits, so a crash never leaves a stale lock behind (except
// on the few systems that fall back to an exclusive-create lock file).
package lockfile

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

// ErrLocked reports that another process holds the lock.
var ErrLocked = errors.New("locked by another process")

// Lock is a held lock.
type Lock struct {
	f    *os.File
	path string
}

// Acquire takes the lock at path without waiting. When another process holds
// it, the error wraps ErrLocked and names that process when it can.
func Acquire(path string) (*Lock, error) {
	f, err := lock(path)
	if errors.Is(err, ErrLocked) {
		if holder := readHolder(path); holder != "" {
			return nil, fmt.Errorf("%s: %w (%s)", path, ErrLocked, holder)
		}
		return nil, fmt.Errorf("%s: %w", path, ErrLocked)
	}
	if err != nil {
		return nil, err
	}
	// The holder's pid helps whoever is refused to find the process.
	if err := f.Truncate(0); err == nil {
		_, _ = f.WriteAt(fmt.Appendf(nil, "pid %d\n", os.Getpid()), 0)
	}
	return &Lock{f: f, path: path}, nil
}

// Release gives the lock up.
func (l *Lock) Release() error {
	if l == nil || l.f == nil {
		return nil
	}
	err := unlock(l.f, l.path)
	l.f = nil
	return err
}

func readHolder(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	s := strings.TrimSpace(string(b))
	if len(s) > 64 || !strings.HasPrefix(s, "pid ") {
		return ""
	}
	return "held by " + s
}
