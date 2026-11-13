package hub

import (
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/repokey"
)

// Limits on client input.
const (
	maxPaths      = 5000
	maxPathLen    = 1024
	maxNameLen    = 255 // branch, base and ref names
	maxClientLen  = 128
	maxMessageLen = 2000
	maxNoteLen    = 10000
	maxLine       = 10_000_000
	maxClockSkew  = 5 * time.Minute
)

func invalid(format string, args ...any) error { return fmt.Errorf(format, args...) }

func normalizeRepo(repo string) (string, error) {
	key, err := repokey.Normalize(repo)
	if err != nil {
		return "", fmt.Errorf("repo: %w", err)
	}
	return key, nil
}

func (s *Server) presenceEntry(in api.Presence, member string) (api.PresenceEntry, error) {
	var err error
	if in.Repo, err = normalizeRepo(in.Repo); err != nil {
		return api.PresenceEntry{}, err
	}
	if err := checkText("branch", in.Branch, maxNameLen, false); err != nil {
		return api.PresenceEntry{}, err
	}
	if err := checkText("base", in.Base, maxNameLen, false); err != nil {
		return api.PresenceEntry{}, err
	}
	in.Head = strings.ToLower(in.Head)
	if in.Head != "" && !isSHA(in.Head, 4) {
		return api.PresenceEntry{}, invalid("head must be a commit SHA")
	}
	if in.Ahead < 0 || in.Behind < 0 {
		return api.PresenceEntry{}, invalid("ahead and behind cannot be negative")
	}
	if in.Client == "" {
		in.Client = "default"
	}
	if err := checkText("client", in.Client, maxClientLen, false); err != nil {
		return api.PresenceEntry{}, err
	}
	if in.Changed, err = cleanPaths("changed", in.Changed); err != nil {
		return api.PresenceEntry{}, err
	}
	if in.Related, err = cleanPaths("related", in.Related); err != nil {
		return api.PresenceEntry{}, err
	}
	now := s.now()
	return api.PresenceEntry{Presence: in, Member: member, Updated: now, Expires: now.Add(s.cfg.PresenceTTL)}, nil
}

// cleanPaths validates repository-relative paths and returns them sorted
// without duplicates.
func cleanPaths(field string, paths []string) ([]string, error) {
	if len(paths) > maxPaths {
		return nil, invalid("%s: at most %d paths", field, maxPaths)
	}
	out := make([]string, 0, len(paths))
	for i, p := range paths {
		if err := checkPath(p); err != nil {
			return nil, invalid("%s[%d]: %v", field, i, err)
		}
		out = append(out, p)
	}
	slices.Sort(out)
	return slices.Compact(out), nil
}

