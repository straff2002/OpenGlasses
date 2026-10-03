package bootstrap

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"avenkin.dev/mobilecore/commission"
)

type conversation struct {
	t      *testing.T
	stdin  *io.PipeWriter
	events chan map[string]any
	done   chan error
}

func converse(t *testing.T, cfg Config, issue Issuer) *conversation {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	c := &conversation{t: t, stdin: inW, events: make(chan map[string]any, 64), done: make(chan error, 1)}
	go func() {
		scanner := bufio.NewScanner(outR)
		scanner.Buffer(nil, 1<<20)
		for scanner.Scan() {
			var event map[string]any
			if json.Unmarshal(scanner.Bytes(), &event) != nil {
				event = map[string]any{"event": "unparseable", "line": scanner.Text()}
			}
			c.events <- event
		}
		close(c.events)
	}()
	go func() {
		e := Converse(cfg, issue, inR, outW)
		outW.Close()
		c.done <- e
	}()
	t.Cleanup(func() { inW.Close() })
	return c
}

func (c *conversation) next(kind string) map[string]any {
	c.t.Helper()
	select {
	case event, open := <-c.events:
		if !open {
			c.t.Fatalf("conversation ended waiting for %s", kind)
		}
		if event["event"] != kind {
			c.t.Fatalf("got %v, want %s", event, kind)
		}
		return event
	case <-time.After(5 * time.Second):
		c.t.Fatalf("no %s event", kind)
	}
	return nil
}

func (c *conversation) write(line string) {
	c.t.Helper()
	if _, e := io.WriteString(c.stdin, line+"\n"); e != nil {
		c.t.Fatal(e)
	}
}

func liveConfig(now int64) Config {
	return Config{Invitation: token("invitation"), OrganizationID: "test-organisation", Address: officeAddress,
		IssuedAt: now, ExpiresAt: now + 900, OfficeKey: officeKey, Listen: loopback}
}

func phoneOf(t *testing.T, invitationEvent map[string]any) (string, string) {
	t.Helper()
	envelope, e := commission.ParseQRText(invitationEvent["qr"].(string))
	if e != nil {
		t.Fatal(e)
	}
	return envelope, redeem(t, envelope, "phone")
}

