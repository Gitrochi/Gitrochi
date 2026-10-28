// Package monitor is the repository monitoring daemon that runs on a
// developer machine. It polls each configured repository with git, detects
// ref changes (and forced updates), keeps the Rust index in sync through
// `gitrochi-index`, and publishes presence and events to the hub.
//
// Concurrency: every git and index process goes through one gitexec.Runner,
// which bounds how many run at once. Each repository has one worker, and a
// pass over a repository holds that repository's lock, so one repository is
// never synced twice at the same time. Triggers coalesce: while a pass runs,
// any number of triggers cause exactly one more pass.
package monitor

import (
	"context"
	"errors"
	"log/slog"
	"math/rand/v2"
	"net"
	"net/http"
	"os"
	"runtime"
	"sync"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/backoff"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/client"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/gitexec"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/index"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/metrics"
)

// Options carry what does not belong in the configuration file.
type Options struct {
	Token      string // hub token; never logged
	Version    string
	Logger     *slog.Logger
	Now        func() time.Time
	Rand       func() float64 // jitter source in [0, 1)
	GitEnv     []string       // extra environment for git and the index
	HTTPClient *http.Client
	Getenv     func(string) string // GITROCHI_INDEX, GITROCHI_INDEX_BIN; os.Getenv
}

// Monitor watches repositories.
type Monitor struct {
	cfg     Config
	opts    Options
	log     *slog.Logger
	now     func() time.Time
	rand    func() float64
	runner  *gitexec.Runner
	index   *index.Index   // nil without the binary
	hub     *client.Client // nil without a hub
	state   *stateStore
	repos   []*repo
	started time.Time

	fetchPolicy backoff.Policy
	hubPolicy   backoff.Policy
	indexPolicy backoff.Policy

	reg          *metrics.Registry
	polls        *metrics.Counter
	pollFailures *metrics.Counter
	refChanges   *metrics.CounterVec
	fetches      *metrics.CounterVec
	hubRequests  *metrics.CounterVec
	indexRuns    *metrics.CounterVec
}

