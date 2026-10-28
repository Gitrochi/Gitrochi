package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/client"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/gittest"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/hub"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/monitor"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/store"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/stream"
)

// TestMain lets the test binary stand in for gitrochi-hub in end-to-end
// tests (see serve_unix_test.go).
func TestMain(m *testing.M) {
	if os.Getenv("GITROCHI_HUB_TEST_CLI") == "1" {
		os.Exit(Main(os.Args[1:], os.Stdout, os.Stderr, "test"))
	}
	os.Exit(m.Run())
}

type run struct {
	code           int
	stdout, stderr string
}

// cli runs the command line in-process with vars as its environment.
func cli(t *testing.T, vars map[string]string, args ...string) run {
	t.Helper()
	var out, errb bytes.Buffer
	e := &env{stdout: &out, stderr: &errb, getenv: func(k string) string { return vars[k] }, version: "test"}
	code := e.run(args)
	return run{code, out.String(), errb.String()}
}

func (r run) decode(t *testing.T, v any) {
	t.Helper()
	if err := json.Unmarshal([]byte(r.stdout), v); err != nil {
		t.Fatalf("stdout is not JSON (%v):\n%s\nstderr:\n%s", err, r.stdout, r.stderr)
	}
}

func TestInitAndTokenLifecycle(t *testing.T) {
	data := filepath.Join(t.TempDir(), "hub")
	r := cli(t, nil, "init", "--data", data)
	var admin api.TokenCreateResponse
	r.decode(t, &admin)
	if r.code != 0 || admin.Role != api.RoleAdmin || admin.Name != "admin" || !strings.HasPrefix(admin.Token, "grh_") || !strings.Contains(r.stderr, "shown only once") {
		t.Fatalf("init: %+v %s", r, r.stderr)
	}
	if r := cli(t, nil, "init", "--data", data); r.code != 1 || !strings.Contains(r.stderr, "already initialized") {
		t.Fatalf("second init: %+v", r)
	}
	env := map[string]string{EnvData: data}
	r = cli(t, env, "token", "create", "--name", "alice")
	var alice api.TokenCreateResponse
	r.decode(t, &alice)
	if r.code != 0 || alice.Role != api.RoleMember {
		t.Fatalf("create: %+v", r)
	}
	r = cli(t, env, "token", "list")
	if r.code != 0 || strings.Contains(r.stdout, "grh_") || strings.Contains(r.stdout, "hash") {
		t.Fatalf("list must not print secrets or hashes: %s", r.stdout)
	}
	var list api.TokensResponse
	r.decode(t, &list)
	if len(list.Tokens) != 2 {
		t.Fatalf("list %+v", list)
	}
	if r := cli(t, env, "token", "revoke", "--name", "alice"); r.code != 0 || !strings.Contains(r.stdout, alice.ID) {
		t.Fatalf("revoke: %+v", r)
	}
	if r := cli(t, env, "token", "revoke", "--name", "alice"); r.code != 1 {
		t.Fatalf("revoking again: %+v", r)
	}
	if r := cli(t, env, "token", "revoke", "--id", alice.ID, "--name", "alice"); r.code != 2 {
		t.Fatalf("both --id and --name: %+v", r)
	}
	st, err := store.Open(store.Options{Dir: data})
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.Authenticate(admin.Token); err != nil {
		t.Fatalf("the admin token printed by init does not work: %v", err)
	}
	if _, err := st.Authenticate(alice.Token); err == nil {
		t.Fatal("the revoked token still works")
	}
}

func TestOfflineCommandsRefuseADirectoryInUse(t *testing.T) {
	data := t.TempDir()
	st, err := store.Open(store.Options{Dir: data}) // a running server
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, args := range [][]string{
		{"token", "create", "--data", data, "--name", "bob"},
		{"token", "list", "--data", data},
		{"init", "--data", data},
	} {
		r := cli(t, nil, args...)
		if r.code != 1 || !strings.Contains(r.stderr, "locked") || !strings.Contains(r.stderr, "/api/v1/tokens") {
			t.Fatalf("%v: %+v", args, r)
		}
	}
}

func TestUsageAndVersion(t *testing.T) {
	for _, args := range [][]string{{}, {"bogus"}, {"token"}, {"token", "rename"}, {"serve"}, {"monitor"}, {"overlaps"}, {"serve", "--data", "x", "--tls-cert", "c"}} {
		if r := cli(t, nil, args...); r.code != 2 {
			t.Errorf("%v: exit %d, want 2 (%s)", args, r.code, r.stderr)
		}
	}
	if r := cli(t, nil, "help"); r.code != 0 || !strings.Contains(r.stdout, "gitrochi-hub serve") {
		t.Fatalf("help: %+v", r)
	}
	if r := cli(t, nil, "serve", "-h"); r.code != 0 {
		t.Fatalf("serve -h: %+v", r)
	}
	var v api.Version
	r := cli(t, nil, "version")
	r.decode(t, &v)
	if v.Tool != "gitrochi-hub" || v.Version != "test" || v.Go == "" || v.OS == "" {
		t.Fatalf("version %+v", v)
	}
}