func TestTheConversationRunsOneInvitationToDelivery(t *testing.T) {
	Linger = 50 * time.Millisecond
	t.Cleanup(func() { Linger = 10 * time.Second })
	cfg := liveConfig(time.Now().Unix())
	cfg.Certificate = certificate(t)
	var issued []string
	issue := func(profile, enrolment, office, phoneTransport, phoneKey string, now int64) (string, error) {
		issued = append(issued, profile, enrolment, office, phoneTransport, phoneKey)
		if profile == "unauthorised.profile" {
			return "", errors.New("this computer's administrator key is not authorised by that profile")
		}
		return `{"payload":"YmluZGluZw==","signature":"AA=="}`, nil
	}
	c := converse(t, cfg, issue)
	invitation := c.next("invitation")
	invitationEnvelope, red := phoneOf(t, invitation)
	if invitation["invitationSHA256"] != commission.Digest(invitationEnvelope) || invitation["expiresAt"] != float64(cfg.ExpiresAt) ||
		!strings.HasPrefix(invitation["address"].(string), officeAddress+":") || invitation["officeTransportID"] == "" ||
		invitation["officeID"] != commission.OfficeID(officeKey.Public().(ed25519.PublicKey)) {
		t.Fatal("invitation event does not describe the invitation", invitation)
	}

	c.write(`{"op":"approve","profileDocument":"p.s","licenceCode":"l.s","officeAddress":"192.168.77.10:22000"}`)
	if !strings.Contains(c.next("error")["message"].(string), "no phone has redeemed") {
		t.Fatal("approved before a redemption")
	}
	a, e := Exchange(context.Background(), toLoopback, invitationEnvelope, red)
	if e != nil || !a.Awaiting {
		t.Fatal("not awaiting", e)
	}
	redemption := c.next("redemption")
	if redemption["envelope"] != red {
		t.Fatal("redemption event carries another envelope")
	}
	c.write(`not json`)
	c.next("error")
	c.write(`{"op":"launch"}`)
	c.next("error")
	c.write(`{"op":"refuse","reason":"already_used"}`)
	c.next("error")
	c.write(`{"op":"approve","profileDocument":"unauthorised.profile","licenceCode":"l.s","officeAddress":"192.168.77.10:22000"}`)
	if !strings.Contains(c.next("error")["message"].(string), "not authorised") {
		t.Fatal("binding failure not reported")
	}
	issuedBefore := len(issued)
	for _, address := range []string{"", "8.8.8.8:22000", "192.168.77.10", "tcp://192.168.77.10:22000"} {
		c.write(`{"op":"approve","profileDocument":"p.s","licenceCode":"l.s","officeAddress":"` + address + `"}`)
		if !strings.Contains(c.next("error")["message"].(string), "office sync address") {
			t.Fatalf("approved with office address %q", address)
		}
	}
	if len(issued) != issuedBefore {
		t.Fatal("a peer binding was issued for an approval without a usable office address")
	}
	// The invitation is still live after the failures; the next approval goes through.
	c.write(`{"op":"approve","profileDocument":"p.s","licenceCode":"l.s","officeAddress":"192.168.77.10:22000"}`)
	ready := c.next("approval-ready")
	if ready["peerBinding"] != `{"payload":"YmluZGluZw==","signature":"AA=="}` {
		t.Fatal("approval-ready does not carry the binding")
	}
	if issued[6] != redemption["enrolmentID"] || issued[7] != invitation["officeTransportID"] ||
		issued[8] != redemption["phoneTransportID"] || issued[9] != redemption["phoneApplicationKey"] {
		t.Fatal("binding issued for other identities", issued)
	}
	a, e = Exchange(context.Background(), toLoopback, invitationEnvelope, red)
	if e != nil || a.Decision.Approval == nil || a.Decision.Approval.LicenceCode != "l.s" ||
		a.Decision.Approval.OfficeAddress != "192.168.77.10:22000" {
		t.Fatal("phone did not get the approval", e)
	}
	c.next("delivered")
	if c.next("closed")["reason"] != "delivered" {
		t.Fatal("conversation did not close after delivery")
	}
	if e = <-c.done; e != nil {
		t.Fatal(e)
	}
	if _, e = Exchange(context.Background(), toLoopback, invitationEnvelope, red); e == nil {
		t.Fatal("listener still answering after it closed")
	}
}

func TestClosingStdinCancelsTheInvitation(t *testing.T) {
	cfg := liveConfig(time.Now().Unix())
	cfg.Certificate = certificate(t)
	c := converse(t, cfg, nil)
	invitationEnvelope, red := phoneOf(t, c.next("invitation"))
	c.stdin.Close()
	if c.next("closed")["reason"] != "cancelled" {
		t.Fatal("not cancelled")
	}
	if _, e := Exchange(context.Background(), toLoopback, invitationEnvelope, red); e == nil {
		t.Fatal("listener still answering after cancellation")
	}
}

func TestTheConversationEndsAtExpiry(t *testing.T) {
	now := time.Now().Unix()
	cfg := liveConfig(now)
	cfg.Certificate = certificate(t)
	cfg.Now = func() int64 { return now }
	cfg.ExpiresAt = now + 1
	c := converse(t, cfg, nil)
	c.next("invitation")
	if c.next("closed")["reason"] != "expired" {
		t.Fatal("not expired")
	}
}

func TestAStartUpFailureIsReportedAndCloses(t *testing.T) {
	cfg := liveConfig(time.Now().Unix())
	cfg.Certificate = certificate(t)
	cfg.Address = "8.8.8.8"
	c := converse(t, cfg, nil)
	c.next("error")
	if c.next("closed")["reason"] != "failed" {
		t.Fatal("start-up failure did not close as failed")
	}
	if <-c.done == nil {
		t.Fatal("start-up failure returned no error")
	}
}

