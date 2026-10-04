package checkin

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"avenkin.dev/mobilecore/officepreview"
)

func must[T any](v T, e error) T {
	if e != nil {
		panic(e)
	}
	return v
}

type world struct {
	office, phone, administrator        ed25519.PrivateKey
	officePublic, phonePublic, adminPub ed25519.PublicKey
	binding, challenge, checkIn, result string
	removal, receipt                    string
	held                                officepreview.PeerBinding
	bindingDigest                       string
}

func fixtureWorld(t *testing.T) world {
	t.Helper()
	made := must(Fixtures())
	w := world{office: fixtureKey("Avenkin public fixture office key v1"), phone: fixtureKey("Avenkin public fixture phone key v1"),
		administrator: fixtureKey("Avenkin public fixture administrator key v1"),
		binding:       string(made["office-check-in-binding-v1.json"]), challenge: string(made["office-check-in-challenge-v1.json"]),
		checkIn: string(made["office-check-in-v1.json"]), result: string(made["office-check-in-result-v1.json"]),
		removal: string(made["office-removal-v1.json"]), receipt: string(made["office-removal-receipt-v1.json"])}
	w.officePublic, w.phonePublic, w.adminPub = w.office.Public().(ed25519.PublicKey), w.phone.Public().(ed25519.PublicKey), w.administrator.Public().(ed25519.PublicKey)
	w.held, w.bindingDigest = mustBinding(t, w.binding, w.adminPub)
	return w
}

func mustBinding(t *testing.T, text string, key ed25519.PublicKey) (officepreview.PeerBinding, string) {
	t.Helper()
	b, digest, e := ReadBinding(text, key)
	if e != nil {
		t.Fatal(e)
	}
	return b, digest
}

func refused(t *testing.T, name string, e error, want error) {
	t.Helper()
	if e == nil || (want != nil && !errors.Is(e, want)) {
		t.Fatalf("%s: got %v, want %v", name, e, want)
	}
}

// The checked-in fixtures are exactly what Fixtures makes, and read back as one renewal and one
// removal. Run with CHECKIN_WRITE_FIXTURES=1 to write them.
func TestTheGoldenFixturesAreCurrentAndReadBack(t *testing.T) {
	made := must(Fixtures())
	root := filepath.Join("..", "..", "..", "Contracts", "fixtures")
	for name, want := range made {
		path := filepath.Join(root, name)
		if os.Getenv("CHECKIN_WRITE_FIXTURES") == "1" {
			if e := os.WriteFile(path, want, 0644); e != nil {
				t.Fatal(e)
			}
		}
		got, e := os.ReadFile(path)
		if e != nil {
			t.Fatalf("%s: %v", name, e)
		}
		if string(got) != string(want) {
			t.Fatalf("%s is not what Fixtures makes; regenerate with CHECKIN_WRITE_FIXTURES=1", name)
		}
	}
	w := fixtureWorld(t)
	now := FixtureNow + 120
	x := must(Renewable(w.challenge, w.checkIn, w.binding, w.officePublic, w.adminPub, now))
	if x.Binding.Generation != 1 || x.CheckIn.AppVersion != "1.0.0" {
		t.Fatal("the exchange did not read back")
	}
	result, next, _, e := ReadResult(w.result, w.adminPub, w.checkIn, x.CheckIn, w.held, now)
	if e != nil || result.Outcome != OutcomeRenewed || next.Generation != 2 || next.ExpiresAt-next.IssuedAt != 30*86400 {
		t.Fatal("the result did not read back as a renewal", e)
	}
	removal := must(ReadRemoval(w.removal, w.adminPub, "fixture-organisation", "fixture-profile", "fixture-enrolment", w.held.PhoneTransportID))
	if removal.Reason != ReasonRemoved {
		t.Fatal("removal reason")
	}
	must(ReadRemovalReceipt(w.receipt, w.phonePublic, w.removal, removal))
}

