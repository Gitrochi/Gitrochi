package auth

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
)

func TestGenerateParseAndVerify(t *testing.T) {
	id, token := Generate()
	if !strings.HasPrefix(token, Prefix) {
		t.Fatalf("token %q lacks the prefix", token)
	}
	got, ok := ParseID(token)
	if !ok || got != id || !ValidID(id) {
		t.Fatalf("ParseID = %q, %v; want %q", got, ok, id)
	}
	hash := Hash(token)
	sum := sha256.Sum256([]byte(token))
	if hash != hex.EncodeToString(sum[:]) {
		t.Fatal("Hash is not the hex SHA-256 of the token")
	}
	if strings.Contains(hash, token) || strings.Contains(token, hash) {
		t.Fatal("hash and token overlap")
	}
	if !Verify(token, hash) {
		t.Fatal("Verify rejects the right token")
	}
	_, other := Generate()
	if Verify(other, hash) {
		t.Fatal("Verify accepts another token")
	}
	repl := "A"
	if token[len(token)-1] == 'A' {
		repl = "B"
	}
	if tampered := token[:len(token)-1] + repl; Verify(tampered, hash) {
		t.Fatal("Verify accepts a tampered token")
	}
	if Verify(token, "not-hex") || Verify(token, hash[:10]) {
		t.Fatal("Verify accepts a malformed stored hash")
	}
}

func TestTokensAreUnique(t *testing.T) {
	seen := make(map[string]bool)
	for range 1000 {
		id, token := Generate()
		if seen[id] || seen[token] {
			t.Fatal("duplicate token or id")
		}
		seen[id], seen[token] = true, true
	}
}

func TestParseIDRejectsMalformed(t *testing.T) {
	_, token := Generate()
	for _, bad := range []string{
		"", "grh_", token[1:], token + "A", "xyz" + token[3:],
		token[:len(Prefix)] + "ABCDEF0123456789" + token[len(Prefix)+16:], // upper-case id
		token[:len(Prefix)+16] + "-" + token[len(Prefix)+17:],
		token[:len(token)-1] + "1", // 1 is outside base32
	} {
		if _, ok := ParseID(bad); ok {
			t.Errorf("ParseID(%q) accepted", bad)
		}
	}
}

func TestValidRole(t *testing.T) {
	if !ValidRole("admin") || !ValidRole("member") || ValidRole("owner") || ValidRole("") {
		t.Fatal("ValidRole")
	}
}
