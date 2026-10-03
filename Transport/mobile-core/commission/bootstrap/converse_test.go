package bootstrap

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"io"
	"strings"
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

	c.write(`{"op":"approve","profileDocument":"p.s","licenceCode":"l.s"}`)
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
	c.write(`{"op":"approve","profileDocument":"unauthorised.profile","licenceCode":"l.s"}`)
	if !strings.Contains(c.next("error")["message"].(string), "not authorised") {
		t.Fatal("binding failure not reported")
	}
	// The invitation is still live after the failure; the next approval goes through.
	c.write(`{"op":"approve","profileDocument":"p.s","licenceCode":"l.s"}`)
	ready := c.next("approval-ready")
	if ready["peerBinding"] != `{"payload":"YmluZGluZw==","signature":"AA=="}` {
		t.Fatal("approval-ready does not carry the binding")
	}
	if issued[6] != redemption["enrolmentID"] || issued[7] != invitation["officeTransportID"] ||
		issued[8] != redemption["phoneTransportID"] || issued[9] != redemption["phoneApplicationKey"] {
		t.Fatal("binding issued for other identities", issued)
	}
	a, e = Exchange(context.Background(), toLoopback, invitationEnvelope, red)
	if e != nil || a.Decision.Approval == nil || a.Decision.Approval.LicenceCode != "l.s" {
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
