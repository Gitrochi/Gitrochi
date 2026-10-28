package hub

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/metrics"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/presence"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/store"
)

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.HandleFunc("GET /metrics", s.metrics)

	mux.Handle("GET /api/v1/me", s.authed(s.me))
	mux.Handle("POST /api/v1/presence", s.authed(s.postPresence))
	mux.Handle("DELETE /api/v1/presence", s.authed(s.deletePresence))
	// Repository keys contain slashes, so these routes take the rest of the
	// path and split off the last segment themselves.
	mux.Handle("GET /api/v1/repos/{rest...}", s.authed(s.repoGet))
	mux.Handle("POST /api/v1/repos/{rest...}", s.authed(s.repoPost))
	mux.Handle("DELETE /api/v1/notes/{id}", s.authed(s.deleteNote))
	mux.Handle("POST /api/v1/events", s.authed(s.postEvent))
	mux.Handle("GET /api/v1/events", s.authed(s.getEvents))
	mux.Handle("GET /api/v1/stream", s.authed(s.stream))

	mux.Handle("GET /api/v1/tokens", s.adminOnly(s.listTokens))
	mux.Handle("POST /api/v1/tokens", s.adminOnly(s.createToken))
	mux.Handle("DELETE /api/v1/tokens/{id}", s.adminOnly(s.revokeToken))
	return mux
}

// now is the server's clock in UTC whole seconds, the precision of every
// time in the API.
func (s *Server) now() time.Time { return s.cfg.Now().UTC().Truncate(time.Second) }

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "version": s.cfg.Version})
}

func (s *Server) readyz(w http.ResponseWriter, _ *http.Request) {
	switch {
	case s.draining.Load():
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "draining"})
	case s.store.Err() != nil:
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "journal unavailable"})
	default:
		writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
	}
}

func (s *Server) metrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", metrics.ContentType)
	if err := s.reg.WriteText(w); err != nil {
		s.log.Debug("writing metrics", "err", err)
	}
}

func (s *Server) me(w http.ResponseWriter, _ *http.Request, p store.Principal) {
	writeJSON(w, http.StatusOK, api.Me{TokenID: p.TokenID, Name: p.Name, Role: p.Role})
}

func (s *Server) postPresence(w http.ResponseWriter, r *http.Request, p store.Principal) {
	var in api.Presence
	if !s.decode(w, r, &in) {
		return
	}
	entry, err := s.presenceEntry(in, p.Name)
	if err != nil {
		badRequest(w, err)
		return
	}
	s.presence.Set(entry)
	all := presence.Overlaps(s.presence.List(entry.Repo, s.now()))
	writeJSON(w, http.StatusOK, api.PresenceResponse{Presence: entry, Overlaps: presence.Involving(all, p.Name)})
}

func (s *Server) deletePresence(w http.ResponseWriter, r *http.Request, p store.Principal) {
	q := r.URL.Query()
	repo, err := normalizeRepo(q.Get("repo"))
	if err != nil {
		badRequest(w, err)
		return
	}
	client := q.Get("client")
	if client == "" {
		client = "default"
	}
	s.presence.Remove(repo, p.Name, client)
	w.WriteHeader(http.StatusNoContent)
}

// repoPath splits /api/v1/repos/<key>/<resource>. Slashes in the key may
// be literal or percent-encoded.
func repoPath(r *http.Request) (repo, resource string, err error) {
	rest := r.PathValue("rest")
	i := strings.LastIndexByte(rest, '/')
	if i <= 0 {
		return "", "", nil
	}
	repo, err = normalizeRepo(rest[:i])
	return repo, rest[i+1:], err
}

func (s *Server) repoGet(w http.ResponseWriter, r *http.Request, p store.Principal) {
	repo, resource, err := repoPath(r)
	if err != nil {
		badRequest(w, err)
		return
	}
	switch resource {
	case "overlaps":
		setRoute(r, "GET /api/v1/repos/{repo}/overlaps")
		overlaps := presence.Overlaps(s.presence.List(repo, s.now()))
		writeJSON(w, http.StatusOK, api.OverlapsResponse{Repo: repo, Overlaps: overlaps})
	case "presence":
		setRoute(r, "GET /api/v1/repos/{repo}/presence")
		writeJSON(w, http.StatusOK, api.PresenceList{Repo: repo, Presence: s.presence.List(repo, s.now())})
	case "notes":
		setRoute(r, "GET /api/v1/repos/{repo}/notes")
		q := r.URL.Query()
		after, ok := queryUint(w, q.Get("after"), "after")
		if !ok {
			return
		}
		limit, ok := queryLimit(w, q.Get("limit"), 500, 5000)
		if !ok {
			return
		}
		commit := strings.ToLower(q.Get("commit"))
		if commit != "" && !isSHA(commit, 4) {
			badRequest(w, invalid("commit must be a commit SHA"))
			return
		}
		notes := s.store.Notes(repo, commit, q.Get("path"), after, limit)
		writeJSON(w, http.StatusOK, api.NotesResponse{Repo: repo, Notes: notes})
	default:
		writeError(w, http.StatusNotFound, api.CodeNotFound, "unknown repository resource")
	}
}

