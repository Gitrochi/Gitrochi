// Package cli implements the gitrochi-hub command line. Commands print one
// JSON document on stdout, like gitrochi-index; diagnostics go to stderr.
// Exit status 0 is success, 1 a failure and 2 a usage error.
package cli

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"strings"
	"syscall"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/client"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/gitexec"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/gitinfo"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/hub"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/lockfile"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/monitor"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/repokey"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/store"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/stream"
)

// Environment variables.
const (
	EnvData  = "GITROCHI_HUB_DATA"
	EnvToken = "GITROCHI_HUB_TOKEN"
	EnvURL   = "GITROCHI_HUB_URL"
)

const usage = `gitrochi-hub: Gitrochi's team hub and repository monitor

Usage:
  gitrochi-hub serve    --data DIR [--listen 127.0.0.1:7420] [--tls-cert FILE --tls-key FILE]
  gitrochi-hub init     --data DIR [--name admin]
  gitrochi-hub token    create --data DIR --name NAME [--role member|admin]
  gitrochi-hub token    list   --data DIR
  gitrochi-hub token    revoke --data DIR (--id ID | --name NAME)
  gitrochi-hub monitor  --config FILE [--token-file FILE] [--once]
  gitrochi-hub overlaps --hub URL --repo REPO [--token-file FILE]
  gitrochi-hub health   [--url URL]
  gitrochi-hub version

Run "gitrochi-hub COMMAND -h" for a command's flags.
`

type env struct {
	stdout, stderr io.Writer
	getenv         func(string) string
	version        string
}

// Main runs the command line and returns the exit status.
func Main(args []string, stdout, stderr io.Writer, version string) int {
	e := &env{stdout: stdout, stderr: stderr, getenv: os.Getenv, version: version}
	return e.run(args)
}

func (e *env) run(args []string) int {
	if len(args) == 0 {
		fmt.Fprint(e.stderr, usage)
		return 2
	}
	switch args[0] {
	case "serve":
		return e.serve(args[1:])
	case "init":
		return e.initData(args[1:])
	case "token":
		return e.token(args[1:])
	case "monitor":
		return e.monitor(args[1:])
	case "overlaps":
		return e.overlaps(args[1:])
	case "health":
		return e.health(args[1:])
	case "version", "--version":
		return e.printJSON(Version(e.version))
	case "help", "-h", "--help":
		fmt.Fprint(e.stdout, usage)
		return 0
	}
	fmt.Fprintf(e.stderr, "gitrochi-hub: unknown command %q\n\n%s", args[0], usage)
	return 2
}

// Version describes this build.
func Version(version string) api.Version {
	v := api.Version{Tool: "gitrochi-hub", Version: version, Go: runtime.Version(), OS: runtime.GOOS, Arch: runtime.GOARCH}
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, s := range bi.Settings {
			if s.Key == "vcs.revision" {
				v.Commit = s.Value
			}
		}
	}
	return v
}

func (e *env) flags(name, summary string) *flag.FlagSet {
	fs := flag.NewFlagSet("gitrochi-hub "+name, flag.ContinueOnError)
	fs.SetOutput(e.stderr)
	fs.Usage = func() {
		fmt.Fprintf(e.stderr, "Usage of gitrochi-hub %s: %s\n", name, summary)
		fs.PrintDefaults()
	}
	return fs
}

// parse returns the exit status to use when parsing ends the command.
func (e *env) parse(fs *flag.FlagSet, args []string) (int, bool) {
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0, false
		}
		return 2, false
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(e.stderr, "%s: unexpected argument %q\n", fs.Name(), fs.Arg(0))
		return 2, false
	}
	return 0, true
}

func (e *env) fail(format string, args ...any) int {
	fmt.Fprintf(e.stderr, "gitrochi-hub: "+format+"\n", args...)
	return 1
}

func (e *env) usageError(format string, args ...any) int {
	fmt.Fprintf(e.stderr, "gitrochi-hub: "+format+"\n", args...)
	return 2
}

func (e *env) printJSON(v any) int {
	enc := json.NewEncoder(e.stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return e.fail("%v", err)
	}
	return 0
}

type logFlags struct{ format, level *string }

