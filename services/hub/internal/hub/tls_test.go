package hub

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/api"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/store"
	"github.com/Gitrochi/Gitrochi/services/hub/internal/stream"
)

// selfSigned writes a certificate for 127.0.0.1 and returns its files and a
// pool that trusts it.
func selfSigned(t *testing.T) (certFile, keyFile string, pool *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "hub.example.com"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		DNSNames:     []string{"hub.example.com"},
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	certFile, keyFile = filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600)
	os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600)
	cert, _ := x509.ParseCertificate(der)
	pool = x509.NewCertPool()
	pool.AddCert(cert)
	return certFile, keyFile, pool
}

// Over HTTP/2 a stream's write deadline is a timer; an idle SSE stream must
// survive deadlines far shorter than the gap between events.
func TestStreamOverHTTP2WithTLSStaysOpenWhileIdle(t *testing.T) {
	certFile, keyFile, pool := selfSigned(t)
	b := stream.NewBroker()
	st, err := store.Open(store.Options{Dir: t.TempDir(), OnEvents: b.Publish})
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	tok, _ := st.CreateToken("alice", api.RoleMember)
	srv := New(Config{SSEWriteTimeout: 150 * time.Millisecond, WriteTimeout: 300 * time.Millisecond, SSEHeartbeat: time.Hour}, st, b, nil)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- srv.Serve(ctx, ln, certFile, keyFile) }()
	defer func() { cancel(); <-done }()

	hc := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}, ForceAttemptHTTP2: true}}
	req, _ := http.NewRequest("GET", "https://"+ln.Addr().String()+"/api/v1/stream", nil)
	req.Header.Set("Authorization", "Bearer "+tok.Token)
	resp, err := hc.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.ProtoMajor != 2 {
		t.Fatalf("negotiated %s, want HTTP/2", resp.Proto)
	}
	time.Sleep(time.Second) // idle for several deadlines
	if _, err := st.AppendEvent(api.EventInput{Repo: repoKey, Type: api.EventCIPassed, Message: "after idle"}, "bob"); err != nil {
		t.Fatal(err)
	}
	c := &sseClient{resp: resp, rd: newReader(resp)}
	f := c.nextEvent(t)
	if !strings.Contains(f.data, "after idle") {
		t.Fatalf("frame %+v", f)
	}
}
