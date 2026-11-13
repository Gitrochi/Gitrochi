package hub

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/store"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/stream"
)

const repoKey = "example.com/team/app"

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Add(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

type harness struct {
	t      *testing.T
	dir    string
	store  *store.Store
	srv    *Server
	base   string
	admin  string
	alice  string
	bob    string
	cancel context.CancelFunc
	done   chan error
}

// start runs a real server on a loopback port. wrap may replace the
// listener (to shrink socket buffers).
func start(t *testing.T, cfg Config, wrap func(net.Listener) net.Listener, opts ...func(*store.Options)) *harness {
	t.Helper()
	h := &harness{t: t, dir: t.TempDir(), done: make(chan error, 1)}
	b := stream.NewBroker()
	so := store.Options{Dir: h.dir, OnEvents: b.Publish}
	for _, o := range opts {
		o(&so)
	}
	st, err := store.Open(so)
	if err != nil {
		t.Fatal(err)
	}
	h.store = st
	for name, dst := range map[string]*string{"admin": &h.admin, "alice": &h.alice, "bob": &h.bob} {
		role := api.RoleMember
		if name == "admin" {
			role = api.RoleAdmin
		}
		resp, err := st.CreateToken(name, role)
		if err != nil {
			t.Fatal(err)
		}
		*dst = resp.Token
	}
	h.srv = New(cfg, st, b, nil)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	h.base = "http://" + ln.Addr().String()
	if wrap != nil {
		ln = wrap(ln)
	}
	ctx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel
	go func() { h.done <- h.srv.Serve(ctx, ln, "", "") }()
	t.Cleanup(func() {
		h.stop()
		st.Close()
	})
	return h
}

func (h *harness) stop() error {
	if h.cancel == nil {
		return nil
	}
	h.cancel()
	h.cancel = nil
	select {
	case err := <-h.done:
		return err
	case <-time.After(20 * time.Second):
		h.t.Fatal("server did not shut down")
		return nil
	}
}

type result struct {
	status int
	header http.Header
	body   []byte
}

func (h *harness) do(method, path, token string, body any) result {
	h.t.Helper()
	var rd io.Reader
	switch b := body.(type) {
	case nil:
	case string:
		rd = strings.NewReader(b)
	default:
		raw, _ := json.Marshal(b)
		rd = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, h.base+path, rd)
	if err != nil {
		h.t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return result{resp.StatusCode, resp.Header, data}
}

func (r result) decode(t *testing.T, v any) {
	t.Helper()
	if err := json.Unmarshal(r.body, v); err != nil {
		t.Fatalf("decoding %s: %v", r.body, err)
	}
}

func (r result) code(t *testing.T) string {
	t.Helper()
	var e api.ErrorBody
	r.decode(t, &e)
	return e.Error.Code
}

func TestAuthenticationAndRoles(t *testing.T) {
	h := start(t, Config{}, nil)
	r := h.do("GET", "/api/v1/me", "", nil)
	if r.status != 401 || r.code(t) != api.CodeUnauthorized || r.header.Get("WWW-Authenticate") == "" {
		t.Fatalf("no token: %d %s", r.status, r.body)
	}
	if r := h.do("GET", "/api/v1/me", "grh_not-a-token", nil); r.status != 401 {
		t.Fatalf("bad token: %d", r.status)
	}
	var me api.Me
	h.do("GET", "/api/v1/me", h.alice, nil).decode(t, &me)
	if me.Name != "alice" || me.Role != api.RoleMember {
		t.Fatalf("me = %+v", me)
	}
	if r := h.do("GET", "/api/v1/tokens", h.alice, nil); r.status != 403 {
		t.Fatalf("member listing tokens: %d", r.status)
	}
	created := h.do("POST", "/api/v1/tokens", h.admin, map[string]string{"name": "carol"})
	if created.status != 201 {
		t.Fatalf("admin creating a token: %d %s", created.status, created.body)
	}
	var carol api.TokenCreateResponse
	created.decode(t, &carol)
	if carol.Role != api.RoleMember || carol.Token == "" {
		t.Fatalf("created %+v", carol)
	}
	if r := h.do("GET", "/api/v1/me", carol.Token, nil); r.status != 200 {
		t.Fatalf("new token: %d", r.status)
	}
	if r := h.do("DELETE", "/api/v1/tokens/"+carol.ID, h.admin, nil); r.status != 200 {
		t.Fatalf("revoke: %d %s", r.status, r.body)
	}
	if r := h.do("GET", "/api/v1/me", carol.Token, nil); r.status != 401 {
		t.Fatalf("revoked token: %d", r.status)
	}
	var list api.TokensResponse
	h.do("GET", "/api/v1/tokens", h.admin, nil).decode(t, &list)
	if len(list.Tokens) != 4 || strings.Contains(string(h.do("GET", "/api/v1/tokens", h.admin, nil).body), "grh_") {
		t.Fatalf("token list must have 4 entries and no secrets: %+v", list)
	}
}

func TestPresenceAndOverlaps(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 5, 1, 9, 0, 0, 0, time.UTC)}
	h := start(t, Config{Now: clock.Now, PresenceTTL: 10 * time.Minute}, nil)
	var first api.PresenceResponse
	r := h.do("POST", "/api/v1/presence", h.alice, api.Presence{
		Repo: "git@example.com:team/app.git", Branch: "feature/login", Head: "ABCDEF1",
		Changed: []string{"src/auth.go", "src/api.go", "src/api.go"}, Related: []string{"docs/auth.md"}, Client: "laptop",
	})
	r.decode(t, &first)
	if r.status != 200 || first.Presence.Repo != repoKey || first.Presence.Head != "abcdef1" || len(first.Presence.Changed) != 2 {
		t.Fatalf("alice's presence: %d %s", r.status, r.body)
	}
	if len(first.Overlaps) != 0 {
		t.Fatal("alice alone has no overlaps")
	}
	var second api.PresenceResponse
	h.do("POST", "/api/v1/presence", h.bob, api.Presence{
		Repo: "https://example.com/team/app", Branch: "feature/docs", Changed: []string{"docs/auth.md", "src/auth.go"}, Client: "desk",
	}).decode(t, &second)
	if len(second.Overlaps) != 2 {
		t.Fatalf("bob's overlaps: %+v", second.Overlaps)
	}
	same, related := second.Overlaps[0], second.Overlaps[1]
	if same.Kind != api.OverlapSameFile || same.A.Member != "alice" || same.B.Member != "bob" || fmt.Sprint(same.Paths) != "[src/auth.go]" {
		t.Fatalf("same-file overlap %+v", same)
	}
	if related.Kind != api.OverlapRelatedFile || related.A.Member != "bob" || related.B.Member != "alice" || fmt.Sprint(related.Paths) != "[docs/auth.md]" {
		t.Fatalf("related-file overlap %+v", related)
	}
	for _, path := range []string{"/api/v1/repos/example.com/team/app/overlaps", "/api/v1/repos/example.com%2Fteam%2Fapp/overlaps", "/api/v1/repos/git@example.com:team%2Fapp.git/overlaps"} {
		var o api.OverlapsResponse
		r := h.do("GET", path, h.admin, nil)
		r.decode(t, &o)
		if r.status != 200 || o.Repo != repoKey || len(o.Overlaps) != 2 {
			t.Fatalf("GET %s: %d %s", path, r.status, r.body)
		}
	}
	var list api.PresenceList
	h.do("GET", "/api/v1/repos/example.com/team/app/presence", h.alice, nil).decode(t, &list)
	if len(list.Presence) != 2 || list.Presence[0].Member != "alice" {
		t.Fatalf("presence list %+v", list)
	}
	// Withdrawing ends the overlaps.
	if r := h.do("DELETE", "/api/v1/presence?repo=example.com/team/app&client=desk", h.bob, nil); r.status != 204 {
		t.Fatalf("delete presence: %d", r.status)
	}
	var o api.OverlapsResponse
	h.do("GET", "/api/v1/repos/example.com/team/app/overlaps", h.alice, nil).decode(t, &o)
	if len(o.Overlaps) != 0 {
		t.Fatalf("overlaps after bob left: %+v", o.Overlaps)
	}
	// Entries expire after the TTL.
	h.do("POST", "/api/v1/presence", h.bob, api.Presence{Repo: repoKey, Changed: []string{"src/auth.go"}})
	clock.Add(11 * time.Minute)
	h.do("GET", "/api/v1/repos/example.com/team/app/overlaps", h.alice, nil).decode(t, &o)
	if len(o.Overlaps) != 0 {
		t.Fatalf("expired presence still overlaps: %+v", o.Overlaps)
	}
}