func addLogFlags(fs *flag.FlagSet) logFlags {
	return logFlags{
		format: fs.String("log-format", "text", "log format: text or json"),
		level:  fs.String("log-level", "info", "log level: debug, info, warn or error"),
	}
}

func (l logFlags) logger(w io.Writer) (*slog.Logger, error) {
	var level slog.Level
	if err := level.UnmarshalText([]byte(*l.level)); err != nil {
		return nil, fmt.Errorf("--log-level: %w", err)
	}
	opts := &slog.HandlerOptions{Level: level}
	switch *l.format {
	case "text":
		return slog.New(slog.NewTextHandler(w, opts)), nil
	case "json":
		return slog.New(slog.NewJSONHandler(w, opts)), nil
	}
	return nil, errors.New("--log-format must be text or json")
}

func (e *env) dataFlag(fs *flag.FlagSet) *string {
	return fs.String("data", e.getenv(EnvData), "data `directory` (env "+EnvData+")")
}

// openStore opens the data directory for an offline command.
func (e *env) openStore(dir string) (*store.Store, int) {
	if dir == "" {
		return nil, e.usageError("--data or %s is required", EnvData)
	}
	st, err := store.Open(store.Options{Dir: dir})
	if errors.Is(err, lockfile.ErrLocked) {
		return nil, e.fail("%v\nA running server holds this data directory; stop it, or manage tokens through the API (/api/v1/tokens) with an admin token.", err)
	}
	if err != nil {
		return nil, e.fail("%v", err)
	}
	return st, 0
}

func (e *env) serve(args []string) int {
	fs := e.flags("serve", "run the hub server")
	data := e.dataFlag(fs)
	listen := fs.String("listen", hub.DefaultListen, "listen `address`")
	certFile := fs.String("tls-cert", "", "TLS certificate `file` (PEM)")
	keyFile := fs.String("tls-key", "", "TLS private key `file` (PEM)")
	ttl := fs.Duration("presence-ttl", 10*time.Minute, "how long a presence report lasts")
	rate := fs.Float64("rate", 20, "requests per second per token; negative disables the limit")
	burst := fs.Int("burst", 60, "request burst per token")
	maxBody := fs.Int64("max-body", 1<<20, "request body limit in bytes")
	retention := fs.Int("event-retention", store.DefaultEventRetention, "events kept for listing and stream resume")
	snapEvery := fs.Int("snapshot-every", store.DefaultSnapshotEvery, "journal records between snapshots")
	snapInterval := fs.Duration("snapshot-interval", store.DefaultSnapshotInterval, "snapshot at least this often while changes arrive")
	logs := addLogFlags(fs)
	if code, ok := e.parse(fs, args); !ok {
		return code
	}
	if *data == "" {
		return e.usageError("--data or %s is required", EnvData)
	}
	if (*certFile == "") != (*keyFile == "") {
		return e.usageError("--tls-cert and --tls-key go together")
	}
	log, err := logs.logger(e.stderr)
	if err != nil {
		return e.usageError("%v", err)
	}
	broker := stream.NewBroker()
	st, err := store.Open(store.Options{
		Dir:              *data,
		EventRetention:   *retention,
		SnapshotEvery:    *snapEvery,
		SnapshotInterval: *snapInterval,
		Logger:           log,
		OnEvents:         broker.Publish,
	})
	if errors.Is(err, lockfile.ErrLocked) {
		return e.fail("%v\nAnother gitrochi-hub process uses this data directory.", err)
	}
	if err != nil {
		return e.fail("%v", err)
	}
	defer st.Close()
	if st.ActiveTokens() == 0 {
		return e.fail("%s has no active tokens; run gitrochi-hub init --data %s first", *data, *data)
	}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		return e.fail("%v", err)
	}
	srv := hub.New(hub.Config{
		PresenceTTL:  *ttl,
		RateLimit:    *rate,
		RateBurst:    *burst,
		MaxBodyBytes: *maxBody,
		Version:      Version(e.version),
	}, st, broker, log)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	log.Info("gitrochi-hub serving", "addr", ln.Addr().String(), "tls", *certFile != "", "version", e.version)
	err = srv.Serve(ctx, ln, *certFile, *keyFile)
	if cerr := st.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		log.Error("server stopped", "err", err)
		return 1
	}
	log.Info("server stopped")
	return 0
}

