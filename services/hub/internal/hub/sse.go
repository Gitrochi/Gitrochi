package hub

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/store"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/stream"
)

// stream serves GET /api/v1/stream as Server-Sent Events. A client resumes
// with the Last-Event-ID header (or ?after=): retained events after that ID
// are sent first, then live ones. When the client missed events (retention
// dropped some, or its cursor predates a reset of the hub's data) a
// "truncated" event comes first and the client should refetch what it
// shows. A subscriber that falls behind is dropped and reconnects; on
// shutdown a "shutdown" event is sent before the stream ends.
func (s *Server) stream(w http.ResponseWriter, r *http.Request, _ store.Principal) {
	q := r.URL.Query()
	repo := ""
	if v := q.Get("repo"); v != "" {
		var err error
		if repo, err = normalizeRepo(v); err != nil {
			badRequest(w, err)
			return
		}
	}
	cursor := r.Header.Get("Last-Event-ID")
	if cursor == "" {
		cursor = q.Get("after")
	}
	after, ok := queryUint(w, strings.TrimSpace(cursor), "Last-Event-ID")
	if !ok {
		return
	}

	var sub *stream.Subscription
	var subErr error
	backlog, from, truncated := s.store.Replay(repo, after, func() {
		sub, subErr = s.broker.Subscribe(repo, s.cfg.SSEBuffer)
	})
	if subErr != nil {
		writeError(w, http.StatusServiceUnavailable, api.CodeUnavailable, "the hub is shutting down")
		return
	}
	defer sub.Close()

	rc := http.NewResponseController(w)
	// The stream outlives the server's read and write timeouts; each write
	// gets its own deadline instead.
	_ = rc.SetReadDeadline(time.Time{})
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("X-Accel-Buffering", "no") // keep reverse proxies from buffering the stream
	w.WriteHeader(http.StatusOK)

	out := &sseWriter{w: w, rc: rc, timeout: s.cfg.SSEWriteTimeout}
	out.raw("retry: 3000\n\n")
	if truncated {
		oldest := uint64(0)
		if len(backlog) > 0 {
			oldest = backlog[0].ID
		}
		out.event("truncated", 0, map[string]uint64{"after": after, "oldest": oldest})
	}
	last := from
	for _, e := range backlog {
		out.event(e.Type, e.ID, e)
		last = e.ID
	}
	if out.flush() != nil {
		return
	}

	heartbeat := time.NewTicker(s.cfg.SSEHeartbeat)
	defer heartbeat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-sub.Done():
			if sub.Reason() == stream.ReasonShutdown {
				out.event("shutdown", 0, struct{}{})
				_ = out.flush()
			}
			return
		case e := <-sub.Events():
			// Send everything already queued, then flush once.
			for {
				if e.ID > last {
					out.event(e.Type, e.ID, e)
					last = e.ID
				}
				select {
				case e = <-sub.Events():
					continue
				default:
				}
				break
			}
			if out.flush() != nil {
				return
			}
		case <-heartbeat.C:
			out.raw(": ping\n\n")
			if out.flush() != nil {
				return
			}
		}
	}
}

// sseWriter buffers SSE frames and writes them with a deadline, so a client
// that stops reading cannot hold the handler forever.
type sseWriter struct {
	w       http.ResponseWriter
	rc      *http.ResponseController
	timeout time.Duration
	buf     bytes.Buffer
}

func (o *sseWriter) raw(s string) { o.buf.WriteString(s) }

func (o *sseWriter) event(name string, id uint64, data any) {
	b, err := json.Marshal(data)
	if err != nil {
		return
	}
	if id > 0 {
		o.buf.WriteString("id: " + strconv.FormatUint(id, 10) + "\n")
	}
	o.buf.WriteString("event: " + name + "\ndata: ")
	o.buf.Write(b) // JSON never contains a raw newline
	o.buf.WriteString("\n\n")
}

// flush writes the buffered frames. The deadline covers only the write: an
// HTTP/2 stream deadline is a timer that resets the stream even while it is
// idle, so it is cleared again afterwards.
func (o *sseWriter) flush() error {
	if err := o.rc.SetWriteDeadline(time.Now().Add(o.timeout)); err != nil && !errors.Is(err, http.ErrNotSupported) {
		return err
	}
	if o.buf.Len() > 0 {
		_, err := o.w.Write(o.buf.Bytes())
		o.buf.Reset()
		if err != nil {
			return err
		}
	}
	if err := o.rc.Flush(); err != nil {
		return err
	}
	if err := o.rc.SetWriteDeadline(time.Time{}); err != nil && !errors.Is(err, http.ErrNotSupported) {
		return err
	}
	return nil
}
