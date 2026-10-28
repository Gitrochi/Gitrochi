package monitor

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
)

// repoState is what the monitor remembers about a repository between runs,
// so a restart (or the next --once from cron) still sees the ref changes
// made in between and still delivers events the hub has not taken yet.
type repoState struct {
	Refs      map[string]string `json:"refs"`
	Pending   []api.EventInput  `json:"pending,omitempty"`
	LastFetch time.Time         `json:"lastFetch,omitzero"`
}

// stateStore keeps the state file. It is safe for concurrent use.
type stateStore struct {
	path string

	mu    sync.Mutex
	repos map[string]json.RawMessage // by repository path
	dirty bool
}

func loadState(path string) (*stateStore, error) {
	s := &stateStore{path: path, repos: make(map[string]json.RawMessage)}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	var f struct {
		Version int                        `json:"version"`
		Repos   map[string]json.RawMessage `json:"repos"`
	}
	if err := json.Unmarshal(b, &f); err != nil || f.Version != 1 {
		// Losing the snapshot only costs one round of change detection.
		return s, fmt.Errorf("%s is unreadable; starting from scratch", path)
	}
	for k, v := range f.Repos {
		s.repos[k] = v
	}
	return s, nil
}

func (s *stateStore) get(repo string) (repoState, bool) {
	s.mu.Lock()
	raw, ok := s.repos[repo]
	s.mu.Unlock()
	if !ok {
		return repoState{}, false
	}
	var st repoState
	if json.Unmarshal(raw, &st) != nil {
		return repoState{}, false
	}
	return st, true
}

func (s *stateStore) put(repo string, st repoState) {
	raw, err := json.Marshal(st)
	if err != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !bytes.Equal(s.repos[repo], raw) {
		s.repos[repo] = raw
		s.dirty = true
	}
}

// save writes the file atomically when something changed.
func (s *stateStore) save() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.dirty {
		return nil
	}
	b, err := json.Marshal(struct {
		Version int                        `json:"version"`
		Repos   map[string]json.RawMessage `json:"repos"`
	}{1, s.repos})
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		os.Remove(tmp)
		return err
	}
	s.dirty = false
	return nil
}
