package bootstrap

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"avenkin.dev/mobilecore/commission"

	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/tlsutil"
)

func keyFor(label string) ed25519.PrivateKey {
	seed := sha256.Sum256([]byte(label))
	return ed25519.NewKeyFromSeed(seed[:])
}

func certificate(t *testing.T) tls.Certificate {
	t.Helper()
	c, e := tlsutil.NewCertificateInMemory("syncthing", 2)
	if e != nil {
		t.Fatal(e)
	}
	return c
}

// The invitation names a private address; the socket is loopback, and the phone's dial goes
// to loopback on the same port. Nothing else differs from a real office.
func loopback(string, string) (net.Listener, error) { return net.Listen("tcp4", "127.0.0.1:0") }
func toLoopback(ctx context.Context, _, address string) (net.Conn, error) {
	_, port, e := net.SplitHostPort(address)
	if e != nil {
		return nil, e
	}
	return (&net.Dialer{}).DialContext(ctx, "tcp4", "127.0.0.1:"+port)
}

type recorder struct {
	mu     sync.Mutex
	events []map[string]any
}

func (r *recorder) notify(event map[string]any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
}
func (r *recorder) all(kind string) []map[string]any {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []map[string]any
	for _, e := range r.events {
		if e["event"] == kind {
			out = append(out, e)
		}
	}
	return out
}

const officeAddress = "192.168.77.10"

var officeKey = keyFor("test office application key")

func token(label string) string {
	sum := sha256.Sum256([]byte(label))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func start(t *testing.T, clock *atomic.Int64, events *recorder) *Server {
	t.Helper()
	now := clock.Load()
	s, e := Listen(Config{Invitation: token("invitation"), OrganizationID: "test-organisation", Address: officeAddress,
		IssuedAt: now, ExpiresAt: now + 900, Certificate: certificate(t), OfficeKey: officeKey,
		Notify: events.notify, Now: clock.Load, Listen: loopback})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func redeem(t *testing.T, invitationEnvelope, phone string) string {
	t.Helper()
	i, e := Invitation(invitationEnvelope)
	if e != nil {
		t.Fatal(e)
	}
	key := keyFor(phone)
	r, e := commission.SignRedemption(commission.Redemption{Version: 1, Kind: commission.RedemptionKind,
		InvitationSHA256: commission.Digest(invitationEnvelope), Invitation: i.Invitation, EnrolmentID: phone + "-enrolment",
		PhoneTransportID:    protocol.NewDeviceID([]byte(phone)).String(),
		PhoneApplicationKey: base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey)),
		AppVersion:          "2.4.0", AppBuild: "412", ExistingEnrolment: "", CreatedAt: i.IssuedAt + 5}, key)
	if e != nil {
		t.Fatal(e)
	}
	return r
}

func exchange(t *testing.T, s *Server, redemption string) Answer {
	t.Helper()
	a, e := Exchange(context.Background(), toLoopback, s.Invitation(), redemption)
	if e != nil {
		t.Fatal(e)
	}
	return a
}

func clockAt(now int64) *atomic.Int64 {
	var c atomic.Int64
	c.Store(now)
	return &c
}

func TestAPhoneRedeemsWaitsAndIsApproved(t *testing.T) {
	events := &recorder{}
	s := start(t, clockAt(time.Now().Unix()), events)
	if !strings.HasPrefix(s.Address(), officeAddress+":") {
		t.Fatal("invitation does not name the office's private address", s.Address())
	}
	red := redeem(t, s.Invitation(), "phone")
	for range 3 {
		if a := exchange(t, s, red); !a.Awaiting {
			t.Fatal("office answered before a person decided")
		}
	}
	redemptions := events.all("redemption")
	if len(redemptions) != 1 {
		t.Fatalf("%d redemption events for one phone polling", len(redemptions))
	}
	comparison, _ := commission.Comparison(s.InvitationSHA256(), commission.Digest(red))
	got := redemptions[0]
	if got["comparison"] != comparison || got["envelope"] != red || got["redemptionSHA256"] != commission.Digest(red) ||
		got["enrolmentID"] != "phone-enrolment" || got["existingEnrolment"] != "" || got["appBuild"] != "412" {
		t.Fatal("redemption event does not describe the redemption", got)
	}
	approval, e := s.Approve("profile.signature", "licence.signature", `{"payload":"e30=","signature":"AA=="}`)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Refuse("policy"); e == nil {
		t.Fatal("a decided invitation was decided again")
	}
	for range 2 {
		a := exchange(t, s, red)
		if a.Awaiting || a.Decision.Approval == nil || a.Envelope != approval || a.Decision.Approval.PeerBinding != `{"payload":"e30=","signature":"AA=="}` {
			t.Fatal("phone did not get the approval", a)
		}
	}
	if n := len(events.all("delivered")); n != 1 {
		t.Fatalf("%d delivered events", n)
	}
	if ready := events.all("approval-ready"); len(ready) != 1 || ready[0]["decisionSHA256"] != commission.Digest(approval) {
		t.Fatal("no approval-ready event")
	}
}

