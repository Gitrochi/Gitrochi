// Package presence keeps the soft state of who is working on what, and
// finds where that work overlaps.
//
// Presence is not journaled: clients report it on every poll and entries
// expire after a TTL, so after a restart it is rebuilt within one poll
// interval.
package presence

import (
	"cmp"
	"slices"
	"sync"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
)

type entryKey struct{ member, client string }

// Table holds presence entries by repository. It is safe for concurrent use.
type Table struct {
	mu     sync.Mutex
	byRepo map[string]map[entryKey]api.PresenceEntry
	count  int
}

// NewTable returns an empty table.
func NewTable() *Table {
	return &Table{byRepo: make(map[string]map[entryKey]api.PresenceEntry)}
}

// Set stores e, replacing the member's previous entry for the same client.
func (t *Table) Set(e api.PresenceEntry) {
	t.mu.Lock()
	defer t.mu.Unlock()
	m := t.byRepo[e.Repo]
	if m == nil {
		m = make(map[entryKey]api.PresenceEntry)
		t.byRepo[e.Repo] = m
	}
	k := entryKey{e.Member, e.Client}
	if _, ok := m[k]; !ok {
		t.count++
	}
	m[k] = e
}

// Remove deletes an entry and reports whether it existed.
func (t *Table) Remove(repo, member, client string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	m := t.byRepo[repo]
	k := entryKey{member, client}
	if _, ok := m[k]; !ok {
		return false
	}
	delete(m, k)
	t.count--
	if len(m) == 0 {
		delete(t.byRepo, repo)
	}
	return true
}

// List returns a repository's unexpired entries ordered by member and client.
func (t *Table) List(repo string, now time.Time) []api.PresenceEntry {
	t.mu.Lock()
	out := make([]api.PresenceEntry, 0, len(t.byRepo[repo]))
	for _, e := range t.byRepo[repo] {
		if now.Before(e.Expires) {
			out = append(out, e)
		}
	}
	t.mu.Unlock()
	slices.SortFunc(out, compareEntries)
	return out
}

// Sweep drops expired entries and returns how many it dropped.
func (t *Table) Sweep(now time.Time) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	n := 0
	for repo, m := range t.byRepo {
		for k, e := range m {
			if !now.Before(e.Expires) {
				delete(m, k)
				n++
			}
		}
		if len(m) == 0 {
			delete(t.byRepo, repo)
		}
	}
	t.count -= n
	return n
}

// Len counts stored entries, expired ones not yet swept included.
func (t *Table) Len() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.count
}

func compareEntries(a, b api.PresenceEntry) int {
	return cmp.Or(cmp.Compare(a.Member, b.Member), cmp.Compare(a.Client, b.Client))
}

// Overlaps finds pairs of different members whose work touches the same
// files. Entries of one member (several clients) never overlap each other.
// A related-file overlap leaves out paths both members changed, which are
// already a same-file overlap.
func Overlaps(entries []api.PresenceEntry) []api.Overlap {
	entries = slices.Clone(entries)
	slices.SortFunc(entries, compareEntries)
	changed := make([]map[string]struct{}, len(entries))
	related := make([]map[string]struct{}, len(entries))
	for i, e := range entries {
		changed[i] = toSet(e.Changed)
		related[i] = toSet(e.Related)
	}
	out := []api.Overlap{}
	for i := range entries {
		for j := i + 1; j < len(entries); j++ {
			a, b := &entries[i], &entries[j]
			if a.Member == b.Member {
				continue
			}
			if paths := intersect(a.Changed, changed[j], nil); len(paths) > 0 {
				out = append(out, overlap(api.OverlapSameFile, a, b, paths))
			}
			if paths := intersect(a.Changed, related[j], changed[j]); len(paths) > 0 {
				out = append(out, overlap(api.OverlapRelatedFile, a, b, paths))
			}
			if paths := intersect(b.Changed, related[i], changed[i]); len(paths) > 0 {
				out = append(out, overlap(api.OverlapRelatedFile, b, a, paths))
			}
		}
	}
	return out
}

// Involving keeps the overlaps that include member.
func Involving(overlaps []api.Overlap, member string) []api.Overlap {
	out := []api.Overlap{}
	for _, o := range overlaps {
		if o.A.Member == member || o.B.Member == member {
			out = append(out, o)
		}
	}
	return out
}

func overlap(kind string, a, b *api.PresenceEntry, paths []string) api.Overlap {
	return api.Overlap{Kind: kind, A: participant(a), B: participant(b), Paths: paths}
}

func participant(e *api.PresenceEntry) api.Participant {
	return api.Participant{Member: e.Member, Client: e.Client, Branch: e.Branch, Head: e.Head}
}

func toSet(paths []string) map[string]struct{} {
	m := make(map[string]struct{}, len(paths))
	for _, p := range paths {
		m[p] = struct{}{}
	}
	return m
}

// intersect returns the sorted paths of list that are in set but not in
// exclude.
func intersect(list []string, set, exclude map[string]struct{}) []string {
	var out []string
	for _, p := range list {
		if _, ok := set[p]; !ok {
			continue
		}
		if _, skip := exclude[p]; skip {
			continue
		}
		out = append(out, p)
	}
	slices.Sort(out)
	return slices.Compact(out)
}
