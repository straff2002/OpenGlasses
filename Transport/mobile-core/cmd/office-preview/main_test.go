package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"avenkin.dev/mobilecore/commission"
	"avenkin.dev/mobilecore/commission/bootstrap"
	p "avenkin.dev/mobilecore/officepreview"

	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/tlsutil"
)

func TestOneShotOperationsAreUnchanged(t *testing.T) {
	root := t.TempDir()
	for _, request := range []string{`{"op":"status"}`, "{\"op\":\"status\"}\n", "{\n\"op\": \"status\"\n}"} {
		var out bytes.Buffer
		if status := helper([]string{"helper", root}, strings.NewReader(request), &out); status != 0 {
			t.Fatalf("%q: exit %d, %s", request, status, out.String())
		}
		var reply map[string]any
		if json.Unmarshal(out.Bytes(), &reply) != nil || reply["paired"] != false || reply["managedOfficeID"] == "" {
			t.Fatalf("%q: %s", request, out.String())
		}
	}
	for request, want := range map[string]string{
		`{"op":"launch"}`:                        "unknown native operation",
		strings.Repeat(" ", p.MaximumEnvelope+1): "request too large",
	} {
		var out bytes.Buffer
		if status := helper([]string{"helper", root}, strings.NewReader(request), &out); status != 1 || !strings.Contains(out.String(), want) {
			t.Fatalf("%.20q: exit %d, %s", request, status, out.String())
		}
	}
	var out bytes.Buffer
	if helper([]string{"helper", "relative"}, strings.NewReader(`{"op":"status"}`), &out) != 1 || !strings.Contains(out.String(), "root required") {
		t.Fatal("relative root accepted")
	}
}

func loopback(string, string) (net.Listener, error) { return net.Listen("tcp4", "127.0.0.1:0") }
func toLoopback(ctx context.Context, _, address string) (net.Conn, error) {
	_, port, _ := net.SplitHostPort(address)
	return (&net.Dialer{}).DialContext(ctx, "tcp4", "127.0.0.1:"+port)
}

type session struct {
	t      *testing.T
	stdin  *io.PipeWriter
	events chan string
	status chan int
}

func open(t *testing.T, root, first string) *session {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := &session{t: t, stdin: inW, events: make(chan string, 64), status: make(chan int, 1)}
	// Read stdout as the desktop does: continuously.
	go func() {
		scanner := bufio.NewScanner(outR)
		scanner.Buffer(nil, 1<<20)
		for scanner.Scan() {
			s.events <- scanner.Text()
		}
		close(s.events)
	}()
	go func() {
		status := helper([]string{"helper", root}, inR, outW)
		outW.Close()
		s.status <- status
	}()
	t.Cleanup(func() { inW.Close() })
	s.write(first)
	return s
}

func (s *session) write(line string) {
	if _, e := io.WriteString(s.stdin, line+"\n"); e != nil {
		s.t.Fatal(e)
	}
}

func (s *session) next(kind string) map[string]any {
	s.t.Helper()
	var line string
	select {
	case l, ok := <-s.events:
		if !ok {
			s.t.Fatalf("no %s event", kind)
		}
		line = l
	case <-time.After(5 * time.Second):
		s.t.Fatalf("no %s event", kind)
	}
	var event map[string]any
	if e := json.Unmarshal([]byte(line), &event); e != nil || event["event"] != kind {
		s.t.Fatalf("got %s, want %s", line, kind)
	}
	return event
}

func serveLine(t *testing.T, edit func(map[string]any)) (string, string) {
	dir := t.TempDir()
	certificate, key := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	made, e := tlsutil.NewCertificate(certificate, key, "syncthing", 2, false)
	if e != nil {
		t.Fatal(e)
	}
	secret := sha256.Sum256([]byte("invitation"))
	now := time.Now().Unix()
	line := map[string]any{"op": "commission-serve", "invitation": base64.RawURLEncoding.EncodeToString(secret[:]),
		"organizationID": "test-organisation", "address": "192.168.77.10", "issuedAt": now, "expiresAt": now + 900,
		"certificate": certificate, "key": key}
	if edit != nil {
		edit(line)
	}
	b, _ := json.Marshal(line)
	return string(b), protocol.NewDeviceID(made.Certificate[0]).String()
}

