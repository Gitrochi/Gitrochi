// Package metrics writes counters and gauges in the Prometheus text format,
// without a client library.
package metrics

import (
	"bufio"
	"io"
	"math"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

// ContentType is the media type of WriteText's output.
const ContentType = "text/plain; version=0.0.4; charset=utf-8"

// Registry holds metrics in registration order.
type Registry struct {
	mu      sync.Mutex
	metrics []metric
}

type metric interface {
	write(w *bufio.Writer)
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry { return &Registry{} }

func (r *Registry) add(m metric) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.metrics = append(r.metrics, m)
}

// WriteText writes every metric.
func (r *Registry) WriteText(w io.Writer) error {
	r.mu.Lock()
	ms := slices.Clone(r.metrics)
	r.mu.Unlock()
	bw := bufio.NewWriter(w)
	for _, m := range ms {
		m.write(bw)
	}
	return bw.Flush()
}

// Counter is a monotonically increasing value.
type Counter struct {
	name, help string
	bits       atomic.Uint64
}

// Counter registers a counter.
func (r *Registry) Counter(name, help string) *Counter {
	c := &Counter{name: name, help: help}
	r.add(c)
	return c
}

// Inc adds one.
func (c *Counter) Inc() { c.Add(1) }

// Add adds v, which must not be negative.
func (c *Counter) Add(v float64) {
	for {
		old := c.bits.Load()
		if c.bits.CompareAndSwap(old, math.Float64bits(math.Float64frombits(old)+v)) {
			return
		}
	}
}

// Value returns the current value.
func (c *Counter) Value() float64 { return math.Float64frombits(c.bits.Load()) }

func (c *Counter) write(w *bufio.Writer) {
	header(w, c.name, c.help, "counter")
	sample(w, c.name, "", c.Value())
}

// CounterVec is a counter with labels.
type CounterVec struct {
	name, help string
	labels     []string
	mu         sync.Mutex
	values     map[string]float64 // key: rendered label set
}

// CounterVec registers a counter with the given label names.
func (r *Registry) CounterVec(name, help string, labels ...string) *CounterVec {
	c := &CounterVec{name: name, help: help, labels: labels, values: make(map[string]float64)}
	r.add(c)
	return c
}

// Inc adds one to the series with the given label values.
func (c *CounterVec) Inc(values ...string) { c.Add(1, values...) }

// Add adds v to the series with the given label values.
func (c *CounterVec) Add(v float64, values ...string) {
	key := renderLabels(c.labels, values)
	c.mu.Lock()
	c.values[key] += v
	c.mu.Unlock()
}

// Value returns one series' value.
func (c *CounterVec) Value(values ...string) float64 {
	key := renderLabels(c.labels, values)
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.values[key]
}

func (c *CounterVec) write(w *bufio.Writer) {
	c.mu.Lock()
	keys := make([]string, 0, len(c.values))
	for k := range c.values {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	vals := make([]float64, len(keys))
	for i, k := range keys {
		vals[i] = c.values[k]
	}
	c.mu.Unlock()
	header(w, c.name, c.help, "counter")
	for i, k := range keys {
		sample(w, c.name, k, vals[i])
	}
}

type funcMetric struct {
	name, help, kind string
	fn               func() float64
}

// GaugeFunc registers a gauge read from fn at every scrape.
func (r *Registry) GaugeFunc(name, help string, fn func() float64) {
	r.add(&funcMetric{name: name, help: help, kind: "gauge", fn: fn})
}

// CounterFunc registers a counter read from fn at every scrape.
func (r *Registry) CounterFunc(name, help string, fn func() float64) {
	r.add(&funcMetric{name: name, help: help, kind: "counter", fn: fn})
}

func (f *funcMetric) write(w *bufio.Writer) {
	header(w, f.name, f.help, f.kind)
	sample(w, f.name, "", f.fn())
}

// Info registers a gauge of value 1 whose labels carry build information.
func (r *Registry) Info(name, help string, labels, values []string) {
	r.add(&infoMetric{name: name, help: help, labels: renderLabels(labels, values)})
}

type infoMetric struct{ name, help, labels string }

func (m *infoMetric) write(w *bufio.Writer) {
	header(w, m.name, m.help, "gauge")
	sample(w, m.name, m.labels, 1)
}

func header(w *bufio.Writer, name, help, kind string) {
	w.WriteString("# HELP " + name + " " + escapeHelp(help) + "\n")
	w.WriteString("# TYPE " + name + " " + kind + "\n")
}

func sample(w *bufio.Writer, name, labels string, v float64) {
	w.WriteString(name)
	if labels != "" {
		w.WriteString("{" + labels + "}")
	}
	w.WriteByte(' ')
	w.WriteString(formatValue(v))
	w.WriteByte('\n')
}

func formatValue(v float64) string {
	switch {
	case math.IsInf(v, 1):
		return "+Inf"
	case math.IsInf(v, -1):
		return "-Inf"
	case math.IsNaN(v):
		return "NaN"
	}
	return strconv.FormatFloat(v, 'g', -1, 64)
}

func renderLabels(names, values []string) string {
	var b strings.Builder
	for i, n := range names {
		v := ""
		if i < len(values) {
			v = values[i]
		}
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(n + `="` + escapeLabel(v) + `"`)
	}
	return b.String()
}

var (
	labelEscaper = strings.NewReplacer(`\`, `\\`, "\n", `\n`, `"`, `\"`)
	helpEscaper  = strings.NewReplacer(`\`, `\\`, "\n", `\n`)
)

func escapeLabel(s string) string { return labelEscaper.Replace(s) }

func escapeHelp(s string) string { return helpEscaper.Replace(s) }
