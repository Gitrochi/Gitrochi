package metrics

import (
	"strings"
	"testing"
)

func TestTextFormat(t *testing.T) {
	r := NewRegistry()
	c := r.Counter("x_total", "Things.")
	c.Inc()
	c.Add(2)
	v := r.CounterVec("req_total", "Requests.", "route", "code")
	v.Inc("GET /b", "200")
	v.Inc("GET /a", "200")
	v.Inc("GET /a", "200")
	v.Inc(`odd"route`+"\n", "500")
	r.GaugeFunc("g", "Gauge\nwith a newline.", func() float64 { return 1.5 })
	r.Info("build_info", "Build.", []string{"version"}, []string{"1.0"})
	var b strings.Builder
	if err := r.WriteText(&b); err != nil {
		t.Fatal(err)
	}
	want := `# HELP x_total Things.
# TYPE x_total counter
x_total 3
# HELP req_total Requests.
# TYPE req_total counter
req_total{route="GET /a",code="200"} 2
req_total{route="GET /b",code="200"} 1
req_total{route="odd\"route\n",code="500"} 1
# HELP g Gauge\nwith a newline.
# TYPE g gauge
g 1.5
# HELP build_info Build.
# TYPE build_info gauge
build_info{version="1.0"} 1
`
	if b.String() != want {
		t.Fatalf("got:\n%s\nwant:\n%s", b.String(), want)
	}
	if v.Value("GET /a", "200") != 2 {
		t.Fatal("Value")
	}
}
