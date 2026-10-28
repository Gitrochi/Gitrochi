package monitor

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/backoff"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/client"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/gitinfo"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/repokey"
)

// Bounds on what one repository holds.
const (
	maxChanged       = 5000 // the hub's limit per presence list
	maxPending       = 200  // undelivered events; the oldest go first
	maxRecentChanges = 20
	maxForcedChecks  = 100 // ancestry checks per pass, after a fetch that moved many refs
	keyRetry         = 5 * time.Minute
)

// trackedRefs are snapshotted on every poll.
var trackedRefs = []string{"refs/heads/", "refs/remotes/", "refs/tags/"}

// RepoStatus is one repository's entry in Status.
type RepoStatus struct {
	Path          string              `json:"path"`
	Key           string              `json:"key,omitempty"`
	KeyError      string              `json:"keyError,omitempty"`
	Branch        string              `json:"branch,omitempty"`
	Detached      bool                `json:"detached,omitempty"`
	Head          string              `json:"head,omitempty"`
	Upstream      string              `json:"upstream,omitempty"`
	Ahead         int                 `json:"ahead"`
	Behind        int                 `json:"behind"`
	DefaultBranch string              `json:"defaultBranch,omitempty"`
	Base          string              `json:"base,omitempty"`
	Changed       int                 `json:"changed"`
	Dirty         int                 `json:"dirty"`
	Conflicts     int                 `json:"conflicts,omitempty"`
	Related       []string            `json:"related"`
	Refs          int                 `json:"refs"`
	RecentChanges []gitinfo.RefChange `json:"recentChanges"`
	Overlaps      []api.Overlap       `json:"overlaps"`
	PendingEvents int                 `json:"pendingEvents"`
	Polls         int64               `json:"polls"`
	Failures      int64               `json:"failures"`
	LastPoll      time.Time           `json:"lastPoll,omitzero"`
	LastPollMs    int64               `json:"lastPollMs"`
	LastError     string              `json:"lastError,omitempty"`
	LastErrorAt   time.Time           `json:"lastErrorAt,omitzero"`
	LastSync      time.Time           `json:"lastSync,omitzero"`
	IndexError    string              `json:"indexError,omitempty"`
	LastFetch     time.Time           `json:"lastFetch,omitzero"`
	FetchError    string              `json:"fetchError,omitempty"`
	LastPublish   time.Time           `json:"lastPublish,omitzero"`
	HubError      string              `json:"hubError,omitempty"`
	HubRetryAt    time.Time           `json:"hubRetryAt,omitzero"`
}

// repo is one monitored repository. Everything below passMu is owned by
// the goroutine holding passMu.
type repo struct {
	m       *Monitor
	cfg     RepoConfig
	wake    chan struct{} // capacity 1: repeated triggers coalesce
	passFn  func(context.Context)
	passMu  sync.Mutex
	active  atomic.Int32
	maxSeen atomic.Int32 // most passes ever running at once (always 1)

	git          *gitinfo.Git
	key          string
	keyErr       error
	keyTried     time.Time
	refs         map[string]string
	haveRefs     bool
	lastHead     string
	lastBaseTip  string
	base         string
	committed    []string
	needSync     bool
	impactSig    string
	related      []string
	pending      []api.EventInput
	presenceSig  string
	presenceAt   time.Time
	lastFetch    time.Time
	fetchState   backoff.State
	hubState     backoff.State
	indexState   backoff.State
	published    atomic.Value // string: key of a successful presence post
	statusMu     sync.Mutex
	status       RepoStatus
	recentChange []gitinfo.RefChange
}

func newRepo(m *Monitor, rc RepoConfig) *repo {
	r := &repo{m: m, cfg: rc, wake: make(chan struct{}, 1)}
	r.status = RepoStatus{Path: rc.Path, Related: []string{}, RecentChanges: []gitinfo.RefChange{}, Overlaps: []api.Overlap{}}
	if st, ok := m.state.get(rc.Path); ok {
		r.refs, r.haveRefs = st.Refs, st.Refs != nil
		r.pending = st.Pending
		r.lastFetch = st.LastFetch
	}
	return r
}

func (r *repo) trigger() {
	select {
	case r.wake <- struct{}{}:
	default:
	}
}

func (r *repo) statusCopy() RepoStatus {
	r.statusMu.Lock()
	defer r.statusMu.Unlock()
	st := r.status
	st.Related = slices.Clone(st.Related)
	st.RecentChanges = slices.Clone(st.RecentChanges)
	st.Overlaps = slices.Clone(st.Overlaps)
	return st
}

func (r *repo) publishedKey() string {
	k, _ := r.published.Load().(string)
	return k
}

