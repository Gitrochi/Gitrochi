package gitinfo

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/gitexec"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/gittest"
)

func TestParseStatus(t *testing.T) {
	out := strings.Join([]string{
		"# branch.oid 1234567890abcdef1234567890abcdef12345678",
		"# branch.head feature/x",
		"# branch.upstream origin/feature/x",
		"# branch.ab +2 -1",
		"1 .M N... 100644 100644 100644 aaaa bbbb src/a b.go",
		"2 R. N... 100644 100644 100644 aaaa bbbb R100 new.go", "old.go",
		"u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict.go",
		"? untracked.txt",
		"",
	}, "\x00")
	st, err := ParseStatus([]byte(out))
	if err != nil {
		t.Fatal(err)
	}
	want := Status{
		Head: "1234567890abcdef1234567890abcdef12345678", Branch: "feature/x", Upstream: "origin/feature/x",
		Ahead: 2, Behind: 1, Dirty: []string{"conflict.go", "new.go", "old.go", "src/a b.go"},
		Staged: 1, Unstaged: 1, Conflicts: 1,
	}
	if !reflect.DeepEqual(st, want) {
		t.Fatalf("got  %+v\nwant %+v", st, want)
	}
	st, err = ParseStatus([]byte("# branch.oid (initial)\x00# branch.head (detached)\x00"))
	if err != nil || st.Head != "" || !st.Detached || st.Branch != "" {
		t.Fatalf("initial detached: %+v, %v", st, err)
	}
	for _, bad := range []string{"1 .M short", "2 R. N... 1 2 3 a b R100 new.go", "# branch.ab +x -1", "Z what"} {
		if _, err := ParseStatus([]byte(bad + "\x00")); err == nil {
			t.Errorf("ParseStatus(%q) accepted", bad)
		}
	}
}