func TestCommissionServeRunsOneInvitation(t *testing.T) {
	listen = loopback
	t.Cleanup(func() { listen = nil })
	root := t.TempDir()
	first, transport := serveLine(t, nil)
	s := open(t, root, first)
	invitation := s.next("invitation")
	office, e := p.OpenOffice(root)
	if e != nil {
		t.Fatal(e)
	}
	if invitation["officeTransportID"] != transport || invitation["officeID"] != office.ManagedOfficeID() {
		t.Fatal("invitation is not this office's", invitation)
	}
	envelope, e := commission.ParseQRText(invitation["qr"].(string))
	if e != nil {
		t.Fatal(e)
	}
	i, _ := commission.ReadInvitation(envelope, time.Now().Unix())
	phoneSeed := sha256.Sum256([]byte("phone"))
	phone := ed25519.NewKeyFromSeed(phoneSeed[:])
	red, e := commission.SignRedemption(commission.Redemption{Version: 1, Kind: commission.RedemptionKind,
		InvitationSHA256: commission.Digest(envelope), Invitation: i.Invitation, EnrolmentID: "enrolment-1",
		PhoneTransportID:    protocol.NewDeviceID([]byte("phone")).String(),
		PhoneApplicationKey: base64.StdEncoding.EncodeToString(phone.Public().(ed25519.PublicKey)),
		AppVersion:          "2.4.0", AppBuild: "412", CreatedAt: time.Now().Unix()}, phone)
	if e != nil {
		t.Fatal(e)
	}
	if a, e := bootstrap.Exchange(context.Background(), toLoopback, envelope, red); e != nil || !a.Awaiting {
		t.Fatal("not awaiting", e)
	}
	if s.next("redemption")["enrolmentID"] != "enrolment-1" {
		t.Fatal("redemption event is for another enrolment")
	}
	// A real office issues the binding only for a profile signed by a production vendor key
	// that names this computer's administrator key.
	s.write(`{"op":"approve","profileDocument":"e30=.AAAA","licenceCode":"l.s","officeAddress":"192.168.77.10:22000"}`)
	if message := s.next("error")["message"].(string); !strings.HasPrefix(message, "peer binding: ") {
		t.Fatal(message)
	}
	s.write(`{"op":"refuse","reason":"refused_by_person"}`)
	s.next("refusal-ready")
	a, e := bootstrap.Exchange(context.Background(), toLoopback, envelope, red)
	if e != nil || a.Decision.Refusal == nil || a.Decision.Refusal.Reason != "refused_by_person" {
		t.Fatal("phone did not get the refusal", e)
	}
	s.next("delivered")
	s.stdin.Close()
	if s.next("closed")["reason"] != "cancelled" || <-s.status != 0 {
		t.Fatal("conversation did not end cleanly")
	}
}

func TestCommissionServeRefusesABadStart(t *testing.T) {
	listen = loopback
	t.Cleanup(func() { listen = nil })
	for name, edit := range map[string]func(map[string]any){
		"public address":    func(l map[string]any) { l["address"] = "8.8.8.8" },
		"wildcard address":  func(l map[string]any) { l["address"] = "0.0.0.0" },
		"relative cert":     func(l map[string]any) { l["certificate"] = "cert.pem" },
		"missing key":       func(l map[string]any) { l["key"] = "/nonexistent/key.pem" },
		"unknown field":     func(l map[string]any) { l["port"] = 1 },
		"short invitation":  func(l map[string]any) { l["invitation"] = "abc" },
		"too long":          func(l map[string]any) { l["expiresAt"] = l["issuedAt"].(int64) + 901 },
		"bad organisation":  func(l map[string]any) { l["organizationID"] = "a b" },
		"not yet live":      func(l map[string]any) { l["issuedAt"] = l["issuedAt"].(int64) + 60 },
		"certificate & key": func(l map[string]any) { l["key"] = l["certificate"] },
	} {
		first, _ := serveLine(t, edit)
		s := open(t, t.TempDir(), first)
		s.next("error")
		if s.next("closed")["reason"] != "failed" || <-s.status != 1 {
			t.Fatal(name, "did not fail")
		}
	}
}