func TestStrictInput(t *testing.T) {
	h := start(t, Config{MaxBodyBytes: 512}, nil)
	cases := []struct {
		name, path, body string
		status           int
		code             string
	}{
		{"unknown field", "/api/v1/presence", `{"repo":"example.com/a/b","color":"red"}`, 400, api.CodeInvalidArgument},
		{"trailing data", "/api/v1/presence", `{"repo":"example.com/a/b"} {}`, 400, api.CodeInvalidArgument},
		{"empty body", "/api/v1/presence", ``, 400, api.CodeInvalidArgument},
		{"wrong type", "/api/v1/presence", `{"repo":"example.com/a/b","ahead":"3"}`, 400, api.CodeInvalidArgument},
		{"local repo", "/api/v1/presence", `{"repo":"/srv/git/app"}`, 400, api.CodeInvalidArgument},
		{"absolute path", "/api/v1/presence", `{"repo":"example.com/a/b","changed":["/etc/passwd"]}`, 400, api.CodeInvalidArgument},
		{"too large", "/api/v1/presence", `{"repo":"example.com/a/b","changed":["` + strings.Repeat("a", 600) + `"]}`, 413, api.CodePayloadTooLarge},
		{"unknown event type", "/api/v1/events", `{"repo":"example.com/a/b","type":"deploy.done"}`, 400, api.CodeInvalidArgument},
		{"update without old", "/api/v1/events", `{"repo":"example.com/a/b","type":"ref.updated","ref":"refs/heads/main","new":"` + strings.Repeat("a", 40) + `"}`, 400, api.CodeInvalidArgument},
		{"short sha", "/api/v1/events", `{"repo":"example.com/a/b","type":"ref.created","ref":"refs/heads/x","new":"` + strings.Repeat("a", 41) + `"}`, 400, api.CodeInvalidArgument},
		{"bad ref", "/api/v1/events", `{"repo":"example.com/a/b","type":"ref.deleted","ref":"main","old":"` + strings.Repeat("a", 40) + `"}`, 400, api.CodeInvalidArgument},
		{"forced create", "/api/v1/events", `{"repo":"example.com/a/b","type":"ref.created","ref":"refs/heads/x","new":"` + strings.Repeat("a", 40) + `","forced":true}`, 400, api.CodeInvalidArgument},
		{"note without target", "/api/v1/repos/example.com/a/b/notes", `{"body":"hi"}`, 400, api.CodeInvalidArgument},
		{"note line without path", "/api/v1/repos/example.com/a/b/notes", `{"commit":"abcdef1","line":3,"body":"hi"}`, 400, api.CodeInvalidArgument},
	}
	for _, c := range cases {
		r := h.do("POST", c.path, h.alice, c.body)
		if r.status != c.status || r.code(t) != c.code {
			t.Errorf("%s: %d %s, want %d %s", c.name, r.status, r.body, c.status, c.code)
		}
	}
}

