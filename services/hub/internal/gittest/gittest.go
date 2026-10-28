// Package gittest builds hermetic git repositories for tests: git never
// reads the system or the user's configuration, and the identity is set
// inside each fixture repository.
package gittest

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Env returns environment entries that isolate git from the machine's
// configuration: no system config, an empty global config, and a temporary
// HOME.
func Env(t testing.TB) []string {
	t.Helper()
	home := t.TempDir()
	global := filepath.Join(home, "gitconfig")
	if err := os.WriteFile(global, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	return []string{
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL=" + global,
		"HOME=" + home,
		"XDG_CONFIG_HOME=" + filepath.Join(home, ".config"),
	}
}

// Repo is a fixture repository.
type Repo struct {
	t   testing.TB
	Dir string
	Env []string
}

// Init creates a repository with branch main in a temporary directory.
func Init(t testing.TB, env []string) *Repo {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	r := &Repo{t: t, Dir: t.TempDir(), Env: env}
	r.Git("init", "-q", "-b", "main")
	r.Git("config", "user.name", "Gitrochi Test")
	r.Git("config", "user.email", "test@example.com")
	r.Git("config", "commit.gpgsign", "false")
	return r
}

// Git runs git in the repository and returns its trimmed stdout.
func (r *Repo) Git(args ...string) string {
	r.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = r.Dir
	cmd.Env = append(cleanEnv(), r.Env...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		r.t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, stderr.String())
	}
	return strings.TrimSpace(string(out))
}

// Write writes a file relative to the work tree.
func (r *Repo) Write(path, content string) {
	r.t.Helper()
	full := filepath.Join(r.Dir, filepath.FromSlash(path))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		r.t.Fatal(err)
	}
}

// Commit writes files, commits everything and returns the new HEAD.
func (r *Repo) Commit(message string, files map[string]string) string {
	r.t.Helper()
	for p, c := range files {
		r.Write(p, c)
	}
	r.Git("add", "-A")
	r.Git("commit", "-q", "--allow-empty", "-m", message)
	return r.Git("rev-parse", "HEAD")
}

// cleanEnv drops variables that would point git at another repository.
func cleanEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "GIT_") {
			continue
		}
		env = append(env, kv)
	}
	return env
}