func TestParseRefsAndDiff(t *testing.T) {
	refs, err := ParseRefs([]byte("aaaa\x00refs/heads/main\x00\nbbbb\x00refs/remotes/origin/HEAD\x00refs/remotes/origin/main\n"))
	if err != nil || len(refs) != 2 || refs["refs/remotes/origin/HEAD"].Symref != "refs/remotes/origin/main" {
		t.Fatalf("ParseRefs = %+v, %v", refs, err)
	}
	if _, err := ParseRefs([]byte("zzzz\x00refs/heads/x\x00\n")); err == nil {
		t.Fatal("a non-hex object must be refused")
	}
	got := DiffRefs(
		map[string]string{"refs/heads/a": "1", "refs/heads/b": "2", "refs/heads/c": "3"},
		map[string]string{"refs/heads/a": "1", "refs/heads/b": "4", "refs/heads/d": "5"},
	)
	want := []RefChange{
		{Ref: "refs/heads/b", Kind: Updated, Old: "2", New: "4"},
		{Ref: "refs/heads/c", Kind: Deleted, Old: "3"},
		{Ref: "refs/heads/d", Kind: Created, New: "5"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("DiffRefs = %+v", got)
	}
}

func snapshot(t *testing.T, g *Git) map[string]string {
	t.Helper()
	refs, err := g.Refs(context.Background(), "refs/heads/")
	if err != nil {
		t.Fatal(err)
	}
	out := make(map[string]string)
	for name, r := range refs {
		out[name] = r.Object
	}
	return out
}

func TestRefChangesAndForcedUpdatesInARealRepository(t *testing.T) {
	env := gittest.Env(t)
	repo := gittest.Init(t, env)
	g := &Git{Runner: gitexec.NewRunner("", 4, env), Dir: repo.Dir, Timeout: time.Minute}
	ctx := context.Background()

	a := repo.Commit("first", map[string]string{"src/api.go": "v1\n", "README.md": "hello\n"})
	repo.Git("branch", "gone")
	repo.Git("switch", "-q", "-c", "feature")
	b := repo.Commit("second", map[string]string{"src/api.go": "v2\n"})
	s1 := snapshot(t, g)
	if s1["refs/heads/main"] != a || s1["refs/heads/feature"] != b || len(s1) != 3 {
		t.Fatalf("snapshot %v", s1)
	}

	c := repo.Commit("third", map[string]string{"src/api.go": "v3\n"})
	s2 := snapshot(t, g)
	changes := DiffRefs(s1, s2)
	if err := g.MarkForced(ctx, changes); err != nil {
		t.Fatal(err)
	}
	if len(changes) != 1 || changes[0].Kind != Updated || changes[0].Old != b || changes[0].New != c || changes[0].Forced {
		t.Fatalf("fast-forward: %+v", changes)
	}

	// Rewrite feature (reset and recommit), delete one branch, add another.
	repo.Git("reset", "-q", "--hard", a)
	d := repo.Commit("rewritten", map[string]string{"src/db.go": "db\n"})
	repo.Git("branch", "-D", "gone")
	repo.Git("branch", "fresh", "main")
	changes = DiffRefs(s2, snapshot(t, g))
	if err := g.MarkForced(ctx, changes); err != nil {
		t.Fatal(err)
	}
	want := []RefChange{
		{Ref: "refs/heads/feature", Kind: Updated, Old: c, New: d, Forced: true},
		{Ref: "refs/heads/fresh", Kind: Created, New: a},
		{Ref: "refs/heads/gone", Kind: Deleted, Old: a},
	}
	if !reflect.DeepEqual(changes, want) {
		t.Fatalf("changes\n got  %+v\n want %+v", changes, want)
	}
	if ff, err := g.IsAncestor(ctx, strings.Repeat("0", 40), d); err != nil || ff {
		t.Fatalf("a missing old tip: %v, %v; want not an ancestor, no error", ff, err)
	}

	mb, err := g.MergeBase(ctx, "main", "HEAD")
	if err != nil || mb != a {
		t.Fatalf("MergeBase = %q, %v", mb, err)
	}
	files, err := g.ChangedBetween(ctx, mb, "HEAD")
	if err != nil || !reflect.DeepEqual(files, []string{"src/db.go"}) {
		t.Fatalf("ChangedBetween = %v, %v", files, err)
	}

	repo.Write("README.md", "changed\n")
	repo.Git("mv", "src/api.go", "src/server.go")
	st, err := g.Status(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Branch != "feature" || st.Head != d || st.Staged != 1 || st.Unstaged != 1 ||
		!reflect.DeepEqual(st.Dirty, []string{"README.md", "src/api.go", "src/server.go"}) {
		t.Fatalf("status %+v", st)
	}

	repo.Git("reset", "-q", "--hard")
	repo.Git("switch", "-q", "--orphan", "unrelated")
	repo.Commit("orphan", map[string]string{"other.txt": "x\n"})
	if mb, err := g.MergeBase(ctx, "main", "HEAD"); err != nil || mb != "" {
		t.Fatalf("unrelated histories: %q, %v", mb, err)
	}

	repo.Git("remote", "add", "origin", "https://example.com/team/app.git")
	if u, err := g.RemoteURL(ctx, "origin"); err != nil || u != "https://example.com/team/app.git" {
		t.Fatalf("RemoteURL = %q, %v", u, err)
	}
	if _, err := g.RemoteURL(ctx, "upstream"); err == nil {
		t.Fatal("a missing remote must be an error")
	}
	sub := filepath.Join(repo.Dir, "nested")
	os.MkdirAll(sub, 0o755)
	top, err := TopLevel(ctx, g.Runner, sub, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	wantTop, _ := filepath.EvalSymlinks(repo.Dir)
	if gotTop, _ := filepath.EvalSymlinks(top); gotTop != wantTop {
		t.Fatalf("TopLevel = %q, want %q", gotTop, wantTop)
	}
}
