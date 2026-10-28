package hub

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/store"
)

// reqInfo carries what the logging middleware reports about a request.
type reqInfo struct {
	route  string // overrides the mux pattern for routes dispatched by hand
	member string
}

type infoKey struct{}

func setRoute(r *http.Request, route string) {
	if info, ok := r.Context().Value(infoKey{}).(*reqInfo); ok {
		info.route = route
	}
}

// observe logs and counts every request and turns panics into 500s. Tokens
// are never logged: only the member name of an authenticated request.
func (s *Server) observe(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		info := &reqInfo{}
		r = r.WithContext(context.WithValue(r.Context(), infoKey{}, info))
		rw := &responseWriter{ResponseWriter: w}
		defer func() {
			if v := recover(); v != nil {
				if v == http.ErrAbortHandler {
					panic(v)
				}
				s.log.Error("handler panicked", "panic", fmt.Sprint(v), "stack", string(debug.Stack()))
				if !rw.wroteHeader {
					writeError(rw, http.StatusInternalServerError, api.CodeInternal, "internal error")
				}
			}
			route := info.route
			if route == "" {
				route = r.Pattern // set by the mux on this request
			}
			if route == "" {
				route = "unmatched"
			}
			status := rw.status
			if status == 0 {
				status = http.StatusOK
			}
			s.requests.Inc(route, strconv.Itoa(status))
			level := slog.LevelInfo
			switch route {
			case "GET /healthz", "GET /readyz", "GET /metrics":
				level = slog.LevelDebug
			}
			s.log.LogAttrs(r.Context(), level, "request",
				slog.String("method", r.Method),
				slog.String("route", route),
				slog.String("path", r.URL.Path),
				slog.Int("status", status),
				slog.Int64("bytes", rw.bytes),
				slog.Duration("duration", time.Since(start)),
				slog.String("member", info.member),
				slog.String("remote", r.RemoteAddr))
		}()
		next.ServeHTTP(rw, r)
	})
}

// responseWriter records the status and size. Unwrap lets
// http.ResponseController reach the connection for SSE deadlines.
type responseWriter struct {
	http.ResponseWriter
	status      int
	bytes       int64
	wroteHeader bool
}

func (w *responseWriter) WriteHeader(code int) {
	if !w.wroteHeader {
		w.status, w.wroteHeader = code, true
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *responseWriter) Write(b []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	n, err := w.ResponseWriter.Write(b)
	w.bytes += int64(n)
	return n, err
}

func (w *responseWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *responseWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

type authedHandler func(w http.ResponseWriter, r *http.Request, p store.Principal)

// authed requires a valid bearer token and applies the token's rate limit.
func (s *Server) authed(h authedHandler) http.Handler { return s.withAuth(h, false) }

// adminOnly is authed plus the admin role.
func (s *Server) adminOnly(h authedHandler) http.Handler { return s.withAuth(h, true) }

func (s *Server) withAuth(h authedHandler, admin bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, err := store.Principal{}, store.ErrUnauthorized
		if token, ok := bearerToken(r); ok {
			p, err = s.store.Authenticate(token)
		}
		if err != nil {
			s.authFailures.Inc()
			w.Header().Set("WWW-Authenticate", `Bearer realm="gitrochi-hub"`)
			writeError(w, http.StatusUnauthorized, api.CodeUnauthorized, "a valid bearer token is required")
			return
		}
		if info, ok := r.Context().Value(infoKey{}).(*reqInfo); ok {
			info.member = p.Name
		}
		if ok, wait := s.limiter.Allow(p.TokenID); !ok {
			s.rateLimited.Inc()
			w.Header().Set("Retry-After", strconv.Itoa(max(1, int(math.Ceil(wait.Seconds())))))
			writeError(w, http.StatusTooManyRequests, api.CodeRateLimited, "too many requests; retry later")
			return
		}
		if admin && !p.Admin() {
			writeError(w, http.StatusForbidden, api.CodeForbidden, "this needs an admin token")
			return
		}
		h(w, r, p)
	})
}

func bearerToken(r *http.Request) (string, bool) {
	scheme, token, ok := strings.Cut(r.Header.Get("Authorization"), " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") {
		return "", false
	}
	token = strings.TrimSpace(token)
	return token, token != ""
}

// decode reads exactly one JSON value into v, rejecting unknown fields and
// bodies over the size limit. It writes the error response itself.
func (s *Server) decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	err := dec.Decode(v)
	if err == nil {
		if extra := dec.Decode(&json.RawMessage{}); extra != io.EOF {
			err = extra
			if err == nil {
				err = errors.New("unexpected data after the JSON value")
			}
		}
	}
	if err == nil {
		return true
	}
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		writeError(w, http.StatusRequestEntityTooLarge, api.CodePayloadTooLarge,
			fmt.Sprintf("the request body is larger than %d bytes", tooLarge.Limit))
		return false
	}
	if errors.Is(err, io.EOF) {
		err = errors.New("the request body is empty")
	}
	writeError(w, http.StatusBadRequest, api.CodeInvalidArgument,
		"invalid JSON body: "+strings.TrimPrefix(err.Error(), "json: "))
	return false
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		status = http.StatusInternalServerError
		b = []byte(`{"error":{"code":"INTERNAL","message":"encoding the response failed"}}`)
	}
	h := w.Header()
	h.Set("Content-Type", "application/json; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = w.Write(append(b, '\n'))
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, api.ErrorBody{Error: api.ErrorDetail{Code: code, Message: message}})
}

func badRequest(w http.ResponseWriter, err error) {
	writeError(w, http.StatusBadRequest, api.CodeInvalidArgument, err.Error())
}

// storeError maps store errors to responses.
func (s *Server) storeError(w http.ResponseWriter, err error) {
	var invalid *store.InvalidError
	switch {
	case errors.As(err, &invalid):
		badRequest(w, invalid)
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, api.CodeNotFound, "not found")
	case errors.Is(err, store.ErrForbidden):
		writeError(w, http.StatusForbidden, api.CodeForbidden, "only the author or an admin may do this")
	case errors.Is(err, store.ErrUnavailable), errors.Is(err, store.ErrClosed):
		w.Header().Set("Retry-After", "30")
		writeError(w, http.StatusServiceUnavailable, api.CodeUnavailable, "the hub cannot store changes right now")
	default:
		s.log.Error("store", "err", err)
		writeError(w, http.StatusInternalServerError, api.CodeInternal, "internal error")
	}
}