func TestRateLimitPerToken(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 5, 1, 9, 0, 0, 0, time.UTC)}
	h := start(t, Config{Now: clock.Now, RateLimit: 1, RateBurst: 2}, nil)
	for i := range 2 {
		if r := h.do("GET", "/api/v1/me", h.alice, nil); r.status != 200 {
			t.Fatalf("request %d: %d", i, r.status)
		}
	}
	r := h.do("GET", "/api/v1/me", h.alice, nil)
	if r.status != 429 || r.code(t) != api.CodeRateLimited {
		t.Fatalf("third request: %d %s", r.status, r.body)
	}
	if secs, err := strconv.Atoi(r.header.Get("Retry-After")); err != nil || secs < 1 {
		t.Fatalf("Retry-After %q", r.header.Get("Retry-After"))
	}
	if r := h.do("GET", "/api/v1/me", h.bob, nil); r.status != 200 {
		t.Fatalf("another token was limited: %d", r.status)
	}
	clock.Add(time.Second)
	if r := h.do("GET", "/api/v1/me", h.alice, nil); r.status != 200 {
		t.Fatalf("after the refill: %d", r.status)
	}
	var m strings.Builder
	h.srv.reg.WriteText(&m)
	if !strings.Contains(m.String(), "gitrochi_hub_rate_limited_total 1\n") {
		t.Fatal("the rejection was not counted")
	}
}