func (e *env) initData(args []string) int {
	fs := e.flags("init", "create the data directory and the first admin token")
	data := e.dataFlag(fs)
	name := fs.String("name", "admin", "name of the first admin")
	if code, ok := e.parse(fs, args); !ok {
		return code
	}
	st, code := e.openStore(*data)
	if st == nil {
		return code
	}
	defer st.Close()
	if len(st.Tokens()) > 0 {
		return e.fail("%s is already initialized; use gitrochi-hub token create", *data)
	}
	resp, err := st.CreateToken(*name, api.RoleAdmin)
	if err != nil {
		return e.fail("%v", err)
	}
	if err := st.Close(); err != nil {
		return e.fail("%v", err)
	}
	fmt.Fprintln(e.stderr, "Store this token now: it is shown only once.")
	return e.printJSON(resp)
}

func (e *env) token(args []string) int {
	if len(args) == 0 {
		return e.usageError("token needs a subcommand: create, list or revoke")
	}
	sub, args := args[0], args[1:]
	fs := e.flags("token "+sub, "manage tokens offline (the server must not be running)")
	data := e.dataFlag(fs)
	switch sub {
	case "create":
		name := fs.String("name", "", "member name")
		role := fs.String("role", api.RoleMember, "role: member or admin")
		if code, ok := e.parse(fs, args); !ok {
			return code
		}
		if *name == "" {
			return e.usageError("--name is required")
		}
		st, code := e.openStore(*data)
		if st == nil {
			return code
		}
		defer st.Close()
		resp, err := st.CreateToken(*name, *role)
		if err != nil {
			return e.fail("%v", err)
		}
		if err := st.Close(); err != nil {
			return e.fail("%v", err)
		}
		fmt.Fprintln(e.stderr, "Store this token now: it is shown only once.")
		return e.printJSON(resp)
	case "list":
		if code, ok := e.parse(fs, args); !ok {
			return code
		}
		st, code := e.openStore(*data)
		if st == nil {
			return code
		}
		defer st.Close()
		return e.printJSON(api.TokensResponse{Tokens: st.Tokens()})
	case "revoke":
		id := fs.String("id", "", "token id")
		name := fs.String("name", "", "revoke every active token of this member")
		if code, ok := e.parse(fs, args); !ok {
			return code
		}
		if (*id == "") == (*name == "") {
			return e.usageError("give exactly one of --id and --name")
		}
		st, code := e.openStore(*data)
		if st == nil {
			return code
		}
		defer st.Close()
		var revoked []api.TokenInfo
		var err error
		if *id != "" {
			var info api.TokenInfo
			if info, err = st.RevokeToken(*id); err == nil {
				revoked = []api.TokenInfo{info}
			}
		} else {
			revoked, err = st.RevokeTokensNamed(*name)
		}
		if errors.Is(err, store.ErrNotFound) {
			return e.fail("no such active token")
		}
		if err != nil {
			return e.fail("%v", err)
		}
		if err := st.Close(); err != nil {
			return e.fail("%v", err)
		}
		return e.printJSON(map[string][]api.TokenInfo{"revoked": revoked})
	}
	return e.usageError("unknown token subcommand %q (create, list or revoke)", sub)
}

