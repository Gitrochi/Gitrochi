package ratelimit

import (
	"testing"
	"time"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func TestBurstThenRefill(t *testing.T) {
	c := &clock{t: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
	l := New(2, 3, c.now) // 2/s, burst 3
	for i := range 3 {
		if ok, _ := l.Allow("a"); !ok {
			t.Fatalf("request %d of the burst refused", i)
		}
	}
	ok, wait := l.Allow("a")
	if ok {
		t.Fatal("request past the burst allowed")
	}
	if wait <= 0 || wait > 500*time.Millisecond {
		t.Fatalf("wait %v, want (0, 500ms]", wait)
	}
	if ok, _ := l.Allow("b"); !ok {
		t.Fatal("keys must not share a bucket")
	}
	c.t = c.t.Add(500 * time.Millisecond) // one token back
	if ok, _ := l.Allow("a"); !ok {
		t.Fatal("refilled token refused")
	}
	if ok, _ := l.Allow("a"); ok {
		t.Fatal("only one token should have come back")
	}
	c.t = c.t.Add(time.Hour)
	for i := range 3 {
		if ok, _ := l.Allow("a"); !ok {
			t.Fatalf("a full bucket refused request %d", i)
		}
	}
	if ok, _ := l.Allow("a"); ok {
		t.Fatal("bucket overfilled past the burst")
	}
}

func TestDisabledAndSweep(t *testing.T) {
	if ok, _ := New(0, 1, nil).Allow("x"); !ok {
		t.Fatal("a zero rate must disable limiting")
	}
	c := &clock{t: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
	l := New(1, 1, c.now)
	l.Allow("a")
	l.Allow("b")
	c.t = c.t.Add(time.Minute)
	l.Allow("b")
	if n := l.Sweep(30 * time.Second); n != 1 || l.Len() != 1 {
		t.Fatalf("Sweep removed %d, %d left; want 1, 1", n, l.Len())
	}
}
