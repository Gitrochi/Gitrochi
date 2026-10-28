// Package hub is the team collaboration server: presence and overlaps,
// events with a live Server-Sent Events stream, notes, and tokens.
package hub

import (
	"context"
	"crypto/tls"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"runtime"
	"sync/atomic"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/metrics"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/presence"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/ratelimit"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/store"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/stream"
)

// DefaultListen is the default listen address: loopback only, so exposing
// the hub is a deliberate choice.
const DefaultListen = "127.0.0.1:7420"

// Config tunes the server. Zero fields take the defaults in parentheses.
type Config struct {
	PresenceTTL       time.Duration // presence entry lifetime (10m)
	RateLimit         float64       // requests per second per token (20); negative disables
	RateBurst         int           // bucket size (60)
	MaxBodyBytes      int64         // request body limit (1 MiB)
	SSEBuffer         int           // events queued per subscriber before it is dropped (256)
	SSEHeartbeat      time.Duration // comment sent on idle streams (15s)
	SSEWriteTimeout   time.Duration // a stalled SSE write ends the stream (10s)
	ReadHeaderTimeout time.Duration // (10s)
	ReadTimeout       time.Duration // whole request, body included (30s)
	WriteTimeout      time.Duration // whole response, SSE excepted (30s)
	IdleTimeout       time.Duration // keep-alive connections (2m)
	ShutdownTimeout   time.Duration // graceful shutdown budget (15s)
	SweepInterval     time.Duration // expired presence and idle buckets (30s)
	Version           api.Version
	Now               func() time.Time
}

func (c Config) withDefaults() Config {
	def := func(d *time.Duration, v time.Duration) {
		if *d <= 0 {
			*d = v
		}
	}
	def(&c.PresenceTTL, 10*time.Minute)
	def(&c.SSEHeartbeat, 15*time.Second)
	def(&c.SSEWriteTimeout, 10*time.Second)
	def(&c.ReadHeaderTimeout, 10*time.Second)
	def(&c.ReadTimeout, 30*time.Second)
	def(&c.WriteTimeout, 30*time.Second)
	def(&c.IdleTimeout, 2*time.Minute)
	def(&c.ShutdownTimeout, 15*time.Second)
	def(&c.SweepInterval, 30*time.Second)
	if c.RateLimit == 0 {
		c.RateLimit = 20
	}
	if c.RateBurst <= 0 {
		c.RateBurst = 60
	}
	if c.MaxBodyBytes <= 0 {
		c.MaxBodyBytes = 1 << 20
	}
	if c.SSEBuffer <= 0 {
		c.SSEBuffer = 256
	}
	if c.Now == nil {
		c.Now = time.Now
	}
	if c.Version.Tool == "" {
		c.Version.Tool = "gitrochi-hub"
	}
	return c
}

// Server serves the hub API.
type Server struct {
	cfg      Config
	store    *store.Store
	broker   *stream.Broker
	presence *presence.Table
	limiter  *ratelimit.Limiter
	log      *slog.Logger
	started  time.Time
	draining atomic.Bool

	reg          *metrics.Registry
	requests     *metrics.CounterVec
	authFailures *metrics.Counter
	rateLimited  *metrics.Counter

	handler http.Handler
}

// New returns a server for st. b must be the broker that receives st's
// events (store.Options.OnEvents).
func New(cfg Config, st *store.Store, b *stream.Broker, log *slog.Logger) *Server {
	cfg = cfg.withDefaults()
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	s := &Server{
		cfg:      cfg,
		store:    st,
		broker:   b,
		presence: presence.NewTable(),
		limiter:  ratelimit.New(cfg.RateLimit, cfg.RateBurst, cfg.Now),
		log:      log,
		started:  cfg.Now(),
		reg:      metrics.NewRegistry(),
	}
	s.registerMetrics()
	s.handler = s.observe(s.routes())
	return s
}

