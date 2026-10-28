package store

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/journal"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/lockfile"
)

const repo = "example.com/team/app"

func openStore(t *testing.T, opts Options) *Store {
	t.Helper()
	s, err := Open(opts)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

// crashCopy copies the files of an open data directory, which is what a
// restart after a crash at this moment would find: every acknowledged
// change has been fsynced.
func crashCopy(t *testing.T, dir string) string {
	t.Helper()
	dst := t.TempDir()
	for _, name := range []string{journal.LogName, journal.SnapshotName} {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dst, name), b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dst
}

func appendEvents(t *testing.T, s *Store, n int) []api.Event {
	t.Helper()
	var out []api.Event
	for i := range n {
		e, err := s.AppendEvent(api.EventInput{Repo: repo, Type: api.EventCIFailed, Message: fmt.Sprint("run ", i)}, "alice")
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, e)
	}
	return out
}

func TestTokensHashedVerifiedRevokedAndDurable(t *testing.T) {
	dir := t.TempDir()
	s := openStore(t, Options{Dir: dir})
	alice, err := s.CreateToken("alice", api.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	admin, err := s.CreateToken("admin", api.RoleAdmin)
	if err != nil {
		t.Fatal(err)
	}
	p, err := s.Authenticate(alice.Token)
	if err != nil || p.Name != "alice" || p.Role != api.RoleMember || p.Admin() || p.TokenID != alice.ID {
		t.Fatalf("Authenticate = %+v, %v", p, err)
	}
	wrong := "Q"
	if strings.HasSuffix(alice.Token, wrong) {
		wrong = "R"
	}
	if _, err := s.Authenticate(alice.Token[:len(alice.Token)-1] + wrong); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("a wrong secret with the right id: %v", err)
	}
	if _, err := s.Authenticate("grh_garbage"); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("a malformed token must be refused")
	}
	if _, err := s.CreateToken("bad name", api.RoleMember); err == nil {
		t.Fatal("names with spaces must be refused")
	}
	if _, err := s.CreateToken("eve", "owner"); err == nil {
		t.Fatal("unknown roles must be refused")
	}
	if _, err := s.RevokeToken(alice.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Authenticate(alice.Token); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("a revoked token still authenticates")
	}
	if _, err := s.RevokeToken("0000000000000000"); !errors.Is(err, ErrNotFound) {
		t.Fatal("revoking an unknown token must be ErrNotFound")
	}

	// The secret never reaches the disk; only its hash does.
	crashed := crashCopy(t, dir)
	for _, name := range []string{journal.LogName, journal.SnapshotName} {
		b, _ := os.ReadFile(filepath.Join(crashed, name))
		if strings.Contains(string(b), alice.Token) || strings.Contains(string(b), admin.Token) {
			t.Fatalf("%s contains a token secret", name)
		}
	}
	s2 := openStore(t, Options{Dir: crashed})
	if _, err := s2.Authenticate(admin.Token); err != nil {
		t.Fatalf("admin token lost in replay: %v", err)
	}
	if _, err := s2.Authenticate(alice.Token); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("revocation lost in replay")
	}
	tokens := s2.Tokens()
	if len(tokens) != 2 || s2.ActiveTokens() != 1 {
		t.Fatalf("tokens after replay: %+v", tokens)
	}
}

