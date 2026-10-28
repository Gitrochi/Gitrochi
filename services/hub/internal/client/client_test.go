package client

import (
	"context"
	"errors"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/hub"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/store"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/stream"
)

// startHub serves a real hub, optionally under a path prefix.
func startHub(t *testing.T, cfg hub.Config, prefix string) (base string, tokens map[string]string) {
	t.Helper()
	b := stream.NewBroker()
	st, err := store.Open(store.Options{Dir: t.TempDir(), OnEvents: b.Publish})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	tokens = map[string]string{}
	for _, name := range []string{"alice", "bob"} {
		resp, err := st.CreateToken(name, api.RoleMember)
		if err != nil {
			t.Fatal(err)
		}
		tokens[name] = resp.Token
	}
	var h http.Handler = hub.New(cfg, st, b, nil).Handler()
	if prefix != "" {
		h = http.StripPrefix(strings.TrimSuffix(prefix, "/"), h)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: h, ReadHeaderTimeout: 5 * time.Second}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	return "http://" + ln.Addr().String() + prefix, tokens
}

func TestNewValidatesTheURL(t *testing.T) {
	for _, bad := range []string{"", "hub.example.com", "ftp://hub.example.com", "https://user:pw@hub.example.com"} {
		if _, err := New(bad, "t", Options{}); err == nil {
			t.Errorf("New(%q) accepted", bad)
		}
	}
	_, err := New("https://user:hunter2@hub.example.com", "t", Options{})
	if err == nil || strings.Contains(err.Error(), "hunter2") {
		t.Fatalf("credentials error %v", err)
	}
}

func TestRoundTripUnderAPathPrefix(t *testing.T) {
	base, tokens := startHub(t, hub.Config{}, "/hub/")
	ctx := context.Background()
	alice, err := New(base, tokens["alice"], Options{})
	if err != nil {
		t.Fatal(err)
	}
	bob, _ := New(base, tokens["bob"], Options{})
	me, err := alice.Me(ctx)
	if err != nil || me.Name != "alice" {
		t.Fatalf("Me = %+v, %v", me, err)
	}
	if _, err := bob.PostPresence(ctx, api.Presence{Repo: "example.com/team/app", Changed: []string{"a.go"}, Client: "desk"}); err != nil {
		t.Fatal(err)
	}
	resp, err := alice.PostPresence(ctx, api.Presence{Repo: "git@example.com:team/app.git", Changed: []string{"a.go"}, Client: "laptop"})
	if err != nil || len(resp.Overlaps) != 1 || resp.Overlaps[0].Kind != api.OverlapSameFile {
		t.Fatalf("PostPresence = %+v, %v", resp, err)
	}
	ov, err := bob.Overlaps(ctx, "example.com/team/app")
	if err != nil || ov.Repo != "example.com/team/app" || len(ov.Overlaps) != 1 {
		t.Fatalf("Overlaps = %+v, %v", ov, err)
	}
	pl, err := bob.Presence(ctx, "example.com/team/app")
	if err != nil || len(pl.Presence) != 2 {
		t.Fatalf("Presence = %+v, %v", pl, err)
	}
	e, err := alice.PostEvent(ctx, api.EventInput{Repo: "example.com/team/app", Type: api.EventCIFailed, Message: "lint"})
	if err != nil || e.ID != 1 || e.Member != "alice" {
		t.Fatalf("PostEvent = %+v, %v", e, err)
	}
	evs, err := bob.Events(ctx, "example.com/team/app", 0, 10)
	if err != nil || len(evs.Events) != 1 || evs.Last != 1 {
		t.Fatalf("Events = %+v, %v", evs, err)
	}
	if err := alice.DeletePresence(ctx, "example.com/team/app", "laptop"); err != nil {
		t.Fatal(err)
	}
	if ov, _ := bob.Overlaps(ctx, "example.com/team/app"); len(ov.Overlaps) != 0 {
		t.Fatalf("overlaps after withdrawal: %+v", ov)
	}
	if err := Health(ctx, base+"healthz", false); err != nil {
		t.Fatalf("Health: %v", err)
	}
}

func TestErrors(t *testing.T) {
	now := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	base, tokens := startHub(t, hub.Config{RateLimit: 1, RateBurst: 1, Now: func() time.Time { return now }}, "")
	ctx := context.Background()
	bad, _ := New(base, "grh_wrong", Options{})
	_, err := bad.Me(ctx)
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Status != 401 || apiErr.Code != api.CodeUnauthorized || Retryable(err) {
		t.Fatalf("bad token: %v", err)
	}
	c, _ := New(base, tokens["alice"], Options{})
	if _, err := c.PostEvent(ctx, api.EventInput{Repo: "example.com/team/app", Type: "nope"}); !errors.As(err, &apiErr) || apiErr.Code != api.CodeInvalidArgument || Retryable(err) {
		t.Fatalf("invalid event: %v", err)
	}
	_, err = c.Me(ctx) // the burst of one was spent above
	if !errors.As(err, &apiErr) || apiErr.Status != 429 || apiErr.RetryAfter < time.Second || !Retryable(err) {
		t.Fatalf("rate limited: %v", err)
	}
	if !Retryable(errors.New("connection refused")) || Retryable(context.Canceled) {
		t.Fatal("Retryable for plain errors")
	}
	if err := Health(ctx, "http://127.0.0.1:1", false); err == nil {
		t.Fatal("Health of a closed port must fail")
	}
}