func (s *Server) registerMetrics() {
	r := s.reg
	r.Info("gitrochi_hub_build_info", "Build information.", []string{"version", "go"},
		[]string{s.cfg.Version.Version, runtime.Version()})
	s.requests = r.CounterVec("gitrochi_hub_http_requests_total", "HTTP requests by route and status code.", "route", "code")
	s.authFailures = r.Counter("gitrochi_hub_auth_failures_total", "Requests rejected for a missing, invalid or revoked token.")
	s.rateLimited = r.Counter("gitrochi_hub_rate_limited_total", "Requests rejected by the per-token rate limit.")
	r.GaugeFunc("gitrochi_hub_sse_subscribers", "Active Server-Sent Events subscribers.",
		func() float64 { return float64(s.broker.Count()) })
	r.CounterFunc("gitrochi_hub_sse_dropped_total", "SSE subscribers dropped for reading too slowly.",
		func() float64 { return float64(s.broker.Dropped()) })
	r.GaugeFunc("gitrochi_hub_journal_bytes", "Size of the journal file in bytes.",
		func() float64 { return float64(s.store.Stats().JournalBytes) })
	r.GaugeFunc("gitrochi_hub_journal_seq", "Sequence number of the newest durable change.",
		func() float64 { return float64(s.store.Stats().Seq) })
	r.GaugeFunc("gitrochi_hub_presence_entries", "Presence entries held in memory.",
		func() float64 { return float64(s.presence.Len()) })
	r.GaugeFunc("gitrochi_hub_events_retained", "Events retained for listing and SSE resume.",
		func() float64 { return float64(s.store.Stats().Events) })
	r.GaugeFunc("gitrochi_hub_notes", "Stored notes.",
		func() float64 { return float64(s.store.Stats().Notes) })
	r.GaugeFunc("gitrochi_hub_tokens_active", "Tokens that are not revoked.",
		func() float64 { return float64(s.store.ActiveTokens()) })
	r.GaugeFunc("gitrochi_hub_goroutines", "Goroutines in the process.",
		func() float64 { return float64(runtime.NumGoroutine()) })
	r.GaugeFunc("gitrochi_hub_uptime_seconds", "Seconds since the server started.",
		func() float64 { return s.cfg.Now().Sub(s.started).Seconds() })
}

// Handler returns the HTTP handler, for tests and embedding.
func (s *Server) Handler() http.Handler { return s.handler }

// Serve serves on ln until ctx is cancelled, then shuts down gracefully:
// readiness turns false, SSE streams are ended, and in-flight requests get
// ShutdownTimeout to finish. With certFile and keyFile it serves TLS.
func (s *Server) Serve(ctx context.Context, ln net.Listener, certFile, keyFile string) error {
	srv := &http.Server{
		Handler:           s.handler,
		ReadHeaderTimeout: s.cfg.ReadHeaderTimeout,
		ReadTimeout:       s.cfg.ReadTimeout,
		WriteTimeout:      s.cfg.WriteTimeout,
		IdleTimeout:       s.cfg.IdleTimeout,
		MaxHeaderBytes:    64 << 10,
		ErrorLog:          slog.NewLogLogger(s.log.Handler(), slog.LevelWarn),
	}
	if certFile != "" {
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	}
	// SSE handlers only return when their subscription ends.
	srv.RegisterOnShutdown(s.broker.Close)

	sweepCtx, stopSweep := context.WithCancel(context.Background())
	defer stopSweep()
	go s.sweep(sweepCtx)

	errc := make(chan error, 1)
	go func() {
		if certFile != "" {
			errc <- srv.ServeTLS(ln, certFile, keyFile)
		} else {
			errc <- srv.Serve(ln)
		}
	}()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	s.draining.Store(true)
	s.log.Info("shutting down", "timeout", s.cfg.ShutdownTimeout)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), s.cfg.ShutdownTimeout)
	defer cancel()
	err := srv.Shutdown(shutdownCtx)
	if err != nil {
		s.log.Warn("graceful shutdown timed out; closing connections", "err", err)
		srv.Close()
	}
	if serveErr := <-errc; !errors.Is(serveErr, http.ErrServerClosed) && err == nil {
		err = serveErr
	}
	return err
}

func (s *Server) sweep(ctx context.Context) {
	t := time.NewTicker(s.cfg.SweepInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if n := s.presence.Sweep(s.cfg.Now()); n > 0 {
				s.log.Debug("expired presence entries", "count", n)
			}
			s.limiter.Sweep(10 * time.Minute)
		}
	}
}
