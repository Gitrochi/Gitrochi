package repokey

import (
	"errors"
	"strings"
	"testing"
)

func TestNormalizeSameRepository(t *testing.T) {
	const want = "example.com/team/app"
	for _, in := range []string{
		"git@example.com:team/app.git",
		"git@Example.COM:team/app",
		"example.com:team/app.git",
		"https://example.com/team/app",
		"https://example.com/team/app.git",
		"https://example.com/team/app/",
		"HTTPS://EXAMPLE.COM/team/app",
		"https://user:secret@example.com:8443/team/app.git",
		"ssh://git@example.com/team/app.git",
		"ssh://git@example.com:2222/team/app.git",
		"git://example.com/team/app",
		"git+ssh://git@example.com/team//app.git",
		"example.com/team/app",
		"example.com./team/app.git",
		"  example.com/team/app  ",
	} {
		got, err := Normalize(in)
		if err != nil {
			t.Errorf("Normalize(%q): %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("Normalize(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestNormalizeKeepsPathCaseAndNesting(t *testing.T) {
	got, err := Normalize("https://example.com/Group/Sub/App.git")
	if err != nil || got != "example.com/Group/Sub/App" {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestNormalizeRejects(t *testing.T) {
	for _, in := range []string{
		"", "   ", "example.com", "https://example.com/", "https://example.com/team/..",
		"ftp://example.com/team/app", "https://example.com/team/my app",
		"git@example.com:", "[::1]:team/app", "example.com/team/a?b",
	} {
		if got, err := Normalize(in); err == nil {
			t.Errorf("Normalize(%q) = %q, want an error", in, got)
		}
	}
}

func TestNormalizeLocalPaths(t *testing.T) {
	for _, in := range []string{
		"/srv/git/app.git", "./app", "../app", "~/app", "file:///srv/git/app.git",
		`C:\repos\app`, "C:/repos/app", `\\server\share\app`,
	} {
		if _, err := Normalize(in); !errors.Is(err, ErrLocal) {
			t.Errorf("Normalize(%q) error = %v, want ErrLocal", in, err)
		}
	}
}

func TestNormalizeErrorsNeverEchoCredentials(t *testing.T) {
	_, err := Normalize("https://user:hunter2@example.com/%zz")
	if err == nil {
		t.Fatal("want an error")
	}
	if strings.Contains(err.Error(), "hunter2") {
		t.Fatalf("error leaks the password: %v", err)
	}
}
