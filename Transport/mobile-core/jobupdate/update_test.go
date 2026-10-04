package jobupdate

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func must[T any](v T, e error) T {
	if e != nil {
		panic(e)
	}
	return v
}

func refused(t *testing.T, name string, e error, want error) {
	t.Helper()
	if e == nil || !errors.Is(e, want) {
		t.Fatalf("%s: got %v, want %v", name, e, want)
	}
}

var (
	office = fixtureKey("Avenkin public fixture office key v1")
	phone  = fixtureKey("Avenkin public fixture phone key v1")
)

// resign changes one member of a signed message's payload as text and signs the result, so a
// case can carry something Sign itself would refuse.
func resign(t *testing.T, message, domain string, key ed25519.PrivateKey, old, new string) string {
	t.Helper()
	var e envelope
	if json.Unmarshal([]byte(message), &e) != nil {
		t.Fatal("not an envelope")
	}
	payload := string(must(base64.StdEncoding.DecodeString(e.Payload)))
	if !strings.Contains(payload, old) {
		t.Fatalf("%q is not in %s", old, payload)
	}
	changed := []byte(strings.Replace(payload, old, new, 1))
	return must(seal(changed, ed25519.Sign(key, SigningInput(domain, changed))))
}

func TestTheGoldenFixturesAreCurrentAndReadBack(t *testing.T) {
	files := must(Fixtures())
	for name, want := range files {
		path := filepath.Join("..", "..", "..", "Contracts", "fixtures", name)
		if os.Getenv("UPDATE_WRITE_FIXTURES") == "1" {
			if e := os.WriteFile(path, want, 0644); e != nil {
				t.Fatal(e)
			}
		}
		got, e := os.ReadFile(path)
		if e != nil || string(got) != string(want) {
			t.Fatalf("%s is not what Fixtures makes; regenerate with UPDATE_WRITE_FIXTURES=1 (%v)", name, e)
		}
	}
	if len(files) != 4 {
		t.Fatalf("%d fixtures", len(files))
	}
	for i, kind := range []string{KindParts, KindSchedule, KindNote} {
		v := must(Read(string(files["job-update-"+kind+"-v1.json"]), FixtureTrust(), FixtureNow))
		if v.Payload.JobID != "job-2031" || v.Payload.Sequence != int64(i+1) || v.Payload.UpdateKind != kind {
			t.Fatalf("%s: %+v", kind, v.Payload)
		}
	}
	parts := must(Read(string(files["job-update-parts-v1.json"]), FixtureTrust(), FixtureNow))
	r := must(ReadReceipt(string(files["job-update-receipt-v1.json"]), phone.Public().(ed25519.PublicKey), SentFor(parts)))
	if r.JobState != JobHeld || r.ReceivedAt != FixtureNow+60 || r.Outcome != OutcomeReceived {
		t.Fatalf("%+v", r)
	}
}

