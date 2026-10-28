package index

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/gitexec"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/gittest"
)

// fakeScript imitates the CLI contract and logs its arguments next to
// itself.
const fakeScript = `#!/bin/sh
printf '%s\n' "$*" >> "$(dirname "$0")/calls"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--db) shift 2 ;;
    --pretty) shift ;;
    *) break ;;
  esac
done
cmd=$1; shift
[ "$1" = -- ] && shift
case "$cmd" in
  sync) echo '{"repository":"/r","database":"/r/index.sqlite3","upToDate":false,"newCommits":3,"totalCommits":3,"refs":2,"durationMs":4,"shallow":false}' ;;
  impact)
    if [ "$1" = boom ]; then
      echo '{"error":{"code":"NOT_A_REPOSITORY","message":"not a git repository"}}'
      exit 1
    fi
    if [ "$1" = garbage ]; then echo 'not json'; exit 0; fi
    echo '{"changed":["src/api.go"],"suggestions":[{"path":"docs/api.md","score":0.9,"because":[{"path":"src/api.go","commits":4,"confidence":0.8}]}]}' ;;
  *) exit 2 ;;
esac
`

func fake(t *testing.T, name string) (bin, calls string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the fake index is a shell script")
	}
	dir := t.TempDir()
	bin = filepath.Join(dir, name)
	if err := os.WriteFile(bin, []byte(fakeScript), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, filepath.Join(dir, "calls")
}

func TestSyncAndImpactFollowTheContract(t *testing.T) {
	bin, calls := fake(t, "gitrochi-index")
	x := &Index{Bin: bin, Runner: gitexec.NewRunner("", 1, nil), Timeout: time.Minute, DB: "/data/index.sqlite3"}
	repo := t.TempDir()
	ctx := context.Background()
	res, err := x.Sync(ctx, repo)
	if err != nil || res.TotalCommits != 3 || res.NewCommits != 3 || res.UpToDate {
		t.Fatalf("Sync = %+v, %v", res, err)
	}
	imp, err := x.Impact(ctx, repo, []string{"src/api.go", "--weird.txt", "docs/guide.md"})
	if err != nil || len(imp.Suggestions) != 1 || imp.Suggestions[0].Path != "docs/api.md" || imp.Suggestions[0].Because[0].Confidence != 0.8 {
		t.Fatalf("Impact = %+v, %v", imp, err)
	}
	b, _ := os.ReadFile(calls)
	want := "--repo " + repo + " --db /data/index.sqlite3 sync\n" +
		"--repo " + repo + " --db /data/index.sqlite3 impact -- src/api.go --weird.txt docs/guide.md\n"
	if string(b) != want {
		t.Fatalf("calls:\n%s\nwant:\n%s", b, want)
	}
	if imp, err := x.Impact(ctx, repo, nil); err != nil || len(imp.Suggestions) != 0 {
		t.Fatal("nothing to ask must not run the index")
	}
	if b2, _ := os.ReadFile(calls); string(b2) != want {
		t.Fatal("an empty impact ran the index")
	}
	// Long lists are cut to stay under command-line limits.
	many := make([]string, 0, 300)
	for i := range 300 {
		many = append(many, fmt.Sprintf("src/file%03d.go", i))
	}
	if _, err := x.Impact(ctx, repo, many); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(calls)
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if n := len(strings.Fields(lines[len(lines)-1])) - 6; n != maxImpactPaths {
		t.Fatalf("passed %d paths, want the first %d", n, maxImpactPaths)
	}
}

func TestErrors(t *testing.T) {
	bin, _ := fake(t, "gitrochi-index")
	x := &Index{Bin: bin, Runner: gitexec.NewRunner("", 1, nil)}
	_, err := x.Impact(context.Background(), t.TempDir(), []string{"boom"})
	var ie *Error
	if !errors.As(err, &ie) || ie.Code != "NOT_A_REPOSITORY" {
		t.Fatalf("err = %v, want the index's JSON error", err)
	}
	if _, err := x.Impact(context.Background(), t.TempDir(), []string{"garbage"}); err == nil || !strings.Contains(err.Error(), "unreadable JSON") {
		t.Fatalf("garbage output: %v", err)
	}
}

