package backoff

import (
	"testing"
	"time"
)

func TestDelayGrowsAndCaps(t *testing.T) {
	p := Policy{Base: time.Second, Max: 30 * time.Second, Factor: 2, Jitter: 0, Rand: func() float64 { return 0.99 }}
	want := []time.Duration{0, time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second, 30 * time.Second}
	for failures, w := range want {
		if got := p.Delay(failures); got != w {
			t.Errorf("Delay(%d) = %v, want %v", failures, got, w)
		}
	}
	if got := p.Delay(10000); got != 30*time.Second {
		t.Errorf("Delay(10000) = %v, want the cap", got)
	}
}

func TestJitterStaysInRange(t *testing.T) {
	for _, r := range []float64{0, 0.25, 0.5, 0.999} {
		p := Policy{Base: 4 * time.Second, Max: time.Minute, Factor: 2, Jitter: 0.5, Rand: func() float64 { return r }}
		got := p.Delay(3) // 16s before jitter
		if got < 8*time.Second || got > 16*time.Second {
			t.Errorf("rand %v: Delay = %v, outside [8s, 16s]", r, got)
		}
	}
	lo := Policy{Base: 4 * time.Second, Jitter: 0.5, Rand: func() float64 { return 0 }}.Delay(1)
	hi := Policy{Base: 4 * time.Second, Jitter: 0.5, Rand: func() float64 { return 0.999 }}.Delay(1)
	if lo == hi {
		t.Fatal("jitter has no effect")
	}
}

func TestStateGatesAttempts(t *testing.T) {
	p := Policy{Base: 10 * time.Second, Max: time.Minute, Jitter: 0, Rand: func() float64 { return 0 }}
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	var s State
	if !s.Ready(now) {
		t.Fatal("a fresh state must be ready")
	}
	if d := s.Fail(p, now); d != 10*time.Second {
		t.Fatalf("first delay %v", d)
	}
	if s.Ready(now.Add(9 * time.Second)) {
		t.Fatal("ready before the delay passed")
	}
	if !s.Ready(now.Add(10 * time.Second)) {
		t.Fatal("not ready after the delay")
	}
	if d := s.Fail(p, now); d != 20*time.Second {
		t.Fatalf("second delay %v, want growth", d)
	}
	s.Succeed()
	if !s.Ready(now) || s.Failures != 0 {
		t.Fatal("Succeed must reset")
	}
}