func TestAnUpdateIsTheOfficesForThisBindingAndInsideItsWindow(t *testing.T) {
	message := string(must(Fixtures())["job-update-parts-v1.json"])
	trust := FixtureTrust()

	other := fixtureKey("another office")
	wrongKey := trust
	wrongKey.OfficeApplicationKey = other.Public().(ed25519.PublicKey)
	_, e := Read(message, wrongKey, FixtureNow)
	refused(t, "another office's key", e, ErrSignature)
	_, e = Read(strings.Replace(message, `"payload":"e`, `"payload":"f`, 1), trust, FixtureNow)
	if e == nil {
		t.Fatal("a changed payload verified")
	}

	for name, change := range map[string]func(*Trust){
		"another organisation":  func(x *Trust) { x.OrganizationID = "another-organisation" },
		"another enrolment":     func(x *Trust) { x.EnrolmentID = "another-enrolment" },
		"another office":        func(x *Trust) { x.OfficeID = "office-000000000000000000000000" },
		"another generation":    func(x *Trust) { x.Generation = 2 },
		"another office device": func(x *Trust) { x.OfficeTransportID = x.PhoneTransportID },
		"another phone":         func(x *Trust) { x.PhoneTransportID = x.OfficeTransportID },
	} {
		changed := FixtureTrust()
		change(&changed)
		_, e := Read(message, changed, FixtureNow)
		refused(t, name, e, ErrAuthority)
	}

	_, e = Read(message, trust, FixtureNow-3600)
	refused(t, "before it was issued", e, ErrTime)
	_, e = Read(message, trust, FixtureNow+7*86400)
	refused(t, "at its expiry", e, ErrTime)

	for name, text := range map[string]string{
		"not an envelope":     `{"payload":"e30=","signature":"AA==","extra":1}`,
		"an empty message":    ``,
		"an oversize message": `{"payload":"` + strings.Repeat("A", MaximumMessage) + `","signature":"AA=="}`,
	} {
		_, e := Read(text, trust, FixtureNow)
		refused(t, name, e, ErrMalformed)
	}
	// A payload with a member the contract does not list is refused whoever signed it.
	_, e = Read(resign(t, message, Domain, office, `"version":1`, `"version":1,"apply":1`), trust, FixtureNow)
	refused(t, "an unlisted member", e, ErrMalformed)
	_, e = Read(resign(t, message, Domain, office, `,"scheduledUntil":0`, ``), trust, FixtureNow)
	refused(t, "a member left out", e, ErrMalformed)
}

func TestEachKindCarriesOnlyItsOwnMembers(t *testing.T) {
	updates := FixtureUpdates()
	parts, schedule, note := updates[0], updates[1], updates[2]
	bad := map[string]func() Update{
		"a version that is not 1":             func() Update { u := note; u.Version = 2; return u },
		"another kind of message":             func() Update { u := note; u.Kind = "avenkin.managed-job"; return u },
		"an identifier that is not hex":       func() Update { u := note; u.UpdateID = strings.Repeat("G", 32); return u },
		"a job that is a path":                func() Update { u := note; u.JobID = "../job"; return u },
		"no job":                              func() Update { u := note; u.JobID = ""; return u },
		"sequence zero":                       func() Update { u := note; u.Sequence = 0; return u },
		"a window longer than thirty days":    func() Update { u := note; u.ExpiresAt = u.IssuedAt + MaximumLifetime + 1; return u },
		"expiry before issue":                 func() Update { u := note; u.ExpiresAt = u.IssuedAt; return u },
		"a kind that is not a word":           func() Update { u := note; u.UpdateKind = "Parts!"; return u },
		"a note with nothing in it":           func() Update { u := note; u.Body = ""; return u },
		"a note with a part":                  func() Update { u := note; u.Part = "Valve"; return u },
		"a note with a time":                  func() Update { u := note; u.ScheduledFor = FixtureNow; return u },
		"a body with a control character":     func() Update { u := note; u.Body = "a\x07b"; return u },
		"a body with a carriage return":       func() Update { u := note; u.Body = "a\r\nb"; return u },
		"a body that is not UTF-8":            func() Update { u := note; u.Body = "a\xffb"; return u },
		"a body over the limit":               func() Update { u := note; u.Body = strings.Repeat("a", MaximumBodyBytes+1); return u },
		"parts with no part":                  func() Update { u := parts; u.Part = ""; return u },
		"parts with no state":                 func() Update { u := parts; u.PartState = ""; return u },
		"a state the contract does not name":  func() Update { u := parts; u.PartState = "lost"; return u },
		"a part over two lines":               func() Update { u := parts; u.Part = "Fan\nmotor"; return u },
		"a negative quantity":                 func() Update { u := parts; u.Quantity = -1; return u },
		"a quantity over the limit":           func() Update { u := parts; u.Quantity = MaximumQuantity + 1; return u },
		"a date that is not a date":           func() Update { u := parts; u.ExpectedOn = "2027-02-30"; return u },
		"a date with a time":                  func() Update { u := parts; u.ExpectedOn = "2027-01-18T09:00:00Z"; return u },
		"parts with a time":                   func() Update { u := parts; u.ScheduledFor = FixtureNow; return u },
		"a schedule with no time":             func() Update { u := schedule; u.ScheduledFor = 0; return u },
		"a window that ends before it starts": func() Update { u := schedule; u.ScheduledUntil = u.ScheduledFor; return u },
		"a schedule with a part":              func() Update { u := schedule; u.Part = "Valve"; return u },
		"an end with no start":                func() Update { u := note; u.UpdateKind = "survey"; u.ScheduledUntil = FixtureNow; return u },
	}
	for name, make := range bad {
		if _, e := Sign(make(), office); !errors.Is(e, ErrFields) {
			t.Fatalf("%s: signed (%v)", name, e)
		}
	}
	// The same payloads signed by the office all the same are refused by the reader.
	message := must(Sign(parts, office))
	_, e := Read(resign(t, message, Domain, office, `"partState":"dispatched"`, `"partState":"lost"`), FixtureTrust(), FixtureNow)
	refused(t, "a signed payload out of form", e, ErrFields)
	_, e = Read(resign(t, message, Domain, office, `"quantity":1`, `"quantity":"1"`), FixtureTrust(), FixtureNow)
	if e == nil {
		t.Fatal("a quantity in words verified")
	}
	_, e = Read(resign(t, message, Domain, office, `"quantity":1`, `"quantity":1.5`), FixtureTrust(), FixtureNow)
	refused(t, "a fractional quantity", e, ErrMalformed)

	// Optional members may be left empty, and a kind this version does not define verifies.
	bare := parts
	bare.Body, bare.Quantity, bare.ExpectedOn = "", 0, ""
	open := schedule
	open.ScheduledUntil, open.Body = 0, "Morning."
	later := note
	later.UpdateKind = "site-access"
	for name, u := range map[string]Update{"parts with only a part and a state": bare, "a time with no end": open, "a kind from a later version": later} {
		v, e := Read(must(Sign(u, office)), FixtureTrust(), FixtureNow)
		if e != nil || v.Payload != u {
			t.Fatalf("%s: %v", name, e)
		}
	}
}

