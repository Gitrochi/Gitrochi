package stream

import (
	"testing"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
)

func events(repo string, ids ...uint64) []api.Event {
	out := make([]api.Event, len(ids))
	for i, id := range ids {
		out[i] = api.Event{ID: id, Repo: repo, Type: api.EventRefUpdated}
	}
	return out
}

func TestSlowSubscriberIsDroppedWithoutBlocking(t *testing.T) {
	b := NewBroker()
	slow, _ := b.Subscribe("", 2)
	fast, _ := b.Subscribe("", 100)
	done := make(chan struct{})
	go func() {
		// Far more events than the slow buffer holds; Publish must not wait.
		for i := range 50 {
			b.Publish(events("r", uint64(i+1)))
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Publish blocked on a subscriber that does not read")
	}
	select {
	case <-slow.Done():
	default:
		t.Fatal("the slow subscriber was not dropped")
	}
	if slow.Reason() != ReasonSlow || b.Dropped() != 1 {
		t.Fatalf("reason %q, dropped %d", slow.Reason(), b.Dropped())
	}
	if b.Count() != 1 {
		t.Fatalf("Count = %d, want 1", b.Count())
	}
	for i := range 50 {
		if e := <-fast.Events(); e.ID != uint64(i+1) {
			t.Fatalf("fast subscriber got %d, want %d", e.ID, i+1)
		}
	}
}

func TestRepoFilterAndClose(t *testing.T) {
	b := NewBroker()
	one, _ := b.Subscribe("example.com/a", 10)
	all, _ := b.Subscribe("", 10)
	b.Publish(append(events("example.com/a", 1), events("example.com/b", 2)...))
	if e := <-one.Events(); e.ID != 1 {
		t.Fatalf("filtered subscriber got %d", e.ID)
	}
	select {
	case e := <-one.Events():
		t.Fatalf("filtered subscriber got another repository's event %d", e.ID)
	default:
	}
	if len(all.Events()) != 2 {
		t.Fatal("unfiltered subscriber must get both")
	}
	b.Close()
	<-one.Done()
	if one.Reason() != ReasonShutdown {
		t.Fatalf("reason %q", one.Reason())
	}
	if _, err := b.Subscribe("", 1); err != ErrClosed {
		t.Fatalf("Subscribe after Close: %v", err)
	}
	all.Close() // closing an ended subscription is harmless
}
