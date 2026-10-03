package commission

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"

	"github.com/syncthing/syncthing/lib/protocol"
)

// FixtureNow is the clock every commissioning fixture is made at.
const FixtureNow = int64(1800000000)

func fixtureKey(label string) ed25519.PrivateKey {
	seed := sha256.Sum256([]byte(label))
	return ed25519.NewKeyFromSeed(seed[:])
}

// Fixtures returns the public golden fixtures of the commissioning contract, by file name.
// Every key is derived from a public label and has no authority; the three artefacts inside the
// approval are fictional text, because this contract carries them without reading them.
func Fixtures() (map[string][]byte, error) {
	office := fixtureKey("Avenkin public fixture office key v1")
	phone := fixtureKey("Avenkin public fixture phone key v1")
	officePublic := office.Public().(ed25519.PublicKey)
	officeTransport := protocol.NewDeviceID([]byte("fixture-office-transport")).String()
	phoneTransport := protocol.NewDeviceID([]byte("fixture-phone-transport")).String()
	secret := sha256.Sum256([]byte("Avenkin public fixture commission invitation v1"))
	b64 := base64.StdEncoding.EncodeToString

	invitation, e := SignInvitation(Invitation{1, InvitationKind, base64.RawURLEncoding.EncodeToString(secret[:]),
		"fixture-organisation", OfficeID(officePublic), b64(officePublic), officeTransport, "192.168.1.24:22443",
		FixtureNow, FixtureNow + MaximumLifetime}, office)
	if e != nil {
		return nil, e
	}
	redemption, e := SignRedemption(Redemption{1, RedemptionKind, Digest(invitation), base64.RawURLEncoding.EncodeToString(secret[:]),
		"fixture-enrolment", phoneTransport, b64(phone.Public().(ed25519.PublicKey)), "1.0.0", "100", "", FixtureNow + 30}, phone)
	if e != nil {
		return nil, e
	}
	approval, e := SignApproval(Approval{1, ApprovalKind, Digest(invitation), Digest(redemption), "fixture-enrolment", phoneTransport,
		b64(phone.Public().(ed25519.PublicKey)), "FICTIONAL-PROFILE.FICTIONAL-SIGNATURE", "FICTIONAL-LICENCE.FICTIONAL-SIGNATURE",
		`{"payload":"RklDVElPTkFMLUJJTkRJTkc=","signature":"RklDVElPTkFM"}`, FixtureNow + 60}, office)
	if e != nil {
		return nil, e
	}
	refusal, e := SignRefusal(Refusal{1, RefusalKind, Digest(invitation), Digest(redemption), "refused_by_person", FixtureNow + 60}, office)
	if e != nil {
		return nil, e
	}
	comparison, e := Comparison(Digest(invitation), Digest(redemption))
	if e != nil {
		return nil, e
	}
	keys, e := json.MarshalIndent(map[string]any{
		"note":                 "Fictional keys derived from public labels: seed = SHA-256(label). They have no authority.",
		"now":                  FixtureNow,
		"officeKeyLabel":       "Avenkin public fixture office key v1",
		"officeApplicationKey": b64(officePublic),
		"phoneKeyLabel":        "Avenkin public fixture phone key v1",
		"phoneApplicationKey":  b64(phone.Public().(ed25519.PublicKey)),
		"invitationSHA256":     Digest(invitation),
		"redemptionSHA256":     Digest(redemption),
	}, "", "  ")
	if e != nil {
		return nil, e
	}
	return map[string][]byte{
		"commission-invitation-v1.json": []byte(invitation),
		"commission-qr-v1.txt":          []byte(QRText(invitation)),
		"commission-redemption-v1.json": []byte(redemption),
		"commission-approval-v1.json":   []byte(approval),
		"commission-refusal-v1.json":    []byte(refusal),
		"commission-comparison-v1.txt":  []byte(comparison),
		"commission-fixture-keys.json":  append(keys, '\n'),
	}, nil
}
