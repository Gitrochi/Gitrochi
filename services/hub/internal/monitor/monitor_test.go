package monitor

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/client"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/gittest"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/hub"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/index"
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

// realHub serves a real hub on a loopback port.
func realHub(t *testing.T) (url string, tokens map[string]string) {
	t.Helper()
	b := stream.NewBroker()
	st, err := store.Open(store.Options{Dir: t.TempDir(), OnEvents: b.Publish})
	if err != nil {
		t.Fatal(err)
	}
	tokens = map[string]string{}
	for _, name := range []string{"alice", "bob"} {
		resp, err := st.CreateToken(name, api.RoleMember)
		if err != nil {
			t.Fatal(err)
		}
		tokens[name] = resp.Token
	}
	srv := hub.New(hub.Config{}, st, b, nil)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { srv.Serve(ctx, ln, "", ""); close(done) }()
	t.Cleanup(func() { cancel(); <-done; st.Close() })
	return "http://" + ln.Addr().String(), tokens
}

func writeScript(t *testing.T, name, body string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the fakes are shell scripts")
	}
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// fakeIndex answers sync and impact the way the contract describes, and
// logs its arguments next to itself.
const fakeIndex = `printf '%s\n' "$*" >> "$(dirname "$0")/calls"
while [ $# -gt 0 ]; do case "$1" in --repo|--db) shift 2 ;; --) shift ;; *) break ;; esac; done
case "$1" in
  sync) echo '{"repository":"r","database":"d","upToDate":false,"newCommits":1,"totalCommits":1,"refs":1,"durationMs":1,"shallow":false}' ;;
  impact) echo '{"changed":[],"suggestions":[{"path":"docs/api.md","score":0.9,"because":[{"path":"src/api.go","commits":3,"confidence":0.75}]},{"path":"src/api.go","score":0.5,"because":[]}]}' ;;
  *) exit 2 ;;
esac
`

// slowGit runs the real git a little slower and counts, from the outside,
// how many run at once.
const slowGit = `mkdir "$FAKE_DIR/run.$$"
ls -d "$FAKE_DIR"/run.* | wc -l >> "$FAKE_DIR/counts"
sleep 0.05
git "$@"
code=$?
rmdir "$FAKE_DIR/run.$$"
exit $code
`

// fixture is a repository whose origin names example.com/team/app (it is
// never fetched), on a feature branch with one commit and one dirty file.
func fixture(t *testing.T, env []string) *gittest.Repo {
	t.Helper()
	repo := gittest.Init(t, env)
	repo.Commit("base", map[string]string{"src/api.go": "v1\n", "docs/api.md": "doc\n", "README.md": "hello\n"})
	repo.Git("remote", "add", "origin", "https://example.com/team/app.git")
	repo.Git("switch", "-q", "-c", "feature/a")
	repo.Commit("api", map[string]string{"src/api.go": "v2\n"})
	repo.Write("README.md", "work in progress\n")
	return repo
}