func TestAChallengeIsSignedOnlyForItsOwnOfficeAndWhileLive(t *testing.T) {
	w := fixtureWorld(t)
	c := must(ReadChallenge(w.challenge, w.officePublic))
	raw := must(json.Marshal(c))
	sealed := must(SignChallengePayload(raw, w.office, FixtureNow))
	if sealed != w.challenge {
		t.Fatal("signing the exact payload does not give the fixture")
	}
	other := fixtureKey("another office")
	_, e := SignChallengePayload(raw, other, FixtureNow)
	refused(t, "another office's key", e, ErrOther)
	_, e = SignChallengePayload(raw, w.office, c.ExpiresAt)
	refused(t, "expired", e, ErrTime)
	_, e = SignChallengePayload(raw, w.office, c.IssuedAt-MaximumIssueSkew-1)
	refused(t, "issued too far ahead", e, ErrTime)
	long := c
	long.ExpiresAt = c.IssuedAt + MaximumChallengeLifetime + 1
	_, e = SignChallengePayload(must(json.Marshal(long)), w.office, FixtureNow)
	refused(t, "longer than seven days", e, ErrFields)
	_, e = SignChallengePayload([]byte(strings.Replace(string(raw), `"version":1,`, `"version":1,"extra":1,`, 1)), w.office, FixtureNow)
	refused(t, "an extra field", e, ErrMalformed)
	_, e = SignChallengePayload([]byte(strings.Replace(string(raw), `"generation":1`, `"generation":1.0`, 1)), w.office, FixtureNow)
	refused(t, "a fractional number", e, ErrMalformed)
	_, e = ReadChallenge(w.challenge, other.Public().(ed25519.PublicKey))
	refused(t, "read under another key", e, ErrSignature)
}

func TestOnlyACheckInForALiveChallengeUnderTheSameBindingIsRenewable(t *testing.T) {
	w := fixtureWorld(t)
	now := FixtureNow + 120
	challenge := must(ReadChallenge(w.challenge, w.officePublic))
	checkIn := must(ReadCheckIn(w.checkIn, w.phonePublic))
	renewable := func(challengeEnvelope, checkInEnvelope, binding string, at int64) error {
		_, e := Renewable(challengeEnvelope, checkInEnvelope, binding, w.officePublic, w.adminPub, at)
		return e
	}
	if e := renewable(w.challenge, w.checkIn, w.binding, now); e != nil {
		t.Fatal(e)
	}
	refused(t, "expired challenge", renewable(w.challenge, w.checkIn, w.binding, challenge.ExpiresAt), ErrTime)
	refused(t, "before the challenge", renewable(w.challenge, w.checkIn, w.binding, challenge.IssuedAt-1), ErrTime)

	// A check-in signed by another key, or for another challenge.
	stranger := fixtureKey("a stranger")
	refused(t, "another key", renewable(w.challenge, must(SignCheckIn(checkIn, stranger)), w.binding, now), ErrSignature)
	second := challenge
	second.ChallengeID = strings.Repeat("ab", 16)
	secondEnvelope := must(SignChallenge(second, w.office))
	refused(t, "a check-in for another challenge", renewable(secondEnvelope, w.checkIn, w.binding, now), ErrOther)
	stale := checkIn
	stale.ChallengeSHA256 = strings.Repeat("0", 64)
	refused(t, "another challenge digest", renewable(w.challenge, must(SignCheckIn(stale, w.phone)), w.binding, now), ErrOther)

	// An older generation, or another binding digest: the challenge no longer names the binding.
	newer := w.held
	newer.Generation = 2
	newerBinding := must(fixtureBinding(newer, w.administrator))
	refused(t, "a challenge set under an older generation", renewable(w.challenge, w.checkIn, newerBinding, now), ErrOther)
	otherGeneration := checkIn
	otherGeneration.Generation = 2
	refused(t, "a check-in naming another generation", renewable(w.challenge, must(SignCheckIn(otherGeneration, w.phone)), w.binding, now), ErrOther)

	// A binding signed by someone else, or naming another office key.
	refused(t, "a binding not the administrator's", renewable(w.challenge, w.checkIn, must(fixtureBinding(w.held, stranger)), now), ErrSignature)
	foreign := w.held
	foreign.OfficeApplicationKey = base64.StdEncoding.EncodeToString(stranger.Public().(ed25519.PublicKey))
	refused(t, "a binding for another office key", renewable(w.challenge, w.checkIn, must(fixtureBinding(foreign, w.administrator)), now), ErrOther)

	// A binding that has run out is not renewed, even with a challenge still live.
	lapsed := w.held
	lapsed.IssuedAt, lapsed.ExpiresAt = FixtureNow-31*86400, FixtureNow-86400
	lapsedBinding := must(fixtureBinding(lapsed, w.administrator))
	_, lapsedDigest := mustBinding(t, lapsedBinding, w.adminPub)
	late := challenge
	late.BindingSHA256 = lapsedDigest
	lateEnvelope := must(SignChallenge(late, w.office))
	lateCheckIn := must(SignCheckIn(CheckInFor(lateEnvelope, late, checkIn.Nonce, checkIn.LeaseRenewBy, "1.0.0", "100", now), w.phone))
	refused(t, "a lapsed binding", renewable(lateEnvelope, lateCheckIn, lapsedBinding, now), ErrTime)

	// Each message under another message's domain.
	payload := must(CheckInPayload(checkIn))
	wrongDomain := must(seal(payload, ed25519.Sign(w.phone, SigningInput(RemovalReceiptDomain, payload)), MaximumMessage))
	refused(t, "a check-in signed under another domain", renewable(w.challenge, wrongDomain, w.binding, now), ErrSignature)
}