func TestNotes(t *testing.T) {
	h := start(t, Config{}, nil)
	base := "/api/v1/repos/example.com/team/app/notes"
	r := h.do("POST", base, h.alice, api.NoteInput{Path: "src/api.go", Line: 12, Body: "  Keep in sync with the billing API.  "})
	var note api.Note
	r.decode(t, &note)
	if r.status != 201 || note.Author != "alice" || note.Body != "Keep in sync with the billing API." || note.Repo != repoKey {
		t.Fatalf("create: %d %s", r.status, r.body)
	}
	h.do("POST", base, h.bob, api.NoteInput{Commit: "ABCDEF0123", Body: "Reverted in the next release."})
	var list api.NotesResponse
	h.do("GET", base+"?commit=abcdef01", h.alice, nil).decode(t, &list)
	if len(list.Notes) != 1 || list.Notes[0].Author != "bob" {
		t.Fatalf("commit filter: %+v", list.Notes)
	}
	h.do("GET", base+"?path=src/api.go", h.alice, nil).decode(t, &list)
	if len(list.Notes) != 1 || list.Notes[0].ID != note.ID {
		t.Fatalf("path filter: %+v", list.Notes)
	}
	del := fmt.Sprintf("/api/v1/notes/%d", note.ID)
	if r := h.do("DELETE", del, h.bob, nil); r.status != 403 {
		t.Fatalf("another member deleting: %d", r.status)
	}
	if r := h.do("DELETE", del, h.alice, nil); r.status != 204 {
		t.Fatalf("the author deleting: %d %s", r.status, r.body)
	}
	if r := h.do("DELETE", del, h.admin, nil); r.status != 404 {
		t.Fatalf("deleting again: %d", r.status)
	}
	if r := h.do("DELETE", "/api/v1/notes/x", h.admin, nil); r.status != 400 {
		t.Fatalf("bad id: %d", r.status)
	}
	var events api.EventsResponse
	h.do("GET", "/api/v1/events?repo=example.com/team/app", h.alice, nil).decode(t, &events)
	if len(events.Events) != 3 || events.Events[2].Type != api.EventNoteDeleted || events.Events[2].Note == nil {
		t.Fatalf("note events: %+v", events.Events)
	}
}

