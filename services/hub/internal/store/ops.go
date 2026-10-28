package store

import (
	"slices"
	"strings"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/auth"
)

// Authenticate returns the principal of a valid, unrevoked token.
func (s *Store) Authenticate(token string) (Principal, error) {
	id, ok := auth.ParseID(token)
	if !ok {
		return Principal{}, ErrUnauthorized
	}
	s.mu.RLock()
	t := s.tokens[id]
	var p Principal
	var hash string
	revoked := true
	if t != nil {
		p = Principal{TokenID: t.ID, Name: t.Name, Role: t.Role}
		hash, revoked = t.Hash, !t.Revoked.IsZero()
	}
	s.mu.RUnlock()
	if t == nil || revoked || !auth.Verify(token, hash) {
		return Principal{}, ErrUnauthorized
	}
	return p, nil
}

// CreateToken issues a token. The response carries the only copy of the
// secret; the store keeps its hash.
func (s *Store) CreateToken(name, role string) (api.TokenCreateResponse, error) {
	if err := ValidateName(name); err != nil {
		return api.TokenCreateResponse{}, err
	}
	if !auth.ValidRole(role) {
		return api.TokenCreateResponse{}, invalidf("role must be %q or %q", api.RoleAdmin, api.RoleMember)
	}
	var id, token string
	for {
		id, token = auth.Generate()
		s.mu.RLock()
		_, taken := s.tokens[id]
		s.mu.RUnlock()
		if !taken {
			break
		}
	}
	rec := tokenRecord{ID: id, Name: name, Role: role, Hash: auth.Hash(token), Created: s.now()}
	if err := s.submit(func() (string, any) { return opTokenCreate, rec }); err != nil {
		return api.TokenCreateResponse{}, err
	}
	return api.TokenCreateResponse{TokenInfo: rec.info(), Token: token}, nil
}

// Tokens lists every token, revoked ones included, oldest first.
func (s *Store) Tokens() []api.TokenInfo {
	s.mu.RLock()
	out := make([]api.TokenInfo, 0, len(s.tokens))
	for _, t := range s.tokens {
		out = append(out, t.info())
	}
	s.mu.RUnlock()
	slices.SortFunc(out, func(a, b api.TokenInfo) int {
		if c := a.Created.Compare(b.Created); c != 0 {
			return c
		}
		return strings.Compare(a.ID, b.ID)
	})
	return out
}

// ActiveTokens counts the tokens that are not revoked.
func (s *Store) ActiveTokens() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	n := 0
	for _, t := range s.tokens {
		if t.Revoked.IsZero() {
			n++
		}
	}
	return n
}

// RevokeToken revokes a token by id. Revoking a revoked token changes
// nothing.
func (s *Store) RevokeToken(id string) (api.TokenInfo, error) {
	s.mu.RLock()
	t := s.tokens[id]
	var info api.TokenInfo
	if t != nil {
		info = t.info()
	}
	s.mu.RUnlock()
	if t == nil {
		return api.TokenInfo{}, ErrNotFound
	}
	if !info.Revoked.IsZero() {
		return info, nil
	}
	at := s.now()
	if err := s.submit(func() (string, any) { return opTokenRevoke, revokeData{ID: id, At: at} }); err != nil {
		return api.TokenInfo{}, err
	}
	info.Revoked = at
	return info, nil
}

// RevokeTokensNamed revokes every active token with the given name.
func (s *Store) RevokeTokensNamed(name string) ([]api.TokenInfo, error) {
	var revoked []api.TokenInfo
	for _, t := range s.Tokens() {
		if t.Name != name || !t.Revoked.IsZero() {
			continue
		}
		info, err := s.RevokeToken(t.ID)
		if err != nil {
			return revoked, err
		}
		revoked = append(revoked, info)
	}
	if len(revoked) == 0 {
		return nil, ErrNotFound
	}
	return revoked, nil
}

// AppendEvent stores a validated event from member and returns it with its
// ID.
func (s *Store) AppendEvent(in api.EventInput, member string) (api.Event, error) {
	now := s.now()
	e := api.Event{
		Repo:     in.Repo,
		Type:     in.Type,
		Ref:      in.Ref,
		Old:      in.Old,
		New:      in.New,
		Forced:   in.Forced,
		Message:  in.Message,
		At:       in.At,
		Member:   member,
		Received: now,
	}
	if e.At.IsZero() {
		e.At = now
	}
	err := s.submit(func() (string, any) {
		e.ID = s.allocEventID()
		return opEvent, e
	})
	return e, err
}