func TestTheTwoStepCheckInIsTheOneStepCheckIn(t *testing.T) {
	w := fixtureWorld(t)
	checkIn := must(ReadCheckIn(w.checkIn, w.phonePublic))
	payload := must(CheckInPayload(checkIn))
	sealed := must(SealCheckIn(payload, ed25519.Sign(w.phone, SigningInput(CheckInDomain, payload))))
	if sealed != w.checkIn {
		t.Fatal("the two-step check-in differs from the fixture")
	}
	_, e := SealCheckIn([]byte(`{"version":1}`), make([]byte, 64))
	refused(t, "sealing something else", e, ErrMalformed)
}

func TestAPhoneAcceptsOnlyTheResultForItsOwnCheckInAndARealRenewal(t *testing.T) {
	w := fixtureWorld(t)
	now := FixtureNow + 120
	waiting := must(ReadCheckIn(w.checkIn, w.phonePublic))
	read := func(result, checkInEnvelope string, held officepreview.PeerBinding, at int64) error {
		_, _, _, e := ReadResult(result, w.adminPub, checkInEnvelope, waiting, held, at)
		return e
	}
	if e := read(w.result, w.checkIn, w.held, now); e != nil {
		t.Fatal(e)
	}
	x := must(Renewable(w.challenge, w.checkIn, w.binding, w.officePublic, w.adminPub, now))
	next := w.held
	next.Generation, next.IssuedAt, next.ExpiresAt = 2, now, now+30*86400
	resultWith := func(b officepreview.PeerBinding, key ed25519.PrivateKey) string {
		return must(SignResult(ResultFor(x, w.checkIn, must(fixtureBinding(b, w.administrator)), now), key))
	}

	refused(t, "signed by the office application key", read(resultWith(next, w.office), w.checkIn, w.held, now), ErrSignature)
	otherCheckIn := waiting
	otherCheckIn.Nonce = base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	refused(t, "a result for another check-in", read(w.result, must(SignCheckIn(otherCheckIn, w.phone)), w.held, now), ErrOther)
	otherPhone := w.held
	otherPhone.EnrolmentID = "another-enrolment"
	refused(t, "a result for another enrolment", read(w.result, w.checkIn, otherPhone, now), ErrOther)

	same := next
	same.Generation = 1
	refused(t, "the generation repeated", read(resultWith(same, w.administrator), w.checkIn, w.held, now), ErrBinding)
	changed := next
	changed.OfficeTransportID = w.held.PhoneTransportID
	refused(t, "an identity changed", read(resultWith(changed, w.administrator), w.checkIn, w.held, now), ErrBinding)
	swapped := next
	swapped.PhoneApplicationKey = w.held.OfficeApplicationKey
	refused(t, "the phone key changed", read(resultWith(swapped, w.administrator), w.checkIn, w.held, now), ErrBinding)
	long := next
	long.ExpiresAt = now + 31*86400
	refused(t, "a binding longer than thirty days", read(resultWith(long, w.administrator), w.checkIn, w.held, now), ErrFields)
	refused(t, "a renewed binding not yet valid", read(w.result, w.checkIn, w.held, now-1), ErrTime)
	refused(t, "a renewed binding that has run out", read(w.result, w.checkIn, w.held, now+30*86400), ErrTime)

	// A phone already on the renewed generation takes the same result as no renewal at all.
	held2, _ := mustBinding(t, must(fixtureBinding(next, w.administrator)), w.adminPub)
	refused(t, "taken in again after it was applied", read(w.result, w.checkIn, held2, now), ErrBinding)

	// A binding signed by another key inside an administrator-signed result.
	forged := must(SignResult(ResultFor(x, w.checkIn, must(fixtureBinding(next, w.office)), now), w.administrator))
	refused(t, "a binding the administrator did not sign", read(forged, w.checkIn, w.held, now), ErrSignature)
}