func TestTheKeyHolderSignsOnlyAPayloadItWouldAccept(t *testing.T) {
	trust := FixtureTrust()
	note := FixtureUpdates()[2]
	payload := must(json.Marshal(note))
	message := must(SignPayload(payload, office, trust.OfficeID, FixtureNow))
	v := must(Read(message, trust, FixtureNow))
	if v.PayloadSHA256 != Digest(payload) {
		t.Fatal("the payload was re-encoded")
	}
	_, e := SignPayload(payload, office, "office-000000000000000000000000", FixtureNow)
	refused(t, "another office's identity", e, ErrAuthority)
	_, e = SignPayload(payload, office, trust.OfficeID, note.IssuedAt-MaximumIssueSkew-1)
	refused(t, "issued in the future", e, ErrTime)
	_, e = SignPayload(payload, office, trust.OfficeID, note.ExpiresAt)
	refused(t, "already expired", e, ErrTime)
	_, e = SignPayload(append(payload, ' '), office[:10], trust.OfficeID, FixtureNow)
	refused(t, "no key", e, ErrSignature)
	_, e = SignPayload([]byte(`{"version":1}`), office, trust.OfficeID, FixtureNow)
	refused(t, "not the closed payload", e, ErrMalformed)
	empty := note
	empty.Body = ""
	_, e = SignPayload(must(json.Marshal(empty)), office, trust.OfficeID, FixtureNow)
	refused(t, "out of form", e, ErrFields)
}

