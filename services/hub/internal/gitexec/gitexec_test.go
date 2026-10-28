package gitexec

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// script writes an executable shell script and returns its path.
func script(t *testing.T, body string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the fake commands are shell scripts")
	}
	path := filepath.Join(t.TempDir(), "fake")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// The fake command counts how many copies of itself run at once, from the
// outside: each marks itself in a directory while it runs.
const countingScript = `mkdir "$FAKE_DIR/run.$$"
ls -d "$FAKE_DIR"/run.* | wc -l >> "$FAKE_DIR/counts"
sleep 0.2
rmdir "$FAKE_DIR/run.$$"
`

func TestConcurrentProcessesNeverExceedTheLimit(t *testing.T) {
	dir := t.TempDir()
	r := NewRunner(script(t, countingScript), 3, []string{"FAKE_DIR=" + dir})
	var wg sync.WaitGroup
	for range 12 {
		wg.Go(func() {
			if _, err := r.Git(context.Background(), dir, 10*time.Second, "status"); err != nil {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	b, err := os.ReadFile(filepath.Join(dir, "counts"))
	if err != nil {
		t.Fatal(err)
	}
	most := 0
	for _, f := range strings.Fields(string(b)) {
		n, _ := strconv.Atoi(f)
		most = max(most, n)
	}
	if most > 3 {
		t.Fatalf("%d processes ran at once; the limit is 3", most)
	}
	if most < 2 {
		t.Fatalf("at most %d process ran at once; the pool should run them in parallel", most)
	}
	st := r.Stats()
	if st.Peak > 3 || st.Started != 12 || st.InFlight != 0 || st.Limit != 3 {
		t.Fatalf("stats %+v", st)
	}
}

func TestExitErrorKeepsCodeAndHidesCredentials(t *testing.T) {
	r := NewRunner(script(t, `echo "fatal: unable to access 'https://user:s3cret@example.com/team/app.git/'" >&2
exit 3
`), 1, nil)
	_, err := r.Git(context.Background(), t.TempDir(), time.Minute, "fetch", "origin")
	var ee *ExitError
	if !errors.As(err, &ee) || ee.Code != 3 || ExitCode(err) != 3 {
		t.Fatalf("err = %v", err)
	}
	if strings.Contains(err.Error(), "s3cret") || !strings.Contains(err.Error(), "https://***@example.com") {
		t.Fatalf("stderr not redacted: %v", err)
	}
	if !strings.HasPrefix(ee.Command, "fake fetch") {
		t.Fatalf("command %q", ee.Command)
	}
	if ExitCode(errors.New("x")) != -1 || ExitCode(nil) != -1 {
		t.Fatal("ExitCode of other errors")
	}
}

func TestOutputLimit(t *testing.T) {
	r := NewRunner(script(t, `i=0; while [ $i -lt 100 ]; do printf 0123456789; i=$((i+1)); done`), 1, nil)
	res, err := r.Run(context.Background(), Cmd{Dir: t.TempDir(), MaxOutput: 50})
	if !errors.Is(err, ErrOutputTooLarge) || len(res.Stdout) != 50 {
		t.Fatalf("err %v, %d bytes", err, len(res.Stdout))
	}
}

func TestCancelWhileWaitingForASlot(t *testing.T) {
	r := NewRunner(script(t, "sleep 2\n"), 1, nil)
	go r.Git(context.Background(), t.TempDir(), time.Minute, "x")
	for r.Stats().InFlight == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	began := time.Now()
	if _, err := r.Git(ctx, t.TempDir(), time.Minute, "y"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v", err)
	}
	if time.Since(began) > time.Second {
		t.Fatal("a waiting caller must give up when its context ends")
	}
}

func TestInheritedRepositoryVariablesAreDropped(t *testing.T) {
	t.Setenv("GIT_DIR", "/elsewhere/.git")
	t.Setenv("GIT_WORK_TREE", "/elsewhere")
	r := NewRunner(script(t, `printf '%s|%s|%s' "$GIT_DIR" "$GIT_WORK_TREE" "$GIT_TERMINAL_PROMPT"`), 1, nil)
	out, err := r.Git(context.Background(), t.TempDir(), time.Minute, "x")
	if err != nil || string(out) != "||0" {
		t.Fatalf("out %q, %v", out, err)
	}
}