func TestEventsListing(t *testing.T) {
	h := start(t, Config{}, nil)
	sha := func(c string) string { return strings.Repeat(c, 40) }
	posts := []api.EventInput{
		{Repo: repoKey, Type: api.EventRefCreated, Ref: "refs/heads/a", New: sha("a")},
		{Repo: "example.com/team/other", Type: api.EventCIFailed, Ref: "main", New: "abcdef1", Message: "unit tests"},
		{Repo: repoKey, Type: api.EventRefUpdated, Ref: "refs/heads/a", Old: sha("a"), New: sha("b"), Forced: true},
		{Repo: repoKey, Type: api.EventRefDeleted, Ref: "refs/heads/a", Old: sha("b")},
	}
	for _, p := range posts {
		if r := h.do("POST", "/api/v1/events", h.alice, p); r.status != 201 {
			t.Fatalf("post %+v: %d %s", p, r.status, r.body)
		}
	}
	var page api.EventsResponse
	h.do("GET", "/api/v1/events?repo=git@example.com:team/app.git&limit=2", h.bob, nil).decode(t, &page)
	if len(page.Events) != 2 || !page.More || page.Events[1].ID != 3 || !page.Events[1].Forced || page.Events[0].Member != "alice" {
		t.Fatalf("first page %+v", page)
	}
	h.do("GET", fmt.Sprintf("/api/v1/events?repo=%s&after=%d", repoKey, page.Last), h.bob, nil).decode(t, &page)
	if len(page.Events) != 1 || page.Events[0].Type != api.EventRefDeleted || page.More {
		t.Fatalf("second page %+v", page)
	}
	if r := h.do("GET", "/api/v1/events?limit=0", h.bob, nil); r.status != 400 {
		t.Fatalf("limit 0: %d", r.status)
	}
}

// sseClient reads Server-Sent Events frames.
type sseClient struct {
	resp *http.Response
	rd   *bufio.Reader
}

type frame struct {
	id, event, data string
	comment         bool
}