// loop runs passes on the poll interval and on triggers until ctx ends.
func (r *repo) loop(ctx context.Context) {
	// Spread the first polls so repositories do not poll in lockstep.
	first := time.Duration(r.m.rand() * float64(min(r.m.cfg.PollInterval.D(), 5*time.Second)))
	timer := time.NewTimer(first)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		case <-r.wake:
		}
		if r.passFn != nil {
			r.passFn(ctx)
		} else {
			r.pass(ctx)
		}
		r.m.saveState()
		timer.Reset(r.m.cfg.PollInterval.D())
	}
}

// pass polls the repository once. Passes over one repository never overlap.
func (r *repo) pass(ctx context.Context) {
	r.passMu.Lock()
	defer r.passMu.Unlock()
	n := r.active.Add(1)
	defer r.active.Add(-1)
	if n > r.maxSeen.Load() {
		r.maxSeen.Store(n)
	}

	start := time.Now()
	st := r.statusCopy()
	err := r.poll(ctx, &st)
	st.Polls++
	st.LastPoll = r.m.now()
	st.LastPollMs = time.Since(start).Milliseconds()
	st.PendingEvents = len(r.pending)
	r.m.polls.Inc()
	if err != nil {
		if ctx.Err() != nil {
			return // shutting down; the next run starts over
		}
		st.Failures++
		st.LastError, st.LastErrorAt = err.Error(), st.LastPoll
		r.m.pollFailures.Inc()
		r.m.log.Warn("poll failed", "repo", r.cfg.Path, "err", err)
	} else {
		st.LastError, st.LastErrorAt = "", time.Time{}
	}
	r.statusMu.Lock()
	r.status = st
	r.statusMu.Unlock()
	if r.refs != nil {
		r.m.state.put(r.cfg.Path, repoState{Refs: r.refs, Pending: r.pending, LastFetch: r.lastFetch})
	}
}

func (r *repo) poll(ctx context.Context, st *RepoStatus) error {
	m := r.m
	if r.git == nil {
		top, err := gitinfo.TopLevel(ctx, m.runner, r.cfg.Path, m.cfg.GitTimeout.D())
		if err != nil {
			return fmt.Errorf("not a git work tree: %w", err)
		}
		r.git = &gitinfo.Git{Runner: m.runner, Dir: top, Timeout: m.cfg.GitTimeout.D()}
	}
	now := m.now()
	if r.key == "" && (r.keyTried.IsZero() || now.Sub(r.keyTried) >= keyRetry) {
		r.resolveKey(ctx, now)
	}
	st.Key = r.key
	st.KeyError = ""
	if r.keyErr != nil {
		st.KeyError = r.keyErr.Error()
	}

	if m.cfg.FetchInterval > 0 && now.Sub(r.lastFetch) >= m.cfg.FetchInterval.D() && r.fetchState.Ready(now) {
		if err := r.git.Fetch(ctx, r.cfg.Remote, m.cfg.FetchTimeout.D()); err != nil {
			if ctx.Err() != nil {
				return err
			}
			d := r.fetchState.Fail(m.fetchPolicy, now)
			st.FetchError = err.Error()
			m.fetches.Inc("error")
			m.log.Warn("fetch failed", "repo", r.cfg.Path, "retry_in", d, "err", err)
		} else {
			r.fetchState.Succeed()
			r.lastFetch = now
			st.LastFetch, st.FetchError = now, ""
			m.fetches.Inc("ok")
		}
	}

	status, err := r.git.Status(ctx)
	if err != nil {
		return err
	}
	refs, err := r.git.Refs(ctx, trackedRefs...)
	if err != nil {
		return err
	}
	snapshot := make(map[string]string, len(refs))
	for name, ref := range refs {
		if ref.Symref == "" {
			snapshot[name] = ref.Object
		}
	}
	if !r.haveRefs {
		r.needSync = true // first sight: bring the index up to date
	} else if changes := gitinfo.DiffRefs(r.refs, snapshot); len(changes) > 0 {
		if err := r.git.MarkForced(ctx, changes[:min(len(changes), maxForcedChecks)]); err != nil {
			return err // the snapshot stays, so the next poll sees the changes again
		}
		r.recordChanges(changes, now)
		r.needSync = true
	}
	r.refs, r.haveRefs = snapshot, true

	baseRef := r.defaultRef(refs)
	baseTip := refs[baseRef].Object
	if status.Head == "" || baseTip == "" {
		r.base, r.committed = "", nil
	} else if status.Head != r.lastHead || baseTip != r.lastBaseTip {
		mb, err := r.git.MergeBase(ctx, baseTip, status.Head)
		if err != nil {
			return err
		}
		var files []string
		if mb != "" && mb != status.Head {
			if files, err = r.git.ChangedBetween(ctx, mb, status.Head); err != nil {
				return err
			}
		}
		r.base, r.committed = mb, files
	}
	r.lastHead, r.lastBaseTip = status.Head, baseTip
	changed := mergePaths(r.committed, status.Dirty)

	if m.index != nil {
		r.runIndex(ctx, st, changed, now)
	}

	st.Branch, st.Detached, st.Head = status.Branch, status.Detached, status.Head
	st.Upstream, st.Ahead, st.Behind = status.Upstream, status.Ahead, status.Behind
	st.DefaultBranch, st.Base = baseRef, r.base
	st.Changed, st.Dirty, st.Conflicts = len(changed), len(status.Dirty), status.Conflicts
	st.Related = nonNil(slices.Clone(r.related))
	st.Refs = len(snapshot)
	st.RecentChanges = slices.Clone(r.recentChange)

	if m.hub != nil && r.key != "" {
		r.publish(ctx, st, api.Presence{
			Repo:    r.key,
			Branch:  status.Branch,
			Head:    status.Head,
			Base:    r.base,
			Ahead:   status.Ahead,
			Behind:  status.Behind,
			Changed: nonNil(changed),
			Related: nonNil(r.related),
			Client:  m.cfg.Client,
		}, now)
	}
	return nil
}

