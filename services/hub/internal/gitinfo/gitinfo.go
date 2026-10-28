// Package gitinfo reads repository state from git's machine-readable
// output. It only reads, except for Fetch, which updates remote-tracking
// refs the way `git fetch` does.
package gitinfo

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/gitexec"
)

// Git runs read-only git commands in one repository.
type Git struct {
	Runner  *gitexec.Runner
	Dir     string        // the work tree's top level
	Timeout time.Duration // per command
}

func (g *Git) run(ctx context.Context, args ...string) ([]byte, error) {
	return g.Runner.Git(ctx, g.Dir, g.Timeout, args...)
}

// TopLevel returns the top-level directory of the work tree containing dir.
func TopLevel(ctx context.Context, r *gitexec.Runner, dir string, timeout time.Duration) (string, error) {
	out, err := r.Git(ctx, dir, timeout, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// Ref is one ref.
type Ref struct {
	Name   string
	Object string
	Symref string // target of a symbolic ref such as refs/remotes/origin/HEAD
}

const refFormat = "%(objectname)%00%(refname)%00%(symref)"

// Refs lists the refs under the given prefixes (refs/heads/ …).
func (g *Git) Refs(ctx context.Context, prefixes ...string) (map[string]Ref, error) {
	out, err := g.run(ctx, append([]string{"for-each-ref", "--format=" + refFormat}, prefixes...)...)
	if err != nil {
		return nil, err
	}
	return ParseRefs(out)
}

// ParseRefs parses `git for-each-ref --format=` + refFormat output.
func ParseRefs(out []byte) (map[string]Ref, error) {
	refs := make(map[string]Ref)
	for line := range strings.SplitSeq(string(out), "\n") {
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\x00")
		if len(parts) != 3 || !isHex(parts[0]) || !strings.HasPrefix(parts[1], "refs/") {
			return nil, fmt.Errorf("unexpected for-each-ref line %q", shorten(line))
		}
		refs[parts[1]] = Ref{Name: parts[1], Object: parts[0], Symref: parts[2]}
	}
	return refs, nil
}

// Status is the state of HEAD and the work tree.
type Status struct {
	Head      string // HEAD commit; "" before the first commit
	Branch    string // "" when HEAD is detached
	Detached  bool
	Upstream  string
	Ahead     int // commits on HEAD that the upstream lacks
	Behind    int // commits on the upstream that HEAD lacks
	Dirty     []string
	Staged    int
	Unstaged  int
	Conflicts int
}

// Status reads `git status --porcelain=v2 --branch -z` for tracked files.
func (g *Git) Status(ctx context.Context) (Status, error) {
	out, err := g.run(ctx, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no")
	if err != nil {
		return Status{}, err
	}
	return ParseStatus(out)
}

// ParseStatus parses `git status --porcelain=v2 --branch -z` output. Dirty
// lists changed tracked paths, sorted; a rename contributes both paths.
func ParseStatus(out []byte) (Status, error) {
	var st Status
	fields := strings.Split(string(out), "\x00")
	for i := 0; i < len(fields); i++ {
		f := fields[i]
		if f == "" {
			continue
		}
		switch f[0] {
		case '#':
			key, val, _ := strings.Cut(strings.TrimPrefix(f, "# "), " ")
			switch key {
			case "branch.oid":
				if val != "(initial)" {
					st.Head = val
				}
			case "branch.head":
				if val == "(detached)" {
					st.Detached = true
				} else {
					st.Branch = val
				}
			case "branch.upstream":
				st.Upstream = val
			case "branch.ab":
				a, b, ok := strings.Cut(val, " ")
				ahead, err1 := strconv.Atoi(strings.TrimPrefix(a, "+"))
				behind, err2 := strconv.Atoi(strings.TrimPrefix(b, "-"))
				if !ok || err1 != nil || err2 != nil {
					return st, fmt.Errorf("unexpected status header %q", shorten(f))
				}
				st.Ahead, st.Behind = ahead, behind
			}
		case '1': // 1 XY sub mH mI mW hH hI path
			parts := strings.SplitN(f, " ", 9)
			if len(parts) != 9 {
				return st, fmt.Errorf("unexpected status entry %q", shorten(f))
			}
			st.count(parts[1])
			st.Dirty = append(st.Dirty, parts[8])
		case '2': // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
			parts := strings.SplitN(f, " ", 10)
			if len(parts) != 10 || i+1 >= len(fields) || fields[i+1] == "" {
				return st, fmt.Errorf("unexpected status entry %q", shorten(f))
			}
			st.count(parts[1])
			i++
			st.Dirty = append(st.Dirty, parts[9], fields[i])
		case 'u': // u XY sub m1 m2 m3 mW h1 h2 h3 path
			parts := strings.SplitN(f, " ", 11)
			if len(parts) != 11 {
				return st, fmt.Errorf("unexpected status entry %q", shorten(f))
			}
			st.Conflicts++
			st.Dirty = append(st.Dirty, parts[10])
		case '?', '!':
			// Untracked and ignored files are not WIP of tracked work.
		default:
			return st, fmt.Errorf("unexpected status entry %q", shorten(f))
		}
	}
	slices.Sort(st.Dirty)
	st.Dirty = slices.Compact(st.Dirty)
	return st, nil
}

func (st *Status) count(xy string) {
	if len(xy) != 2 {
		return
	}
	if xy[0] != '.' {
		st.Staged++
	}
	if xy[1] != '.' {
		st.Unstaged++
	}
}

// MergeBase returns the best common ancestor of a and b, or "" when they
// share no history.
func (g *Git) MergeBase(ctx context.Context, a, b string) (string, error) {
	out, err := g.run(ctx, "merge-base", a, b)
	if err != nil {
		if gitexec.ExitCode(err) == 1 {
			return "", nil
		}
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// ChangedBetween lists the paths that differ between two commits. Renames
// count as a deletion and an addition, so both paths are listed.
func (g *Git) ChangedBetween(ctx context.Context, base, head string) ([]string, error) {
	out, err := g.run(ctx, "diff", "--name-only", "--no-renames", "--no-color", "-z", base, head, "--")
	if err != nil {
		return nil, err
	}
	return SplitNUL(out), nil
}

// IsAncestor reports whether old is an ancestor of new, that is, whether
// moving a ref from old to new is a fast-forward. An old commit that no
// longer exists (pruned after a rewrite) is not an ancestor.
func (g *Git) IsAncestor(ctx context.Context, oldTip, newTip string) (bool, error) {
	_, err := g.run(ctx, "merge-base", "--is-ancestor", oldTip, newTip)
	if err == nil {
		return true, nil
	}
	switch gitexec.ExitCode(err) {
	case 1, 128:
		return false, nil
	}
	return false, err
}

// RemoteURL returns a remote's fetch URL after insteadOf rewriting.
func (g *Git) RemoteURL(ctx context.Context, remote string) (string, error) {
	out, err := g.run(ctx, "remote", "get-url", remote)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// Fetch updates remote's remote-tracking refs and prunes deleted ones. It
// leaves FETCH_HEAD alone and skips automatic gc and maintenance, which are
// the user's business, not a background monitor's.
func (g *Git) Fetch(ctx context.Context, remote string, timeout time.Duration) error {
	_, err := g.Runner.Git(ctx, g.Dir, timeout,
		"-c", "gc.auto=0", "-c", "maintenance.auto=false",
		"fetch", "--prune", "--quiet", "--no-write-fetch-head", remote)
	return err
}

// Ref change kinds.
const (
	Created = "created"
	Updated = "updated"
	Deleted = "deleted"
)

// RefChange is a difference between two ref snapshots.
type RefChange struct {
	Ref    string    `json:"ref"`
	Kind   string    `json:"kind"`
	Old    string    `json:"old,omitempty"`
	New    string    `json:"new,omitempty"`
	Forced bool      `json:"forced"`
	At     time.Time `json:"at,omitzero"`
}

// DiffRefs compares two snapshots (ref name to object) and returns the
// changes sorted by ref. Forced is not set; see MarkForced.
func DiffRefs(old, cur map[string]string) []RefChange {
	var out []RefChange
	for name, obj := range cur {
		prev, ok := old[name]
		switch {
		case !ok:
			out = append(out, RefChange{Ref: name, Kind: Created, New: obj})
		case prev != obj:
			out = append(out, RefChange{Ref: name, Kind: Updated, Old: prev, New: obj})
		}
	}
	for name, obj := range old {
		if _, ok := cur[name]; !ok {
			out = append(out, RefChange{Ref: name, Kind: Deleted, Old: obj})
		}
	}
	slices.SortFunc(out, func(a, b RefChange) int { return strings.Compare(a.Ref, b.Ref) })
	return out
}

// MarkForced sets Forced on updates whose old tip is not an ancestor of the
// new one. The checks run in parallel; the runner bounds the processes.
func (g *Git) MarkForced(ctx context.Context, changes []RefChange) error {
	var wg sync.WaitGroup
	errs := make([]error, len(changes))
	for i := range changes {
		c := &changes[i]
		if c.Kind != Updated {
			continue
		}
		wg.Go(func() {
			ff, err := g.IsAncestor(ctx, c.Old, c.New)
			c.Forced, errs[i] = !ff, err
		})
	}
	wg.Wait()
	for _, err := range errs {
		if err != nil {
			return err
		}
	}
	return nil
}

// SplitNUL splits NUL-terminated output.
func SplitNUL(out []byte) []string {
	var paths []string
	for p := range strings.SplitSeq(string(out), "\x00") {
		if p != "" {
			paths = append(paths, p)
		}
	}
	return paths
}

func isHex(s string) bool {
	if len(s) < 4 {
		return false
	}
	for _, c := range []byte(s) {
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func shorten(s string) string {
	if len(s) > 120 {
		return s[:120] + "…"
	}
	return s
}