func TestARemovalIsTheAdministratorsAndForThisPhoneOnly(t *testing.T) {
	w := fixtureWorld(t)
	read := func(text, organisation, profile, enrolment string) error {
		_, e := ReadRemoval(text, w.adminPub, organisation, profile, enrolment, w.held.PhoneTransportID)
		return e
	}
	if e := read(w.removal, "fixture-organisation", "fixture-profile", "fixture-enrolment"); e != nil {
		t.Fatal(e)
	}
	refused(t, "another enrolment", read(w.removal, "fixture-organisation", "fixture-profile", "another"), ErrOther)
	refused(t, "another profile", read(w.removal, "fixture-organisation", "another", "fixture-enrolment"), ErrOther)
	sent := must(ReadRemoval(w.removal, w.adminPub, "fixture-organisation", "fixture-profile", "fixture-enrolment", w.held.PhoneTransportID))
	refused(t, "signed by the office application key", read(must(SignRemoval(sent, w.office)), "fixture-organisation", "fixture-profile", "fixture-enrolment"), ErrSignature)
	odd := sent
	odd.Reason = "expired"
	_, e := SignRemoval(odd, w.administrator)
	refused(t, "an unknown reason", e, ErrFields)

	receipt := must(ReadRemovalReceipt(w.receipt, w.phonePublic, w.removal, sent))
	other := sent
	other.RemovalID = strings.Repeat("cd", 16)
	_, e = ReadRemovalReceipt(w.receipt, w.phonePublic, must(SignRemoval(other, w.administrator)), other)
	refused(t, "a receipt for another removal", e, ErrOther)
	_, e = ReadRemovalReceipt(w.receipt, w.officePublic, w.removal, sent)
	refused(t, "a receipt under another key", e, ErrSignature)
	payload := must(RemovalReceiptPayload(receipt))
	if must(SealRemovalReceipt(payload, ed25519.Sign(w.phone, SigningInput(RemovalReceiptDomain, payload)))) != w.receipt {
		t.Fatal("the two-step receipt differs from the fixture")
	}
}

// fakeHolder is a key holder with one enrolment's record in memory.
type fakeHolder struct {
	administrator ed25519.PrivateKey
	generation    int64
	removed       bool
	issued        int
	last, from    string
}