func TestFind(t *testing.T) {
	bin, _ := fake(t, "gitrochi-index")
	env := func(kv map[string]string) func(string) string {
		return func(k string) string { return kv[k] }
	}
	none := env(nil)
	t.Setenv("PATH", t.TempDir()) // no gitrochi-index on PATH
	if got, err := Find("", none); got != "" || err != nil {
		t.Fatalf("absent from PATH: %q, %v", got, err)
	}
	if got, err := Find(bin, none); got != bin || err != nil {
		t.Fatalf("configured: %q, %v", got, err)
	}
	if got, err := Find("", env(map[string]string{EnvBinary: bin})); got != bin || err != nil {
		t.Fatalf("GITROCHI_INDEX_BIN: %q, %v", got, err)
	}
	if _, err := Find(filepath.Join(t.TempDir(), "missing"), none); err == nil {
		t.Fatal("a configured binary that does not exist must be an error")
	}
	if _, err := Find("", env(map[string]string{EnvBinary: "/nonexistent/gitrochi-index"})); err == nil {
		t.Fatal("a GITROCHI_INDEX_BIN that does not exist must be an error")
	}
	off := env(map[string]string{EnvSwitch: "0", EnvBinary: bin})
	if got, err := Find(bin, off); got != "" || err != nil {
		t.Fatalf("GITROCHI_INDEX=0 must turn the index off: %q, %v", got, err)
	}
	if got, _ := Find(Off, none); got != "" {
		t.Fatal(`"off" must turn the index off`)
	}
	t.Setenv("PATH", filepath.Dir(bin))
	if got, err := Find("", none); got != bin || err != nil {
		t.Fatalf("on PATH: %q, %v", got, err)
	}
}

// realBinary finds a built gitrochi-index: GITROCHI_INDEX_BIN, or the
// workspace's release build.
func realBinary(t *testing.T) string {
	t.Helper()
	candidates := []string{os.Getenv(EnvBinary)}
	name := "gitrochi-index"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	candidates = append(candidates, filepath.Join("..", "..", "..", "..", "crates", "target", "release", name))
	for _, c := range candidates {
		if c == "" {
			continue
		}
		if abs, err := filepath.Abs(c); err == nil {
			if fi, err := os.Stat(abs); err == nil && !fi.IsDir() {
				return abs
			}
		}
	}
	t.Skip("no gitrochi-index binary (build crates/gitrochi-index or set GITROCHI_INDEX_BIN)")
	return ""
}

func TestRealBinaryFindsFilesThatChangeTogether(t *testing.T) {
	bin := realBinary(t)
	env := gittest.Env(t)
	repo := gittest.Init(t, env)
	for i, v := range []string{"1", "2", "3"} {
		repo.Commit("api change "+v, map[string]string{"src/api.go": "v" + v + "\n", "docs/api.md": "doc " + v + "\n"})
		if i == 0 {
			repo.Commit("readme", map[string]string{"README.md": "hello\n"})
		}
		// A path that looks like an option, changing with the guide.
		repo.Commit("odd "+v, map[string]string{"--weird.txt": v + "\n", "docs/guide.md": v + "\n"})
	}
	db := filepath.Join(t.TempDir(), "index.sqlite3")
	x := &Index{Bin: bin, Runner: gitexec.NewRunner("", 2, env), Timeout: time.Minute, DB: db}
	ctx := context.Background()
	res, err := x.Sync(ctx, repo.Dir)
	if err != nil {
		t.Fatal(err)
	}
	if res.TotalCommits != 7 || res.NewCommits != 7 {
		t.Fatalf("Sync = %+v", res)
	}
	if again, err := x.Sync(ctx, repo.Dir); err != nil || again.NewCommits != 0 {
		t.Fatalf("second Sync = %+v, %v; want nothing new", again, err)
	}
	imp, err := x.Impact(ctx, repo.Dir, []string{"src/api.go"})
	if err != nil {
		t.Fatal(err)
	}
	paths := make([]string, 0, len(imp.Suggestions))
	for _, s := range imp.Suggestions {
		paths = append(paths, s.Path)
	}
	if !slices.Contains(paths, "docs/api.md") || slices.Contains(paths, "src/api.go") {
		t.Fatalf("suggestions %v, want docs/api.md and not the asked path", paths)
	}
	odd, err := x.Impact(ctx, repo.Dir, []string{"--weird.txt"})
	if err != nil {
		t.Fatalf("a path that looks like an option: %v", err)
	}
	if len(odd.Suggestions) == 0 || odd.Suggestions[0].Path != "docs/guide.md" {
		t.Fatalf("suggestions for --weird.txt: %+v", odd.Suggestions)
	}
	if _, err := os.Stat(db); err != nil {
		t.Fatalf("the index was not written to --db: %v", err)
	}
	if _, err := os.Stat(filepath.Join(repo.Dir, ".git", "gitrochi")); !os.IsNotExist(err) {
		t.Fatal("the index wrote into the repository's .git despite --db")
	}
}
