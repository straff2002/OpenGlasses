package mobilecore

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net"
	"sync"
	"testing"
	"time"

	"avenkin.dev/mobilecore/commission"
	"avenkin.dev/mobilecore/commission/bootstrap"

	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/tlsutil"
)

// The office listens on loopback while its invitation names a private address; the phone's
// dial goes to loopback on the same port. Everything else is the real path.
func commissionOffice(t *testing.T, now int64, events func(map[string]any)) *bootstrap.Server {
	t.Helper()
	certificate, e := tlsutil.NewCertificateInMemory("syncthing", 2)
	if e != nil {
		t.Fatal(e)
	}
	seed := sha256.Sum256([]byte("bridge test office"))
	secret := sha256.Sum256([]byte("bridge test invitation"))
	s, e := bootstrap.Listen(bootstrap.Config{Invitation: base64.RawURLEncoding.EncodeToString(secret[:]),
		OrganizationID: "test-organisation", Address: "10.20.30.40", IssuedAt: now, ExpiresAt: now + 900,
		Certificate: certificate, OfficeKey: ed25519.NewKeyFromSeed(seed[:]), Notify: events,
		Listen: func(string, string) (net.Listener, error) { return net.Listen("tcp4", "127.0.0.1:0") }})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func dialPort(port string) bootstrap.Dial {
	return func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "tcp4", "127.0.0.1:"+port)
	}
}

func useOffice(t *testing.T, s *bootstrap.Server) {
	_, port, _ := net.SplitHostPort(s.Address())
	commissionDial = dialPort(port)
	t.Cleanup(func() { commissionDial = nil })
}

// decoded reads a bridge function's JSON result, failing the test on its error.
func decoded(t *testing.T) func(string, error) map[string]any {
	return func(raw string, e error) map[string]any {
		t.Helper()
		if e != nil {
			t.Fatal(e)
		}
		out := map[string]any{}
		if e = json.Unmarshal([]byte(raw), &out); e != nil {
			t.Fatal(e)
		}
		return out
	}
}

// redeemAsThePhone does what the app does: read the code, make the signing input, sign it with
// a key the bridge never sees, seal it.
func redeemAsThePhone(t *testing.T, qr string, now int64, phoneTransportID string, key ed25519.PrivateKey) (string, string) {
	t.Helper()
	read := decoded(t)(CommissionReadQR(qr, now))
	invitation := read["invitationEnvelope"].(string)
	publicKey := base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
	unsigned := decoded(t)(CommissionRedemptionSigningInput(invitation, "enrolment-7", phoneTransportID, publicKey, "2.4.0", "412", "", now))
	input, e := base64.StdEncoding.DecodeString(unsigned["signingInput"].(string))
	if e != nil {
		t.Fatal(e)
	}
	signature := base64.StdEncoding.EncodeToString(ed25519.Sign(key, input))
	redemption, e := CommissionSealRedemption(invitation, unsigned["payload"].(string), signature)
	if e != nil {
		t.Fatal(e)
	}
	return invitation, redemption
}

type eventLog struct {
	mu     sync.Mutex
	events []map[string]any
}

func (l *eventLog) add(e map[string]any) { l.mu.Lock(); l.events = append(l.events, e); l.mu.Unlock() }
func (l *eventLog) find(kind string) map[string]any {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, e := range l.events {
		if e["event"] == kind {
			return e
		}
	}
	return nil
}

