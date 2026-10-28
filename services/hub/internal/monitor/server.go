package monitor

import (
	"encoding/json"
	"net"
	"net/http"
	"strings"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/metrics"
)

// Handler serves the local endpoints: GET /healthz, GET /status,
// GET /metrics and POST /trigger?repo=<path or key> (all repositories
// without repo).
func (m *Monitor) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, m.Status())
	})
	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", metrics.ContentType)
		_ = m.reg.WriteText(w)
	})
	mux.HandleFunc("POST /trigger", func(w http.ResponseWriter, r *http.Request) {
		n := m.Trigger(r.URL.Query().Get("repo"))
		status := http.StatusAccepted
		if n == 0 {
			status = http.StatusNotFound
		}
		writeJSON(w, status, map[string]int{"triggered": n})
	})
	// Browsers must not drive the daemon from other sites: no cross-origin
	// POSTs, and no DNS-rebound host names on a loopback listener.
	var h http.Handler = http.NewCrossOriginProtection().Handler(mux)
	if isLoopback(m.cfg.Listen) {
		h = loopbackHostOnly(h)
	}
	return h
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func isLoopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func loopbackHostOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(r.Host); err == nil {
			host = h
		}
		host = strings.Trim(host, "[]")
		ip := net.ParseIP(host)
		if !strings.EqualFold(host, "localhost") && (ip == nil || !ip.IsLoopback()) {
			http.Error(w, "the monitor answers on a loopback host name only", http.StatusMisdirectedRequest)
			return
		}
		next.ServeHTTP(w, r)
	})
}
