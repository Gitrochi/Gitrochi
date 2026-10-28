package store

import (
	"sort"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
)

// eventRing keeps the newest events, oldest first, up to limit. It grows on
// demand so a small hub does not pay for the full retention up front.
type eventRing struct {
	buf   []api.Event
	start int
	n     int
	limit int
}

// push appends e and returns the ID of the event it pushed out, or 0.
func (r *eventRing) push(e api.Event) uint64 {
	if r.n < len(r.buf) {
		r.buf[(r.start+r.n)%len(r.buf)] = e
		r.n++
		return 0
	}
	if len(r.buf) < r.limit {
		grown := make([]api.Event, min(max(2*len(r.buf), 64), r.limit))
		for i := range r.n {
			grown[i] = *r.at(i)
		}
		r.buf, r.start = grown, 0
		r.buf[r.n] = e
		r.n++
		return 0
	}
	dropped := r.buf[r.start].ID
	r.buf[r.start] = e
	r.start = (r.start + 1) % len(r.buf)
	return dropped
}

func (r *eventRing) len() int { return r.n }

func (r *eventRing) at(i int) *api.Event { return &r.buf[(r.start+i)%len(r.buf)] }

// firstAfter is the index of the oldest event with an ID above id.
func (r *eventRing) firstAfter(id uint64) int {
	return sort.Search(r.n, func(i int) bool { return r.at(i).ID > id })
}

func (r *eventRing) oldest() uint64 {
	if r.n == 0 {
		return 0
	}
	return r.at(0).ID
}

func (r *eventRing) all() []api.Event {
	out := make([]api.Event, r.n)
	for i := range r.n {
		out[i] = *r.at(i)
	}
	return out
}