func (e *env) monitor(args []string) int {
	fs := e.flags("monitor", "watch repositories and publish to the hub")
	cfgPath := fs.String("config", "", "configuration `file` (JSON)")
	tokenFile := fs.String("token-file", "", "`file` holding the hub token (or env "+EnvToken+")")
	once := fs.Bool("once", false, "poll every repository once, print the status and exit (1 when something failed)")
	listen := fs.String("listen", "", `status listen address, overriding the configuration ("off" disables)`)
	logs := addLogFlags(fs)
	if code, ok := e.parse(fs, args); !ok {
		return code
	}
	if *cfgPath == "" {
		return e.usageError("--config is required")
	}
	log, err := logs.logger(e.stderr)
	if err != nil {
		return e.usageError("%v", err)
	}
	cfg, err := monitor.LoadConfig(*cfgPath)
	if err != nil {
		return e.fail("%v", err)
	}
	if *listen != "" {
		cfg.Listen = *listen
	}
	token, err := e.readToken(*tokenFile, cfg.TokenFile, log)
	if err != nil {
		return e.fail("%v", err)
	}
	m, err := monitor.New(cfg, monitor.Options{Token: token, Version: e.version, Logger: log, Getenv: e.getenv})
	if err != nil {
		return e.fail("%v", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *once {
		st := m.Once(ctx)
		if code := e.printJSON(st); code != 0 {
			return code
		}
		if st.Failed() {
			return 1
		}
		return 0
	}
	if err := m.Run(ctx); err != nil {
		return e.fail("%v", err)
	}
	return 0
}

// readToken takes the token from the flag's file, the environment, or the
// configured file, in that order. The token is never printed.
func (e *env) readToken(flagFile, configFile string, log *slog.Logger) (string, error) {
	file := flagFile
	if file == "" {
		if t := strings.TrimSpace(e.getenv(EnvToken)); t != "" {
			return t, nil
		}
		file = configFile
	}
	if file == "" {
		return "", nil
	}
	if fi, err := os.Stat(file); err == nil && runtime.GOOS != "windows" && fi.Mode().Perm()&0o077 != 0 && log != nil {
		log.Warn("the token file is readable by other users; chmod 600 it", "file", file)
	}
	b, err := os.ReadFile(file)
	if err != nil {
		return "", err
	}
	t := strings.TrimSpace(string(b))
	if t == "" {
		return "", fmt.Errorf("%s is empty", file)
	}
	return t, nil
}

func (e *env) overlaps(args []string) int {
	fs := e.flags("overlaps", "print a repository's overlaps")
	hubURL := fs.String("hub", e.getenv(EnvURL), "hub `URL` (env "+EnvURL+")")
	repo := fs.String("repo", "", "repository: a remote URL, a hub key, or a local work tree")
	remote := fs.String("remote", "origin", "remote whose URL names a local work tree's repository")
	tokenFile := fs.String("token-file", "", "`file` holding the hub token (or env "+EnvToken+")")
	caFile := fs.String("ca-file", "", "PEM `file` with the hub's CA certificates")
	timeout := fs.Duration("timeout", 30*time.Second, "request timeout")
	if code, ok := e.parse(fs, args); !ok {
		return code
	}
	if *hubURL == "" || *repo == "" {
		return e.usageError("--hub and --repo are required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	key, err := resolveRepo(ctx, *repo, *remote)
	if err != nil {
		return e.fail("%v", err)
	}
	token, err := e.readToken(*tokenFile, "", nil)
	if err != nil {
		return e.fail("%v", err)
	}
	if token == "" {
		return e.usageError("a token is required: --token-file or %s", EnvToken)
	}
	c, err := client.New(*hubURL, token, client.Options{CAFile: *caFile, Timeout: *timeout, UserAgent: "gitrochi-hub/" + e.version})
	if err != nil {
		return e.fail("%v", err)
	}
	resp, err := c.Overlaps(ctx, key)
	if err != nil {
		return e.fail("%v", err)
	}
	return e.printJSON(resp)
}

// resolveRepo accepts a key or remote URL, or a local work tree whose
// remote names the repository.
func resolveRepo(ctx context.Context, repo, remote string) (string, error) {
	if fi, err := os.Stat(repo); err == nil && fi.IsDir() {
		r := gitexec.NewRunner("", 1, nil)
		top, err := gitinfo.TopLevel(ctx, r, repo, 30*time.Second)
		if err != nil {
			return "", err
		}
		g := &gitinfo.Git{Runner: r, Dir: top, Timeout: 30 * time.Second}
		url, err := g.RemoteURL(ctx, remote)
		if err != nil {
			return "", fmt.Errorf("%s has no remote %s", repo, remote)
		}
		return repokey.Normalize(url)
	}
	return repokey.Normalize(repo)
}

func (e *env) health(args []string) int {
	fs := e.flags("health", "probe a server's /healthz (for container health checks)")
	url := fs.String("url", "http://"+hub.DefaultListen+"/healthz", "`URL` to probe")
	timeout := fs.Duration("timeout", 5*time.Second, "probe timeout")
	insecure := fs.Bool("insecure", false, "skip TLS certificate checks (probing a TLS hub on loopback)")
	if code, ok := e.parse(fs, args); !ok {
		return code
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	if err := client.Health(ctx, *url, *insecure); err != nil {
		return e.fail("unhealthy: %v", err)
	}
	return 0
}
