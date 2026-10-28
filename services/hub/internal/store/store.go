// Package store keeps the hub's durable state — tokens, events and notes —
// in memory, backed by the journal in the data directory.
//
// Every change goes through one writer goroutine: callers queue a record,
// the writer appends whatever is queued as one batch with a single fsync,
// applies the batch to memory in sequence order, publishes the batch's
// events, and only then acknowledges the callers. So a change is visible and
// acknowledged only once it is durable, and events reach subscribers in ID
// order.
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/journal"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/lockfile"
)

// LockName is the lock file that marks a data directory as in use.
const LockName = "hub.lock"

// Defaults for Options.
const (
	DefaultEventRetention   = 10000
	DefaultSnapshotEvery    = 1000
	DefaultSnapshotInterval = 5 * time.Minute
)

var (
	// ErrNotFound reports an unknown token or note.
	ErrNotFound = errors.New("not found")
	// ErrForbidden reports a change the caller may not make.
	ErrForbidden = errors.New("forbidden")
	// ErrUnauthorized reports an unknown, malformed or revoked token.
	ErrUnauthorized = errors.New("invalid or revoked token")
	// ErrUnavailable reports that the journal can no longer be written.
	ErrUnavailable = errors.New("the hub cannot write its journal")
	// ErrClosed reports a change after Close.
	ErrClosed = errors.New("store is closed")
)

// InvalidError reports a bad argument. Its message is safe to show clients.
type InvalidError struct{ Msg string }

func (e *InvalidError) Error() string { return e.Msg }

func invalidf(format string, args ...any) error {
	return &InvalidError{Msg: fmt.Sprintf(format, args...)}
}

// Journal operations.
const (
	opTokenCreate = "token.create"
	opTokenRevoke = "token.revoke"
	opEvent       = "event"
	opNoteCreate  = "note.create"
	opNoteDelete  = "note.delete"
)

// Options configure Open.
type Options struct {
	Dir              string
	EventRetention   int           // events kept for listing and SSE resume
	SnapshotEvery    int           // records between snapshots
	SnapshotInterval time.Duration // snapshot at least this often while changes arrive
	Logger           *slog.Logger
	Now              func() time.Time
	// OnEvents receives every batch of new events, in ID order, after they
	// are durable. It is called from the writer goroutine and must not block.
	OnEvents func([]api.Event)
}

// Principal is an authenticated token.
type Principal struct {
	TokenID string
	Name    string
	Role    string
}

// Admin reports whether the principal has the admin role.
func (p Principal) Admin() bool { return p.Role == api.RoleAdmin }

type tokenRecord struct {
	ID      string    `json:"id"`
	Name    string    `json:"name"`
	Role    string    `json:"role"`
	Hash    string    `json:"hash"`
	Created time.Time `json:"created"`
	Revoked time.Time `json:"revoked,omitzero"`
}

func (t *tokenRecord) info() api.TokenInfo {
	return api.TokenInfo{ID: t.ID, Name: t.Name, Role: t.Role, Created: t.Created, Revoked: t.Revoked}
}

type revokeData struct {
	ID string    `json:"id"`
	At time.Time `json:"at"`
}

type noteCreateData struct {
	Note  api.Note  `json:"note"`
	Event api.Event `json:"event"`
}

type noteDeleteData struct {
	ID    uint64    `json:"id"`
	Event api.Event `json:"event"`
}

type snapshotState struct {
	Tokens         []tokenRecord `json:"tokens"`
	Notes          []api.Note    `json:"notes"`
	Events         []api.Event   `json:"events"`
	NextEventID    uint64        `json:"nextEventId"`
	NextNoteID     uint64        `json:"nextNoteId"`
	DroppedThrough uint64        `json:"droppedThrough"`
}

type pending struct {
	rec  journal.Record
	done chan error
}