func TestASequenceIsTakenOnceAndOrderMeansNothing(t *testing.T) {
	updates := FixtureUpdates()
	first := must(Read(must(Sign(updates[0], office)), FixtureTrust(), FixtureNow))
	if Stands("", first) != New {
		t.Fatal("nothing held is new")
	}
	if Stands(first.PayloadSHA256, first) != Same {
		t.Fatal("the same bytes twice are one update")
	}
	other := updates[0]
	other.Body = "Courier to the depot."
	conflicting := must(Read(must(Sign(other, office)), FixtureTrust(), FixtureNow))
	if Stands(first.PayloadSHA256, conflicting) != Conflict {
		t.Fatal("other bytes at a held sequence are a conflict")
	}
	// A lower sequence after a higher one is still new: each is compared only with what is held
	// at its own sequence.
	third := must(Read(must(Sign(updates[2], office)), FixtureTrust(), FixtureNow))
	if third.Payload.Sequence <= first.Payload.Sequence || Stands("", first) != New {
		t.Fatal("order decided something")
	}
}

func TestAReceiptIsThePhonesAndForExactlyTheUpdateSent(t *testing.T) {
	files := must(Fixtures())
	phoneKey := phone.Public().(ed25519.PublicKey)
	parts := must(Read(string(files["job-update-parts-v1.json"]), FixtureTrust(), FixtureNow))
	sent := SentFor(parts)
	receipt := string(files["job-update-receipt-v1.json"])

	// Two steps, as a phone whose key is outside the transport signs.
	payload := must(ReceiptPayload(ReceiptFor(parts, JobFinished, FixtureNow+90)))
	sealed := must(SealReceipt(payload, ed25519.Sign(phone, SigningInput(ReceiptDomain, payload))))
	if r := must(ReadReceipt(sealed, phoneKey, sent)); r.JobState != JobFinished {
		t.Fatalf("%+v", r)
	}
	if _, e := SealReceipt([]byte(`{"version":1}`), make([]byte, ed25519.SignatureSize)); !errors.Is(e, ErrMalformed) {
		t.Fatal("sealed something that is not a receipt")
	}
	if _, e := ReceiptPayload(ReceiptFor(parts, "read", FixtureNow)); !errors.Is(e, ErrFields) {
		t.Fatal("a job state the contract does not name")
	}

	_, e := ReadReceipt(receipt, office.Public().(ed25519.PublicKey), sent)
	refused(t, "signed by another key", e, ErrSignature)
	// An update is not a receipt, whoever signed it.
	_, e = ReadReceipt(string(files["job-update-parts-v1.json"]), office.Public().(ed25519.PublicKey), sent)
	refused(t, "an update offered as a receipt", e, ErrSignature)

	for name, change := range map[string]func(*Sent){
		"another update":       func(s *Sent) { s.UpdateID = strings.Repeat("0", 32) },
		"other bytes":          func(s *Sent) { s.UpdateSHA256 = strings.Repeat("0", 64) },
		"another organisation": func(s *Sent) { s.OrganizationID = "another-organisation" },
		"another enrolment":    func(s *Sent) { s.EnrolmentID = "another-enrolment" },
		"another office":       func(s *Sent) { s.OfficeID = "another-office" },
		"another generation":   func(s *Sent) { s.Generation = 2 },
		"another phone":        func(s *Sent) { s.PhoneTransportID = FixtureTrust().OfficeTransportID },
		"another job":          func(s *Sent) { s.JobID = "job-2032" },
		"another sequence":     func(s *Sent) { s.Sequence = 2 },
	} {
		changed := sent
		change(&changed)
		_, e := ReadReceipt(receipt, phoneKey, changed)
		refused(t, name, e, ErrOther)
	}
	_, e = ReadReceipt(resign(t, receipt, ReceiptDomain, phone, `"outcome":"received"`, `"outcome":"read"`), phoneKey, sent)
	refused(t, "an outcome the contract does not name", e, ErrFields)
	_, e = ReadReceipt(resign(t, receipt, ReceiptDomain, phone, `"version":1`, `"version":1,"openedAt":1`), phoneKey, sent)
	refused(t, "an unlisted member", e, ErrMalformed)
}
