package mobilecore

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"avenkin.dev/mobilecore/checkin"
	"avenkin.dev/mobilecore/officepreview"
)

// checkInFixture is an inbox opened under the golden check-in binding (generation 1), with the
// fixture keys: seed = SHA-256(label), public and without authority.
type checkInFixture struct {
	t                            *testing.T
	home                         string
	inbox                        *managedInbox
	office, phone, administrator ed25519.PrivateKey
	files                        map[string][]byte
	held                         officepreview.PeerBinding
	bindingSHA256                string
}

func checkInBinding(t *testing.T, f *checkInFixture, generation int64, bindingSHA256 string) string {
	t.Helper()
	b64 := base64.StdEncoding.EncodeToString
	raw, err := json.Marshal(managedBinding{
		OrganizationID: f.held.OrganizationID, EnrolmentID: f.held.EnrolmentID, OfficeID: f.held.OfficeID, Generation: generation,
		OfficeTransportID: f.held.OfficeTransportID, OfficeApplicationKey: f.held.OfficeApplicationKey, PhoneApplicationKey: f.held.PhoneApplicationKey,
		ProfileID: f.held.ProfileID, BindingSHA256: bindingSHA256, AdministratorKey: b64(f.administrator.Public().(ed25519.PublicKey)),
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func (f *checkInFixture) open(generation int64, bindingSHA256 string) *managedInbox {
	f.t.Helper()
	trust, phoneKey, authority, err := parseManagedBindingAuthority(checkInBinding(f.t, f, generation, bindingSHA256), f.held.PhoneTransportID)
	if err != nil || authority == nil {
		f.t.Fatalf("%v %v", err, authority)
	}
	inbox, err := openManagedInbox(f.home, trust, phoneKey)
	if err != nil {
		f.t.Fatal(err)
	}
	inbox.authority = authority
	return inbox
}

func newCheckInFixture(t *testing.T) *checkInFixture {
	t.Helper()
	files, err := checkin.Fixtures()
	if err != nil {
		t.Fatal(err)
	}
	f := &checkInFixture{t: t, home: t.TempDir(), files: files, office: testKey("Avenkin public fixture office key v1"),
		phone: testKey("Avenkin public fixture phone key v1"), administrator: testKey("Avenkin public fixture administrator key v1")}
	f.held, f.bindingSHA256, err = checkin.ReadBinding(string(files["office-check-in-binding-v1.json"]), f.administrator.Public().(ed25519.PublicKey))
	if err != nil {
		t.Fatal(err)
	}
	f.inbox = f.open(1, f.bindingSHA256)
	return f
}

func (f *checkInFixture) put(name string, data []byte) {
	f.t.Helper()
	path := filepath.Join(f.inbox.control, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		f.t.Fatal(err)
	}
}

func (f *checkInFixture) pending(now int64) checkInPending {
	f.t.Helper()
	pending, err := f.inbox.checkInPending(now)
	if err != nil {
		f.t.Fatal(err)
	}
	return pending
}

func (f *checkInFixture) challenge(change func(*checkin.Challenge), signer ed25519.PrivateKey) (string, []byte) {
	f.t.Helper()
	c := checkin.Challenge{Version: 1, Kind: checkin.ChallengeKind, ChallengeID: strings.Repeat("c", 32),
		Nonce: base64.RawURLEncoding.EncodeToString(make([]byte, 32)), OrganizationID: f.held.OrganizationID, EnrolmentID: f.held.EnrolmentID,
		OfficeID: checkin.OfficeID(signer.Public().(ed25519.PublicKey)), PhoneTransportID: f.held.PhoneTransportID, Generation: 1,
		BindingSHA256: f.bindingSHA256, IssuedAt: checkin.FixtureNow, ExpiresAt: checkin.FixtureNow + 3600}
	if change != nil {
		change(&c)
	}
	envelope, err := checkin.SignChallenge(c, signer)
	if err != nil {
		f.t.Fatal(err)
	}
	return c.ChallengeID, []byte(envelope)
}

func envelopeText(t *testing.T, e pendingEnvelope) string {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(e.Envelope)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

const fixtureChallengeFile = "office-check-in-challenge-v1.json"

func (f *checkInFixture) fixtureChallengeID() string {
	c, err := checkin.ReadChallenge(string(f.files[fixtureChallengeFile]), f.office.Public().(ed25519.PublicKey))
	if err != nil {
		f.t.Fatal(err)
	}
	return c.ChallengeID
}

func TestACheckInIsOfferedOncePublishedAndRenewableAtTheOffice(t *testing.T) {
	f := newCheckInFixture(t)
	id := f.fixtureChallengeID()
	now := checkin.FixtureNow + 60
	if p := f.pending(now); len(p.Challenges)+len(p.Results)+len(p.Removals) != 0 {
		t.Fatalf("something was listed in empty folders: %+v", p)
	}
	f.put("checkin/"+id+challengeSuffix, f.files[fixtureChallengeFile])
	p := f.pending(now)
	if len(p.Challenges) != 1 || p.Challenges[0].ID != id || envelopeText(t, p.Challenges[0]) != string(f.files[fixtureChallengeFile]) {
		t.Fatalf("the live challenge was not listed as its exact bytes: %+v", p)
	}
	payload, err := f.inbox.checkInPayload(id, now+26*86400, "1.0.0", "100", now)
	if err != nil {
		t.Fatal(err)
	}
	// Answered once: the same bytes and nonce, whatever the caller says the second time.
	again, err := f.inbox.checkInPayload(id, now+1, "9.9.9", "999", now+5)
	if err != nil || string(again) != string(payload) {
		t.Fatalf("a second check-in was built for one challenge: %v", err)
	}
	name := checkInName(id)
	if f.inbox.outbound(name) {
		t.Fatal("offered before publication")
	}
	// A signature that is not this phone's, or over another domain, publishes nothing.
	for label, signature := range map[string][]byte{
		"the office's":   ed25519.Sign(f.office, checkin.SigningInput(checkin.CheckInDomain, payload)),
		"another domain": ed25519.Sign(f.phone, checkin.SigningInput(checkin.RemovalReceiptDomain, payload)),
	} {
		if _, err = f.inbox.publishCheckIn(id, signature); err == nil {
			t.Fatalf("%s signature was accepted", label)
		}
	}
	if _, err = os.Stat(filepath.Join(f.inbox.records, "checkin")); !os.IsNotExist(err) {
		t.Fatal("something was published")
	}
	envelope, err := f.inbox.publishCheckIn(id, ed25519.Sign(f.phone, checkin.SigningInput(checkin.CheckInDomain, payload)))
	if err != nil {
		t.Fatal(err)
	}
	published, _ := os.ReadFile(filepath.Join(f.inbox.records, filepath.FromSlash(name)))
	if string(published) != string(envelope) {
		t.Fatal("what was returned is not what was published")
	}
	// The office's own check, on the exact envelopes.
	if _, err = checkin.Renewable(string(f.files[fixtureChallengeFile]), string(envelope), string(f.files["office-check-in-binding-v1.json"]),
		f.office.Public().(ed25519.PublicKey), f.administrator.Public().(ed25519.PublicKey), now); err != nil {
		t.Fatal(err)
	}
	// Only the published check-in may be served: nothing received, nothing else.
	other := strings.Repeat("d", 32)
	for _, refused := range []string{"checkin/" + id + challengeSuffix, "checkin/" + id + resultSuffix, checkInName(other), removalName(id), "checkin/../inbox.json", "checkin/" + id + ".envelope.json.tmp"} {
		if f.inbox.outbound(refused) {
			t.Fatalf("%s would be served", refused)
		}
	}
	if !f.inbox.outbound(name) {
		t.Fatal("the published check-in is not in the outbound list")
	}
	// A restart remembers the check-in; publishing again keeps the bytes.
	f.inbox = f.open(1, f.bindingSHA256)
	republished, err := f.inbox.publishCheckIn(id, ed25519.Sign(f.phone, checkin.SigningInput(checkin.CheckInDomain, payload)))
	if err != nil || string(republished) != string(envelope) || !f.inbox.outbound(name) {
		t.Fatalf("the check-in did not survive a restart: %v", err)
	}
}

// answer publishes the golden check-in itself, so the golden result is for it: the phone's nonce
// is the fixture's rather than a random one.
func (f *checkInFixture) answerWithGoldenCheckIn() string {
	f.t.Helper()
	id := f.fixtureChallengeID()
	f.put("checkin/"+id+challengeSuffix, f.files[fixtureChallengeFile])
	var envelope struct{ Payload, Signature string }
	if err := json.Unmarshal(f.files["office-check-in-v1.json"], &envelope); err != nil {
		f.t.Fatal(err)
	}
	signature, _ := base64.StdEncoding.DecodeString(envelope.Signature)
	f.inbox.state.CheckIn = &checkInRecord{ChallengeID: id, ChallengeSHA256: checkin.Digest(string(f.files[fixtureChallengeFile])),
		Generation: 1, ExpiresAt: checkin.FixtureNow + checkin.MaximumChallengeLifetime, Payload: envelope.Payload}
	published, err := f.inbox.publishCheckIn(id, signature)
	if err != nil || string(published) != string(f.files["office-check-in-v1.json"]) {
		f.t.Fatalf("the golden check-in was not published as its own bytes: %v", err)
	}
	return id
}

func TestOnlyTheResultForThePublishedCheckInIsListedAndNotAfterTheRenewal(t *testing.T) {
	f := newCheckInFixture(t)
	now := checkin.FixtureNow + 200
	id := f.fixtureChallengeID()
	// A result with no check-in waiting is not listed.
	f.put("checkin/"+id+resultSuffix, f.files["office-check-in-result-v1.json"])
	if p := f.pending(now); len(p.Results) != 0 {
		t.Fatal("a result was listed for a check-in this phone never made")
	}
	f.answerWithGoldenCheckIn()
	// Before the renewed binding's issuedAt on this phone's clock it waits, and is not refused.
	if p := f.pending(checkin.FixtureNow + 100); len(p.Results) != 0 || len(f.inbox.state.Refused) != 0 {
		t.Fatalf("a result not yet valid was listed or remembered: %+v", f.inbox.state.Refused)
	}
	p := f.pending(now)
	if len(p.Results) != 1 || p.Results[0].ID != id || envelopeText(t, p.Results[0]) != string(f.files["office-check-in-result-v1.json"]) {
		t.Fatalf("the result was not listed as its exact bytes: %+v", p)
	}
	// The same result under the office application key, and one for another check-in.
	var result checkin.Result
	var envelope struct{ Payload string }
	_ = json.Unmarshal(f.files["office-check-in-result-v1.json"], &envelope)
	raw, _ := base64.StdEncoding.DecodeString(envelope.Payload)
	_ = json.Unmarshal(raw, &result)
	byOffice, _ := checkin.SignResult(result, f.office)
	f.put("checkin/"+id+resultSuffix, []byte(byOffice))
	if p = f.pending(now); len(p.Results) != 0 {
		t.Fatal("a result signed by the office application key was listed")
	}
	result.CheckInSHA256 = strings.Repeat("0", 64)
	foreign, _ := checkin.SignResult(result, f.administrator)
	f.put("checkin/"+id+resultSuffix, []byte(foreign))
	if p = f.pending(now); len(p.Results) != 0 {
		t.Fatal("a result for another check-in was listed")
	}
	// Once the native caller holds the renewed binding the folders start under generation 2: the
	// old result is no renewal of it, and the check-in is withdrawn.
	f.put("checkin/"+id+resultSuffix, f.files["office-check-in-result-v1.json"])
	_, renewedSHA256, err := checkin.ReadBinding(result.PeerBinding, f.administrator.Public().(ed25519.PublicKey))
	if err != nil {
		t.Fatal(err)
	}
	f.inbox = f.open(2, renewedSHA256)
	if p = f.pending(now); len(p.Results)+len(p.Challenges) != 0 {
		t.Fatalf("a used exchange was listed under the new generation: %+v", p)
	}
	if f.inbox.state.CheckIn != nil || f.inbox.outbound(checkInName(id)) {
		t.Fatal("the answered check-in was not withdrawn")
	}
	if _, err = os.Stat(filepath.Join(f.inbox.records, filepath.FromSlash(checkInName(id)))); !os.IsNotExist(err) {
		t.Fatal("the answered check-in is still in records")
	}
}

func TestAChallengeThatDoesNotVerifyIsNotListedOrAnswered(t *testing.T) {
	now := checkin.FixtureNow + 60
	stranger := testKey("someone else")
	for name, arrange := range map[string]func(*checkInFixture) (string, []byte){
		"expired": func(f *checkInFixture) (string, []byte) {
			return f.challenge(func(c *checkin.Challenge) { c.ExpiresAt = now }, f.office)
		},
		"not yet live": func(f *checkInFixture) (string, []byte) {
			return f.challenge(func(c *checkin.Challenge) { c.IssuedAt = now + 1 }, f.office)
		},
		"another enrolment": func(f *checkInFixture) (string, []byte) {
			return f.challenge(func(c *checkin.Challenge) { c.EnrolmentID = "another" }, f.office)
		},
		"another generation": func(f *checkInFixture) (string, []byte) {
			return f.challenge(func(c *checkin.Challenge) { c.Generation = 2 }, f.office)
		},
		"another binding": func(f *checkInFixture) (string, []byte) {
			return f.challenge(func(c *checkin.Challenge) { c.BindingSHA256 = strings.Repeat("0", 64) }, f.office)
		},
		"another office's key": func(f *checkInFixture) (string, []byte) { return f.challenge(nil, stranger) },
		"misnamed": func(f *checkInFixture) (string, []byte) {
			_, envelope := f.challenge(nil, f.office)
			return strings.Repeat("e", 32), envelope
		},
		"a check-in under the challenge's name": func(f *checkInFixture) (string, []byte) {
			return f.fixtureChallengeID(), f.files["office-check-in-v1.json"]
		},
		"not json": func(f *checkInFixture) (string, []byte) { return strings.Repeat("c", 32), []byte("challenge") },
	} {
		f := newCheckInFixture(t)
		id, envelope := arrange(f)
		f.put("checkin/"+id+challengeSuffix, envelope)
		if p := f.pending(now); len(p.Challenges) != 0 {
			t.Fatalf("%s: listed", name)
		}
		if _, err := f.inbox.checkInPayload(id, now+86400, "1.0.0", "100", now); err == nil || f.inbox.state.CheckIn != nil {
			t.Fatalf("%s: answered", name)
		}
	}
	// Names the contract gives no place are not opened; a malformed file is remembered once.
	f := newCheckInFixture(t)
	f.put("checkin/challenge.json", []byte("{}"))
	f.put("checkin/"+strings.Repeat("A", 32)+challengeSuffix, []byte("{}"))
	f.put("checkin/"+strings.Repeat("c", 32)+challengeSuffix, []byte("{}"))
	f.pending(now)
	f.pending(now)
	if len(f.inbox.state.Refused) != 1 {
		t.Fatalf("malformed input was not remembered exactly once: %+v", f.inbox.state.Refused)
	}
}

func TestTheLatestLiveChallengeWithdrawsTheAnswerToAnOlderOne(t *testing.T) {
	f := newCheckInFixture(t)
	now := checkin.FixtureNow + 60
	older, envelope := f.challenge(nil, f.office)
	f.put("checkin/"+older+challengeSuffix, envelope)
	payload, err := f.inbox.checkInPayload(older, now+86400, "1.0.0", "100", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.inbox.publishCheckIn(older, ed25519.Sign(f.phone, checkin.SigningInput(checkin.CheckInDomain, payload))); err != nil {
		t.Fatal(err)
	}
	newer, envelope := f.challenge(func(c *checkin.Challenge) {
		c.ChallengeID, c.IssuedAt = hex.EncodeToString(make([]byte, 16)), checkin.FixtureNow+30
	}, f.office)
	f.put("checkin/"+newer+challengeSuffix, envelope)
	if p := f.pending(now); len(p.Challenges) != 1 || p.Challenges[0].ID != newer {
		t.Fatalf("the latest challenge was not the one listed: %+v", p)
	}
	if _, err = f.inbox.checkInPayload(older, now+86400, "1.0.0", "100", now); err == nil {
		t.Fatal("the older challenge was answered again")
	}
	if _, err = f.inbox.checkInPayload(newer, now+86400, "1.0.0", "100", now); err != nil {
		t.Fatal(err)
	}
	if f.inbox.outbound(checkInName(older)) || f.inbox.outbound(checkInName(newer)) {
		t.Fatal("a withdrawn or unpublished check-in would be served")
	}
	if _, err = os.Stat(filepath.Join(f.inbox.records, filepath.FromSlash(checkInName(older)))); !os.IsNotExist(err) {
		t.Fatal("the withdrawn check-in is still in records")
	}
	// A check-in whose challenge has expired is withdrawn too.
	f.pending(checkin.FixtureNow + 3600)
	if f.inbox.state.CheckIn != nil {
		t.Fatal("a check-in outlived its challenge")
	}
}

func TestARemovalIsListedReceiptedOnceAndOnlyItsReceiptServed(t *testing.T) {
	f := newCheckInFixture(t)
	now := checkin.FixtureNow + 86460
	removal := f.files["office-removal-v1.json"]
	read, err := checkin.ReadRemoval(string(removal), f.administrator.Public().(ed25519.PublicKey), f.held.OrganizationID, f.held.ProfileID, f.held.EnrolmentID, f.held.PhoneTransportID)
	if err != nil {
		t.Fatal(err)
	}
	id := read.RemovalID
	// Signed by the office application key, for another enrolment, or misnamed: not listed.
	byOffice, _ := checkin.SignRemoval(read, f.office)
	other := read
	other.EnrolmentID = "another-enrolment"
	forOther, _ := checkin.SignRemoval(other, f.administrator)
	for name, file := range map[string][2]string{
		"office application key": {id, byOffice},
		"another enrolment":      {id, forOther},
		"misnamed":               {strings.Repeat("e", 32), string(removal)},
	} {
		g := newCheckInFixture(t)
		g.put("removal/"+file[0]+envelopeSuffix, []byte(file[1]))
		if p := g.pending(now); len(p.Removals) != 0 {
			t.Fatalf("%s: listed", name)
		}
		if _, err = g.inbox.removalReceiptPayload(file[0], now); err == nil {
			t.Fatalf("%s: a receipt was offered", name)
		}
	}
	f.put("removal/"+id+envelopeSuffix, removal)
	if p := f.pending(now); len(p.Removals) != 1 || p.Removals[0].ID != id || envelopeText(t, p.Removals[0]) != string(removal) {
		t.Fatalf("the removal was not listed as its exact bytes: %+v", p)
	}
	payload, err := f.inbox.removalReceiptPayload(id, now)
	if err != nil {
		t.Fatal(err)
	}
	if again, _ := f.inbox.removalReceiptPayload(id, now+500); string(again) != string(payload) {
		t.Fatal("a second receipt was built for one removal")
	}
	if _, err = f.inbox.publishRemovalReceipt(id, ed25519.Sign(f.phone, checkin.SigningInput(checkin.CheckInDomain, payload))); err == nil {
		t.Fatal("a signature under the check-in domain was accepted")
	}
	if f.inbox.outbound(removalName(id)) {
		t.Fatal("offered before publication")
	}
	envelope, err := f.inbox.publishRemovalReceipt(id, ed25519.Sign(f.phone, checkin.SigningInput(checkin.RemovalReceiptDomain, payload)))
	if err != nil {
		t.Fatal(err)
	}
	// With the fixture's clock and key the receipt is the golden one, and the office accepts it.
	if string(envelope) != string(f.files["office-removal-receipt-v1.json"]) {
		t.Fatal("the receipt is not the golden receipt")
	}
	if _, err = checkin.ReadRemovalReceipt(string(envelope), f.phone.Public().(ed25519.PublicKey), string(removal), read); err != nil {
		t.Fatal(err)
	}
	if !f.inbox.outbound(removalName(id)) || f.inbox.outbound("removal/"+strings.Repeat("d", 32)+envelopeSuffix) || f.inbox.outbound(checkInName(id)) {
		t.Fatal("the outbound list is not exactly the published removal receipt")
	}
}

func TestFoldersOpenedWithoutTheCheckInAuthorityCarryNoCheckIn(t *testing.T) {
	f := newCheckInFixture(t)
	f.put("checkin/"+f.fixtureChallengeID()+challengeSuffix, f.files[fixtureChallengeFile])
	f.inbox.authority = nil
	if p := f.pending(checkin.FixtureNow + 60); len(p.Challenges) != 0 {
		t.Fatal("a challenge was listed with nothing to verify it against")
	}
	if _, err := f.inbox.checkInPayload(f.fixtureChallengeID(), checkin.FixtureNow+86400, "1.0.0", "100", checkin.FixtureNow+60); err == nil {
		t.Fatal("a check-in was offered")
	}
	// The binding object is closed in both forms: the three come together or not at all.
	var whole map[string]any
	_ = json.Unmarshal([]byte(checkInBinding(t, f, 1, f.bindingSHA256)), &whole)
	for _, missing := range []string{"profileID", "bindingSHA256", "administratorKey"} {
		part := map[string]any{}
		for k, v := range whole {
			if k != missing {
				part[k] = v
			}
		}
		raw, _ := json.Marshal(part)
		if _, _, _, err := parseManagedBindingAuthority(string(raw), f.held.PhoneTransportID); err == nil {
			t.Fatalf("a binding without %s was accepted", missing)
		}
	}
	whole["administratorKey"] = "AAAA"
	raw, _ := json.Marshal(whole)
	if _, _, _, err := parseManagedBindingAuthority(string(raw), f.held.PhoneTransportID); err == nil {
		t.Fatal("a short administrator key was accepted")
	}
}
