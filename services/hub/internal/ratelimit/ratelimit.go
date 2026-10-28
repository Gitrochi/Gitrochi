// Package ratelimit limits requests per key (a token) with token buckets.
package ratelimit

import (
	"math"
	"sync"
	"time"
)

// Limiter holds one bucket per key. It is safe for concurrent use.
type Limiter struct {
	rate  float64 // tokens added per second
	burst float64
	now   func() time.Time

	mu      sync.Mutex
	buckets map[string]*bucket
}

type bucket struct {
	tokens float64
	last   time.Time
}

// New returns a limiter allowing rate requests per second per key with
// bursts of up to burst. A rate of zero or less disables limiting. now may
// be nil.
func New(rate float64, burst int, now func() time.Time) *Limiter {
	if now == nil {
		now = time.Now
	}
	return &Limiter{
		rate:    rate,
		burst:   math.Max(float64(burst), 1),
		now:     now,
		buckets: make(map[string]*bucket),
	}
}

// Allow takes a token from key's bucket. When the bucket is empty it
// returns false and how long until a token is available.
func (l *Limiter) Allow(key string) (bool, time.Duration) {
	if l.rate <= 0 {
		return true, 0
	}
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()
	b := l.buckets[key]
	if b == nil {
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	}
	if elapsed := now.Sub(b.last).Seconds(); elapsed > 0 {
		b.tokens = math.Min(l.burst, b.tokens+elapsed*l.rate)
	}
	b.last = now
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	wait := time.Duration((1 - b.tokens) / l.rate * float64(time.Second))
	return false, wait
}

// Sweep forgets buckets untouched for longer than idle; a forgotten bucket
// comes back full, which an idle key would have reached anyway.
func (l *Limiter) Sweep(idle time.Duration) int {
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()
	n := 0
	for k, b := range l.buckets {
		if now.Sub(b.last) > idle {
			delete(l.buckets, k)
			n++
		}
	}
	return n
}

// Len counts tracked keys.
func (l *Limiter) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}