func (h *harness) stream(t *testing.T, query, lastID string, hc *http.Client) *sseClient {
	t.Helper()
	req, _ := http.NewRequest("GET", h.base+"/api/v1/stream"+query, nil)
	req.Header.Set("Authorization", "Bearer "+h.alice)
	if lastID != "" {
		req.Header.Set("Last-Event-ID", lastID)
	}
	if hc == nil {
		hc = http.DefaultClient
	}
	resp, err := hc.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "text/event-stream" {
		t.Fatalf("stream: %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	t.Cleanup(func() { resp.Body.Close() })
	return &sseClient{resp: resp, rd: newReader(resp)}
}

func newReader(resp *http.Response) *bufio.Reader { return bufio.NewReader(resp.Body) }

// next returns the next frame, comments included.
func (c *sseClient) next() (frame, error) {
	var f frame
	seen := false
	for {
		line, err := c.rd.ReadString('\n')
		if err != nil {
			return f, err
		}
		line = strings.TrimSuffix(line, "\n")
		if line == "" {
			if seen {
				return f, nil
			}
			continue
		}
		seen = true
		switch {
		case strings.HasPrefix(line, ":"):
			f.comment = true
		case strings.HasPrefix(line, "id: "):
			f.id = line[4:]
		case strings.HasPrefix(line, "event: "):
			f.event = line[7:]
		case strings.HasPrefix(line, "data: "):
			f.data = line[6:]
		}
	}
}

// nextEvent skips comments and the retry hint.
func (c *sseClient) nextEvent(t *testing.T) frame {
	t.Helper()
	for {
		f, err := c.next()
		if err != nil {
			t.Fatalf("reading the stream: %v", err)
		}
		if !f.comment && f.event != "" {
			return f
		}
	}
}

func TestStreamResumesWithLastEventIDThenGoesLive(t *testing.T) {
	h := start(t, Config{SSEHeartbeat: 50 * time.Millisecond}, nil)
	for i := range 3 {
		h.do("POST", "/api/v1/events", h.bob, api.EventInput{Repo: repoKey, Type: api.EventCIFailed, Message: fmt.Sprint("run ", i+1)})
	}
	h.do("POST", "/api/v1/events", h.bob, api.EventInput{Repo: "example.com/team/other", Type: api.EventCIPassed})
	s := h.stream(t, "?repo=example.com/team/app", "1", nil)
	for _, want := range []string{"2", "3"} {
		f := s.nextEvent(t)
		if f.id != want || f.event != api.EventCIFailed {
			t.Fatalf("backlog frame %+v, want id %s", f, want)
		}
	}
	h.do("POST", "/api/v1/events", h.bob, api.EventInput{Repo: repoKey, Type: api.EventCIPassed, Message: "live"})
	f := s.nextEvent(t)
	var e api.Event
	json.Unmarshal([]byte(f.data), &e)
	if f.id != "5" || e.Message != "live" || e.Member != "bob" {
		t.Fatalf("live frame %+v", f)
	}
	// Idle streams carry heartbeats.
	for {
		f, err := s.next()
		if err != nil {
			t.Fatal(err)
		}
		if f.comment {
			break
		}
	}
}

func TestStreamReportsTruncatedHistory(t *testing.T) {
	h := start(t, Config{}, nil, func(o *store.Options) { o.EventRetention = 2 })
	for range 4 {
		h.do("POST", "/api/v1/events", h.bob, api.EventInput{Repo: repoKey, Type: api.EventCIPassed})
	}
	s := h.stream(t, "", "1", nil)
	f := s.nextEvent(t)
	if f.event != "truncated" || f.data != `{"after":1,"oldest":3}` {
		t.Fatalf("first frame %+v, want truncated", f)
	}
	for _, want := range []string{"3", "4"} {
		if f := s.nextEvent(t); f.id != want {
			t.Fatalf("frame %+v, want id %s", f, want)
		}
	}
	// A cursor inside the retained range resumes without the warning.
	if f := h.stream(t, "", "3", nil).nextEvent(t); f.event == "truncated" || f.id != "4" {
		t.Fatalf("frame %+v", f)
	}
	// A cursor from before a reset of the hub's data starts over.
	s = h.stream(t, "", "99", nil)
	if f := s.nextEvent(t); f.event != "truncated" || f.data != `{"after":99,"oldest":3}` {
		t.Fatalf("future cursor: first frame %+v", f)
	}
	if f := s.nextEvent(t); f.id != "3" {
		t.Fatalf("future cursor: frame %+v, want the oldest retained event", f)
	}
}

// smallBuffers shrinks the server side of every accepted connection's send
// buffer, so a client that stops reading fills it quickly.
type smallBuffers struct{ net.Listener }

func (l smallBuffers) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if tc, ok := c.(*net.TCPConn); ok {
		tc.SetWriteBuffer(4096)
	}
	return c, err
}

func TestSlowStreamSubscriberIsDropped(t *testing.T) {
	h := start(t, Config{SSEBuffer: 4, SSEWriteTimeout: time.Minute, SSEHeartbeat: time.Hour},
		func(l net.Listener) net.Listener { return smallBuffers{l} })
	hc := &http.Client{Transport: &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			c, err := (&net.Dialer{}).DialContext(ctx, network, addr)
			if tc, ok := c.(*net.TCPConn); ok {
				tc.SetReadBuffer(4096)
			}
			return c, err
		},
	}}
	s := h.stream(t, "", "", hc) // connected, then never read
	waitFor(t, func() bool { return h.srv.broker.Count() == 1 })

	big := strings.Repeat("x", maxMessageLen)
	start := time.Now()
	var wg sync.WaitGroup
	for w := range 8 {
		wg.Go(func() {
			for i := range 60 {
				if _, err := h.store.AppendEvent(api.EventInput{Repo: repoKey, Type: api.EventCIFailed, Message: big}, fmt.Sprint("w", w, i)); err != nil {
					t.Error(err)
					return
				}
			}
		})
	}
	wg.Wait()
	if d := time.Since(start); d > 30*time.Second {
		t.Fatalf("publishing took %v: a slow subscriber must not hold publishers back", d)
	}
	waitFor(t, func() bool { return h.srv.broker.Count() == 0 })
	if h.srv.broker.Dropped() != 1 {
		t.Fatalf("dropped = %d, want 1", h.srv.broker.Dropped())
	}
	// The dropped client sees its stream end and would resume with Last-Event-ID.
	done := make(chan error, 1)
	go func() {
		_, err := io.Copy(io.Discard, s.rd)
		done <- err
	}()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("the dropped stream did not end")
	}
}