// cursorLocked checks a client's cursor. One beyond the newest event comes
// from before the data directory was reset: it restarts from the beginning,
// and the client is told it missed events.
func (s *Store) cursorLocked(after uint64) (uint64, bool) {
	if after > s.maxEventID {
		return 0, true
	}
	return after, after < s.droppedThrough
}

// Events lists retained events after the cursor, optionally for one
// repository.
func (s *Store) Events(repo string, after uint64, limit int) api.EventsResponse {
	s.mu.RLock()
	defer s.mu.RUnlock()
	after, truncated := s.cursorLocked(after)
	resp := api.EventsResponse{
		Events:    []api.Event{},
		Last:      after,
		Oldest:    s.events.oldest(),
		Truncated: truncated,
	}
	for i := s.events.firstAfter(after); i < s.events.len(); i++ {
		e := s.events.at(i)
		if repo != "" && e.Repo != repo {
			resp.Last = e.ID
			continue
		}
		if len(resp.Events) == limit {
			resp.More = true
			break
		}
		resp.Events = append(resp.Events, *e)
		resp.Last = e.ID
	}
	return resp
}

// Replay returns the retained events after the cursor and calls register
// while holding the state lock, so an event either is in the backlog or
// reaches the subscription register creates (possibly both: subscribers skip
// IDs they have sent). truncated reports that the client missed events:
// retention dropped some after the cursor, or the cursor predates a reset
// (then the backlog starts from the beginning and from is 0).
func (s *Store) Replay(repo string, after uint64, register func()) (backlog []api.Event, from uint64, truncated bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	register()
	from, truncated = s.cursorLocked(after)
	for i := s.events.firstAfter(from); i < s.events.len(); i++ {
		if e := s.events.at(i); repo == "" || e.Repo == repo {
			backlog = append(backlog, *e)
		}
	}
	return backlog, from, truncated
}

// CreateNote stores a validated note by author.
func (s *Store) CreateNote(n api.Note) (api.Note, error) {
	n.Created = s.now()
	err := s.submit(func() (string, any) {
		n.ID = s.allocNoteID()
		note := n
		ev := api.Event{
			ID:       s.allocEventID(),
			Repo:     n.Repo,
			Type:     api.EventNoteCreated,
			At:       n.Created,
			Member:   n.Author,
			Received: n.Created,
			Note:     &note,
		}
		return opNoteCreate, noteCreateData{Note: n, Event: ev}
	})
	return n, err
}

// Notes lists a repository's notes after the cursor, oldest first. commit
// matches abbreviated SHAs in either direction; path matches exactly.
func (s *Store) Notes(repo, commit, path string, after uint64, limit int) []api.Note {
	s.mu.RLock()
	defer s.mu.RUnlock()
	ids := s.notesByRepo[repo]
	i, _ := slices.BinarySearch(ids, after+1)
	out := []api.Note{}
	for ; i < len(ids) && len(out) < limit; i++ {
		n := s.notes[ids[i]]
		if commit != "" && (n.Commit == "" || !(strings.HasPrefix(n.Commit, commit) || strings.HasPrefix(commit, n.Commit))) {
			continue
		}
		if path != "" && n.Path != path {
			continue
		}
		out = append(out, *n)
	}
	return out
}

// DeleteNote deletes a note. Only its author or an admin may.
func (s *Store) DeleteNote(id uint64, by Principal) error {
	s.mu.RLock()
	n, ok := s.notes[id]
	var note api.Note
	if ok {
		note = *n
	}
	s.mu.RUnlock()
	if !ok {
		return ErrNotFound
	}
	if note.Author != by.Name && !by.Admin() {
		return ErrForbidden
	}
	at := s.now()
	return s.submit(func() (string, any) {
		ev := api.Event{
			ID:       s.allocEventID(),
			Repo:     note.Repo,
			Type:     api.EventNoteDeleted,
			At:       at,
			Member:   by.Name,
			Received: at,
			Note:     &note,
		}
		return opNoteDelete, noteDeleteData{ID: id, Event: ev}
	})
}