// After expiry an approval is refused before a binding is issued: issuing writes the ledger.
func TestNoBindingIsIssuedAfterExpiry(t *testing.T) {
	clock := clockAt(time.Now().Unix())
	cfg := liveConfig(clock.Load())
	cfg.Certificate, cfg.Now = certificate(t), clock.Load
	issued := 0
	issue := func(string, string, string, string, string, int64) (string, error) { issued++; return "binding", nil }
	c := converse(t, cfg, issue)
	invitationEnvelope, red := phoneOf(t, c.next("invitation"))
	if _, e := Exchange(context.Background(), toLoopback, invitationEnvelope, red); e != nil {
		t.Fatal(e)
	}
	c.next("redemption")
	clock.Add(900)
	c.write(`{"op":"approve","profileDocument":"p.s","licenceCode":"l.s","officeAddress":"192.168.77.10:22000"}`)
	if !strings.Contains(c.next("error")["message"].(string), "expired") {
		t.Fatal("approval after expiry not refused as expired")
	}
	c.write(`{"op":"refuse","reason":"policy"}`)
	c.next("error")
	if issued != 0 {
		t.Fatal("a peer binding was issued after expiry")
	}
	a, e := Exchange(context.Background(), toLoopback, invitationEnvelope, red)
	if e != nil || a.Decision.Refusal == nil || a.Decision.Refusal.Reason != "expired" {
		t.Fatal("phone not told the invitation expired", e)
	}
}

// blockedWriter takes the first write, then blocks every later one until released.
type blockedWriter struct {
	mu      sync.Mutex
	written []string
	release chan struct{}
}

func (w *blockedWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	n := len(w.written)
	w.mu.Unlock()
	if n > 0 {
		<-w.release
	}
	w.mu.Lock()
	w.written = append(w.written, string(p))
	w.mu.Unlock()
	return len(p), nil
}

// A desktop that stops reading stdout does not keep the listener open past expiry.
func TestExpiryClosesTheListenerWhileStdoutIsBlocked(t *testing.T) {
	now := time.Now().Unix()
	cfg := liveConfig(now)
	cfg.Certificate, cfg.ExpiresAt = certificate(t), now+2
	bound := make(chan string, 1)
	cfg.Listen = func(network, address string) (net.Listener, error) {
		l, e := loopback(network, address)
		if e == nil {
			bound <- l.Addr().String()
		}
		return l, e
	}
	out := &blockedWriter{release: make(chan struct{})}
	stdinR, stdinW := io.Pipe()
	defer stdinW.Close()
	done := make(chan error, 1)
	go func() { done <- Converse(cfg, nil, stdinR, out) }()
	address := <-bound
	// Events pile up behind the blocked writer: a redemption among them.
	waitFor(t, func() bool { out.mu.Lock(); defer out.mu.Unlock(); return len(out.written) == 1 })
	var invitation map[string]any
	out.mu.Lock()
	_ = json.Unmarshal([]byte(out.written[0]), &invitation)
	out.mu.Unlock()
	invitationEnvelope, red := phoneOf(t, invitation)
	if a, e := Exchange(context.Background(), toLoopback, invitationEnvelope, red); e != nil || !a.Awaiting {
		t.Fatal("request stalled behind stdout", e)
	}
	waitFor(t, func() bool {
		c, e := net.DialTimeout("tcp4", address, 200*time.Millisecond)
		if e == nil {
			c.Close()
		}
		return e != nil
	})
	close(out.release)
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("conversation did not end once stdout drained")
	}
	last := out.written[len(out.written)-1]
	if !strings.Contains(last, `"event":"closed"`) || !strings.Contains(last, `"expired"`) ||
		!strings.Contains(out.written[1], `"event":"redemption"`) {
		t.Fatal("events out of order or closed not last", out.written)
	}
}

func waitFor(t *testing.T, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatal("condition not reached")
		}
		time.Sleep(20 * time.Millisecond)
	}
}