func TestStreamOutlivesServerTimeouts(t *testing.T) {
	h := start(t, Config{ReadTimeout: 300 * time.Millisecond, WriteTimeout: 300 * time.Millisecond, SSEHeartbeat: 100 * time.Millisecond}, nil)
	s := h.stream(t, "", "", nil)
	time.Sleep(900 * time.Millisecond) // three times both timeouts
	h.do("POST", "/api/v1/events", h.bob, api.EventInput{Repo: repoKey, Type: api.EventCIPassed, Message: "late"})
	f := s.nextEvent(t)
	if !strings.Contains(f.data, `"late"`) {
		t.Fatalf("frame %+v", f)
	}
}

func TestGracefulShutdownDrainsStreamsAndFlushes(t *testing.T) {
	h := start(t, Config{}, nil)
	s := h.stream(t, "", "", nil)
	r := h.do("POST", "/api/v1/events", h.bob, api.EventInput{Repo: repoKey, Type: api.EventCIFailed, Message: "before shutdown"})
	if r.status != 201 {
		t.Fatal(r.status)
	}
	if f := s.nextEvent(t); f.event != api.EventCIFailed {
		t.Fatalf("frame %+v", f)
	}
	began := time.Now()
	if err := h.stop(); err != nil {
		t.Fatalf("Serve: %v", err)
	}
	if d := time.Since(began); d > 5*time.Second {
		t.Fatalf("shutdown took %v with an open stream", d)
	}
	if f := s.nextEvent(t); f.event != "shutdown" {
		t.Fatalf("last frame %+v, want shutdown", f)
	}
	if _, err := s.next(); err != io.EOF && err != io.ErrUnexpectedEOF {
		t.Fatalf("after shutdown: %v, want the stream to end", err)
	}
	if err := h.store.Close(); err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(store.Options{Dir: h.dir})
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if got := st.Events("", 0, 10); len(got.Events) != 1 || got.Events[0].Message != "before shutdown" {
		t.Fatalf("after restart: %+v", got.Events)
	}
}

func TestHealthReadyAndMetrics(t *testing.T) {
	h := start(t, Config{Version: api.Version{Version: "1.2.3"}}, nil)
	var health struct {
		Status  string      `json:"status"`
		Version api.Version `json:"version"`
	}
	h.do("GET", "/healthz", "", nil).decode(t, &health)
	if health.Status != "ok" || health.Version.Version != "1.2.3" {
		t.Fatalf("healthz %+v", health)
	}
	if r := h.do("GET", "/readyz", "", nil); r.status != 200 {
		t.Fatalf("readyz %d", r.status)
	}
	h.do("POST", "/api/v1/presence", h.alice, api.Presence{Repo: repoKey})
	h.do("POST", "/api/v1/presence", h.bob, api.Presence{Repo: repoKey})
	h.do("POST", "/api/v1/events", h.bob, api.EventInput{Repo: repoKey, Type: api.EventCIPassed})
	h.do("GET", "/api/v1/repos/example.com/team/app/overlaps", h.bob, nil)
	h.do("GET", "/nowhere", h.bob, nil)
	h.stream(t, "", "", nil)
	waitFor(t, func() bool { return h.srv.broker.Count() == 1 })
	m := string(h.do("GET", "/metrics", "", nil).body)
	for _, want := range []string{
		`gitrochi_hub_http_requests_total{route="POST /api/v1/presence",code="200"} 2`,
		`gitrochi_hub_http_requests_total{route="GET /api/v1/repos/{repo}/overlaps",code="200"} 1`,
		`gitrochi_hub_http_requests_total{route="unmatched",code="404"} 1`,
		"gitrochi_hub_sse_subscribers 1\n",
		"gitrochi_hub_presence_entries 2\n",
		"gitrochi_hub_events_retained 1\n",
		`gitrochi_hub_build_info{version="1.2.3"`,
	} {
		if !strings.Contains(m, want) {
			t.Errorf("metrics lack %q", want)
		}
	}
	if !strings.Contains(m, "gitrochi_hub_journal_bytes ") || strings.Contains(m, "gitrochi_hub_journal_bytes 0\n") {
		t.Error("journal size missing or zero")
	}
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not reached in time")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