func startHub(t *testing.T) (base string, tokens map[string]string) {
	t.Helper()
	b := stream.NewBroker()
	st, err := store.Open(store.Options{Dir: t.TempDir(), OnEvents: b.Publish})
	if err != nil {
		t.Fatal(err)
	}
	tokens = map[string]string{}
	for _, n := range []string{"alice", "bob"} {
		resp, _ := st.CreateToken(n, api.RoleMember)
		tokens[n] = resp.Token
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

// hermeticGit points the git processes the CLI starts away from the
// machine's configuration.
func hermeticGit(t *testing.T) []string {
	env := gittest.Env(t)
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		t.Setenv(k, v)
	}
	return env
}

func TestOverlapsAndHealthCommands(t *testing.T) {
	env := hermeticGit(t)
	base, tokens := startHub(t)
	ctx := context.Background()
	for name, changed := range map[string]string{"alice": "src/api.go", "bob": "src/api.go"} {
		c, _ := client.New(base, tokens[name], client.Options{})
		if _, err := c.PostPresence(ctx, api.Presence{Repo: "example.com/team/app", Changed: []string{changed}}); err != nil {
			t.Fatal(err)
		}
	}
	repo := gittest.Init(t, env)
	repo.Git("remote", "add", "origin", "git@example.com:team/app.git")
	tokenEnv := map[string]string{EnvToken: tokens["alice"], EnvURL: base}
	for _, target := range []string{"https://example.com/team/app.git", repo.Dir} {
		r := cli(t, tokenEnv, "overlaps", "--repo", target)
		var o api.OverlapsResponse
		r.decode(t, &o)
		if r.code != 0 || o.Repo != "example.com/team/app" || len(o.Overlaps) != 1 || o.Overlaps[0].Kind != api.OverlapSameFile {
			t.Fatalf("overlaps --repo %s: %+v", target, r)
		}
		if strings.Contains(r.stdout+r.stderr, tokens["alice"]) {
			t.Fatal("the token was printed")
		}
	}
	if r := cli(t, map[string]string{EnvURL: base}, "overlaps", "--repo", "example.com/team/app"); r.code != 2 {
		t.Fatalf("without a token: %+v", r)
	}
	if r := cli(t, nil, "health", "--url", base); r.code != 0 {
		t.Fatalf("health: %+v", r)
	}
	if r := cli(t, nil, "health", "--url", "http://127.0.0.1:1/healthz", "--timeout", "2s"); r.code != 1 {
		t.Fatalf("health of a closed port: %+v", r)
	}
}

func TestMonitorOnceCommand(t *testing.T) {
	env := hermeticGit(t)
	base, tokens := startHub(t)
	repo := gittest.Init(t, env)
	repo.Commit("base", map[string]string{"a.go": "a\n"})
	repo.Git("remote", "add", "origin", "https://example.com/team/app.git")
	dir := t.TempDir()
	tokenFile := filepath.Join(dir, "token")
	os.WriteFile(tokenFile, []byte(tokens["alice"]+"\n"), 0o600)
	cfg := filepath.Join(dir, "monitor.json")
	body, _ := json.Marshal(map[string]any{"repos": []string{repo.Dir}, "hub": base, "index": "off", "state": "state.json", "client": "laptop"})
	os.WriteFile(cfg, body, 0o600)

	r := cli(t, nil, "monitor", "--config", cfg, "--token-file", tokenFile, "--once")
	var st monitor.Status
	r.decode(t, &st)
	if r.code != 0 || len(st.Repos) != 1 || st.Repos[0].Key != "example.com/team/app" || st.Repos[0].Branch != "main" || st.Hub == "" {
		t.Fatalf("monitor --once: %+v\n%s", r, r.stderr)
	}
	if strings.Contains(r.stdout+r.stderr, tokens["alice"]) {
		t.Fatal("the token was printed")
	}
	if _, err := os.Stat(filepath.Join(dir, "state.json")); err != nil {
		t.Fatalf("no state file next to the configuration: %v", err)
	}
	// A failing pass makes --once exit 1.
	os.WriteFile(cfg, []byte(`{"repos": ["`+filepath.ToSlash(t.TempDir())+`"], "index": "off", "state": "state.json"}`), 0o600)
	if r := cli(t, nil, "monitor", "--config", cfg, "--once"); r.code != 1 || !strings.Contains(r.stdout, "not a git work tree") {
		t.Fatalf("a directory that is not a repository: %+v", r)
	}
	if r := cli(t, nil, "monitor", "--config", filepath.Join(dir, "missing.json"), "--once"); r.code != 1 {
		t.Fatalf("a missing configuration: %+v", r)
	}
}
