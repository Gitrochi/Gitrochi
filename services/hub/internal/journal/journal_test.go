package journal

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func recs(from, to uint64) []Record {
	var out []Record
	for s := from; s <= to; s++ {
		out = append(out, Record{Seq: s, Op: "event", Data: json.RawMessage(`{"n":` + jsonNum(s) + `}`)})
	}
	return out
}

func jsonNum(n uint64) string {
	b, _ := json.Marshal(n)
	return string(b)
}

func open(t *testing.T, dir string) (*Journal, Recovered) {
	t.Helper()
	j, rec, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { j.Close() })
	return j, rec
}

func seqs(rs []Record) []uint64 {
	var out []uint64
	for _, r := range rs {
		out = append(out, r.Seq)
	}
	return out
}

func TestAppendAndReplay(t *testing.T) {
	dir := t.TempDir()
	j, rec := open(t, dir)
	if rec.State != nil || len(rec.Records) != 0 {
		t.Fatal("a new directory must be empty")
	}
	if err := j.Append(recs(1, 3)); err != nil {
		t.Fatal(err)
	}
	if err := j.Append(recs(4, 4)); err != nil {
		t.Fatal(err)
	}
	if err := j.Append(recs(6, 6)); err == nil {
		t.Fatal("a gap in sequence numbers must be refused")
	}
	j.Close()
	_, rec = open(t, dir)
	if got := seqs(rec.Records); len(got) != 4 || got[3] != 4 || rec.LastSeq() != 4 {
		t.Fatalf("replayed %v", got)
	}
}

func TestTornLastLineIsDroppedAndTruncated(t *testing.T) {
	dir := t.TempDir()
	j, _ := open(t, dir)
	if err := j.Append(recs(1, 2)); err != nil {
		t.Fatal(err)
	}
	j.Close()
	path := filepath.Join(dir, LogName)
	good, _ := os.ReadFile(path)
	// A crash in the middle of writing record 3.
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"seq":3,"op":"event","da`)
	f.Close()

	j, rec := open(t, dir)
	if got := seqs(rec.Records); len(got) != 2 || got[1] != 2 {
		t.Fatalf("replayed %v, want [1 2]", got)
	}
	if rec.TornBytes == 0 {
		t.Fatal("TornBytes not reported")
	}
	if b, _ := os.ReadFile(path); string(b) != string(good) {
		t.Fatalf("file not truncated to the intact records:\n%s", b)
	}
	// Appending continues on a clean line.
	if err := j.Append(recs(3, 3)); err != nil {
		t.Fatal(err)
	}
	j.Close()
	_, rec = open(t, dir)
	if got := seqs(rec.Records); len(got) != 3 || got[2] != 3 || rec.TornBytes != 0 {
		t.Fatalf("after repair replayed %v (torn %d)", got, rec.TornBytes)
	}
}

func TestZeroPaddedTailIsTolerated(t *testing.T) {
	dir := t.TempDir()
	j, _ := open(t, dir)
	j.Append(recs(1, 1))
	j.Close()
	f, _ := os.OpenFile(filepath.Join(dir, LogName), os.O_APPEND|os.O_WRONLY, 0)
	f.Write(make([]byte, 64)) // what some file systems leave after a crash
	f.Close()
	_, rec := open(t, dir)
	if len(rec.Records) != 1 || rec.TornBytes != 64 {
		t.Fatalf("records %d torn %d", len(rec.Records), rec.TornBytes)
	}
}

func TestDamageBeforeTheEndIsAnError(t *testing.T) {
	dir := t.TempDir()
	j, _ := open(t, dir)
	j.Append(recs(1, 3))
	j.Close()
	path := filepath.Join(dir, LogName)
	b, _ := os.ReadFile(path)
	lines := strings.SplitAfter(string(b), "\n")
	lines[1] = "{not json}\n"
	os.WriteFile(path, []byte(strings.Join(lines, "")), 0o600)
	if _, _, err := Open(dir); err == nil || !strings.Contains(err.Error(), "line 2") {
		t.Fatalf("Open = %v, want an error naming line 2", err)
	}
}

func TestSnapshotCompactsTheLog(t *testing.T) {
	dir := t.TempDir()
	j, _ := open(t, dir)
	j.Append(recs(1, 5))
	if j.Size() == 0 {
		t.Fatal("Size must count appended bytes")
	}
	if err := j.Snapshot(4, json.RawMessage(`{"x":1}`)); err == nil {
		t.Fatal("a snapshot behind the log end must be refused")
	}
	if err := j.Snapshot(5, json.RawMessage(`{"upTo":5}`)); err != nil {
		t.Fatal(err)
	}
	if j.Size() != 0 {
		t.Fatalf("log not cut: %d bytes", j.Size())
	}
	if fi, _ := os.Stat(filepath.Join(dir, LogName)); fi.Size() != 0 {
		t.Fatal("log file not truncated")
	}
	j.Append(recs(6, 7))
	j.Close()
	_, rec := open(t, dir)
	if rec.SnapshotSeq != 5 || string(rec.State) != `{"upTo":5}` {
		t.Fatalf("snapshot %d %s", rec.SnapshotSeq, rec.State)
	}
	if got := seqs(rec.Records); len(got) != 2 || got[0] != 6 || rec.LastSeq() != 7 {
		t.Fatalf("records after the snapshot %v", got)
	}
}

func TestCrashBetweenSnapshotAndCut(t *testing.T) {
	dir := t.TempDir()
	j, _ := open(t, dir)
	j.Append(recs(1, 4))
	j.Close()
	// The snapshot was renamed into place, then the process died before it
	// cut the log: the log still holds records the snapshot covers.
	snap, _ := json.Marshal(snapshotFile{Format: formatVersion, Seq: 3, State: json.RawMessage(`{}`)})
	os.WriteFile(filepath.Join(dir, SnapshotName), snap, 0o600)
	os.WriteFile(filepath.Join(dir, SnapshotName+".tmp"), []byte("half"), 0o600)
	_, rec := open(t, dir)
	if got := seqs(rec.Records); len(got) != 1 || got[0] != 4 {
		t.Fatalf("records %v, want only [4]: covered records must not apply twice", got)
	}
	if _, err := os.Stat(filepath.Join(dir, SnapshotName+".tmp")); !os.IsNotExist(err) {
		t.Fatal("a leftover temporary snapshot must be removed")
	}
}