func (s *Server) repoPost(w http.ResponseWriter, r *http.Request, p store.Principal) {
	repo, resource, err := repoPath(r)
	if err != nil {
		badRequest(w, err)
		return
	}
	if resource != "notes" {
		writeError(w, http.StatusNotFound, api.CodeNotFound, "unknown repository resource")
		return
	}
	setRoute(r, "POST /api/v1/repos/{repo}/notes")
	var in api.NoteInput
	if !s.decode(w, r, &in) {
		return
	}
	n, err := validateNote(repo, in, p.Name)
	if err != nil {
		badRequest(w, err)
		return
	}
	n, err = s.store.CreateNote(n)
	if err != nil {
		s.storeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, n)
}

func (s *Server) deleteNote(w http.ResponseWriter, r *http.Request, p store.Principal) {
	id, err := strconv.ParseUint(r.PathValue("id"), 10, 64)
	if err != nil {
		badRequest(w, invalid("note id must be a number"))
		return
	}
	if err := s.store.DeleteNote(id, p); err != nil {
		s.storeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) postEvent(w http.ResponseWriter, r *http.Request, p store.Principal) {
	var in api.EventInput
	if !s.decode(w, r, &in) {
		return
	}
	in, err := validateEvent(in, s.now())
	if err != nil {
		badRequest(w, err)
		return
	}
	e, err := s.store.AppendEvent(in, p.Name)
	if err != nil {
		s.storeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, e)
}

func (s *Server) getEvents(w http.ResponseWriter, r *http.Request, _ store.Principal) {
	q := r.URL.Query()
	repo := ""
	if v := q.Get("repo"); v != "" {
		var err error
		if repo, err = normalizeRepo(v); err != nil {
			badRequest(w, err)
			return
		}
	}
	after, ok := queryUint(w, q.Get("after"), "after")
	if !ok {
		return
	}
	limit, ok := queryLimit(w, q.Get("limit"), 100, 1000)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, s.store.Events(repo, after, limit))
}

func (s *Server) listTokens(w http.ResponseWriter, _ *http.Request, _ store.Principal) {
	writeJSON(w, http.StatusOK, api.TokensResponse{Tokens: s.store.Tokens()})
}

func (s *Server) createToken(w http.ResponseWriter, r *http.Request, p store.Principal) {
	var in api.TokenCreateRequest
	if !s.decode(w, r, &in) {
		return
	}
	if in.Role == "" {
		in.Role = api.RoleMember
	}
	resp, err := s.store.CreateToken(in.Name, in.Role)
	if err != nil {
		s.storeError(w, err)
		return
	}
	s.log.Info("token created", "id", resp.ID, "name", resp.Name, "role", resp.Role, "by", p.Name)
	writeJSON(w, http.StatusCreated, resp)
}

func (s *Server) revokeToken(w http.ResponseWriter, r *http.Request, p store.Principal) {
	info, err := s.store.RevokeToken(r.PathValue("id"))
	if err != nil {
		s.storeError(w, err)
		return
	}
	s.log.Info("token revoked", "id", info.ID, "name", info.Name, "by", p.Name)
	writeJSON(w, http.StatusOK, info)
}

func queryUint(w http.ResponseWriter, v, name string) (uint64, bool) {
	if v == "" {
		return 0, true
	}
	n, err := strconv.ParseUint(v, 10, 64)
	if err != nil {
		badRequest(w, invalid("%s must be a non-negative integer", name))
		return 0, false
	}
	return n, true
}

func queryLimit(w http.ResponseWriter, v string, def, maxLimit int) (int, bool) {
	if v == "" {
		return def, true
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 || n > maxLimit {
		badRequest(w, invalid("limit must be between 1 and %d", maxLimit))
		return 0, false
	}
	return n, true
}