// resolveKey finds the hub key: configured, or from the remote's URL. The
// URL itself is never logged or shown: it may carry credentials.
func (r *repo) resolveKey(ctx context.Context, now time.Time) {
	r.keyTried = now
	if r.cfg.Key != "" {
		r.key, r.keyErr = r.cfg.Key, nil
		return
	}
	url, err := r.git.RemoteURL(ctx, r.cfg.Remote)
	if err != nil {
		r.keyErr = fmt.Errorf("no URL for remote %s; set a key in the configuration", r.cfg.Remote)
		return
	}
	r.key, r.keyErr = repokey.Normalize(url)
}

// defaultRef picks the ref the branch is compared with.
func (r *repo) defaultRef(refs map[string]gitinfo.Ref) string {
	remote := r.cfg.Remote
	if want := r.cfg.DefaultBranch; want != "" {
		for _, c := range []string{want, "refs/remotes/" + want, "refs/remotes/" + remote + "/" + want, "refs/heads/" + want} {
			if _, ok := refs[c]; ok && strings.HasPrefix(c, "refs/") {
				return c
			}
		}
		return ""
	}
	if head, ok := refs["refs/remotes/"+remote+"/HEAD"]; ok && head.Symref != "" {
		if _, ok := refs[head.Symref]; ok {
			return head.Symref
		}
	}
	for _, c := range []string{"refs/remotes/" + remote + "/main", "refs/remotes/" + remote + "/master", "refs/heads/main", "refs/heads/master"} {
		if _, ok := refs[c]; ok {
			return c
		}
	}
	return ""
}

// recordChanges keeps recent changes for the status and queues hub events
// for the refs the configuration publishes.
func (r *repo) recordChanges(changes []gitinfo.RefChange, now time.Time) {
	m := r.m
	for i := range changes {
		c := &changes[i]
		c.At = now
		kind := c.Kind
		if c.Forced {
			kind = "forced"
		}
		m.refChanges.Inc(kind)
		m.log.Info("ref changed", "repo", r.cfg.Path, "ref", c.Ref, "kind", c.Kind, "forced", c.Forced)
	}
	r.recentChange = append(slices.Clone(changes), r.recentChange...)
	if len(r.recentChange) > maxRecentChanges {
		r.recentChange = r.recentChange[:maxRecentChanges]
	}
	if m.hub == nil || r.key == "" {
		return
	}
	for _, c := range changes {
		if !hasAnyPrefix(c.Ref, m.cfg.EventRefs) {
			continue
		}
		e := api.EventInput{Repo: r.key, Ref: c.Ref, Old: c.Old, New: c.New, Forced: c.Forced, At: c.At}
		switch c.Kind {
		case gitinfo.Created:
			e.Type = api.EventRefCreated
		case gitinfo.Updated:
			e.Type = api.EventRefUpdated
		default:
			e.Type = api.EventRefDeleted
		}
		r.pending = append(r.pending, e)
	}
	if over := len(r.pending) - maxPending; over > 0 {
		m.log.Warn("hub unreachable for long; dropping the oldest events", "repo", r.cfg.Path, "dropped", over)
		r.pending = slices.Delete(r.pending, 0, over)
	}
}

