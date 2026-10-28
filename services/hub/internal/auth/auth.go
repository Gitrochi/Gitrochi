// Package auth issues and checks the hub's bearer tokens.
//
// A token is "grh_<id>_<secret>": the id finds the stored record without
// comparing against every token, and only the SHA-256 hash of the whole token
// is stored, compared in constant time.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"strings"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
)

// Prefix starts every token, so leaked tokens are easy to recognize.
const Prefix = "grh_"

const (
	idLen     = 16 // hex characters
	secretLen = 26 // rand.Text: base32, 128 bits
	tokenLen  = len(Prefix) + idLen + 1 + secretLen
)

// Generate returns a new token and its id.
func Generate() (id, token string) {
	var b [idLen / 2]byte
	_, _ = rand.Read(b[:]) // crypto/rand.Read never fails
	id = hex.EncodeToString(b[:])
	return id, Prefix + id + "_" + rand.Text()
}

// ParseID returns the id embedded in a well-formed token.
func ParseID(token string) (string, bool) {
	if len(token) != tokenLen || !strings.HasPrefix(token, Prefix) {
		return "", false
	}
	id := token[len(Prefix) : len(Prefix)+idLen]
	if token[len(Prefix)+idLen] != '_' || !isLowerHex(id) {
		return "", false
	}
	for _, c := range []byte(token[len(Prefix)+idLen+1:]) {
		if !(c >= 'A' && c <= 'Z') && !(c >= '2' && c <= '7') {
			return "", false
		}
	}
	return id, true
}

// Hash returns the hex SHA-256 of a token, the only form that is stored.
func Hash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// Verify reports whether token hashes to storedHash, in constant time.
func Verify(token, storedHash string) bool {
	want, err := hex.DecodeString(storedHash)
	if err != nil || len(want) != sha256.Size {
		return false
	}
	got := sha256.Sum256([]byte(token))
	return subtle.ConstantTimeCompare(got[:], want) == 1
}

// ValidRole reports whether role is a known role.
func ValidRole(role string) bool {
	return role == api.RoleAdmin || role == api.RoleMember
}

// ValidID reports whether id has the shape of a token id.
func ValidID(id string) bool {
	return len(id) == idLen && isLowerHex(id)
}

func isLowerHex(s string) bool {
	for _, c := range []byte(s) {
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return s != ""
}
