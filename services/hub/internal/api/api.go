// Package api defines the JSON shapes of the hub's HTTP API. The server and
// the client both use these types, so the wire format lives in one place.
package api

import "time"

// Token roles.
const (
	RoleAdmin  = "admin"
	RoleMember = "member"
)

// Event types. Clients may post the ref and CI types; the hub emits the note
// types itself when notes change.
const (
	EventRefCreated  = "ref.created"
	EventRefUpdated  = "ref.updated"
	EventRefDeleted  = "ref.deleted"
	EventCIPassed    = "ci.passed"
	EventCIFailed    = "ci.failed"
	EventNoteCreated = "note.created"
	EventNoteDeleted = "note.deleted"
)

// ClientEventTypes are the event types accepted by POST /api/v1/events.
var ClientEventTypes = []string{EventRefCreated, EventRefUpdated, EventRefDeleted, EventCIPassed, EventCIFailed}

// Overlap kinds.
const (
	OverlapSameFile    = "same-file"
	OverlapRelatedFile = "related-file"
)

// Error codes in ErrorBody.
const (
	CodeInvalidArgument = "INVALID_ARGUMENT"
	CodeUnauthorized    = "UNAUTHORIZED"
	CodeForbidden       = "FORBIDDEN"
	CodeNotFound        = "NOT_FOUND"
	CodePayloadTooLarge = "PAYLOAD_TOO_LARGE"
	CodeRateLimited     = "RATE_LIMITED"
	CodeUnavailable     = "UNAVAILABLE"
	CodeInternal        = "INTERNAL"
)

// ErrorBody is the body of every error response.
type ErrorBody struct {
	Error ErrorDetail `json:"error"`
}

// ErrorDetail describes an error.
type ErrorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Presence is what a client reports about its work in progress in one
// repository. Related lists files that historically change together with
// Changed (the monitor fills it from `gitrochi-index impact`).
type Presence struct {
	Repo    string   `json:"repo"`
	Branch  string   `json:"branch"`
	Head    string   `json:"head"`
	Base    string   `json:"base"`
	Ahead   int      `json:"ahead"`
	Behind  int      `json:"behind"`
	Changed []string `json:"changed"`
	Related []string `json:"related"`
	Client  string   `json:"client"`
}

// PresenceEntry is a stored presence report. Repo is the normalized key.
type PresenceEntry struct {
	Presence
	Member  string    `json:"member"`
	Updated time.Time `json:"updated"`
	Expires time.Time `json:"expires"`
}

// PresenceResponse answers POST /api/v1/presence with the stored entry and
// the overlaps that involve the caller.
type PresenceResponse struct {
	Presence PresenceEntry `json:"presence"`
	Overlaps []Overlap     `json:"overlaps"`
}

// PresenceList answers GET /api/v1/repos/{repo}/presence.
type PresenceList struct {
	Repo     string          `json:"repo"`
	Presence []PresenceEntry `json:"presence"`
}

// Participant is one side of an overlap.
type Participant struct {
	Member string `json:"member"`
	Client string `json:"client"`
	Branch string `json:"branch"`
	Head   string `json:"head"`
}

// Overlap is a pair of members whose work touches the same files. For
// same-file overlaps both changed Paths; for related-file overlaps A changed
// Paths and they are in B's related set (B is likely to need them too).
type Overlap struct {
	Kind  string      `json:"kind"`
	A     Participant `json:"a"`
	B     Participant `json:"b"`
	Paths []string    `json:"paths"`
}

// OverlapsResponse answers GET /api/v1/repos/{repo}/overlaps.
type OverlapsResponse struct {
	Repo     string    `json:"repo"`
	Overlaps []Overlap `json:"overlaps"`
}

// EventInput is the body of POST /api/v1/events.
type EventInput struct {
	Repo    string    `json:"repo"`
	Type    string    `json:"type"`
	Ref     string    `json:"ref,omitempty"`
	Old     string    `json:"old,omitempty"`
	New     string    `json:"new,omitempty"`
	Forced  bool      `json:"forced,omitempty"`
	Message string    `json:"message,omitempty"`
	At      time.Time `json:"at,omitzero"`
}

// Event is a stored event. IDs increase monotonically across all
// repositories and are the SSE event IDs.
type Event struct {
	ID       uint64    `json:"id"`
	Repo     string    `json:"repo"`
	Type     string    `json:"type"`
	Ref      string    `json:"ref,omitempty"`
	Old      string    `json:"old,omitempty"`
	New      string    `json:"new,omitempty"`
	Forced   bool      `json:"forced"`
	Message  string    `json:"message,omitempty"`
	At       time.Time `json:"at"`
	Member   string    `json:"member"`
	Received time.Time `json:"received"`
	Note     *Note     `json:"note,omitempty"`
}

// EventsResponse answers GET /api/v1/events. Last is the cursor for the next
// page; Truncated reports that events after the requested cursor were
// already dropped by retention.
type EventsResponse struct {
	Events    []Event `json:"events"`
	Last      uint64  `json:"last"`
	More      bool    `json:"more"`
	Oldest    uint64  `json:"oldest"`
	Truncated bool    `json:"truncated"`
}

// NoteInput is the body of POST /api/v1/repos/{repo}/notes. A note is
// attached to a commit, a path, a line of a path, or a path at a commit.
type NoteInput struct {
	Commit string `json:"commit,omitempty"`
	Path   string `json:"path,omitempty"`
	Line   int    `json:"line,omitempty"`
	Body   string `json:"body"`
}

// Note is a stored team note.
type Note struct {
	ID      uint64    `json:"id"`
	Repo    string    `json:"repo"`
	Commit  string    `json:"commit,omitempty"`
	Path    string    `json:"path,omitempty"`
	Line    int       `json:"line,omitempty"`
	Body    string    `json:"body"`
	Author  string    `json:"author"`
	Created time.Time `json:"created"`
}

// NotesResponse answers GET /api/v1/repos/{repo}/notes.
type NotesResponse struct {
	Repo  string `json:"repo"`
	Notes []Note `json:"notes"`
}

// Me answers GET /api/v1/me.
type Me struct {
	TokenID string `json:"tokenId"`
	Name    string `json:"name"`
	Role    string `json:"role"`
}

// TokenInfo describes a token without its secret.
type TokenInfo struct {
	ID      string    `json:"id"`
	Name    string    `json:"name"`
	Role    string    `json:"role"`
	Created time.Time `json:"created"`
	Revoked time.Time `json:"revoked,omitzero"`
}

// TokenCreateRequest is the body of POST /api/v1/tokens.
type TokenCreateRequest struct {
	Name string `json:"name"`
	Role string `json:"role"`
}

// TokenCreateResponse carries the only copy of a new token's secret.
type TokenCreateResponse struct {
	TokenInfo
	Token string `json:"token"`
}

// TokensResponse answers GET /api/v1/tokens.
type TokensResponse struct {
	Tokens []TokenInfo `json:"tokens"`
}

// Version is printed by `gitrochi-hub version` and served at /healthz.
type Version struct {
	Tool    string `json:"tool"`
	Version string `json:"version"`
	Commit  string `json:"commit,omitempty"`
	Go      string `json:"go"`
	OS      string `json:"os"`
	Arch    string `json:"arch"`
}
