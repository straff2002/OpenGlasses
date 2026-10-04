package checkin

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"testing"

	"avenkin.dev/mobilecore/officepreview"
	"github.com/syncthing/syncthing/lib/protocol"
)

// One renewal and one removal against the real key holder: an office with its own keys and
// generation record on disk, under a profile a test vendor key signed.
func TestARealOfficeRenewsForItsPhonesCheckInAndNeverAfterRemoval(t *testing.T) {
	root := t.TempDir()
	office := must(officepreview.OpenOffice(root))
	administratorPublic := must(officepreview.AdministratorPublicKey(root, true))
	vendorPublic, vendor, _ := ed25519.GenerateKey(rand.Reader)
	profilePayload := must(json.Marshal(map[string]any{
		"format": "openglasses.org-profile", "schemaVersion": 2, "keyId": "test-vendor", "profileId": "profile-1",
		"policyExpiry":    "2027-06-01T00:00:00Z",
		"officeAuthority": map[string]string{"organizationID": "org-1", "administratorPublicKey": administratorPublic, "transportPolicy": "privateLan"},
	}))
	profile := base64.StdEncoding.EncodeToString(profilePayload) + "." +
		base64.StdEncoding.EncodeToString(ed25519.Sign(vendor, append([]byte("openglasses.org-profile.v1\n"), profilePayload...)))
	authority := office.AuthorityWithVendorKeys(map[string]string{"test-vendor": base64.StdEncoding.EncodeToString(vendorPublic)})
	phonePublic, phone, _ := ed25519.GenerateKey(rand.Reader)
	officePublic := office.Key.Public().(ed25519.PublicKey)
	const now = int64(1790000000)
	random := func(n int) []byte { b := make([]byte, n); _, _ = rand.Read(b); return b }

	binding := must(authority.IssuePeerBinding(profile, "enrolment-1", protocol.NewDeviceID([]byte("office")).String(),
		protocol.NewDeviceID([]byte("phone")).String(), base64.StdEncoding.EncodeToString(phonePublic), now))
	administrator := must(authority.Administrator(profile, now))
	held, digest, e := ReadBinding(binding, administrator.PublicKey)
	if e != nil {
		t.Fatal(e)
	}
	challengePayload := must(json.Marshal(Challenge{1, ChallengeKind, hex.EncodeToString(random(16)), base64.RawURLEncoding.EncodeToString(random(32)),
		held.OrganizationID, held.EnrolmentID, held.OfficeID, held.PhoneTransportID, held.Generation, digest, now + 86400, now + 2*86400}))
	challenge := must(SignChallengePayload(challengePayload, office.Key, now+86400))
	read := must(ReadChallenge(challenge, officePublic))
	waiting := CheckInFor(challenge, read, base64.RawURLEncoding.EncodeToString(random(32)), now+20*86400, "1.2.3", "45", now+86460)
	checkIn := must(SignCheckIn(waiting, phone))

	// On request alone — the right envelopes but no check-in the phone signed — nothing is issued.
	_, stranger, _ := ed25519.GenerateKey(rand.Reader)
	if _, _, e = Renew(authority, office.Key, profile, challenge, must(SignCheckIn(waiting, stranger)), binding, now+86500); e == nil {
		t.Fatal("renewed for a check-in the phone did not sign")
	}
	renewed, result, e := Renew(authority, office.Key, profile, challenge, checkIn, binding, now+86500)
	if e != nil {
		t.Fatal(e)
	}
	_, next, _, e := ReadResult(result, administrator.PublicKey, checkIn, waiting, held, now+86500)
	if e != nil || next.Generation != held.Generation+1 || next.ExpiresAt != now+86500+30*86400 {
		t.Fatal("the phone does not accept the renewal", e)
	}
	// The same request again: the same binding. The used check-in against the new binding: nothing.
	if again, _, e := Renew(authority, office.Key, profile, challenge, checkIn, binding, now+86600); e != nil || again != renewed {
		t.Fatal("a repeated request did not return the binding already issued", e)
	}
	if _, _, e = Renew(authority, office.Key, profile, challenge, checkIn, renewed, now+86600); e == nil {
		t.Fatal("a replayed check-in renewed the renewed binding")
	}

	// Removal: signed as sent, the enrolment marked first, and nothing issued for it again.
	raw := must(json.Marshal(Removal{1, RemovalKind, hex.EncodeToString(random(16)), "org-1", "profile-1", "enrolment-1",
		held.OfficeID, held.PhoneTransportID, ReasonRevoked, now + 90000}))
	removal := must(Remove(authority, officePublic, profile, raw, now+90000))
	if _, e = ReadRemoval(removal, administrator.PublicKey, "org-1", "profile-1", "enrolment-1", held.PhoneTransportID); e != nil {
		t.Fatal(e)
	}
	if again := must(Remove(authority, officePublic, profile, raw, now+90100)); again != removal {
		t.Fatal("asking again did not sign the same bytes")
	}
	second := must(json.Marshal(Challenge{1, ChallengeKind, hex.EncodeToString(random(16)), base64.RawURLEncoding.EncodeToString(random(32)),
		next.OrganizationID, next.EnrolmentID, next.OfficeID, next.PhoneTransportID, next.Generation, hexSHA256(payloadOf(t, renewed)), now + 90000, now + 2*90000}))
	secondChallenge := must(SignChallengePayload(second, office.Key, now+90000))
	secondCheckIn := must(SignCheckIn(CheckInFor(secondChallenge, must(ReadChallenge(secondChallenge, officePublic)),
		base64.RawURLEncoding.EncodeToString(random(32)), now+20*86400, "1.2.3", "45", now+90010), phone))
	if _, _, e = Renew(authority, office.Key, profile, secondChallenge, secondCheckIn, renewed, now+90020); e == nil {
		t.Fatal("a removed device's check-in was renewed")
	}
	other := must(json.Marshal(Removal{1, RemovalKind, hex.EncodeToString(random(16)), "org-1", "profile-1", "never-paired",
		held.OfficeID, held.PhoneTransportID, ReasonRemoved, now + 90000}))
	if _, e = Remove(authority, officePublic, profile, other, now+90000); e == nil {
		t.Fatal("a removal was signed for an enrolment this office never bound")
	}
}

func payloadOf(t *testing.T, envelopeText string) []byte {
	t.Helper()
	var e envelope
	if json.Unmarshal([]byte(envelopeText), &e) != nil {
		t.Fatal("envelope")
	}
	return must(base64.StdEncoding.DecodeString(e.Payload))
}