// runIndex syncs the index after ref changes and asks it for related files
// when the changed set moves.
func (r *repo) runIndex(ctx context.Context, st *RepoStatus, changed []string, now time.Time) {
	m := r.m
	if !r.indexState.Ready(now) {
		return
	}
	fail := func(command string, err error) {
		if ctx.Err() != nil {
			return
		}
		d := r.indexState.Fail(m.indexPolicy, now)
		st.IndexError = err.Error()
		m.indexRuns.Inc(command, "error")
		m.log.Warn("gitrochi-index failed", "repo", r.cfg.Path, "command", command, "retry_in", d, "err", err)
	}
	if r.needSync {
		if _, err := m.index.Sync(ctx, r.git.Dir); err != nil {
			fail("sync", err)
			return
		}
		m.indexRuns.Inc("sync", "ok")
		r.needSync = false
		r.impactSig = "" // new history may change the answer
		st.LastSync = now
	}
	if len(changed) == 0 {
		r.related, r.impactSig = nil, ""
	} else if sig := signature(changed); sig != r.impactSig {
		res, err := m.index.Impact(ctx, r.git.Dir, changed)
		if err != nil {
			fail("impact", err)
			return
		}
		m.indexRuns.Inc("impact", "ok")
		// Suggestions come best first; keep the strongest, then sort for a
		// stable presence payload.
		related := make([]string, 0, len(res.Suggestions))
		for _, s := range res.Suggestions {
			if len(related) == m.cfg.ImpactLimit {
				break
			}
			if _, isChanged := slices.BinarySearch(changed, s.Path); s.Path != "" && !isChanged && !slices.Contains(related, s.Path) {
				related = append(related, s.Path)
			}
		}
		slices.Sort(related)
		r.related, r.impactSig = related, sig
	}
	r.indexState.Succeed()
	st.IndexError = ""
}

// publish delivers queued events, then presence when it changed or is due
// for a refresh. After a failure the hub is left alone until the backoff
// delay has passed.
func (r *repo) publish(ctx context.Context, st *RepoStatus, p api.Presence, now time.Time) {
	m := r.m
	if !r.hubState.Ready(now) {
		st.HubRetryAt = r.hubState.Next
		return
	}
	for len(r.pending) > 0 {
		_, err := m.hub.PostEvent(ctx, r.pending[0])
		if err == nil {
			m.hubRequests.Inc("event", "ok")
			r.pending = r.pending[1:]
			continue
		}
		if client.Retryable(err) || isAuthError(err) {
			m.hubRequests.Inc("event", "error")
			r.hubFailed(ctx, st, err, now)
			return
		}
		// The hub rejected this event; keeping it would block the queue.
		m.hubRequests.Inc("event", "rejected")
		m.log.Warn("hub rejected an event; dropping it", "repo", r.cfg.Path, "ref", r.pending[0].Ref, "err", err)
		r.pending = r.pending[1:]
	}
	sig := signature([]string{mustJSON(p)})
	if sig != r.presenceSig || now.Sub(r.presenceAt) >= m.cfg.PresenceRefresh.D() {
		resp, err := m.hub.PostPresence(ctx, p)
		if err != nil {
			m.hubRequests.Inc("presence", "error")
			r.hubFailed(ctx, st, err, now)
			return
		}
		m.hubRequests.Inc("presence", "ok")
		r.presenceSig, r.presenceAt = sig, now
		r.published.Store(r.key)
		st.Overlaps = nonNil(resp.Overlaps)
		st.LastPublish = now
	}
	r.hubState.Succeed()
	st.HubError, st.HubRetryAt = "", time.Time{}
}

func (r *repo) hubFailed(ctx context.Context, st *RepoStatus, err error, now time.Time) {
	if ctx.Err() != nil {
		return
	}
	d := r.hubState.Fail(r.m.hubPolicy, now)
	var apiErr *client.APIError
	if errors.As(err, &apiErr) && apiErr.RetryAfter > d {
		r.hubState.Next = now.Add(apiErr.RetryAfter)
	}
	st.HubError, st.HubRetryAt = err.Error(), r.hubState.Next
	r.m.log.Warn("hub request failed", "repo", r.cfg.Path, "retry_at", r.hubState.Next, "err", err)
}

func isAuthError(err error) bool {
	var apiErr *client.APIError
	return errors.As(err, &apiErr) && (apiErr.Status == http.StatusUnauthorized || apiErr.Status == http.StatusForbidden)
}

// mergePaths returns the sorted union of a and b, capped at maxChanged.
func mergePaths(a, b []string) []string {
	out := make([]string, 0, len(a)+len(b))
	out = append(append(out, a...), b...)
	slices.Sort(out)
	out = slices.Compact(out)
	return out[:min(len(out), maxChanged)]
}

func hasAnyPrefix(s string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

func signature(parts []string) string {
	h := sha256.New()
	for _, p := range parts {
		h.Write([]byte(p))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}
