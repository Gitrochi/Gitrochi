//go:build unix

package gitexec

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// A timed-out git must take its helpers down with it: the fake starts a
// child that holds the output pipe and would outlive a kill of the parent
// alone (Wait would then hang until WaitDelay).
func TestTimeoutKillsTheWholeProcessTree(t *testing.T) {
	dir := t.TempDir()
	r := NewRunner(script(t, `[ "$1" = warm ] && exit 0
sleep 30 &
echo $! > "$FAKE_DIR/child.pid"
wait
`), 1, []string{"FAKE_DIR=" + dir})
	// The first run of a new executable can be slow (malware scanning on
	// macOS); get it out of the timed run.
	if _, err := r.Git(context.Background(), dir, time.Minute, "warm"); err != nil {
		t.Fatal(err)
	}
	const timeout = 500 * time.Millisecond
	began := time.Now()
	_, err := r.Git(context.Background(), dir, timeout, "fetch")
	if !errors.Is(err, ErrTimeout) {
		t.Fatalf("err = %v, want ErrTimeout", err)
	}
	if d := time.Since(began); d > timeout+time.Second {
		t.Fatalf("took %v: Wait hung on the child holding the pipes", d)
	}
	if r.Stats().Timeouts != 1 {
		t.Fatal("timeout not counted")
	}
	b, err := os.ReadFile(filepath.Join(dir, "child.pid"))
	if err != nil {
		t.Fatal(err)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	deadline := time.Now().Add(3 * time.Second)
	for syscall.Kill(pid, 0) == nil {
		if time.Now().After(deadline) {
			syscall.Kill(pid, syscall.SIGKILL)
			t.Fatalf("child %d survived the timeout", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}
