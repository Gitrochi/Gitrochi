// Package client talks to a hub over HTTP. The monitor and the CLI use it.
// It never retries on its own; callers decide (the monitor backs off).
package client

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
)

const maxResponseBytes = 16 << 20

// Options configure New.
type Options struct {
	HTTPClient *http.Client  // overrides Timeout and CAFile
	Timeout    time.Duration // per request (30s)
	CAFile     string        // PEM roots for a hub with a private CA
	UserAgent  string
}

// Client is a hub API client. It is safe for concurrent use.
type Client struct {
	base  *url.URL
	token string
	http  *http.Client
	ua    string
}

// New returns a client for the hub at baseURL (http or https, optionally
// with a path prefix).
func New(baseURL, token string, opts Options) (*Client, error) {
	u, err := parseBase(baseURL)
	if err != nil {
		return nil, err
	}
	hc := opts.HTTPClient
	if hc == nil {
		tr := http.DefaultTransport.(*http.Transport).Clone()
		if opts.CAFile != "" {
			pem, err := os.ReadFile(opts.CAFile)
			if err != nil {
				return nil, err
			}
			pool := x509.NewCertPool()
			if !pool.AppendCertsFromPEM(pem) {
				return nil, fmt.Errorf("%s: no PEM certificates", opts.CAFile)
			}
			tr.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
		}
		timeout := opts.Timeout
		if timeout <= 0 {
			timeout = 30 * time.Second
		}
		hc = &http.Client{Transport: tr, Timeout: timeout}
	}
	ua := opts.UserAgent
	if ua == "" {
		ua = "gitrochi-hub"
	}
	return &Client{base: u, token: token, http: hc, ua: ua}, nil
}

func parseBase(raw string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return nil, errors.New("the hub URL must look like https://hub.example.com")
	}
	if u.User != nil {
		return nil, errors.New("the hub URL must not contain credentials; use a token file")
	}
	u.RawQuery, u.Fragment = "", ""
	return u, nil
}

// URL is the hub's base URL.
func (c *Client) URL() string { return c.base.String() }

// APIError is an error response from the hub.
type APIError struct {
	Status     int
	Code       string
	Message    string
	RetryAfter time.Duration
}

func (e *APIError) Error() string {
	return fmt.Sprintf("hub answered %d %s: %s", e.Status, e.Code, e.Message)
}

// Retryable reports whether the same request may succeed later.
func (e *APIError) Retryable() bool {
	return e.Status == http.StatusTooManyRequests || e.Status >= 500
}

// Retryable reports whether err is worth retrying: network failures and
// retryable API errors are, rejected requests are not.
func Retryable(err error) bool {
	var apiErr *APIError
	if errors.As(err, &apiErr) {
		return apiErr.Retryable()
	}
	return err != nil && !errors.Is(err, context.Canceled)
}

func (c *Client) do(ctx context.Context, method string, path []string, query url.Values, in, out any) error {
	u := c.base.JoinPath(path...)
	if len(query) > 0 {
		u.RawQuery = query.Encode()
	}
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", c.ua)
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return responseError(resp, data)
	}
	if out == nil || len(data) == 0 {
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("hub sent an unreadable response: %w", err)
	}
	return nil
}

func responseError(resp *http.Response, data []byte) error {
	e := &APIError{Status: resp.StatusCode, Code: "HTTP_" + strconv.Itoa(resp.StatusCode), Message: http.StatusText(resp.StatusCode)}
	var body api.ErrorBody
	if json.Unmarshal(data, &body) == nil && body.Error.Code != "" {
		e.Code, e.Message = body.Error.Code, body.Error.Message
	}
	if v := resp.Header.Get("Retry-After"); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs >= 0 {
			e.RetryAfter = time.Duration(secs) * time.Second
		} else if t, err := http.ParseTime(v); err == nil {
			e.RetryAfter = max(0, time.Until(t))
		}
	}
	return e
}

func repoPath(repo, resource string) []string {
	return []string{"api", "v1", "repos", repo, resource}
}

// Me returns the caller's token identity.
func (c *Client) Me(ctx context.Context) (api.Me, error) {
	var out api.Me
	err := c.do(ctx, http.MethodGet, []string{"api", "v1", "me"}, nil, nil, &out)
	return out, err
}

// PostPresence reports work in progress and returns the caller's overlaps.
func (c *Client) PostPresence(ctx context.Context, p api.Presence) (api.PresenceResponse, error) {
	var out api.PresenceResponse
	err := c.do(ctx, http.MethodPost, []string{"api", "v1", "presence"}, nil, p, &out)
	return out, err
}

// DeletePresence withdraws the caller's presence for repo and client.
func (c *Client) DeletePresence(ctx context.Context, repo, client string) error {
	q := url.Values{"repo": {repo}, "client": {client}}
	return c.do(ctx, http.MethodDelete, []string{"api", "v1", "presence"}, q, nil, nil)
}

// Presence lists who is working in repo.
func (c *Client) Presence(ctx context.Context, repo string) (api.PresenceList, error) {
	var out api.PresenceList
	err := c.do(ctx, http.MethodGet, repoPath(repo, "presence"), nil, nil, &out)
	return out, err
}

// Overlaps lists the overlaps in repo.
func (c *Client) Overlaps(ctx context.Context, repo string) (api.OverlapsResponse, error) {
	var out api.OverlapsResponse
	err := c.do(ctx, http.MethodGet, repoPath(repo, "overlaps"), nil, nil, &out)
	return out, err
}

// PostEvent publishes an event.
func (c *Client) PostEvent(ctx context.Context, e api.EventInput) (api.Event, error) {
	var out api.Event
	err := c.do(ctx, http.MethodPost, []string{"api", "v1", "events"}, nil, e, &out)
	return out, err
}

// Events lists events after a cursor; repo may be empty for all.
func (c *Client) Events(ctx context.Context, repo string, after uint64, limit int) (api.EventsResponse, error) {
	q := url.Values{}
	if repo != "" {
		q.Set("repo", repo)
	}
	if after > 0 {
		q.Set("after", strconv.FormatUint(after, 10))
	}
	if limit > 0 {
		q.Set("limit", strconv.Itoa(limit))
	}
	var out api.EventsResponse
	err := c.do(ctx, http.MethodGet, []string{"api", "v1", "events"}, q, nil, &out)
	return out, err
}

// Health checks a /healthz URL (a bare base URL gets /healthz appended).
// insecure skips certificate checks, for probing a TLS hub on loopback.
func Health(ctx context.Context, rawURL string, insecure bool) error {
	u, err := parseBase(rawURL)
	if err != nil {
		return err
	}
	if u.Path == "" || u.Path == "/" {
		u.Path = "/healthz"
	}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	if insecure {
		// A probe on loopback reaches a certificate issued for the public name.
		tr.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	}
	hc := &http.Client{Transport: tr}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return err
	}
	resp, err := hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s answered %s", u.Redacted(), resp.Status)
	}
	return nil
}
