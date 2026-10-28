// Package index runs the Rust repository index through its CLI,
// `gitrochi-index` (contract: crates/gitrochi-index/README.md). The index is
// optional: without the binary the monitor works, minus related files.
package index

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/gitexec"
)

// BinaryName is looked up on PATH when nothing names the binary.
const BinaryName = "gitrochi-index"

// Off in the configuration disables the index.
const Off = "off"

// Environment variables shared with the apps.
const (
	EnvSwitch = "GITROCHI_INDEX"     // "0" turns the index off
	EnvBinary = "GITROCHI_INDEX_BIN" // the binary, when the configuration names none
)

// Find resolves the binary to run, or "" when the index is off or absent.
// GITROCHI_INDEX=0 and a configured "off" turn it off; otherwise the
// configured path, then GITROCHI_INDEX_BIN, must exist; without either,
// gitrochi-index on PATH is used when present.
func Find(configured string, getenv func(string) string) (string, error) {
	if getenv(EnvSwitch) == "0" || configured == Off {
		return "", nil
	}
	explicit := configured
	if explicit == "" {
		explicit = getenv(EnvBinary)
	}
	if explicit == "" {
		p, err := exec.LookPath(BinaryName)
		if err != nil {
			return "", nil
		}
		return p, nil
	}
	p, err := exec.LookPath(explicit)
	if err != nil {
		return "", fmt.Errorf("index binary %s: %w", explicit, err)
	}
	return p, nil
}

// Index runs one binary through the shared process runner, so index runs
// count against the same limit as git (the index runs git itself).
type Index struct {
	Bin     string
	Runner  *gitexec.Runner
	Timeout time.Duration
	// DB overrides the database file; empty uses the repository's shared
	// index (<git common dir>/gitrochi/index.sqlite3), as the apps do.
	DB string
}

// SyncResult is the output of `sync`.
type SyncResult struct {
	Repository   string `json:"repository"`
	Database     string `json:"database"`
	UpToDate     bool   `json:"upToDate"`
	NewCommits   int    `json:"newCommits"`
	TotalCommits int    `json:"totalCommits"`
	Refs         int    `json:"refs"`
	DurationMs   int64  `json:"durationMs"`
	Shallow      bool   `json:"shallow"`
}

// ImpactResult is the output of `impact`.
type ImpactResult struct {
	Changed     []string     `json:"changed"`
	Suggestions []Suggestion `json:"suggestions"`
}

// Suggestion is a file that usually changes with the given ones.
type Suggestion struct {
	Path    string   `json:"path"`
	Score   float64  `json:"score"`
	Because []Reason `json:"because"`
}

// Reason links a suggestion to one of the given paths.
type Reason struct {
	Path       string  `json:"path"`
	Commits    int     `json:"commits"`
	Confidence float64 `json:"confidence"`
}

// Error is an error reported by the index ({"error": {...}} on stdout).
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return "gitrochi-index: " + e.Code + ": " + e.Message }

// Limits for impact arguments: long lists exceed command-line limits (32K
// characters on Windows), and the first paths carry the signal anyway.
const (
	maxImpactPaths = 200
	maxImpactBytes = 16 << 10
)

// Sync brings the repository's index up to date.
func (x *Index) Sync(ctx context.Context, repo string) (SyncResult, error) {
	var out SyncResult
	err := x.run(ctx, repo, []string{"sync"}, &out)
	return out, err
}

// Impact asks which files usually change together with paths. The index
// returns its default number of suggestions; callers trim further.
func (x *Index) Impact(ctx context.Context, repo string, paths []string) (ImpactResult, error) {
	// "--" ends the options, so a path such as "--weird.txt" stays a path.
	args := []string{"impact", "--"}
	size := 0
	for _, p := range paths {
		if len(args)-2 == maxImpactPaths || size+len(p) > maxImpactBytes {
			break
		}
		args = append(args, p)
		size += len(p) + 1
	}
	if len(args) == 2 {
		return ImpactResult{}, nil
	}
	var out ImpactResult
	err := x.run(ctx, repo, args, &out)
	return out, err
}

func (x *Index) run(ctx context.Context, repo string, args []string, out any) error {
	global := []string{"--repo", repo}
	if x.DB != "" {
		global = append(global, "--db", x.DB)
	}
	res, err := x.Runner.Run(ctx, gitexec.Cmd{
		Name:    x.Bin,
		Args:    append(global, args...),
		Dir:     repo,
		Timeout: x.Timeout,
	})
	if err != nil {
		// Exit 1 carries a JSON error on stdout.
		var body struct {
			Error *Error `json:"error"`
		}
		if gitexec.ExitCode(err) == 1 && json.Unmarshal(res.Stdout, &body) == nil && body.Error != nil {
			return body.Error
		}
		if errors.Is(err, os.ErrNotExist) || errors.Is(err, exec.ErrNotFound) {
			return fmt.Errorf("gitrochi-index is not installed at %s", x.Bin)
		}
		return err
	}
	if err := json.Unmarshal(res.Stdout, out); err != nil {
		return fmt.Errorf("gitrochi-index %s printed unreadable JSON: %w", args[0], err)
	}
	return nil
}