func TestARefusalIsServedToThePhone(t *testing.T) {
	events := &recorder{}
	s := start(t, clockAt(time.Now().Unix()), events)
	if _, e := s.Refuse("refused_by_person"); e == nil {
		t.Fatal("refused before any phone redeemed")
	}
	red := redeem(t, s.Invitation(), "phone")
	exchange(t, s, red)
	for _, reason := range []string{"expired", "already_used", "nonsense"} {
		if _, e := s.Refuse(reason); e == nil {
			t.Fatalf("a person refused with %q", reason)
		}
	}
	if _, e := s.Refuse("wrong_organisation"); e != nil {
		t.Fatal(e)
	}
	a := exchange(t, s, red)
	if a.Decision.Refusal == nil || a.Decision.Refusal.Reason != "wrong_organisation" {
		t.Fatal("phone did not get the refusal", a)
	}
	if len(events.all("refusal-ready")) != 1 || len(events.all("delivered")) != 1 {
		t.Fatal("refusal events missing", events.events)
	}
}

func TestASecondRedemptionIsAlreadyUsedAndAnUnexpectedUse(t *testing.T) {
	events := &recorder{}
	s := start(t, clockAt(time.Now().Unix()), events)
	first, second := redeem(t, s.Invitation(), "phone"), redeem(t, s.Invitation(), "intruder")
	exchange(t, s, first)
	for range 2 {
		a := exchange(t, s, second)
		if a.Decision.Refusal == nil || a.Decision.Refusal.Reason != "already_used" {
			t.Fatal("second redemption was not refused as already used", a)
		}
	}
	if used := events.all("unexpected-use"); len(used) != 1 || used[0]["redemptionSHA256"] != commission.Digest(second) {
		t.Fatal("unexpected use not reported once", used)
	}
	if !exchange(t, s, first).Awaiting {
		t.Fatal("the first phone lost its place")
	}
	if _, r, _ := s.Redeemed(); r != first {
		t.Fatal("the exchange is no longer the first phone's")
	}
	// After the decision the intruder is still refused, and nothing is delivered to it.
	if _, e := s.Approve("profile.signature", "licence.signature", "binding"); e != nil {
		t.Fatal(e)
	}
	if a := exchange(t, s, second); a.Decision.Refusal == nil || a.Decision.Refusal.Reason != "already_used" {
		t.Fatal("intruder got something other than already_used")
	}
	if len(events.all("delivered")) != 0 {
		t.Fatal("a refusal to an intruder counted as delivery")
	}
}

func TestAnExpiredInvitationIsRefused(t *testing.T) {
	clock := clockAt(time.Now().Unix())
	events := &recorder{}
	s := start(t, clock, events)
	red := redeem(t, s.Invitation(), "phone")
	exchange(t, s, red)
	clock.Add(900)
	a := exchange(t, s, red)
	if a.Decision.Refusal == nil || a.Decision.Refusal.Reason != "expired" {
		t.Fatal("expired invitation not refused as expired", a)
	}
	if _, e := s.Approve("profile.signature", "licence.signature", "binding"); e != nil {
		t.Fatal(e)
	}
	// A decision made in the last second is still served to the phone it was made for.
	if a = exchange(t, s, red); a.Decision.Approval == nil {
		t.Fatal("decided exchange not served at expiry")
	}
}

func TestThePhoneRefusesAnotherCertificate(t *testing.T) {
	s := start(t, clockAt(time.Now().Unix()), &recorder{})
	impostor := start(t, clockAt(time.Now().Unix()), &recorder{})
	_, port, _ := net.SplitHostPort(impostor.Address())
	toImpostor := func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "tcp4", "127.0.0.1:"+port)
	}
	if _, e := Exchange(context.Background(), toImpostor, s.Invitation(), redeem(t, s.Invitation(), "phone")); !errors.Is(e, ErrNotTheOffice) {
		t.Fatal("phone accepted a certificate that is not the invitation's office", e)
	}
	if _, r, ok := s.Redeemed(); ok || r != "" {
		t.Fatal("the real office saw a redemption")
	}
	if r, _, ok := impostor.Redeemed(); ok {
		t.Fatal("the impostor got a redemption", r)
	}
}

