package monitor

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/repokey"
)

// DefaultListen is the local status address.
const DefaultListen = "127.0.0.1:7421"

// ListenOff disables the local status server.
const ListenOff = "off"

// Duration reads "30s" or a number of seconds from JSON.
type Duration time.Duration

// UnmarshalJSON implements json.Unmarshaler.
func (d *Duration) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err == nil {
		v, err := time.ParseDuration(s)
		if err != nil {
			return fmt.Errorf("invalid duration %q", s)
		}
		*d = Duration(v)
		return nil
	}
	var secs float64
	if err := json.Unmarshal(b, &secs); err != nil {
		return errors.New(`a duration is a string such as "30s" or a number of seconds`)
	}
	*d = Duration(secs * float64(time.Second))
	return nil
}

// MarshalJSON implements json.Marshaler.
func (d Duration) MarshalJSON() ([]byte, error) { return json.Marshal(time.Duration(d).String()) }

// D returns the value as a time.Duration.
func (d Duration) D() time.Duration { return time.Duration(d) }

// Config is the monitor's configuration file.
type Config struct {
	Repos           []RepoConfig `json:"repos"`
	PollInterval    Duration     `json:"pollInterval,omitempty"`    // 30s
	FetchInterval   Duration     `json:"fetchInterval,omitempty"`   // 0: never fetch
	MaxGitProcesses int          `json:"maxGitProcesses,omitempty"` // 4
	GitTimeout      Duration     `json:"gitTimeout,omitempty"`      // 1m
	FetchTimeout    Duration     `json:"fetchTimeout,omitempty"`    // 5m
	IndexTimeout    Duration     `json:"indexTimeout,omitempty"`    // 10m
	Git             string       `json:"git,omitempty"`             // git executable; git on PATH
	Index           string       `json:"index,omitempty"`           // gitrochi-index path; GITROCHI_INDEX_BIN, else on PATH; "off"
	ImpactLimit     int          `json:"impactLimit,omitempty"`     // 20 related files per repository
	Hub             string       `json:"hub,omitempty"`             // hub URL; empty keeps everything local
	TokenFile       string       `json:"tokenFile,omitempty"`
	CAFile          string       `json:"caFile,omitempty"`
	Client          string       `json:"client,omitempty"` // presence client name; the host name
	Listen          string       `json:"listen,omitempty"` // 127.0.0.1:7421; "off"
	State           string       `json:"state,omitempty"`  // ref snapshots between runs; in the user cache directory
	EventRefs       []string     `json:"eventRefs,omitempty"`
	PresenceRefresh Duration     `json:"presenceRefresh,omitempty"` // 4m, below the hub's presence TTL
}

// RepoConfig is one repository. In the file it may also be a bare path.
type RepoConfig struct {
	Path          string `json:"path"`
	Key           string `json:"key,omitempty"`           // hub key; from the remote URL
	Remote        string `json:"remote,omitempty"`        // origin
	DefaultBranch string `json:"defaultBranch,omitempty"` // from <remote>/HEAD, else main or master
}

// UnmarshalJSON accepts a path string or an object.
func (r *RepoConfig) UnmarshalJSON(b []byte) error {
	var path string
	if json.Unmarshal(b, &path) == nil {
		*r = RepoConfig{Path: path}
		return nil
	}
	type plain RepoConfig
	var p plain
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&p); err != nil {
		return err
	}
	*r = RepoConfig(p)
	return nil
}

// LoadConfig reads and validates a configuration file. Relative paths are
// relative to the file's directory; "~/" is the home directory.
func LoadConfig(path string) (Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	var c Config
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return Config{}, fmt.Errorf("%s: %w", path, err)
	}
	if dec.Decode(&json.RawMessage{}) != io.EOF {
		return Config{}, fmt.Errorf("%s: unexpected data after the configuration", path)
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return Config{}, err
	}
	if err := c.Prepare(filepath.Dir(abs)); err != nil {
		return Config{}, fmt.Errorf("%s: %w", path, err)
	}
	return c, nil
}

// Prepare resolves paths against dir, fills defaults and validates.
func (c *Config) Prepare(dir string) error {
	if len(c.Repos) == 0 {
		return errors.New("no repositories configured")
	}
	seen := make(map[string]bool)
	for i := range c.Repos {
		r := &c.Repos[i]
		if r.Path == "" {
			return fmt.Errorf("repos[%d]: path is empty", i)
		}
		p, err := resolvePath(dir, r.Path)
		if err != nil {
			return fmt.Errorf("repos[%d]: %w", i, err)
		}
		r.Path = p
		if seen[p] {
			return fmt.Errorf("repos[%d]: %s is listed twice", i, p)
		}
		seen[p] = true
		if r.Remote == "" {
			r.Remote = "origin"
		}
		if r.Key != "" {
			key, err := repokey.Normalize(r.Key)
			if err != nil {
				return fmt.Errorf("repos[%d].key: %w", i, err)
			}
			r.Key = key
		}
	}
	def := func(d *Duration, v time.Duration) {
		if *d <= 0 {
			*d = Duration(v)
		}
	}
	def(&c.PollInterval, 30*time.Second)
	def(&c.GitTimeout, time.Minute)
	def(&c.FetchTimeout, 5*time.Minute)
	def(&c.IndexTimeout, 10*time.Minute)
	def(&c.PresenceRefresh, 4*time.Minute)
	if c.FetchInterval < 0 {
		c.FetchInterval = 0
	}
	if c.PollInterval.D() < time.Second {
		return errors.New("pollInterval must be at least 1s")
	}
	if c.MaxGitProcesses <= 0 {
		c.MaxGitProcesses = 4
	}
	if c.MaxGitProcesses > 64 {
		return errors.New("maxGitProcesses must be at most 64")
	}
	if c.ImpactLimit <= 0 {
		c.ImpactLimit = 20
	}
	if c.Listen == "" {
		c.Listen = DefaultListen
	}
	if len(c.EventRefs) == 0 {
		c.EventRefs = []string{"refs/heads/"}
	}
	for _, p := range c.EventRefs {
		if !strings.HasPrefix(p, "refs/") {
			return fmt.Errorf("eventRefs: %q must start with refs/", p)
		}
	}
	if c.Client == "" {
		if host, err := os.Hostname(); err == nil && host != "" {
			c.Client = host
		} else {
			c.Client = "monitor"
		}
	}
	for _, f := range []*string{&c.TokenFile, &c.CAFile, &c.State} {
		if *f != "" {
			p, err := resolvePath(dir, *f)
			if err != nil {
				return err
			}
			*f = p
		}
	}
	if c.State == "" {
		cache, err := os.UserCacheDir()
		if err != nil {
			return fmt.Errorf("no state file configured and no user cache directory: %w", err)
		}
		c.State = filepath.Join(cache, "gitrochi-hub", "monitor-state.json")
	}
	return nil
}

func resolvePath(dir, p string) (string, error) {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		p = filepath.Join(home, p[1:])
	}
	if !filepath.IsAbs(p) {
		p = filepath.Join(dir, p)
	}
	return filepath.Clean(p), nil
}
