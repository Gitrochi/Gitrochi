// Package backoff computes retry delays: exponential growth with jitter, so
// many clients failing together do not retry in lockstep.
package backoff

import (
	"math"
	"math/rand/v2"
	"time"
)

// Policy describes the delays. The zero value is usable: 1s doubling up to
// 5m with 50% jitter.
type Policy struct {
	Base   time.Duration // delay after the first failure
	Max    time.Duration // upper bound
	Factor float64       // growth per failure
	Jitter float64       // fraction of the delay that is randomized, 0..1
	// Rand returns a number in [0, 1); nil uses math/rand/v2.
	Rand func() float64
}

func (p Policy) withDefaults() Policy {
	if p.Base <= 0 {
		p.Base = time.Second
	}
	if p.Max <= 0 {
		p.Max = 5 * time.Minute
	}
	if p.Max < p.Base {
		p.Max = p.Base
	}
	if p.Factor < 1 {
		p.Factor = 2
	}
	if p.Jitter < 0 || p.Jitter > 1 {
		p.Jitter = 0.5
	}
	if p.Rand == nil {
		p.Rand = rand.Float64
	}
	return p
}

// Delay is the wait after the given number of consecutive failures (1 for
// the first). The result lies in [d*(1-Jitter), d], d = min(Max,
// Base*Factor^(failures-1)).
func (p Policy) Delay(failures int) time.Duration {
	p = p.withDefaults()
	if failures < 1 {
		return 0
	}
	d := float64(p.Base) * math.Pow(p.Factor, float64(failures-1))
	if d > float64(p.Max) || math.IsInf(d, 0) || math.IsNaN(d) {
		d = float64(p.Max)
	}
	d -= d * p.Jitter * p.Rand()
	return time.Duration(d)
}

// State tracks consecutive failures of one operation.
type State struct {
	Failures int
	Next     time.Time // no attempt before this time
}

// Ready reports whether an attempt may run at now.
func (s *State) Ready(now time.Time) bool { return !now.Before(s.Next) }

// Fail records a failure at now and returns the delay until the next
// attempt.
func (s *State) Fail(p Policy, now time.Time) time.Duration {
	s.Failures++
	d := p.Delay(s.Failures)
	s.Next = now.Add(d)
	return d
}

// Succeed resets the failure count.
func (s *State) Succeed() {
	s.Failures = 0
	s.Next = time.Time{}
}
