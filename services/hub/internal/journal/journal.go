// Package journal persists state as a snapshot plus an append-only log of
// JSON lines written after it.
//
// Crash safety rests on three rules: a batch of records is fsynced before it
// is acknowledged; a snapshot is written to a temporary file, fsynced and
// renamed over the old one before the log is cut; and on replay, records at
// or below the snapshot's sequence number are skipped. An incomplete last
// line (a write torn by a crash, which was never acknowledged) is dropped;
// damage anywhere else stops the replay.
package journal

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

// File names inside the data directory.
const (
	LogName      = "journal.jsonl"
	SnapshotName = "snapshot.json"
)

const formatVersion = 1

// Record is one line of the log. Seq increases by one per record.
type Record struct {
	Seq  uint64          `json:"seq"`
	Op   string          `json:"op"`
	Data json.RawMessage `json:"data,omitempty"`
}

type snapshotFile struct {
	Format  int             `json:"format"`
	Seq     uint64          `json:"seq"`
	Written time.Time       `json:"written"`
	State   json.RawMessage `json:"state"`
}

// Recovered is what Open found on disk.
type Recovered struct {
	// SnapshotSeq is the sequence number the snapshot covers (0 without one).
	SnapshotSeq uint64
	// State is the snapshot's payload, nil when there is no snapshot yet.
	State json.RawMessage
	// Records are the records after the snapshot, in order.
	Records []Record
	// TornBytes counts the bytes of an incomplete last line that were dropped.
	TornBytes int64
}

// LastSeq is the sequence number of the newest recovered record.
func (r Recovered) LastSeq() uint64 {
	if n := len(r.Records); n > 0 {
		return r.Records[n-1].Seq
	}
	return r.SnapshotSeq
}

// Journal is an open log. It is not safe for concurrent use: one goroutine
// owns it.
type Journal struct {
	dir     string
	f       *os.File
	size    int64
	lastSeq uint64
	buf     bytes.Buffer
}

// Open recovers the snapshot and the log in dir and opens the log for
// appending. A torn last line is cut off the file before Open returns.
func Open(dir string) (*Journal, Recovered, error) {
	var rec Recovered
	// Leftovers of a snapshot that was being written when the process died.
	_ = os.Remove(filepath.Join(dir, SnapshotName+".tmp"))

	snap, err := readSnapshot(filepath.Join(dir, SnapshotName))
	if err != nil {
		return nil, rec, err
	}
	if snap != nil {
		rec.SnapshotSeq, rec.State = snap.Seq, snap.State
	}

	path := filepath.Join(dir, LogName)
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return nil, rec, err
	}
	data, err := io.ReadAll(f)
	if err != nil {
		f.Close()
		return nil, rec, err
	}
	records, good, err := parse(data, rec.SnapshotSeq)
	if err != nil {
		f.Close()
		return nil, rec, fmt.Errorf("%s: %w", path, err)
	}
	rec.Records = records
	if torn := int64(len(data)) - good; torn > 0 {
		if err := f.Truncate(good); err != nil {
			f.Close()
			return nil, rec, err
		}
		if err := f.Sync(); err != nil {
			f.Close()
			return nil, rec, err
		}
		rec.TornBytes = torn
	}
	j := &Journal{dir: dir, f: f, size: good, lastSeq: rec.LastSeq()}
	return j, rec, nil
}

// parse reads the records after snapshotSeq and returns how many bytes of
// data are intact.
func parse(data []byte, snapshotSeq uint64) ([]Record, int64, error) {
	var records []Record
	var prev uint64
	off, line := 0, 0
	for off < len(data) {
		end := bytes.IndexByte(data[off:], '\n')
		if end < 0 {
			// The last write never finished.
			return records, int64(off), nil
		}
		line++
		var r Record
		if err := json.Unmarshal(data[off:off+end], &r); err != nil || r.Seq == 0 || r.Op == "" {
			if onlyPadding(data[off+end+1:]) {
				// A damaged final line: a torn write that a crash left padded.
				return records, int64(off), nil
			}
			return nil, 0, fmt.Errorf("line %d is damaged; restore the data directory from a backup", line)
		}
		if r.Seq <= prev {
			return nil, 0, fmt.Errorf("line %d: sequence %d does not follow %d", line, r.Seq, prev)
		}
		prev = r.Seq
		if r.Seq > snapshotSeq {
			records = append(records, r)
		}
		off += end + 1
	}
	return records, int64(off), nil
}

// onlyPadding reports whether b holds nothing but the zero bytes and blanks
// some file systems leave after a crash.
func onlyPadding(b []byte) bool {
	return len(bytes.Trim(b, "\x00 \t\r\n")) == 0
}

func readSnapshot(path string) (*snapshotFile, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var s snapshotFile
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if s.Format != formatVersion {
		return nil, fmt.Errorf("%s: unsupported snapshot format %d", path, s.Format)
	}
	return &s, nil
}

// Append writes records as one batch and fsyncs once. Their sequence numbers
// must continue the log. After an error the journal must not be used again.
func (j *Journal) Append(records []Record) error {
	if len(records) == 0 {
		return nil
	}
	j.buf.Reset()
	seq := j.lastSeq
	for _, r := range records {
		if r.Seq != seq+1 {
			return fmt.Errorf("journal: record %d does not follow %d", r.Seq, seq)
		}
		seq = r.Seq
		line, err := json.Marshal(r)
		if err != nil {
			return err
		}
		j.buf.Write(line)
		j.buf.WriteByte('\n')
	}
	n, err := j.f.Write(j.buf.Bytes())
	j.size += int64(n)
	if err != nil {
		return err
	}
	if err := j.f.Sync(); err != nil {
		return err
	}
	j.lastSeq = seq
	return nil
}

// Snapshot stores state as covering every record up to seq, then cuts the
// log. The caller must not have appended records past seq. If it fails
// before the rename, the old snapshot and the log are untouched; if cutting
// the log fails, replay still skips the records the snapshot covers.
func (j *Journal) Snapshot(seq uint64, state json.RawMessage) error {
	if seq != j.lastSeq {
		return fmt.Errorf("journal: snapshot at %d, but the log ends at %d", seq, j.lastSeq)
	}
	b, err := json.Marshal(snapshotFile{
		Format:  formatVersion,
		Seq:     seq,
		Written: time.Now().UTC().Truncate(time.Second),
		State:   state,
	})
	if err != nil {
		return err
	}
	final := filepath.Join(j.dir, SnapshotName)
	tmp := final + ".tmp"
	if err := writeSynced(tmp, b); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, final); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := syncDir(j.dir); err != nil {
		return err
	}
	if err := j.f.Truncate(0); err != nil {
		return err
	}
	if err := j.f.Sync(); err != nil {
		return err
	}
	j.size = 0
	return nil
}

func writeSynced(path string, b []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// syncDir makes a rename in dir durable.
func syncDir(dir string) error {
	if runtime.GOOS == "windows" {
		// Directories cannot be fsynced there; NTFS journals the rename itself.
		return nil
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	err = d.Sync()
	if cerr := d.Close(); err == nil {
		err = cerr
	}
	return err
}

// Size is the current size of the log file in bytes.
func (j *Journal) Size() int64 { return j.size }

// LastSeq is the sequence number of the last record written.
func (j *Journal) LastSeq() uint64 { return j.lastSeq }

// Close closes the log file.
func (j *Journal) Close() error {
	if j.f == nil {
		return nil
	}
	err := j.f.Close()
	j.f = nil
	return err
}
