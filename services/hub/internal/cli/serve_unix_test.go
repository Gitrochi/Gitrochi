//go:build unix

package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/client"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/store"
)

// The real command end to end: serve in its own process, a request, a
// refused offline command, SIGTERM, and the change still there afterwards.
func TestServeProcessShutsDownGracefullyOnSIGTERM(t *testing.T) {
	data := filepath.Join(t.TempDir(), "hub")
	var admin api.TokenCreateResponse
	cli(t, nil, "init", "--data", data).decode(t, &admin)

	cmd := exec.Command(os.Args[0], "serve", "--data", data, "--listen", "127.0.0.1:0", "--log-format", "json")
	cmd.Env = append(os.Environ(), "GITROCHI_HUB_TEST_CLI=1")
	stderr, err := cmd.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()
	logs := bufio.NewScanner(stderr)
	var addr string
	var logged strings.Builder
	for addr == "" && logs.Scan() {
		logged.WriteString(logs.Text() + "\n")
		var line struct {
			Msg  string `json:"msg"`
			Addr string `json:"addr"`
		}
		if json.Unmarshal(logs.Bytes(), &line) == nil && line.Msg == "gitrochi-hub serving" {
			addr = line.Addr
		}
	}
	if addr == "" {
		t.Fatalf("the server never said where it listens:\n%s", logged.String())
	}
	rest := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(stderr)
		rest <- string(b)
	}()

	c, _ := client.New("http://"+addr, admin.Token, client.Options{})
	ctx := context.Background()
	if _, err := c.PostEvent(ctx, api.EventInput{Repo: "example.com/team/app", Type: api.EventCIFailed, Message: "before SIGTERM"}); err != nil {
		t.Fatal(err)
	}
	if r := cli(t, nil, "token", "list", "--data", data); r.code != 1 || !strings.Contains(r.stderr, "locked") {
		t.Fatalf("token list while serving: %+v", r)
	}

	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	waited := make(chan error, 1)
	go func() { waited <- cmd.Wait() }()
	select {
	case err := <-waited:
		if err != nil {
			t.Fatalf("serve exited with %v\n%s", err, <-rest)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("serve did not exit after SIGTERM")
	}
	tail := <-rest
	if !strings.Contains(tail, `"shutting down"`) || !strings.Contains(tail, `"server stopped"`) {
		t.Fatalf("shutdown logs:\n%s", tail)
	}
	if strings.Contains(logged.String()+tail, admin.Token) {
		t.Fatal("the token reached the logs")
	}
	st, err := store.Open(store.Options{Dir: data})
	if err != nil {
		t.Fatalf("the lock was not released: %v", err)
	}
	defer st.Close()
	if got := st.Events("", 0, 10); len(got.Events) != 1 || got.Events[0].Message != "before SIGTERM" {
		t.Fatalf("events after restart: %+v", got.Events)
	}
}
