// Package gitexec runs git, and the index CLI, as child processes: never
// more than a fixed number at once across the whole process, each with a
// timeout, and with the whole process tree killed on timeout or
// cancellation.
package gitexec

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync/atomic"
	"time"
)

// Defaults for Cmd.
const (
	DefaultTimeout   = time.Minute
	DefaultMaxOutput = 64 << 20
	maxStderr        = 64 << 10
)

var (
	// ErrTimeout reports a command killed for running past its timeout.
	ErrTimeout = errors.New("timed out")
	// ErrOutputTooLarge reports output beyond Cmd.MaxOutput.
	ErrOutputTooLarge = errors.New("output too large")
)

// baseEnv keeps background git from waiting on a person: no terminal
// prompts, no credential dialogs, and no optional index lock that would make
// the user's own git commands fail while a status runs.
var baseEnv = []string{
	"GIT_TERMINAL_PROMPT=0",
	"GCM_INTERACTIVE=never",
	"GIT_OPTIONAL_LOCKS=0",
}

// repoEnv would point git at another repository than the one in Cmd.Dir;
// they are set, for example, when the monitor is started from a git hook.
var repoEnv = []string{
	"GIT_DIR=", "GIT_WORK_TREE=", "GIT_INDEX_FILE=", "GIT_COMMON_DIR=", "GIT_OBJECT_DIRECTORY=",
	"GIT_ALTERNATE_OBJECT_DIRECTORIES=", "GIT_NAMESPACE=", "GIT_PREFIX=",
}

func inheritedEnv() []string {
	env := os.Environ()
	return slices.DeleteFunc(env, func(kv string) bool {
		for _, p := range repoEnv {
			if strings.HasPrefix(kv, p) {
				return true
			}
		}
		return false
	})
}

// Runner starts processes under a shared limit. It is safe for concurrent
// use.
type Runner struct {
	git string
	env []string
	sem chan struct{}

	inFlight atomic.Int64
	peak     atomic.Int64
	started  atomic.Int64
	timeouts atomic.Int64
}

// NewRunner returns a runner allowing limit concurrent processes. git is
// the git executable ("" for git on PATH); env is added to every process's
// environment.
func NewRunner(git string, limit int, env []string) *Runner {
	if git == "" {
		git = "git"
	}
	return &Runner{git: git, env: env, sem: make(chan struct{}, max(limit, 1))}
}

// Cmd is one process to run.
type Cmd struct {
	Name      string // executable; "" runs git
	Args      []string
	Dir       string
	Timeout   time.Duration // DefaultTimeout when zero
	MaxOutput int           // stdout bytes kept; DefaultMaxOutput when zero
}

// Result is a finished process's output.
type Result struct {
	Stdout []byte
	Stderr []byte
}

// ExitError is a process that ran and exited with a non-zero status.
type ExitError struct {
	Command string
	Code    int
	Stderr  string
}

func (e *ExitError) Error() string {
	if e.Stderr == "" {
		return fmt.Sprintf("%s: exit status %d", e.Command, e.Code)
	}
	return fmt.Sprintf("%s: exit status %d: %s", e.Command, e.Code, e.Stderr)
}

// ExitCode returns err's exit status, or -1 when err is not an ExitError.
func ExitCode(err error) int {
	var e *ExitError
	if errors.As(err, &e) {
		return e.Code
	}
	return -1
}

// Git runs git in dir and returns its stdout.
func (r *Runner) Git(ctx context.Context, dir string, timeout time.Duration, args ...string) ([]byte, error) {
	res, err := r.Run(ctx, Cmd{Args: args, Dir: dir, Timeout: timeout})
	return res.Stdout, err
}

// Run waits for a free slot, then runs c. A non-zero exit is an
// *ExitError; a timeout wraps ErrTimeout; cancelling ctx kills the process
// and returns ctx's error.
func (r *Runner) Run(ctx context.Context, c Cmd) (Result, error) {
	select {
	case r.sem <- struct{}{}:
	case <-ctx.Done():
		return Result{}, ctx.Err()
	}
	defer func() { <-r.sem }()
	n := r.inFlight.Add(1)
	defer r.inFlight.Add(-1)
	for {
		p := r.peak.Load()
		if n <= p || r.peak.CompareAndSwap(p, n) {
			break
		}
	}
	r.started.Add(1)

	timeout := c.Timeout
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	maxOut := c.MaxOutput
	if maxOut <= 0 {
		maxOut = DefaultMaxOutput
	}
	name := c.Name
	if name == "" {
		name = r.git
	}
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(runCtx, name, c.Args...)
	cmd.Dir = c.Dir
	cmd.Env = append(append(inheritedEnv(), baseEnv...), r.env...)
	stdout := &capBuffer{max: maxOut}
	stderr := &capBuffer{max: maxStderr}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	killTree(cmd)
	// Helpers that escaped the kill may hold the pipes open; stop waiting.
	cmd.WaitDelay = 2 * time.Second

	err := cmd.Run()
	res := Result{Stdout: stdout.buf.Bytes(), Stderr: stderr.buf.Bytes()}
	what := describe(name, c.Args)
	switch {
	case ctx.Err() != nil:
		return res, ctx.Err()
	case errors.Is(runCtx.Err(), context.DeadlineExceeded):
		r.timeouts.Add(1)
		return res, fmt.Errorf("%s: %w after %s", what, ErrTimeout, timeout)
	case err != nil:
		var ee *exec.ExitError
		if errors.As(err, &ee) && ee.Exited() {
			return res, &ExitError{Command: what, Code: ee.ExitCode(), Stderr: cleanStderr(res.Stderr)}
		}
		return res, fmt.Errorf("%s: %w", what, err)
	case stdout.truncated:
		return res, fmt.Errorf("%s: %w (more than %d bytes)", what, ErrOutputTooLarge, maxOut)
	}
	return res, nil
}

// Stats describes the runner.
type Stats struct {
	Limit    int   `json:"limit"`
	InFlight int64 `json:"inFlight"`
	Peak     int64 `json:"peak"`
	Started  int64 `json:"started"`
	Timeouts int64 `json:"timeouts"`
}

// Stats returns current counts. Peak is the most processes ever running at
// once, which never exceeds Limit.
func (r *Runner) Stats() Stats {
	return Stats{
		Limit:    cap(r.sem),
		InFlight: r.inFlight.Load(),
		Peak:     r.peak.Load(),
		Started:  r.started.Load(),
		Timeouts: r.timeouts.Load(),
	}
}

func describe(name string, args []string) string {
	base := filepath.Base(name)
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			return base + " " + a
		}
	}
	return base
}

// capBuffer keeps the first max bytes and discards the rest, so a chatty
// child never blocks on a full pipe.
type capBuffer struct {
	buf       bytes.Buffer
	max       int
	truncated bool
}

func (b *capBuffer) Write(p []byte) (int, error) {
	if room := b.max - b.buf.Len(); len(p) > room {
		if room > 0 {
			b.buf.Write(p[:room])
		}
		b.truncated = true
		return len(p), nil
	}
	return b.buf.Write(p)
}

var credentialsInURL = regexp.MustCompile(`(?i)\b([a-z][a-z0-9+.-]*://)[^/\s@]+@`)

// cleanStderr shortens stderr for an error message and hides credentials
// that git sometimes echoes inside remote URLs.
func cleanStderr(b []byte) string {
	s := strings.TrimSpace(string(b))
	s = credentialsInURL.ReplaceAllString(s, "${1}***@")
	if len(s) > 500 {
		s = s[:500] + "…"
	}
	return s
}
