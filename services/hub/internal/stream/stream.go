// Package stream fans hub events out to live subscribers (the SSE streams).
//
// Publishing never blocks: each subscriber has a bounded buffer, and a
// subscriber whose buffer is full is dropped. A dropped client reconnects
// with Last-Event-ID and catches up from the store's retained events.
package stream

import (
	"errors"
	"sync"
	"sync/atomic"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
)

// Reasons a subscription ends.
const (
	ReasonSlow     = "slow"
	ReasonShutdown = "shutdown"
	ReasonClosed   = "closed"
)

// ErrClosed reports a subscription attempt after Close.
var ErrClosed = errors.New("stream: broker closed")

// Broker distributes events to subscriptions. It is safe for concurrent use.
type Broker struct {
	mu      sync.Mutex
	subs    map[*Subscription]struct{}
	closed  bool
	dropped atomic.Int64
}

// NewBroker returns a broker without subscribers.
func NewBroker() *Broker {
	return &Broker{subs: make(map[*Subscription]struct{})}
}

// Subscription receives the events of one repository, or of all when repo
// is empty.
type Subscription struct {
	b      *Broker
	repo   string
	ch     chan api.Event
	done   chan struct{}
	reason string // set before done is closed
}

// Subscribe adds a subscription with room for buffer pending events.
func (b *Broker) Subscribe(repo string, buffer int) (*Subscription, error) {
	s := &Subscription{
		b:    b,
		repo: repo,
		ch:   make(chan api.Event, max(buffer, 1)),
		done: make(chan struct{}),
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return nil, ErrClosed
	}
	b.subs[s] = struct{}{}
	return s, nil
}

// Publish hands events to every matching subscription without blocking.
func (b *Broker) Publish(events []api.Event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for s := range b.subs {
		for _, e := range events {
			if s.repo != "" && s.repo != e.Repo {
				continue
			}
			select {
			case s.ch <- e:
			default:
				b.endLocked(s, ReasonSlow)
				b.dropped.Add(1)
			}
			if s.reason != "" {
				break
			}
		}
	}
}

// Close ends every subscription; later Subscribe calls fail.
func (b *Broker) Close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.closed = true
	for s := range b.subs {
		b.endLocked(s, ReasonShutdown)
	}
}

// Count is the number of live subscriptions.
func (b *Broker) Count() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.subs)
}

// Dropped counts subscriptions ended for being too slow.
func (b *Broker) Dropped() int64 { return b.dropped.Load() }

func (b *Broker) endLocked(s *Subscription, reason string) {
	if _, ok := b.subs[s]; !ok {
		return
	}
	delete(b.subs, s)
	s.reason = reason
	close(s.done)
}

// Events delivers the subscription's events.
func (s *Subscription) Events() <-chan api.Event { return s.ch }

// Done is closed when the broker ends the subscription.
func (s *Subscription) Done() <-chan struct{} { return s.done }

// Reason says why the subscription ended; read it after Done is closed.
func (s *Subscription) Reason() string {
	s.b.mu.Lock()
	defer s.b.mu.Unlock()
	return s.reason
}

// Close unsubscribes.
func (s *Subscription) Close() {
	s.b.mu.Lock()
	defer s.b.mu.Unlock()
	s.b.endLocked(s, ReasonClosed)
}