func newMonitor(t *testing.T, cfg Config, opts Options) *Monitor {
	t.Helper()
	if cfg.State == "" {
		cfg.State = filepath.Join(t.TempDir(), "state.json")
	}
	if cfg.Listen == "" {
		cfg.Listen = ListenOff
	}
	if cfg.Client == "" {
		cfg.Client = "laptop"
	}
	if err := cfg.Prepare(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if opts.Getenv == nil {
		opts.Getenv = func(string) string { return "" }
	}
	m, err := New(cfg, opts)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func countLines(t *testing.T, path, substr string) int {
	t.Helper()
	b, _ := os.ReadFile(path)
	n := 0
	for line := range strings.SplitSeq(string(b), "\n") {
		if strings.Contains(line, substr) {
			n++
		}
	}
	return n
}

func TestOncePublishesPresenceRelatedFilesAndRefEvents(t *testing.T) {
	env := gittest.Env(t)
	repo := fixture(t, env)
	hubURL, tokens := realHub(t)
	idx := writeScript(t, "gitrochi-index", fakeIndex)
	calls := filepath.Join(filepath.Dir(idx), "calls")
	cfg := Config{Repos: []RepoConfig{{Path: repo.Dir}}, Hub: hubURL, Index: idx, State: filepath.Join(t.TempDir(), "state.json")}
	ctx := context.Background()

	// Bob changes the file alice changed and the doc her change usually needs.
	bob, _ := client.New(hubURL, tokens["bob"], client.Options{})
	if _, err := bob.PostPresence(ctx, api.Presence{Repo: repoKey, Branch: "feature/b", Changed: []string{"docs/api.md", "src/api.go"}, Client: "desk"}); err != nil {
		t.Fatal(err)
	}

	first := newMonitor(t, cfg, Options{Token: tokens["alice"], GitEnv: env}).Once(ctx)
	if first.Failed() {
		t.Fatalf("status %+v", first)
	}
	r := first.Repos[0]
	base := repo.Git("rev-parse", "main")
	if r.Key != repoKey || r.Branch != "feature/a" || r.Changed != 2 || r.Dirty != 1 ||
		r.DefaultBranch != "refs/heads/main" || r.Base != base || r.LastSync.IsZero() {
		t.Fatalf("repo status %+v", r)
	}
	if fmt.Sprint(r.Related) != "[docs/api.md]" {
		t.Fatalf("related %v: suggestions minus the changed files", r.Related)
	}
	if len(r.RecentChanges) != 0 {
		t.Fatalf("the first sight of a repository is no change: %+v", r.RecentChanges)
	}
	kinds := map[string]string{}
	for _, o := range r.Overlaps {
		kinds[o.Kind] = o.A.Member + ">" + o.B.Member + fmt.Sprint(o.Paths)
	}
	if kinds[api.OverlapSameFile] != "alice>bob[src/api.go]" || kinds[api.OverlapRelatedFile] != "bob>alice[docs/api.md]" {
		t.Fatalf("overlaps %+v", r.Overlaps)
	}
	list, err := bob.Presence(ctx, repoKey)
	if err != nil || len(list.Presence) != 2 {
		t.Fatalf("presence %+v, %v", list, err)
	}
	alice := list.Presence[0]
	if alice.Member != "alice" || alice.Client != "laptop" || alice.Head != repo.Git("rev-parse", "HEAD") || alice.Base != base ||
		fmt.Sprint(alice.Changed) != "[README.md src/api.go]" || fmt.Sprint(alice.Related) != "[docs/api.md]" {
		t.Fatalf("alice's presence %+v", alice)
	}
	if countLines(t, calls, " sync") != 1 || countLines(t, calls, " impact -- README.md src/api.go") != 1 {
		b, _ := os.ReadFile(calls)
		t.Fatalf("index calls:\n%s", b)
	}

	// Before the next run (a cron job, say): feature/a is rewritten,
	// feature/b appears and main moves forward.
	oldTip := repo.Git("rev-parse", "HEAD")
	repo.Git("reset", "-q", "--hard", "main")
	newTip := repo.Commit("rewrite", map[string]string{"src/db.go": "db\n"})
	repo.Git("branch", "feature/b")
	repo.Git("switch", "-q", "main")
	mainTip := repo.Commit("main moves", map[string]string{"CHANGELOG.md": "1\n"})
	repo.Git("switch", "-q", "feature/a")

	second := newMonitor(t, cfg, Options{Token: tokens["alice"], GitEnv: env}).Once(ctx)
	if second.Failed() {
		t.Fatalf("status %+v", second)
	}
	events, err := bob.Events(ctx, repoKey, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	type ev struct {
		typ, ref, old, new string
		forced             bool
	}
	var got []ev
	for _, e := range events.Events {
		if e.Member != "alice" {
			t.Fatalf("event by %q", e.Member)
		}
		got = append(got, ev{e.Type, e.Ref, e.Old, e.New, e.Forced})
	}
	want := []ev{
		{api.EventRefUpdated, "refs/heads/feature/a", oldTip, newTip, true},
		{api.EventRefCreated, "refs/heads/feature/b", "", newTip, false},
		{api.EventRefUpdated, "refs/heads/main", base, mainTip, false},
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("events\n got  %+v\n want %+v", got, want)
	}
	r = second.Repos[0]
	if len(r.RecentChanges) != 3 || r.PendingEvents != 0 || r.Changed != 1 || r.Base != base {
		t.Fatalf("second run %+v", r)
	}
	if countLines(t, calls, " sync") != 2 {
		t.Fatal("a ref change must sync the index again")
	}
}

// fakeHub answers like a hub, or fails on demand.
type fakeHub struct {
	mu     sync.Mutex
	mode   string // up, down or busy
	hits   map[string]int
	events []api.EventInput
	srv    *httptest.Server
}

func newFakeHub(t *testing.T) *fakeHub {
	h := &fakeHub{mode: "down", hits: map[string]int{}}
	h.srv = httptest.NewServer(http.HandlerFunc(h.serve))
	t.Cleanup(h.srv.Close)
	return h
}

func (h *fakeHub) serve(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.hits[r.URL.Path]++
	switch h.mode {
	case "down":
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte(`{"error":{"code":"UNAVAILABLE","message":"down for maintenance"}}`))
		return
	case "busy":
		w.Header().Set("Retry-After", "120")
		w.WriteHeader(http.StatusTooManyRequests)
		w.Write([]byte(`{"error":{"code":"RATE_LIMITED","message":"slow down"}}`))
		return
	}
	switch r.URL.Path {
	case "/api/v1/events":
		var e api.EventInput
		json.NewDecoder(r.Body).Decode(&e)
		h.events = append(h.events, e)
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(api.Event{ID: uint64(len(h.events)), Repo: e.Repo, Type: e.Type})
	case "/api/v1/presence":
		json.NewEncoder(w).Encode(api.PresenceResponse{Overlaps: []api.Overlap{}})
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (h *fakeHub) set(mode string) {
	h.mu.Lock()
	h.mode = mode
	h.mu.Unlock()
}

func (h *fakeHub) total() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	n := 0
	for _, v := range h.hits {
		n += v
	}
	return n
}

func (h *fakeHub) delivered() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []string
	for _, e := range h.events {
		out = append(out, e.Type+" "+e.Ref)
	}
	return out
}

func TestHubFailuresBackOffAndEventsSurviveARestart(t *testing.T) {
	env := gittest.Env(t)
	repo := fixture(t, env)
	fake := newFakeHub(t)
	clock := &fakeClock{t: time.Date(2026, 6, 1, 9, 0, 0, 0, time.UTC)}
	t0 := clock.Now()
	state := filepath.Join(t.TempDir(), "state.json")
	cfg := Config{Repos: []RepoConfig{{Path: repo.Dir}}, Hub: fake.srv.URL, Index: index.Off, State: state}
	opts := Options{Token: "grh_test", GitEnv: env, Now: clock.Now, Rand: func() float64 { return 0 }}
	ctx := context.Background()

	m := newMonitor(t, cfg, opts)
	r := m.Once(ctx).Repos[0]
	if fake.total() != 1 || r.HubError == "" || !r.HubRetryAt.Equal(t0.Add(2*time.Second)) || r.LastError != "" {
		t.Fatalf("after the first failure: %d requests, %+v", fake.total(), r)
	}
	m.Once(ctx)
	if fake.total() != 1 {
		t.Fatal("the hub was called again before the backoff delay passed")
	}
	repo.Git("branch", "feature/x")
	clock.Add(time.Second)
	if r := m.Once(ctx).Repos[0]; fake.total() != 1 || r.PendingEvents != 1 {
		t.Fatalf("still backing off: %d requests, pending %d", fake.total(), r.PendingEvents)
	}
	clock.Add(time.Second)
	r = m.Once(ctx).Repos[0]
	if fake.total() != 2 || !r.HubRetryAt.Equal(clock.Now().Add(4*time.Second)) {
		t.Fatalf("second failure: %d requests, retry at %v; the delay must double", fake.total(), r.HubRetryAt)
	}
	if b, _ := os.ReadFile(state); !strings.Contains(string(b), `"pending"`) || !strings.Contains(string(b), "refs/heads/feature/x") {
		t.Fatalf("the undelivered event is not in the state file:\n%s", b)
	}

	// A restart while the hub is down keeps the event; it goes out once the
	// hub is back.
	fake.set("up")
	clock.Add(time.Second)
	m = newMonitor(t, cfg, opts)
	r = m.Once(ctx).Repos[0]
	if fmt.Sprint(fake.delivered()) != "[ref.created refs/heads/feature/x]" || r.HubError != "" || r.PendingEvents != 0 || r.LastPublish.IsZero() {
		t.Fatalf("after recovery: delivered %v, status %+v", fake.delivered(), r)
	}

	// Retry-After from the hub outweighs a shorter backoff.
	fake.set("busy")
	repo.Git("branch", "feature/y")
	clock.Add(time.Second)
	before := fake.total()
	r = m.Once(ctx).Repos[0]
	if fake.total() != before+1 || !r.HubRetryAt.Equal(clock.Now().Add(120*time.Second)) {
		t.Fatalf("rate limited: retry at %v, want now+120s", r.HubRetryAt)
	}
	clock.Add(60 * time.Second)
	m.Once(ctx)
	if fake.total() != before+1 {
		t.Fatal("the hub was called before its Retry-After passed")
	}
	fake.set("up")
	clock.Add(61 * time.Second)
	m.Once(ctx)
	if got := fake.delivered(); len(got) != 2 || got[1] != "ref.created refs/heads/feature/y" {
		t.Fatalf("delivered %v", got)
	}
}

func maxCount(t *testing.T, path string) int {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	most := 0
	for _, f := range strings.Fields(string(b)) {
		n, _ := strconv.Atoi(f)
		most = max(most, n)
	}
	return most
}

func TestProcessLimitHoldsAcrossRepositories(t *testing.T) {
	env := gittest.Env(t)
	countDir := t.TempDir()
	git := writeScript(t, "slow-git", slowGit)
	var repos []RepoConfig
	for range 6 {
		repos = append(repos, RepoConfig{Path: fixture(t, env).Dir})
	}
	m := newMonitor(t, Config{Repos: repos, Git: git, MaxGitProcesses: 2, Index: index.Off},
		Options{GitEnv: append(env, "FAKE_DIR="+countDir)})
	st := m.Once(context.Background())
	for _, r := range st.Repos {
		if r.LastError != "" || r.Branch != "feature/a" {
			t.Fatalf("repo %+v", r)
		}
	}
	most := maxCount(t, filepath.Join(countDir, "counts"))
	if most > 2 {
		t.Fatalf("%d git processes ran at once; the limit is 2", most)
	}
	if most < 2 {
		t.Fatal("repositories were polled one process at a time; the limit allows two")
	}
	if st.Git.Peak > 2 || st.Git.Limit != 2 || st.Git.Started < 6*4 {
		t.Fatalf("runner stats %+v", st.Git)
	}
}

func TestPassesOverOneRepositoryNeverOverlap(t *testing.T) {
	env := gittest.Env(t)
	git := writeScript(t, "slow-git", slowGit)
	m := newMonitor(t, Config{Repos: []RepoConfig{{Path: fixture(t, env).Dir}}, Git: git, MaxGitProcesses: 8, Index: index.Off},
		Options{GitEnv: append(env, "FAKE_DIR="+t.TempDir())})
	var wg sync.WaitGroup
	for range 4 {
		wg.Go(func() { m.Once(context.Background()) })
	}
	wg.Wait()
	if n := m.repos[0].maxSeen.Load(); n != 1 {
		t.Fatalf("%d passes over one repository ran at once", n)
	}
	if st := m.Status(); st.Repos[0].Polls != 4 || st.Repos[0].LastError != "" {
		t.Fatalf("status %+v", st.Repos[0])
	}
}

func TestTriggersCoalesce(t *testing.T) {
	m := newMonitor(t, Config{Repos: []RepoConfig{{Path: t.TempDir()}}, PollInterval: Duration(time.Hour), Index: index.Off},
		Options{Rand: func() float64 { return 0.99 }})
	r := m.repos[0]
	release := make(chan struct{})
	var calls, active, most atomic.Int32
	r.passFn = func(context.Context) {
		n := active.Add(1)
		if n > most.Load() {
			most.Store(n)
		}
		if calls.Add(1) == 1 {
			<-release
		}
		active.Add(-1)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { r.loop(ctx); close(done) }()
	defer func() { cancel(); <-done }()

	if m.Trigger("") != 1 {
		t.Fatal("Trigger matched no repository")
	}
	waitFor(t, func() bool { return calls.Load() == 1 })
	for range 50 {
		m.Trigger(r.cfg.Path)
	}
	close(release)
	waitFor(t, func() bool { return calls.Load() >= 2 })
	time.Sleep(200 * time.Millisecond)
	if calls.Load() != 2 || most.Load() != 1 {
		t.Fatalf("%d passes (want 2: 50 triggers during a pass coalesce into one), %d at once", calls.Load(), most.Load())
	}
	if m.Trigger("example.com/nowhere") != 0 {
		t.Fatal("an unknown repository matched")
	}
}

func TestIndexFollowsTheAppsEnvironment(t *testing.T) {
	env := gittest.Env(t)
	repo := fixture(t, env)
	idx := writeScript(t, "gitrochi-index", fakeIndex)
	calls := filepath.Join(filepath.Dir(idx), "calls")
	getenv := func(kv map[string]string) func(string) string { return func(k string) string { return kv[k] } }

	off := newMonitor(t, Config{Repos: []RepoConfig{{Path: repo.Dir}}, Index: idx},
		Options{GitEnv: env, Getenv: getenv(map[string]string{index.EnvSwitch: "0"})}).Once(context.Background())
	if off.Index != "" || len(off.Repos[0].Related) != 0 || off.Repos[0].LastError != "" {
		t.Fatalf("with GITROCHI_INDEX=0: %+v", off)
	}
	if _, err := os.Stat(calls); !os.IsNotExist(err) {
		t.Fatal("the index ran although GITROCHI_INDEX=0")
	}

	on := newMonitor(t, Config{Repos: []RepoConfig{{Path: repo.Dir}}},
		Options{GitEnv: env, Getenv: getenv(map[string]string{index.EnvBinary: idx})}).Once(context.Background())
	if on.Index != idx || fmt.Sprint(on.Repos[0].Related) != "[docs/api.md]" {
		t.Fatalf("with GITROCHI_INDEX_BIN: index %q, related %v", on.Index, on.Repos[0].Related)
	}
}

func TestLocalEndpoints(t *testing.T) {
	env := gittest.Env(t)
	repo := fixture(t, env)
	m := newMonitor(t, Config{Repos: []RepoConfig{{Path: repo.Dir}}, Index: index.Off, Listen: DefaultListen}, Options{GitEnv: env})
	m.Once(context.Background())
	h := m.Handler()
	do := func(method, target, host string, header map[string]string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, target, nil)
		req.Host = host
		for k, v := range header {
			req.Header.Set(k, v)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}
	if rec := do("GET", "/healthz", "127.0.0.1:7421", nil); rec.Code != 200 {
		t.Fatalf("healthz %d", rec.Code)
	}
	rec := do("GET", "/status", "localhost:7421", nil)
	var st Status
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil || rec.Code != 200 || len(st.Repos) != 1 || st.Repos[0].Polls != 1 || st.Repos[0].Branch != "feature/a" {
		t.Fatalf("status %d %s", rec.Code, rec.Body)
	}
	if rec := do("POST", "/trigger?repo="+repoKey, "127.0.0.1:7421", nil); rec.Code != 202 || !strings.Contains(rec.Body.String(), `"triggered": 1`) {
		t.Fatalf("trigger by key: %d %s", rec.Code, rec.Body)
	}
	if rec := do("POST", "/trigger?repo=elsewhere", "127.0.0.1:7421", nil); rec.Code != 404 {
		t.Fatalf("trigger of an unknown repository: %d", rec.Code)
	}
	if rec := do("POST", "/trigger", "127.0.0.1:7421", map[string]string{"Sec-Fetch-Site": "cross-site", "Origin": "https://evil.example.com"}); rec.Code != 403 {
		t.Fatalf("a cross-origin POST: %d", rec.Code)
	}
	if rec := do("GET", "/status", "evil.example.com", nil); rec.Code != http.StatusMisdirectedRequest {
		t.Fatalf("a rebound host name: %d", rec.Code)
	}
	if rec := do("GET", "/metrics", "[::1]:7421", nil); !strings.Contains(rec.Body.String(), "gitrochi_monitor_polls_total 1\n") ||
		!strings.Contains(rec.Body.String(), "gitrochi_monitor_process_limit 4\n") {
		t.Fatalf("metrics:\n%s", rec.Body)
	}
}

// With a built gitrochi-index, the whole path runs for real: history in a
// repository becomes related files in the monitor's status.
func TestRealIndexEndToEnd(t *testing.T) {
	bin := os.Getenv(index.EnvBinary)
	if bin == "" {
		bin = filepath.Join("..", "..", "..", "..", "crates", "target", "release", "gitrochi-index")
	}
	bin, _ = filepath.Abs(bin)
	if fi, err := os.Stat(bin); err != nil || fi.IsDir() || runtime.GOOS == "windows" {
		t.Skip("no gitrochi-index binary (build crates/gitrochi-index or set GITROCHI_INDEX_BIN)")
	}
	env := gittest.Env(t)
	repo := gittest.Init(t, env)
	for _, v := range []string{"1", "2", "3"} {
		repo.Commit("api "+v, map[string]string{"src/api.go": v + "\n", "docs/api.md": v + "\n"})
	}
	repo.Commit("readme", map[string]string{"README.md": "hello\n"})
	repo.Git("switch", "-q", "-c", "feature/a")
	repo.Commit("api change", map[string]string{"src/api.go": "4\n"})
	db := filepath.Join(t.TempDir(), "index.sqlite3")
	st := newMonitor(t, Config{Repos: []RepoConfig{{Path: repo.Dir, Key: repoKey, DefaultBranch: "main"}}, Index: bin},
		Options{GitEnv: append(env, "GITROCHI_INDEX_DB="+db)}).Once(context.Background())
	r := st.Repos[0]
	if r.LastError != "" || r.IndexError != "" || r.LastSync.IsZero() {
		t.Fatalf("status %+v", r)
	}
	if fmt.Sprint(r.Related) != "[docs/api.md]" {
		t.Fatalf("related %v, want the file that changed with src/api.go", r.Related)
	}
	if _, err := os.Stat(db); err != nil {
		t.Fatalf("the index database is not where GITROCHI_INDEX_DB points: %v", err)
	}
	if _, err := os.Stat(filepath.Join(repo.Dir, ".git", "gitrochi")); !os.IsNotExist(err) {
		t.Fatal("the index wrote into the repository's .git")
	}
}

func TestLoadConfig(t *testing.T) {
	dir := t.TempDir()
	home, _ := os.UserHomeDir()
	write := func(body string) string {
		p := filepath.Join(dir, "monitor.json")
		os.WriteFile(p, []byte(body), 0o600)
		return p
	}
	c, err := LoadConfig(write(`{
  "repos": ["work/app", {"path": "~/src/lib", "key": "git@example.com:team/lib.git", "defaultBranch": "origin/develop"}],
  "pollInterval": "45s",
  "fetchInterval": 600,
  "hub": "https://hub.example.com",
  "tokenFile": "hub-token"
}`))
	if err != nil {
		t.Fatal(err)
	}
	if c.Repos[0].Path != filepath.Join(dir, "work", "app") || c.Repos[0].Remote != "origin" {
		t.Fatalf("relative repository %+v", c.Repos[0])
	}
	if c.Repos[1].Path != filepath.Join(home, "src", "lib") || c.Repos[1].Key != "example.com/team/lib" {
		t.Fatalf("home repository %+v", c.Repos[1])
	}
	if c.PollInterval.D() != 45*time.Second || c.FetchInterval.D() != 10*time.Minute || c.MaxGitProcesses != 4 ||
		c.Listen != DefaultListen || c.TokenFile != filepath.Join(dir, "hub-token") || c.EventRefs[0] != "refs/heads/" || c.State == "" {
		t.Fatalf("config %+v", c)
	}
	for name, body := range map[string]string{
		"unknown field":       `{"repos": ["a"], "pollIntervall": "1m"}`,
		"unknown repo field":  `{"repos": [{"path": "a", "branch": "main"}]}`,
		"no repositories":     `{"repos": []}`,
		"duplicate":           `{"repos": ["a", "./a"]}`,
		"bad duration":        `{"repos": ["a"], "pollInterval": "soon"}`,
		"too fast":            `{"repos": ["a"], "pollInterval": "10ms"}`,
		"local key":           `{"repos": [{"path": "a", "key": "/srv/git/app"}]}`,
		"bad event ref":       `{"repos": ["a"], "eventRefs": ["heads/"]}`,
		"too many processes":  `{"repos": ["a"], "maxGitProcesses": 1000}`,
		"trailing characters": `{"repos": ["a"]} x`,
	} {
		if _, err := LoadConfig(write(body)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not reached in time")
		}
		time.Sleep(5 * time.Millisecond)
	}
}