func TestThePhoneCommissionsOverThePinnedBootstrapConnection(t *testing.T) {
	now := time.Now().Unix()
	log := &eventLog{}
	office := commissionOffice(t, now, log.add)
	useOffice(t, office)
	phone, e := NewClient(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	seed := sha256.Sum256([]byte("bridge test phone"))
	key := ed25519.NewKeyFromSeed(seed[:])

	read := decoded(t)(CommissionReadQR(office.QRText(), now))
	if read["address"] != office.Address() || read["officeTransportID"] != office.OfficeTransportID() ||
		read["invitationSHA256"] != office.InvitationSHA256() || read["organizationID"] != "test-organisation" ||
		read["expiresAt"] != float64(now+900) {
		t.Fatal("scanned invitation is not the office's", read)
	}
	if _, e = CommissionReadQR(office.QRText(), now+900); e == nil {
		t.Fatal("read an expired code")
	}
	if _, e = CommissionReadQR("https://example.com/", now); e == nil {
		t.Fatal("read a code that is not an invitation")
	}

	invitation, redemption := redeemAsThePhone(t, office.QRText(), now, phone.DeviceID(), key)
	signed, e := commission.SignRedemption(commission.Redemption{Version: 1, Kind: commission.RedemptionKind,
		InvitationSHA256: commission.Digest(invitation), Invitation: must(bootstrap.Invitation(invitation)).Invitation,
		EnrolmentID: "enrolment-7", PhoneTransportID: phone.DeviceID(),
		PhoneApplicationKey: base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey)),
		AppVersion:          "2.4.0", AppBuild: "412", CreatedAt: now}, key)
	if e != nil || signed != redemption {
		t.Fatal("the redemption signed outside the bridge differs from SignRedemption's", e)
	}
	if _, e = CommissionSealRedemption(invitation, base64.StdEncoding.EncodeToString([]byte("{}")),
		base64.StdEncoding.EncodeToString(make([]byte, 64))); e == nil {
		t.Fatal("sealed a redemption that does not verify")
	}

	for range 2 {
		if got := decoded(t)(CommissionExchange(invitation, redemption)); got["status"] != "awaiting" {
			t.Fatal("not awaiting", got)
		}
	}
	comparison, e := CommissionComparison(invitation, redemption)
	if e != nil || log.find("redemption")["comparison"] != comparison {
		t.Fatal("the two screens show different codes", comparison, log.find("redemption"))
	}
	approval, e := office.Approve("profile.signature", "licence.signature", `{"payload":"e30=","signature":"AA=="}`)
	if e != nil {
		t.Fatal(e)
	}
	got := decoded(t)(CommissionExchange(invitation, redemption))
	if got["status"] != "approved" || got["enrolmentID"] != "enrolment-7" || got["profileDocument"] != "profile.signature" ||
		got["licenceCode"] != "licence.signature" || got["peerBinding"] != `{"payload":"e30=","signature":"AA=="}` ||
		got["decisionEnvelope"] != approval {
		t.Fatal("approval not returned", got)
	}
	if log.find("delivered") == nil {
		t.Fatal("office did not see the delivery")
	}
}

func TestThePhoneReadsARefusalAndRefusesAnImpostor(t *testing.T) {
	now := time.Now().Unix()
	office := commissionOffice(t, now, nil)
	impostor := commissionOffice(t, now, nil)
	seed := sha256.Sum256([]byte("bridge test phone"))
	key := ed25519.NewKeyFromSeed(seed[:])
	invitation, redemption := redeemAsThePhone(t, office.QRText(), now, protocol.NewDeviceID([]byte("phone")).String(), key)

	_, port, _ := net.SplitHostPort(impostor.Address())
	commissionDial = dialPort(port)
	t.Cleanup(func() { commissionDial = nil })
	if _, e := CommissionExchange(invitation, redemption); e == nil {
		t.Fatal("exchanged with a listener that is not the invitation's office")
	}
	if _, _, redeemed := impostor.Redeemed(); redeemed {
		t.Fatal("the impostor received the redemption")
	}

	useOffice(t, office)
	if got := decoded(t)(CommissionExchange(invitation, redemption)); got["status"] != "awaiting" {
		t.Fatal(got)
	}
	if _, e := office.Refuse("refused_by_person"); e != nil {
		t.Fatal(e)
	}
	got := decoded(t)(CommissionExchange(invitation, redemption))
	if got["status"] != "refused" || got["reason"] != "refused_by_person" {
		t.Fatal("refusal not returned", got)
	}
	// A redemption for another invitation is never sent.
	_, other := redeemAsThePhone(t, impostor.QRText(), now, protocol.NewDeviceID([]byte("phone")).String(), key)
	if _, e := CommissionExchange(invitation, other); e == nil {
		t.Fatal("sent a redemption of another invitation")
	}
}

func must[T any](v T, e error) T {
	if e != nil {
		panic(e)
	}
	return v
}