// raw is a client with no pinning, to reach the listener the way anything on the network can.
func raw(t *testing.T, s *Server, method, path string, body []byte) int {
	t.Helper()
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{DialContext: toLoopback,
		DisableKeepAlives: true,
		TLSClientConfig:   &tls.Config{InsecureSkipVerify: true}}}
	request, _ := http.NewRequest(method, "https://"+s.Address()+path, bytes.NewReader(body))
	response, e := client.Do(request)
	if e != nil {
		t.Fatal(e)
	}
	response.Body.Close()
	return response.StatusCode
}

func TestTheListenerServesOnePurpose(t *testing.T) {
	events := &recorder{}
	s := start(t, clockAt(time.Now().Unix()), events)
	red := []byte(redeem(t, s.Invitation(), "phone"))
	for _, c := range []struct {
		method, path string
		body         []byte
		want         int
	}{
		{"GET", Path, nil, 405},
		{"PUT", Path, red, 405},
		{"GET", "/", nil, 404},
		{"POST", "/", red, 404},
		{"POST", "/commission/v1/redemption/", red, 404},
		{"POST", Path + "?x=1", red, 404},
		{"POST", "/rest/system/status", nil, 404},
		{"POST", Path, bytes.Repeat([]byte("a"), commission.MaximumRedemption+1), 413},
		{"POST", Path, []byte("{}"), 400},
		{"POST", Path, nil, 400},
	} {
		if got := raw(t, s, c.method, c.path, c.body); got != c.want {
			t.Fatalf("%s %s: %d, want %d", c.method, c.path, got, c.want)
		}
	}
	if len(events.events) != 0 {
		t.Fatal("refused requests reached the exchange", events.events)
	}
	if got := raw(t, s, "POST", Path, red); got != 202 {
		t.Fatal("redemption not accepted", got)
	}
	s.requests.Store(MaximumRequests)
	if got := raw(t, s, "POST", Path, red); got != 429 {
		t.Fatal("request past the listener's total answered", got)
	}
}

func TestTheListenerSpeaksOnlyTLS13(t *testing.T) {
	s := start(t, clockAt(time.Now().Unix()), &recorder{})
	conn, e := toLoopback(context.Background(), "tcp4", s.Address())
	if e != nil {
		t.Fatal(e)
	}
	defer conn.Close()
	client := tls.Client(conn, &tls.Config{InsecureSkipVerify: true, MaxVersion: tls.VersionTLS12})
	if client.Handshake() == nil {
		t.Fatal("TLS 1.2 handshake accepted")
	}
}

func TestOnlyAPrivateIPv4AddressIsBound(t *testing.T) {
	now := time.Now().Unix()
	for _, address := range []string{"", "0.0.0.0", "0.0.0.0:0", "127.0.0.1", "8.8.8.8", "169.254.1.1",
		"100.121.34.102", "::1", "[fd00::1]:0", "192.168.1.5:99999", "192.168.1.5:x", "localhost", "192.168.001.5"} {
		_, e := Listen(Config{Invitation: token("invitation"), OrganizationID: "test-organisation", Address: address,
			IssuedAt: now, ExpiresAt: now + 900, Certificate: certificate(t), OfficeKey: officeKey,
			Listen: func(string, string) (net.Listener, error) {
				t.Fatalf("bound %q", address)
				return nil, nil
			}})
		if e == nil {
			t.Fatalf("listened on %q", address)
		}
	}
	for name, cfg := range map[string]Config{
		"not yet live": {IssuedAt: now + 60, ExpiresAt: now + 900},
		"expired":      {IssuedAt: now - 900, ExpiresAt: now},
		"too long":     {IssuedAt: now, ExpiresAt: now + 901},
	} {
		cfg.Invitation, cfg.OrganizationID, cfg.Address = token("invitation"), "test-organisation", officeAddress
		cfg.Certificate, cfg.OfficeKey, cfg.Listen = certificate(t), officeKey, loopback
		if s, e := Listen(cfg); e == nil {
			s.Close()
			t.Fatalf("listened for an invitation that is %s", name)
		}
	}
}

func TestTheListenerHoldsFewConnectionsAtOnce(t *testing.T) {
	s := start(t, clockAt(time.Now().Unix()), &recorder{})
	red := redeem(t, s.Invitation(), "phone")
	var held []net.Conn
	for range MaximumConnections {
		c, e := toLoopback(context.Background(), "tcp4", s.Address())
		if e != nil {
			t.Fatal(e)
		}
		held = append(held, c)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	if _, e := Exchange(ctx, toLoopback, s.Invitation(), red); e == nil {
		t.Fatal("a connection past the cap was served")
	}
	for _, c := range held {
		c.Close()
	}
	if !exchange(t, s, red).Awaiting {
		t.Fatal("listener did not recover when connections closed")
	}
}
