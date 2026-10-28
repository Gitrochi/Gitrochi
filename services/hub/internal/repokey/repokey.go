// Package repokey turns git remote URLs into the hub's repository keys.
//
// A key is the lower-cased host followed by the repository path, without the
// scheme, user, port or ".git" suffix, so every way of naming a remote maps to
// the same key:
//
//	git@example.com:team/app.git       -> example.com/team/app
//	https://example.com/team/app       -> example.com/team/app
//	ssh://git@example.com:2222/team/app -> example.com/team/app
//
// The path keeps its case: some hosts treat it case-sensitively.
package repokey

import (
	"errors"
	"net/url"
	"strings"
	"unicode"
	"unicode/utf8"
)

// MaxLen bounds the length of a key.
const MaxLen = 512

// ErrLocal reports a remote on the local file system, which has no host to
// share with a team.
var ErrLocal = errors.New("a local path has no shared repository key; set an explicit key")

// Errors never quote the input: remote URLs often embed credentials.
var (
	errEmpty   = errors.New("repository is empty")
	errInvalid = errors.New("repository is not a valid remote URL or key")
	errScheme  = errors.New("repository URL has an unsupported scheme")
	errTooLong = errors.New("repository key is too long")
)

// Normalize returns the repository key for a remote URL or an existing key.
func Normalize(remote string) (string, error) {
	s := strings.TrimSpace(remote)
	if s == "" {
		return "", errEmpty
	}
	if len(s) > 4*MaxLen || !utf8.ValidString(s) {
		return "", errInvalid
	}
	var host, path string
	switch {
	case strings.Contains(s, "://"):
		u, err := url.Parse(s)
		if err != nil {
			return "", errInvalid
		}
		switch strings.ToLower(u.Scheme) {
		case "http", "https", "ssh", "git", "git+ssh", "ssh+git":
		case "file":
			return "", ErrLocal
		default:
			return "", errScheme
		}
		host, path = u.Hostname(), u.Path
	case isLocalPath(s):
		return "", ErrLocal
	case isSCP(s):
		// [user@]host:path, as git reads it: a colon before any slash.
		hostPart, rest, _ := strings.Cut(s, ":")
		if at := strings.LastIndexByte(hostPart, '@'); at >= 0 {
			hostPart = hostPart[at+1:]
		}
		host, path = hostPart, rest
	default:
		// Already a key: host/path.
		var ok bool
		host, path, ok = strings.Cut(s, "/")
		if !ok {
			return "", errInvalid
		}
	}
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	if !validHost(host) {
		return "", errInvalid
	}
	segments := make([]string, 0, 4)
	for seg := range strings.SplitSeq(path, "/") {
		if seg != "" {
			segments = append(segments, seg)
		}
	}
	if len(segments) == 0 {
		return "", errInvalid
	}
	last := len(segments) - 1
	segments[last] = strings.TrimSuffix(segments[last], ".git")
	for _, seg := range segments {
		if !validSegment(seg) {
			return "", errInvalid
		}
	}
	key := host + "/" + strings.Join(segments, "/")
	if len(key) > MaxLen {
		return "", errTooLong
	}
	return key, nil
}

func isSCP(s string) bool {
	colon := strings.IndexByte(s, ':')
	if colon <= 0 {
		return false
	}
	slash := strings.IndexByte(s, '/')
	return slash < 0 || colon < slash
}

func isLocalPath(s string) bool {
	switch {
	case strings.HasPrefix(s, "/"), strings.HasPrefix(s, "./"), strings.HasPrefix(s, "../"),
		strings.HasPrefix(s, "~"), strings.HasPrefix(s, `\`), s == ".", s == "..":
		return true
	case len(s) >= 2 && s[1] == ':' && isASCIILetter(s[0]):
		// A Windows drive (C:\repo, C:/repo, C:repo); git treats these as paths too.
		return true
	}
	return false
}

func isASCIILetter(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func validHost(host string) bool {
	if host == "" || len(host) > 255 {
		return false
	}
	for _, r := range host {
		if unicode.IsSpace(r) || unicode.IsControl(r) || strings.ContainsRune(`/\@?#%[]`, r) {
			return false
		}
	}
	return true
}

func validSegment(seg string) bool {
	if seg == "" || seg == "." || seg == ".." {
		return false
	}
	for _, r := range seg {
		if unicode.IsSpace(r) || unicode.IsControl(r) || strings.ContainsRune(`\?#`, r) {
			return false
		}
	}
	return true
}