func (h *fakeHolder) Administrator(string, int64) (officepreview.Administrator, error) {
	return officepreview.Administrator{PublicKey: h.administrator.Public().(ed25519.PublicKey), OrganizationID: "fixture-organisation",
		ProfileID: "fixture-profile", Sign: func(m []byte) []byte { return ed25519.Sign(h.administrator, m) }}, nil
}

func (h *fakeHolder) RenewPeerBinding(_ string, held string, now int64) (string, error) {
	b, digest, e := ReadBinding(held, h.administrator.Public().(ed25519.PublicKey))
	if e != nil {
		return "", e
	}
	if h.removed {
		return "", errors.New("removed")
	}
	if h.generation == b.Generation+1 && h.from == digest {
		return h.last, nil
	}
	if h.generation != b.Generation {
		return "", errors.New("not the latest")
	}
	h.generation++
	h.issued++
	b.Generation, b.IssuedAt, b.ExpiresAt = h.generation, now, now+30*86400
	h.last, h.from = must(fixtureBinding(b, h.administrator)), digest
	return h.last, nil
}

func (h *fakeHolder) MarkRemoved(string, string) error { h.removed = true; return nil }

func TestTheKeyHolderRenewsOnlyForAVerifiedCheckInAndOnce(t *testing.T) {
	w := fixtureWorld(t)
	now := FixtureNow + 120
	h := &fakeHolder{administrator: w.administrator, generation: 1}
	renewed, result, e := Renew(h, w.office, "profile", w.challenge, w.checkIn, w.binding, now)
	if e != nil {
		t.Fatal(e)
	}
	waiting := must(ReadCheckIn(w.checkIn, w.phonePublic))
	_, next, _, e := ReadResult(result, w.adminPub, w.checkIn, waiting, w.held, now)
	if e != nil || next.Generation != 2 {
		t.Fatal("the phone does not accept the holder's result", e)
	}
	// The same request again gives the same binding, not a third generation.
	again, _, e := Renew(h, w.office, "profile", w.challenge, w.checkIn, w.binding, now+5)
	if e != nil || again != renewed || h.issued != 1 {
		t.Fatal("a repeated request issued again", e, h.issued)
	}
	// A replayed check-in cannot renew the renewed binding: the challenge names the old one.
	_, _, e = Renew(h, w.office, "profile", w.challenge, w.checkIn, renewed, now+5)
	refused(t, "a replayed check-in against the new binding", e, ErrOther)
	// Without a check-in there is no renewal.
	_, _, e = Renew(h, w.office, "profile", w.challenge, w.challenge, w.binding, now)
	refused(t, "no check-in", e, nil)
	if h.issued != 1 {
		t.Fatal("something was issued for a refused request")
	}

	// After a removal nothing is renewed, and the removal is signed only for this office.
	removal := must(ReadRemoval(w.removal, w.adminPub, "fixture-organisation", "fixture-profile", "fixture-enrolment", w.held.PhoneTransportID))
	raw := must(json.Marshal(removal))
	foreign := fixtureKey("another office").Public().(ed25519.PublicKey)
	_, e = Remove(h, foreign, "profile", raw, removal.IssuedAt)
	refused(t, "a removal naming another office", e, ErrOther)
	if h.removed {
		t.Fatal("a refused removal marked the enrolment")
	}
	_, e = Remove(h, w.officePublic, "profile", raw, removal.IssuedAt-MaximumIssueSkew-1)
	refused(t, "a removal issued too far ahead", e, ErrTime)
	sealed, e := Remove(h, w.officePublic, "profile", raw, removal.IssuedAt)
	if e != nil || sealed != w.removal || !h.removed {
		t.Fatal("the removal was not signed as sent", e)
	}
	h.generation = 2
	fresh := &fakeHolder{administrator: w.administrator, generation: 1, removed: true}
	_, _, e = Renew(fresh, w.office, "profile", w.challenge, w.checkIn, w.binding, now)
	refused(t, "a renewal after removal", e, nil)
}