// New prepares a monitor for cfg, which must have passed Prepare.
func New(cfg Config, opts Options) (*Monitor, error) {
	if opts.Logger == nil {
		opts.Logger = slog.New(slog.DiscardHandler)
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	if opts.Rand == nil {
		opts.Rand = rand.Float64
	}
	if opts.Getenv == nil {
		opts.Getenv = os.Getenv
	}
	m := &Monitor{
		cfg:  cfg,
		opts: opts,
		log:  opts.Logger,
		now:  func() time.Time { return opts.Now().UTC().Truncate(time.Second) },
		rand: opts.Rand,
	}
	m.started = m.now()
	m.runner = gitexec.NewRunner(cfg.Git, cfg.MaxGitProcesses, opts.GitEnv)
	m.fetchPolicy = backoff.Policy{Base: 30 * time.Second, Max: 30 * time.Minute, Rand: opts.Rand}
	m.hubPolicy = backoff.Policy{Base: 2 * time.Second, Max: 5 * time.Minute, Rand: opts.Rand}
	m.indexPolicy = backoff.Policy{Base: 10 * time.Second, Max: 30 * time.Minute, Rand: opts.Rand}

	bin, err := index.Find(cfg.Index, opts.Getenv)
	if err != nil {
		return nil, err
	}
	switch {
	case bin != "":
		m.index = &index.Index{Bin: bin, Runner: m.runner, Timeout: cfg.IndexTimeout.D()}
	case opts.Getenv(index.EnvSwitch) == "0" || cfg.Index == index.Off:
		m.log.Info("the repository index is turned off; related files stay empty")
	default:
		m.log.Info("gitrochi-index not found; related files stay empty")
	}
	if cfg.Hub != "" {
		if opts.Token == "" {
			return nil, errors.New("a hub is configured but no token was given (--token-file or GITROCHI_HUB_TOKEN)")
		}
		m.hub, err = client.New(cfg.Hub, opts.Token, client.Options{
			HTTPClient: opts.HTTPClient,
			CAFile:     cfg.CAFile,
			UserAgent:  "gitrochi-hub-monitor/" + opts.Version,
		})
		if err != nil {
			return nil, err
		}
	}
	if m.state, err = loadState(cfg.State); err != nil {
		if m.state == nil {
			return nil, err
		}
		m.log.Warn("monitor state", "err", err)
	}
	for _, rc := range cfg.Repos {
		m.repos = append(m.repos, newRepo(m, rc))
	}
	m.registerMetrics()
	return m, nil
}

func (m *Monitor) registerMetrics() {
	r := metrics.NewRegistry()
	m.reg = r
	r.Info("gitrochi_monitor_build_info", "Build information.", []string{"version", "go"},
		[]string{m.opts.Version, runtime.Version()})
	m.polls = r.Counter("gitrochi_monitor_polls_total", "Repository polls.")
	m.pollFailures = r.Counter("gitrochi_monitor_poll_failures_total", "Repository polls that failed.")
	m.refChanges = r.CounterVec("gitrochi_monitor_ref_changes_total", "Ref changes seen, by kind.", "kind")
	m.fetches = r.CounterVec("gitrochi_monitor_fetches_total", "Fetches by result.", "result")
	m.hubRequests = r.CounterVec("gitrochi_monitor_hub_requests_total", "Hub requests by kind and result.", "kind", "result")
	m.indexRuns = r.CounterVec("gitrochi_monitor_index_runs_total", "gitrochi-index runs by command and result.", "command", "result")
	r.GaugeFunc("gitrochi_monitor_repos", "Monitored repositories.", func() float64 { return float64(len(m.repos)) })
	r.GaugeFunc("gitrochi_monitor_processes", "Git and index processes running now.",
		func() float64 { return float64(m.runner.Stats().InFlight) })
	r.GaugeFunc("gitrochi_monitor_processes_peak", "Most git and index processes ever running at once.",
		func() float64 { return float64(m.runner.Stats().Peak) })
	r.GaugeFunc("gitrochi_monitor_process_limit", "Limit on concurrent git and index processes.",
		func() float64 { return float64(m.runner.Stats().Limit) })
	r.CounterFunc("gitrochi_monitor_processes_total", "Git and index processes started.",
		func() float64 { return float64(m.runner.Stats().Started) })
	r.CounterFunc("gitrochi_monitor_process_timeouts_total", "Processes killed for running past their timeout.",
		func() float64 { return float64(m.runner.Stats().Timeouts) })
	r.GaugeFunc("gitrochi_monitor_pending_events", "Events waiting to be delivered to the hub.", func() float64 {
		n := 0
		for _, rp := range m.repos {
			n += rp.statusCopy().PendingEvents
		}
		return float64(n)
	})
}

// Runner exposes the process runner (for its statistics).
func (m *Monitor) Runner() *gitexec.Runner { return m.runner }

// Once polls every repository once, concurrently within the process limit,
// saves the state file and returns the status.
func (m *Monitor) Once(ctx context.Context) Status {
	var wg sync.WaitGroup
	for _, r := range m.repos {
		wg.Go(func() { r.pass(ctx) })
	}
	wg.Wait()
	m.saveState()
	return m.Status()
}

// Run polls until ctx is cancelled, serving the local status endpoints. On
// the way out it withdraws this machine's presence from the hub.
func (m *Monitor) Run(ctx context.Context) error {
	var srv *http.Server
	errc := make(chan error, 1)
	if m.cfg.Listen != ListenOff {
		ln, err := net.Listen("tcp", m.cfg.Listen)
		if err != nil {
			return err
		}
		m.log.Info("status endpoints", "addr", ln.Addr().String())
		srv = &http.Server{
			Handler:           m.Handler(),
			ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout:       10 * time.Second,
			WriteTimeout:      10 * time.Second,
			IdleTimeout:       time.Minute,
		}
		go func() { errc <- srv.Serve(ln) }()
	}
	var wg sync.WaitGroup
	for _, r := range m.repos {
		wg.Go(func() { r.loop(ctx) })
	}
	var err error
	select {
	case <-ctx.Done():
	case err = <-errc:
	}
	if srv != nil {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		srv.Shutdown(shutdownCtx)
		cancel()
	}
	wg.Wait()
	m.withdrawPresence()
	m.saveState()
	if errors.Is(err, http.ErrServerClosed) {
		err = nil
	}
	return err
}

// Trigger asks for an immediate pass over the repositories whose path or
// key is name ("" for all) and returns how many matched. A pass already
// pending absorbs the trigger.
func (m *Monitor) Trigger(name string) int {
	n := 0
	for _, r := range m.repos {
		if name == "" || name == r.cfg.Path || name == r.statusCopy().Key {
			r.trigger()
			n++
		}
	}
	return n
}

func (m *Monitor) withdrawPresence() {
	if m.hub == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for _, r := range m.repos {
		if key := r.publishedKey(); key != "" {
			if err := m.hub.DeletePresence(ctx, key, m.cfg.Client); err != nil {
				m.log.Debug("withdrawing presence", "repo", r.cfg.Path, "err", err)
			}
		}
	}
}

func (m *Monitor) saveState() {
	if err := m.state.save(); err != nil {
		m.log.Warn("saving monitor state", "path", m.cfg.State, "err", err)
	}
}

// Status is the monitor's state, served at /status and printed by --once.
type Status struct {
	Tool    string        `json:"tool"`
	Version string        `json:"version"`
	Started time.Time     `json:"started"`
	Client  string        `json:"client"`
	Hub     string        `json:"hub,omitempty"`
	Index   string        `json:"index,omitempty"`
	Git     gitexec.Stats `json:"git"`
	Repos   []RepoStatus  `json:"repos"`
}

// Failed reports whether any repository has an error to show.
func (s Status) Failed() bool {
	for _, r := range s.Repos {
		if r.LastError != "" || r.HubError != "" || r.IndexError != "" || r.FetchError != "" {
			return true
		}
		// Without a key nothing of this repository reaches the hub.
		if s.Hub != "" && r.Key == "" {
			return true
		}
	}
	return false
}

// Status returns the current status.
func (m *Monitor) Status() Status {
	st := Status{
		Tool:    "gitrochi-hub monitor",
		Version: m.opts.Version,
		Started: m.started,
		Client:  m.cfg.Client,
		Git:     m.runner.Stats(),
		Repos:   make([]RepoStatus, 0, len(m.repos)),
	}
	if m.hub != nil {
		st.Hub = m.hub.URL()
	}
	if m.index != nil {
		st.Index = m.index.Bin
	}
	for _, r := range m.repos {
		st.Repos = append(st.Repos, r.statusCopy())
	}
	return st
}