// Store is the hub's durable state. It is safe for concurrent use.
type Store struct {
	opts Options
	log  *slog.Logger
	now  func() time.Time
	lock *lockfile.Lock
	j    *journal.Journal // owned by the writer goroutine once Open returns

	mu             sync.RWMutex // guards the applied state below
	tokens         map[string]*tokenRecord
	notes          map[uint64]*api.Note
	notesByRepo    map[string][]uint64
	events         eventRing
	droppedThrough uint64 // newest event ID that retention dropped
	appliedSeq     uint64
	maxEventID     uint64
	maxNoteID      uint64

	qmu         sync.Mutex // guards the queue and ID allocation
	queue       []*pending
	nextSeq     uint64
	nextEventID uint64
	nextNoteID  uint64
	closing     bool
	failed      error

	wake    chan struct{}
	stopped chan struct{}

	// Writer goroutine only.
	sinceSnapshot int
	retrySnapshot time.Time

	journalBytes atomic.Int64
	closeOnce    sync.Once
	closeErr     error
}

// Open locks dir, replays its snapshot and journal, and starts the writer.
// It fails with an error wrapping lockfile.ErrLocked while another process
// uses dir.
func Open(opts Options) (*Store, error) {
	if opts.Dir == "" {
		return nil, errors.New("store: no data directory")
	}
	if opts.EventRetention <= 0 {
		opts.EventRetention = DefaultEventRetention
	}
	if opts.SnapshotEvery <= 0 {
		opts.SnapshotEvery = DefaultSnapshotEvery
	}
	if opts.SnapshotInterval <= 0 {
		opts.SnapshotInterval = DefaultSnapshotInterval
	}
	if opts.Logger == nil {
		opts.Logger = slog.New(slog.DiscardHandler)
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	if err := os.MkdirAll(opts.Dir, 0o700); err != nil {
		return nil, err
	}
	lk, err := lockfile.Acquire(filepath.Join(opts.Dir, LockName))
	if err != nil {
		return nil, err
	}
	j, rec, err := journal.Open(opts.Dir)
	if err != nil {
		lk.Release()
		return nil, err
	}
	s := &Store{
		opts:        opts,
		log:         opts.Logger,
		now:         func() time.Time { return opts.Now().UTC().Truncate(time.Second) },
		lock:        lk,
		j:           j,
		tokens:      make(map[string]*tokenRecord),
		notes:       make(map[uint64]*api.Note),
		notesByRepo: make(map[string][]uint64),
		events:      eventRing{limit: opts.EventRetention},
		wake:        make(chan struct{}, 1),
		stopped:     make(chan struct{}),
	}
	fail := func(err error) (*Store, error) {
		j.Close()
		lk.Release()
		return nil, err
	}
	var nextEvent, nextNote uint64
	if rec.State != nil {
		var st snapshotState
		if err := json.Unmarshal(rec.State, &st); err != nil {
			return fail(fmt.Errorf("read snapshot: %w", err))
		}
		s.load(st)
		nextEvent, nextNote = st.NextEventID, st.NextNoteID
	}
	for _, r := range rec.Records {
		if _, err := s.apply(r); err != nil {
			return fail(fmt.Errorf("replay journal record %d: %w", r.Seq, err))
		}
	}
	s.appliedSeq = rec.LastSeq()
	s.nextSeq = s.appliedSeq + 1
	s.nextEventID = max(nextEvent, s.maxEventID+1)
	s.nextNoteID = max(nextNote, s.maxNoteID+1)
	s.sinceSnapshot = len(rec.Records)
	s.journalBytes.Store(j.Size())
	if rec.TornBytes > 0 {
		s.log.Warn("dropped an incomplete last journal line left by a crash", "bytes", rec.TornBytes)
	}
	s.log.Debug("store opened", "dir", opts.Dir, "snapshot_seq", rec.SnapshotSeq, "replayed", len(rec.Records))
	go s.writer()
	return s, nil
}

func (s *Store) load(st snapshotState) {
	for i := range st.Tokens {
		t := st.Tokens[i]
		s.tokens[t.ID] = &t
	}
	for i := range st.Notes {
		s.insertNote(st.Notes[i])
	}
	for _, e := range st.Events {
		s.pushEvent(e)
	}
	s.droppedThrough = max(s.droppedThrough, st.DroppedThrough)
}

// apply changes the in-memory state for one record and returns the events
// it produced. The caller holds mu, or is Open before the writer starts.
func (s *Store) apply(r journal.Record) ([]api.Event, error) {
	switch r.Op {
	case opTokenCreate:
		var t tokenRecord
		if err := json.Unmarshal(r.Data, &t); err != nil {
			return nil, err
		}
		s.tokens[t.ID] = &t
	case opTokenRevoke:
		var d revokeData
		if err := json.Unmarshal(r.Data, &d); err != nil {
			return nil, err
		}
		if t := s.tokens[d.ID]; t != nil && t.Revoked.IsZero() {
			t.Revoked = d.At
		}
	case opEvent:
		var e api.Event
		if err := json.Unmarshal(r.Data, &e); err != nil {
			return nil, err
		}
		s.pushEvent(e)
		return []api.Event{e}, nil
	case opNoteCreate:
		var d noteCreateData
		if err := json.Unmarshal(r.Data, &d); err != nil {
			return nil, err
		}
		s.insertNote(d.Note)
		s.pushEvent(d.Event)
		return []api.Event{d.Event}, nil
	case opNoteDelete:
		var d noteDeleteData
		if err := json.Unmarshal(r.Data, &d); err != nil {
			return nil, err
		}
		n, ok := s.notes[d.ID]
		if !ok {
			// Deleted twice concurrently: the first delete won.
			return nil, nil
		}
		delete(s.notes, d.ID)
		ids := s.notesByRepo[n.Repo]
		if i, found := slices.BinarySearch(ids, d.ID); found {
			s.notesByRepo[n.Repo] = slices.Delete(ids, i, i+1)
		}
		s.pushEvent(d.Event)
		return []api.Event{d.Event}, nil
	default:
		return nil, fmt.Errorf("unknown operation %q", r.Op)
	}
	return nil, nil
}

func (s *Store) insertNote(n api.Note) {
	s.notes[n.ID] = &n
	ids := s.notesByRepo[n.Repo]
	if i, found := slices.BinarySearch(ids, n.ID); !found {
		s.notesByRepo[n.Repo] = slices.Insert(ids, i, n.ID)
	}
	s.maxNoteID = max(s.maxNoteID, n.ID)
}

func (s *Store) pushEvent(e api.Event) {
	if dropped := s.events.push(e); dropped > 0 {
		s.droppedThrough = dropped
	}
	s.maxEventID = max(s.maxEventID, e.ID)
}

// submit queues the record that build returns and waits until it is durable
// and applied. build runs under the queue lock, so IDs it allocates follow
// the sequence order.
func (s *Store) submit(build func() (op string, data any)) error {
	s.qmu.Lock()
	if s.closing {
		s.qmu.Unlock()
		return ErrClosed
	}
	if s.failed != nil {
		s.qmu.Unlock()
		return fmt.Errorf("%w: %v", ErrUnavailable, s.failed)
	}
	op, data := build()
	raw, err := json.Marshal(data)
	if err != nil {
		s.qmu.Unlock()
		return err
	}
	p := &pending{rec: journal.Record{Seq: s.nextSeq, Op: op, Data: raw}, done: make(chan error, 1)}
	s.nextSeq++
	s.queue = append(s.queue, p)
	s.qmu.Unlock()
	select {
	case s.wake <- struct{}{}:
	default:
	}
	return <-p.done
}

// allocEventID and allocNoteID are called from build functions.
func (s *Store) allocEventID() uint64 {
	id := s.nextEventID
	s.nextEventID++
	return id
}

func (s *Store) allocNoteID() uint64 {
	id := s.nextNoteID
	s.nextNoteID++
	return id
}

func (s *Store) writer() {
	defer close(s.stopped)
	ticker := time.NewTicker(s.opts.SnapshotInterval)
	defer ticker.Stop()
	for {
		select {
		case <-s.wake:
		case <-ticker.C:
			if s.sinceSnapshot > 0 {
				s.snapshot()
			}
			continue
		}
		for {
			s.qmu.Lock()
			batch, closing := s.queue, s.closing
			s.queue = nil
			s.qmu.Unlock()
			if len(batch) == 0 {
				if closing {
					if s.sinceSnapshot > 0 {
						s.snapshot()
					}
					return
				}
				break
			}
			s.write(batch)
			if s.sinceSnapshot >= s.opts.SnapshotEvery {
				s.snapshot()
			}
		}
	}
}

func (s *Store) write(batch []*pending) {
	s.qmu.Lock()
	failed := s.failed
	s.qmu.Unlock()
	if failed != nil {
		for _, p := range batch {
			p.done <- fmt.Errorf("%w: %v", ErrUnavailable, failed)
		}
		return
	}
	recs := make([]journal.Record, len(batch))
	for i, p := range batch {
		recs[i] = p.rec
	}
	err := s.j.Append(recs)
	s.journalBytes.Store(s.j.Size())
	if err != nil {
		// Fail-stop: memory never runs ahead of the journal, and nothing is
		// acknowledged that a restart would lose.
		s.qmu.Lock()
		s.failed = err
		s.qmu.Unlock()
		s.log.Error("journal write failed; the hub no longer accepts changes until it is restarted", "err", err)
		for _, p := range batch {
			p.done <- fmt.Errorf("%w: %v", ErrUnavailable, err)
		}
		return
	}
	var events []api.Event
	s.mu.Lock()
	for _, r := range recs {
		evs, err := s.apply(r)
		if err != nil {
			s.log.Error("apply journal record", "seq", r.Seq, "op", r.Op, "err", err)
		}
		events = append(events, evs...)
	}
	s.appliedSeq = recs[len(recs)-1].Seq
	s.mu.Unlock()
	if len(events) > 0 && s.opts.OnEvents != nil {
		s.opts.OnEvents(events)
	}
	for _, p := range batch {
		p.done <- nil
	}
	s.sinceSnapshot += len(batch)
}

// snapshot writes the applied state and cuts the journal. Failures are not
// fatal: the journal still holds every change.
func (s *Store) snapshot() {
	s.qmu.Lock()
	failed := s.failed
	s.qmu.Unlock()
	if failed != nil || time.Now().Before(s.retrySnapshot) {
		return
	}
	s.mu.RLock()
	st := snapshotState{
		Tokens:         make([]tokenRecord, 0, len(s.tokens)),
		Notes:          make([]api.Note, 0, len(s.notes)),
		Events:         s.events.all(),
		NextEventID:    s.maxEventID + 1,
		NextNoteID:     s.maxNoteID + 1,
		DroppedThrough: s.droppedThrough,
	}
	for _, t := range s.tokens {
		st.Tokens = append(st.Tokens, *t)
	}
	for _, n := range s.notes {
		st.Notes = append(st.Notes, *n)
	}
	seq := s.appliedSeq
	s.mu.RUnlock()
	slices.SortFunc(st.Tokens, func(a, b tokenRecord) int { return strings.Compare(a.ID, b.ID) })
	slices.SortFunc(st.Notes, func(a, b api.Note) int { return compareUint(a.ID, b.ID) })

	raw, err := json.Marshal(st)
	if err == nil {
		err = s.j.Snapshot(seq, raw)
	}
	s.journalBytes.Store(s.j.Size())
	if err != nil {
		s.retrySnapshot = time.Now().Add(time.Minute)
		s.log.Warn("snapshot failed; the journal still holds every change", "err", err)
		return
	}
	s.sinceSnapshot = 0
	s.log.Debug("snapshot written", "seq", seq)
}

func compareUint(a, b uint64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// Close flushes queued changes, writes a final snapshot and releases the
// data directory.
func (s *Store) Close() error {
	s.closeOnce.Do(func() {
		s.qmu.Lock()
		s.closing = true
		s.qmu.Unlock()
		select {
		case s.wake <- struct{}{}:
		default:
		}
		<-s.stopped
		err := s.j.Close()
		if rerr := s.lock.Release(); err == nil {
			err = rerr
		}
		s.closeErr = err
	})
	return s.closeErr
}

// Err is non-nil once the journal could not be written.
func (s *Store) Err() error {
	s.qmu.Lock()
	defer s.qmu.Unlock()
	return s.failed
}

// Stats describes the store for metrics.
type Stats struct {
	JournalBytes int64
	Seq          uint64
	Events       int
	Notes        int
	Tokens       int
}

// Stats returns current counts.
func (s *Store) Stats() Stats {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return Stats{
		JournalBytes: s.journalBytes.Load(),
		Seq:          s.appliedSeq,
		Events:       s.events.len(),
		Notes:        len(s.notes),
		Tokens:       len(s.tokens),
	}
}

// ValidateName checks a token (member) name.
func ValidateName(name string) error {
	if name == "" || utf8.RuneCountInString(name) > 64 {
		return invalidf("name must have 1 to 64 characters")
	}
	for _, r := range name {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) && !strings.ContainsRune("._@+-", r) {
			return invalidf("name may contain letters, digits and . _ @ + - only")
		}
	}
	return nil
}