func checkPath(p string) error {
	switch {
	case p == "":
		return errors.New("empty path")
	case len(p) > maxPathLen:
		return fmt.Errorf("path longer than %d bytes", maxPathLen)
	case !utf8.ValidString(p) || hasControl(p, false):
		return errors.New("path has invalid characters")
	case strings.HasPrefix(p, "/") || strings.Contains(p, `\`):
		return errors.New("path must be repository-relative with / separators")
	}
	return nil
}

func validateEvent(in api.EventInput, now time.Time) (api.EventInput, error) {
	var err error
	if in.Repo, err = normalizeRepo(in.Repo); err != nil {
		return in, err
	}
	if !slices.Contains(api.ClientEventTypes, in.Type) {
		return in, invalid("type must be one of %s", strings.Join(api.ClientEventTypes, ", "))
	}
	in.Old, in.New = strings.ToLower(in.Old), strings.ToLower(in.New)
	isRef := strings.HasPrefix(in.Type, "ref.")
	for _, f := range [...]struct{ name, v string }{{"old", in.Old}, {"new", in.New}} {
		switch {
		case f.v == "":
		case isRef && !isFullSHA(f.v):
			// Ref events come from tools that know the full object name.
			return in, invalid("%s must be a full object name (40 or 64 hex digits)", f.name)
		case !isSHA(f.v, 7):
			return in, invalid("%s must be a commit SHA of at least 7 hex digits", f.name)
		}
	}
	if isRef {
		if !validRefName(in.Ref) {
			return in, invalid("ref must be a full ref name such as refs/heads/main")
		}
		switch in.Type {
		case api.EventRefCreated:
			if in.New == "" || in.Old != "" {
				return in, invalid("ref.created needs new and no old")
			}
		case api.EventRefUpdated:
			if in.New == "" || in.Old == "" {
				return in, invalid("ref.updated needs old and new")
			}
		case api.EventRefDeleted:
			if in.Old == "" || in.New != "" {
				return in, invalid("ref.deleted needs old and no new")
			}
		}
	} else if err := checkText("ref", in.Ref, maxNameLen, false); err != nil {
		return in, err
	}
	if in.Forced && in.Type != api.EventRefUpdated {
		return in, invalid("forced applies to ref.updated only")
	}
	if err := checkText("message", in.Message, maxMessageLen, true); err != nil {
		return in, err
	}
	if !in.At.IsZero() {
		in.At = in.At.UTC().Truncate(time.Second)
		if in.At.After(now.Add(maxClockSkew)) {
			in.At = now
		}
	}
	return in, nil
}

func validateNote(repo string, in api.NoteInput, author string) (api.Note, error) {
	n := api.Note{Repo: repo, Author: author}
	if in.Commit == "" && in.Path == "" {
		return n, invalid("a note needs a commit, a path or both")
	}
	if in.Commit != "" {
		n.Commit = strings.ToLower(in.Commit)
		if !isSHA(n.Commit, 4) {
			return n, invalid("commit must be a commit SHA")
		}
	}
	if in.Path != "" {
		if err := checkPath(in.Path); err != nil {
			return n, invalid("path: %v", err)
		}
		n.Path = in.Path
	}
	if in.Line != 0 {
		if in.Path == "" {
			return n, invalid("line needs a path")
		}
		if in.Line < 1 || in.Line > maxLine {
			return n, invalid("line must be between 1 and %d", maxLine)
		}
		n.Line = in.Line
	}
	n.Body = strings.TrimSpace(in.Body)
	if n.Body == "" {
		return n, invalid("body is empty")
	}
	if err := checkText("body", n.Body, maxNoteLen, true); err != nil {
		return n, err
	}
	return n, nil
}

// checkText bounds a free-text field by characters and rejects control
// characters (line breaks and tabs only where multiline is allowed).
func checkText(field, v string, maxRunes int, multiline bool) error {
	if !utf8.ValidString(v) {
		return invalid("%s is not valid UTF-8", field)
	}
	if n := utf8.RuneCountInString(v); n > maxRunes {
		return invalid("%s is longer than %d characters", field, maxRunes)
	}
	if hasControl(v, multiline) {
		return invalid("%s has control characters", field)
	}
	return nil
}

func hasControl(s string, allowBreaks bool) bool {
	for _, r := range s {
		if allowBreaks && (r == '\n' || r == '\t' || r == '\r') {
			continue
		}
		if unicode.IsControl(r) {
			return true
		}
	}
	return false
}

func isSHA(s string, minLen int) bool {
	if len(s) < minLen || len(s) > 64 {
		return false
	}
	for _, c := range []byte(s) {
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// isFullSHA accepts SHA-1 and SHA-256 object names.
func isFullSHA(s string) bool { return (len(s) == 40 || len(s) == 64) && isSHA(s, 40) }

// validRefName applies the parts of git-check-ref-format that matter here.
func validRefName(ref string) bool {
	if !strings.HasPrefix(ref, "refs/") || len(ref) > maxNameLen || len(ref) <= len("refs/") {
		return false
	}
	if strings.Contains(ref, "..") || strings.Contains(ref, "//") || strings.Contains(ref, "@{") ||
		strings.HasSuffix(ref, "/") || strings.HasSuffix(ref, ".") || strings.HasSuffix(ref, ".lock") {
		return false
	}
	for _, r := range ref {
		if r <= ' ' || r == 0x7f || strings.ContainsRune(`~^:?*[\`, r) {
			return false
		}
	}
	return true
}
