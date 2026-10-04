package checkin

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"

	"avenkin.dev/mobilecore/officepreview"
	"github.com/syncthing/syncthing/lib/protocol"
)

// FixtureNow is the clock every check-in fixture is made at.
const FixtureNow = int64(1800000000)

func fixtureKey(label string) ed25519.PrivateKey {
	seed := sha256.Sum256([]byte(label))
	return ed25519.NewKeyFromSeed(seed[:])
}

func fixtureBinding(b officepreview.PeerBinding, administrator ed25519.PrivateKey) (string, error) {
	return sign(BindingDomain, b, administrator, maximumBinding)
}

// Fixtures returns the public golden fixtures of the check-in contract, by file name: one
// renewal (binding, challenge, check-in, result carrying the next generation) and one removal
// with its receipt. Every key is derived from a public label and has no authority; the office
// and phone keys are the commissioning fixtures' own.
func Fixtures() (map[string][]byte, error) {
	office := fixtureKey("Avenkin public fixture office key v1")
	phone := fixtureKey("Avenkin public fixture phone key v1")
	administrator := fixtureKey("Avenkin public fixture administrator key v1")
	officePublic := office.Public().(ed25519.PublicKey)
	phonePublic := phone.Public().(ed25519.PublicKey)
	b64 := base64.StdEncoding.EncodeToString
	label := func(s string) []byte { sum := sha256.Sum256([]byte(s)); return sum[:] }
	officeTransport := protocol.NewDeviceID([]byte("fixture-office-transport")).String()
	phoneTransport := protocol.NewDeviceID([]byte("fixture-phone-transport")).String()

	held := officepreview.PeerBinding{Version: 1, Kind: bindingKind, OrganizationID: "fixture-organisation", ProfileID: "fixture-profile",
		EnrolmentID: "fixture-enrolment", OfficeID: OfficeID(officePublic), Generation: 1, OfficeTransportID: officeTransport,
		OfficeApplicationKey: b64(officePublic), PhoneTransportID: phoneTransport, PhoneApplicationKey: b64(phonePublic),
		IssuedAt: FixtureNow - 2*86400, ExpiresAt: FixtureNow + 28*86400}
	binding, e := fixtureBinding(held, administrator)
	if e != nil {
		return nil, e
	}
	_, bindingDigest, e := ReadBinding(binding, administrator.Public().(ed25519.PublicKey))
	if e != nil {
		return nil, e
	}
	challenge, e := SignChallenge(Challenge{1, ChallengeKind, hex.EncodeToString(label("Avenkin public fixture check-in challenge v1")[:16]),
		base64.RawURLEncoding.EncodeToString(label("Avenkin public fixture office nonce v1")), held.OrganizationID, held.EnrolmentID,
		held.OfficeID, held.PhoneTransportID, held.Generation, bindingDigest, FixtureNow, FixtureNow + MaximumChallengeLifetime}, office)
	if e != nil {
		return nil, e
	}
	read, e := ReadChallenge(challenge, officePublic)
	if e != nil {
		return nil, e
	}
	checkIn, e := SignCheckIn(CheckInFor(challenge, read, base64.RawURLEncoding.EncodeToString(label("Avenkin public fixture phone nonce v1")),
		FixtureNow+26*86400, "1.0.0", "100", FixtureNow+60), phone)
	if e != nil {
		return nil, e
	}
	next := held
	next.Generation, next.IssuedAt, next.ExpiresAt = 2, FixtureNow+120, FixtureNow+120+30*86400
	renewed, e := fixtureBinding(next, administrator)
	if e != nil {
		return nil, e
	}
	exchange, e := Renewable(challenge, checkIn, binding, officePublic, administrator.Public().(ed25519.PublicKey), FixtureNow+120)
	if e != nil {
		return nil, e
	}
	result, e := SignResult(ResultFor(exchange, checkIn, renewed, FixtureNow+120), administrator)
	if e != nil {
		return nil, e
	}
	removalPayload := Removal{1, RemovalKind, hex.EncodeToString(label("Avenkin public fixture removal v1")[:16]), held.OrganizationID,
		held.ProfileID, held.EnrolmentID, held.OfficeID, held.PhoneTransportID, ReasonRemoved, FixtureNow + 86400}
	removal, e := SignRemoval(removalPayload, administrator)
	if e != nil {
		return nil, e
	}
	receipt, e := SignRemovalReceipt(RemovalReceiptFor(removal, removalPayload, FixtureNow+86460), phone)
	if e != nil {
		return nil, e
	}
	keys, e := json.MarshalIndent(map[string]any{
		"note":                   "Fictional keys derived from public labels: seed = SHA-256(label). They have no authority.",
		"now":                    FixtureNow,
		"officeKeyLabel":         "Avenkin public fixture office key v1",
		"officeApplicationKey":   b64(officePublic),
		"phoneKeyLabel":          "Avenkin public fixture phone key v1",
		"phoneApplicationKey":    b64(phonePublic),
		"administratorKeyLabel":  "Avenkin public fixture administrator key v1",
		"administratorPublicKey": b64(administrator.Public().(ed25519.PublicKey)),
		"bindingSHA256":          bindingDigest,
		"challengeSHA256":        Digest(challenge),
		"checkInSHA256":          Digest(checkIn),
		"removalSHA256":          Digest(removal),
	}, "", "  ")
	if e != nil {
		return nil, e
	}
	return map[string][]byte{
		"office-check-in-binding-v1.json":   []byte(binding),
		"office-check-in-challenge-v1.json": []byte(challenge),
		"office-check-in-v1.json":           []byte(checkIn),
		"office-check-in-result-v1.json":    []byte(result),
		"office-removal-v1.json":            []byte(removal),
		"office-removal-receipt-v1.json":    []byte(receipt),
		"office-check-in-fixture-keys.json": append(keys, '\n'),
	}, nil
}
