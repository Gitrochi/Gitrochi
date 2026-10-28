package presence

import (
	"reflect"
	"testing"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
)

var t0 = time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)

func entry(member, client string, changed, related []string) api.PresenceEntry {
	return api.PresenceEntry{
		Presence: api.Presence{Repo: "example.com/team/app", Branch: "feature/" + member, Client: client, Changed: changed, Related: related},
		Member:   member,
		Updated:  t0,
		Expires:  t0.Add(10 * time.Minute),
	}
}

func TestOverlapsSameAndRelatedFile(t *testing.T) {
	alice := entry("alice", "laptop", []string{"src/api.go", "src/db.go"}, []string{"docs/api.md", "src/db.go"})
	bob := entry("bob", "desk", []string{"docs/api.md", "src/api.go", "src/db.go"}, nil)
	carol := entry("carol", "desk", []string{"web/app.ts"}, []string{"src/api.go"})
	got := Overlaps([]api.PresenceEntry{carol, bob, alice})

	type row struct {
		kind, a, b string
		paths      []string
	}
	var rows []row
	for _, o := range got {
		rows = append(rows, row{o.Kind, o.A.Member, o.B.Member, o.Paths})
	}
	want := []row{
		{api.OverlapSameFile, "alice", "bob", []string{"src/api.go", "src/db.go"}},
		// bob changed docs/api.md, which alice's work relates to; src/db.go is
		// already a same-file overlap and is left out.
		{api.OverlapRelatedFile, "bob", "alice", []string{"docs/api.md"}},
		{api.OverlapRelatedFile, "alice", "carol", []string{"src/api.go"}},
		{api.OverlapRelatedFile, "bob", "carol", []string{"src/api.go"}},
	}
	if !reflect.DeepEqual(rows, want) {
		t.Fatalf("overlaps:\n got  %+v\n want %+v", rows, want)
	}
	if got[0].A.Branch != "feature/alice" || got[0].B.Client != "desk" {
		t.Fatalf("participants carry the wrong entry: %+v", got[0])
	}
}

func TestOneMemberNeverOverlapsItself(t *testing.T) {
	a1 := entry("alice", "laptop", []string{"x.go"}, []string{"y.go"})
	a2 := entry("alice", "desktop", []string{"x.go", "y.go"}, nil)
	if got := Overlaps([]api.PresenceEntry{a1, a2}); len(got) != 0 {
		t.Fatalf("got %+v, want none", got)
	}
	if got := Overlaps(nil); got == nil || len(got) != 0 {
		t.Fatal("no entries must give an empty, non-nil list")
	}
}

func TestInvolving(t *testing.T) {
	all := Overlaps([]api.PresenceEntry{
		entry("alice", "l", []string{"a"}, nil),
		entry("bob", "l", []string{"a"}, nil),
		entry("carol", "l", []string{"b"}, nil),
		entry("dave", "l", []string{"b"}, nil),
	})
	if len(all) != 2 {
		t.Fatalf("want 2 overlaps, got %d", len(all))
	}
	mine := Involving(all, "carol")
	if len(mine) != 1 || mine[0].A.Member != "carol" || mine[0].B.Member != "dave" {
		t.Fatalf("Involving(carol) = %+v", mine)
	}
}

func TestTableExpiryAndReplace(t *testing.T) {
	tab := NewTable()
	e := entry("alice", "laptop", []string{"a"}, nil)
	tab.Set(e)
	e.Changed = []string{"b"}
	tab.Set(e) // same member and client: replaces
	tab.Set(entry("alice", "desktop", nil, nil))
	short := entry("bob", "desk", nil, nil)
	short.Expires = t0.Add(time.Minute)
	tab.Set(short)
	if tab.Len() != 3 {
		t.Fatalf("Len = %d, want 3", tab.Len())
	}
	list := tab.List("example.com/team/app", t0.Add(2*time.Minute))
	if len(list) != 2 || list[0].Client != "desktop" || list[1].Changed[0] != "b" {
		t.Fatalf("List = %+v", list)
	}
	if n := tab.Sweep(t0.Add(2 * time.Minute)); n != 1 || tab.Len() != 2 {
		t.Fatalf("Sweep = %d, Len = %d", n, tab.Len())
	}
	if !tab.Remove("example.com/team/app", "alice", "laptop") || tab.Remove("example.com/team/app", "alice", "laptop") {
		t.Fatal("Remove")
	}
	if len(tab.List("example.com/team/other", t0)) != 0 {
		t.Fatal("another repository must be empty")
	}
}