func TestReplayAfterCrashWithTornLine(t *testing.T) {
	dir := t.TempDir()
	s := openStore(t, Options{Dir: dir})
	want := appendEvents(t, s, 7)
	note, err := s.CreateNote(api.Note{Repo: repo, Path: "src/api.go", Line: 3, Body: "shared", Author: "alice"})
	if err != nil {
		t.Fatal(err)
	}

	crashed := crashCopy(t, dir)
	f, err := os.OpenFile(filepath.Join(crashed, journal.LogName), os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString(`{"seq":99,"op":"event","data":{"id":99,"repo":"example.com/te`) // torn by the crash
	f.Close()

	s2 := openStore(t, Options{Dir: crashed})
	got := s2.Events("", 0, 100)
	if len(got.Events) != 8 { // 7 events and note.created
		t.Fatalf("replayed %d events, want 8", len(got.Events))
	}
	for i, e := range want {
		if got.Events[i].ID != e.ID || got.Events[i].Message != e.Message {
			t.Fatalf("event %d = %+v, want %+v", i, got.Events[i], e)
		}
	}
	if notes := s2.Notes(repo, "", "", 0, 10); len(notes) != 1 || notes[0].ID != note.ID {
		t.Fatalf("notes after replay: %+v", notes)
	}
	// IDs continue after the replayed ones.
	e, err := s2.AppendEvent(api.EventInput{Repo: repo, Type: api.EventCIPassed}, "bob")
	if err != nil || e.ID != got.Events[7].ID+1 {
		t.Fatalf("next event %+v, %v", e, err)
	}
}

func TestSnapshotCompaction(t *testing.T) {
	dir := t.TempDir()
	s := openStore(t, Options{Dir: dir, SnapshotEvery: 5})
	appendEvents(t, s, 12)
	if _, err := os.Stat(filepath.Join(dir, journal.SnapshotName)); err != nil {
		t.Fatalf("no snapshot after 12 records with SnapshotEvery 5: %v", err)
	}
	b, _ := os.ReadFile(filepath.Join(dir, journal.LogName))
	if n := strings.Count(string(b), "\n"); n >= 5 {
		t.Fatalf("journal holds %d records; compaction should keep it under 5", n)
	}
	if st := s.Stats(); st.JournalBytes != int64(len(b)) || st.Seq != 12 {
		t.Fatalf("stats %+v, journal %d bytes", st, len(b))
	}
	s2 := openStore(t, Options{Dir: crashCopy(t, dir)})
	if got := s2.Events("", 0, 100); len(got.Events) != 12 || got.Events[11].ID != 12 {
		t.Fatalf("after snapshot + journal replay: %d events", len(got.Events))
	}
	// Close writes a final snapshot and leaves an empty journal.
	s.Close()
	if b, _ := os.ReadFile(filepath.Join(dir, journal.LogName)); len(b) != 0 {
		t.Fatalf("journal not empty after Close: %q", b)
	}
	s3 := openStore(t, Options{Dir: dir})
	if got := s3.Events("", 0, 100); len(got.Events) != 12 {
		t.Fatalf("after Close and reopen: %d events", len(got.Events))
	}
}

func TestConcurrentWritersGroupCommitInOrder(t *testing.T) {
	dir := t.TempDir()
	var mu sync.Mutex
	var published []uint64
	s := openStore(t, Options{Dir: dir, OnEvents: func(evs []api.Event) {
		mu.Lock()
		defer mu.Unlock()
		for _, e := range evs {
			published = append(published, e.ID)
		}
	}})
	const writers, each = 20, 25
	var wg sync.WaitGroup
	for w := range writers {
		wg.Go(func() {
			for i := range each {
				if _, err := s.AppendEvent(api.EventInput{Repo: repo, Type: api.EventCIPassed, Message: fmt.Sprintf("%d/%d", w, i)}, "ci"); err != nil {
					t.Error(err)
					return
				}
			}
		})
	}
	wg.Wait()
	mu.Lock()
	defer mu.Unlock()
	if len(published) != writers*each {
		t.Fatalf("published %d events, want %d", len(published), writers*each)
	}
	for i := range published {
		if published[i] != uint64(i+1) {
			t.Fatalf("published out of order at %d: %d", i, published[i])
		}
	}
	b, _ := os.ReadFile(filepath.Join(dir, journal.LogName))
	if lines := strings.Count(string(b), "\n"); lines != writers*each {
		t.Fatalf("journal has %d lines, want %d", lines, writers*each)
	}
	s2 := openStore(t, Options{Dir: crashCopy(t, dir)})
	if got := s2.Events("", 0, 1000); len(got.Events) != writers*each {
		t.Fatalf("replayed %d events", len(got.Events))
	}
}

func TestRetentionAndCursors(t *testing.T) {
	dir := t.TempDir()
	s := openStore(t, Options{Dir: dir, EventRetention: 10})
	appendEvents(t, s, 25)
	if _, err := s.AppendEvent(api.EventInput{Repo: "example.com/team/other", Type: api.EventCIPassed}, "bob"); err != nil {
		t.Fatal(err)
	}
	all := s.Events("", 0, 100)
	if len(all.Events) != 10 || all.Oldest != 17 || !all.Truncated {
		t.Fatalf("retained %d, oldest %d, truncated %v", len(all.Events), all.Oldest, all.Truncated)
	}
	if s.Events("", 20, 100).Truncated {
		t.Fatal("a cursor inside the retained range is not truncated")
	}
	page := s.Events(repo, 18, 3)
	if len(page.Events) != 3 || page.Events[0].ID != 19 || page.Last != 21 || !page.More {
		t.Fatalf("page %+v", page)
	}
	rest := s.Events(repo, page.Last, 100)
	if len(rest.Events) != 4 || rest.More || rest.Last != 26 {
		t.Fatalf("rest: %d events, last %d, more %v", len(rest.Events), rest.Last, rest.More)
	}
	backlog, from, truncated := s.Replay("example.com/team/other", 0, func() {})
	if len(backlog) != 1 || backlog[0].ID != 26 || from != 0 || !truncated {
		t.Fatalf("Replay = %+v, %d, %v", backlog, from, truncated)
	}
	// A cursor past the newest event predates a reset of the data.
	if backlog, from, truncated := s.Replay("", 500, func() {}); len(backlog) != 10 || from != 0 || !truncated {
		t.Fatalf("future cursor: %d events from %d, truncated %v", len(backlog), from, truncated)
	}
	if future := s.Events("", 500, 100); len(future.Events) != 10 || !future.Truncated || future.Last != 26 {
		t.Fatalf("future cursor in a listing: %d events, truncated %v, last %d", len(future.Events), future.Truncated, future.Last)
	}
	if caughtUp := s.Events("", 26, 100); len(caughtUp.Events) != 0 || caughtUp.Truncated {
		t.Fatalf("a cursor at the newest event: %+v", caughtUp)
	}
	s.Close()
	s2 := openStore(t, Options{Dir: dir, EventRetention: 10})
	again := s2.Events("", 0, 100)
	if len(again.Events) != 10 || again.Oldest != 17 || !again.Truncated {
		t.Fatalf("after reopen: %d events, oldest %d, truncated %v", len(again.Events), again.Oldest, again.Truncated)
	}
}

func TestNotesPermissionsAndEvents(t *testing.T) {
	var mu sync.Mutex
	var types []string
	s := openStore(t, Options{Dir: t.TempDir(), OnEvents: func(evs []api.Event) {
		mu.Lock()
		defer mu.Unlock()
		for _, e := range evs {
			types = append(types, e.Type)
		}
	}})
	commitNote, err := s.CreateNote(api.Note{Repo: repo, Commit: "0123456789abcdef0123456789abcdef01234567", Body: "why", Author: "alice"})
	if err != nil {
		t.Fatal(err)
	}
	pathNote, _ := s.CreateNote(api.Note{Repo: repo, Path: "src/api.go", Line: 9, Body: "careful", Author: "alice"})
	if got := s.Notes(repo, "0123456", "", 0, 10); len(got) != 1 || got[0].ID != commitNote.ID {
		t.Fatalf("commit prefix filter: %+v", got)
	}
	if got := s.Notes(repo, "", "src/api.go", 0, 10); len(got) != 1 || got[0].ID != pathNote.ID {
		t.Fatalf("path filter: %+v", got)
	}
	if got := s.Notes("example.com/team/other", "", "", 0, 10); len(got) != 0 {
		t.Fatal("notes leaked into another repository")
	}
	bob := Principal{Name: "bob", Role: api.RoleMember}
	if err := s.DeleteNote(pathNote.ID, bob); !errors.Is(err, ErrForbidden) {
		t.Fatalf("a member deleted someone else's note: %v", err)
	}
	if err := s.DeleteNote(pathNote.ID, Principal{Name: "alice", Role: api.RoleMember}); err != nil {
		t.Fatalf("the author could not delete: %v", err)
	}
	if err := s.DeleteNote(commitNote.ID, Principal{Name: "root", Role: api.RoleAdmin}); err != nil {
		t.Fatalf("an admin could not delete: %v", err)
	}
	if err := s.DeleteNote(commitNote.ID, Principal{Name: "root", Role: api.RoleAdmin}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleting twice: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	want := []string{api.EventNoteCreated, api.EventNoteCreated, api.EventNoteDeleted, api.EventNoteDeleted}
	if fmt.Sprint(types) != fmt.Sprint(want) {
		t.Fatalf("events %v, want %v", types, want)
	}
}

func TestSecondOpenIsRefused(t *testing.T) {
	dir := t.TempDir()
	openStore(t, Options{Dir: dir})
	if _, err := Open(Options{Dir: dir}); !errors.Is(err, lockfile.ErrLocked) {
		t.Fatalf("second Open: %v, want ErrLocked", err)
	}
}

func TestJournalFailureStopsWrites(t *testing.T) {
	s := openStore(t, Options{Dir: t.TempDir()})
	appendEvents(t, s, 1)
	s.j.Close() // the disk goes away under the writer
	if _, err := s.AppendEvent(api.EventInput{Repo: repo, Type: api.EventCIPassed}, "a"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("write after a journal failure: %v, want ErrUnavailable", err)
	}
	if s.Err() == nil {
		t.Fatal("Err must report the failure")
	}
	if _, err := s.CreateToken("bob", api.RoleMember); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("later writes must fail too: %v", err)
	}
	if got := s.Events("", 0, 10); len(got.Events) != 1 {
		t.Fatalf("a failed write reached memory: %d events", len(got.Events))
	}
}
