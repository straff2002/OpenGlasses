package officebulk

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"avenkin.dev/mobilecore/manualassignment"
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

type world struct {
	office, phone, administrator, publisher ed25519.PrivateKey
	files                                   map[string][]byte
	grant                                   Grant
	grantSHA256                             string
	assignment                              manualassignment.Verified
	sent                                    Sent
}

func fixtureWorld(t *testing.T) world {
	t.Helper()
	w := world{office: fixtureKey("Avenkin public fixture office key v1"), phone: fixtureKey("Avenkin public fixture phone key v1"),
		administrator: fixtureKey("Avenkin public fixture administrator key v1"),
		publisher:     fixtureKey("Avenkin public fixture organisation publisher key v1"), files: must(Fixtures())}
	w.grant, w.grantSHA256 = func() (Grant, string) {
		g, d, e := ReadGrant(string(w.files["office-publisher-grant-v1.json"]), w.administrator.Public().(ed25519.PublicKey), "fixture-organisation", "fixture-profile")
		if e != nil {
			t.Fatal(e)
		}
		return g, d
	}()
	w.assignment = must(manualassignment.Verify(w.files["office-bulk-assignment-v1.json"], manualassignment.Trust{
		OrganizationID: "fixture-organisation", EnrolmentID: "fixture-enrolment", OfficeID: OfficeID(w.office.Public().(ed25519.PublicKey)),
		SetID: "fixture-manuals", Generation: 1, MaximumArchiveBytes: 1 << 20, PublicKey: w.office.Public().(ed25519.PublicKey)}, FixtureNow, nil))
	p := w.assignment.Payload
	var receipt Receipt
	var e envelope
	_ = json.Unmarshal(w.files["office-bulk-assignment-receipt-received-v1.json"], &e)
	raw, _ := base64.StdEncoding.DecodeString(e.Payload)
	_ = json.Unmarshal(raw, &receipt)
	w.sent = Sent{p.AssignmentID, w.assignment.PayloadSHA256, p.OrganizationID, p.EnrolmentID, p.OfficeID, p.Generation,
		receipt.PhoneTransportID, p.SetID, p.Sequence, p.ArchiveSHA256}
	return w
}

// The checked-in fixtures are exactly what Fixtures makes. Run with BULK_WRITE_FIXTURES=1 to
// write them.
func TestTheGoldenFixturesAreCurrentAndReadBack(t *testing.T) {
	for name, want := range must(Fixtures()) {
		path := filepath.Join("..", "..", "..", "Contracts", "fixtures", name)
		if os.Getenv("BULK_WRITE_FIXTURES") == "1" {
			if e := os.WriteFile(path, want, 0644); e != nil {
				t.Fatal(e)
			}
		}
		got, e := os.ReadFile(path)
		if e != nil || string(got) != string(want) {
			t.Fatalf("%s is not what Fixtures makes; regenerate with BULK_WRITE_FIXTURES=1 (%v)", name, e)
		}
	}
	w := fixtureWorld(t)
	if w.grant.PublisherID != "org.fixture-organisation" || !w.grant.Live(FixtureNow) || w.grant.Sequence != 1 {
		t.Fatalf("%+v", w.grant)
	}
	// The archive is the one the assignment names, and its publisher is the one the grant names.
	archive := w.files["office-bulk-vault-v1.zip"]
	p := w.assignment.Payload
	if Digest(archive) != p.ArchiveSHA256 || int64(len(archive)) != p.ArchiveBytes || p.PublisherID != w.grant.PublisherID {
		t.Fatal("the assignment does not name the fixture archive and the granted publisher")
	}
	phoneKey := w.phone.Public().(ed25519.PublicKey)
	for outcome, at := range map[string]int64{OutcomeReceived: FixtureNow + 60, OutcomeInstalled: FixtureNow + 600} {
		r := must(ReadReceipt(string(w.files["office-bulk-assignment-receipt-"+outcome+"-v1.json"]), phoneKey, w.sent))
		if r.Outcome != outcome || r.At != at {
			t.Fatalf("%s: %+v", outcome, r)
		}
	}
}

func TestAGrantIsTheAdministratorsForThisOrganisationAndOnlyForItsOwnPublisher(t *testing.T) {
	w := fixtureWorld(t)
	admin := w.administrator.Public().(ed25519.PublicKey)
	read := func(text string) error {
		_, _, e := ReadGrant(text, admin, "fixture-organisation", "fixture-profile")
		return e
	}
	resign := func(change func(*Grant), key ed25519.PrivateKey) string {
		g := w.grant
		change(&g)
		payload, _ := json.Marshal(g)
		return must(seal(payload, ed25519.Sign(key, SigningInput(GrantDomain, payload))))
	}
	refused(t, "signed by the office application key", read(resign(func(*Grant) {}, w.office)), ErrSignature)
	refused(t, "signed by the publisher itself", read(resign(func(*Grant) {}, w.publisher)), ErrSignature)
	payload, _ := json.Marshal(w.grant)
	refused(t, "under the receipt's domain", read(must(seal(payload, ed25519.Sign(w.administrator, SigningInput(ReceiptDomain, payload))))), ErrSignature)
	refused(t, "under the binding's domain", read(must(seal(payload, ed25519.Sign(w.administrator, SigningInput("Avenkin.OfficePeerBinding.v1", payload))))), ErrSignature)
	for name, change := range map[string]func(*Grant){
		"another organisation": func(g *Grant) { g.OrganizationID, g.PublisherID = "another-organisation", "org.another-organisation" },
		"another profile":      func(g *Grant) { g.ProfileID = "another-profile" },
	} {
		refused(t, name, read(resign(change, w.administrator)), ErrOther)
	}
	for name, change := range map[string]func(*Grant){
		"a publisher that is not the organisation's own": func(g *Grant) { g.PublisherID = "lennox" },
		"another organisation's publisher":               func(g *Grant) { g.PublisherID = "org.another-organisation" },
		"a prefix that only looks like its own":          func(g *Grant) { g.PublisherID = "org.fixture-organisation-two" },
		"a short key":                                    func(g *Grant) { g.PublisherKey = "AAAA" },
		"a name that needs an escape":                    func(g *Grant) { g.PublisherName = `Fixture "Organisation"` },
		"no name":                                        func(g *Grant) { g.PublisherName = "" },
		"a status v1 does not have":                      func(g *Grant) { g.Status = "suspended" },
		"sequence zero":                                  func(g *Grant) { g.Sequence = 0 },
		"a lifetime over the cap":                        func(g *Grant) { g.ExpiresAt = g.IssuedAt + MaximumGrantLifetime + 1 },
		"another kind":                                   func(g *Grant) { g.Kind = ReceiptKind },
	} {
		refused(t, name, read(resign(change, w.administrator)), ErrFields)
	}
	// Its own name under the organisation's prefix is allowed.
	if e := read(resign(func(g *Grant) { g.PublisherID = "org.fixture-organisation.service" }, w.administrator)); e != nil {
		t.Fatal(e)
	}
	text := string(payload)
	for name, changed := range map[string]string{
		"an extra member":     strings.Replace(text, `{"version":1,`, `{"version":1,"vaultID":"x",`, 1),
		"a missing member":    strings.Replace(text, `"sequence":1,`, ``, 1),
		"a duplicate member":  strings.Replace(text, `{"version":1,`, `{"version":1,"version":1,`, 1),
		"a nested value":      strings.Replace(text, `"sequence":1,`, `"sequence":{"n":1},`, 1),
		"a fractional number": strings.Replace(text, `"sequence":1,`, `"sequence":1.0,`, 1),
		"trailing data":       text + "{}",
	} {
		if changed == text {
			t.Fatalf("%s: the payload was not changed", name)
		}
		refused(t, name, read(must(seal([]byte(changed), ed25519.Sign(w.administrator, SigningInput(GrantDomain, []byte(changed)))))), ErrMalformed)
	}
}

func TestAGrantIsLiveOnlyInsideItsWindowAndARevocationIsReadWhenever(t *testing.T) {
	w := fixtureWorld(t)
	if w.grant.Live(w.grant.IssuedAt-1) || !w.grant.Live(w.grant.IssuedAt) || w.grant.Live(w.grant.ExpiresAt) {
		t.Fatal("the window is not issuedAt <= now < expiresAt")
	}
	revoked := w.grant
	revoked.Sequence, revoked.Status = 2, StatusRevoked
	text := must(SignGrant(revoked, w.administrator))
	read, digest, e := ReadGrant(text, w.administrator.Public().(ed25519.PublicKey), "fixture-organisation", "fixture-profile")
	if e != nil || read.Live(FixtureNow) {
		t.Fatalf("a revocation did not read, or reads as live: %v", e)
	}
	for name, c := range map[string]struct {
		grant  Grant
		digest string
		want   Standing
	}{
		"the revocation after the grant":   {read, digest, Newer},
		"the grant again":                  {w.grant, w.grantSHA256, Same},
		"other bytes at the same sequence": {w.grant, digest, Conflict},
	} {
		if got := Stands(w.grant.Sequence, w.grantSHA256, c.grant, c.digest); got != c.want {
			t.Fatalf("%s: got %d, want %d", name, got, c.want)
		}
	}
	// Once revoked, the grant it replaced never comes back.
	if Stands(read.Sequence, digest, w.grant, w.grantSHA256) != Older {
		t.Fatal("an older grant would replace a revocation")
	}
}

func TestAnAssignmentReceiptIsThePhonesAndForExactlyTheAssignmentSent(t *testing.T) {
	w := fixtureWorld(t)
	phoneKey := w.phone.Public().(ed25519.PublicKey)
	installed := must(ReadReceipt(string(w.files["office-bulk-assignment-receipt-installed-v1.json"]), phoneKey, w.sent))
	payload := must(ReceiptPayload(installed))
	if must(SealReceipt(payload, ed25519.Sign(w.phone, SigningInput(ReceiptDomain, payload)))) != string(w.files["office-bulk-assignment-receipt-installed-v1.json"]) {
		t.Fatal("signing in two steps gives another receipt")
	}
	resign := func(change func(*Receipt), key ed25519.PrivateKey) string {
		r := installed
		change(&r)
		raw, _ := json.Marshal(r)
		return must(seal(raw, ed25519.Sign(key, SigningInput(ReceiptDomain, raw))))
	}
	_, e := ReadReceipt(resign(func(*Receipt) {}, w.office), phoneKey, w.sent)
	refused(t, "signed by the office application key", e, ErrSignature)
	_, e = ReadReceipt(must(seal(payload, ed25519.Sign(w.phone, SigningInput("Avenkin.ManagedJobReceipt.v1", payload)))), phoneKey, w.sent)
	refused(t, "under the job receipt's domain", e, ErrSignature)
	for name, change := range map[string]func(*Receipt){
		"another assignment":         func(r *Receipt) { r.AssignmentID = strings.Repeat("0", 32) },
		"another assignment's bytes": func(r *Receipt) { r.AssignmentSHA256 = strings.Repeat("0", 64) },
		"another enrolment":          func(r *Receipt) { r.EnrolmentID = "another-enrolment" },
		"another generation":         func(r *Receipt) { r.Generation = 2 },
		"another set":                func(r *Receipt) { r.SetID = "another-set" },
		"another sequence":           func(r *Receipt) { r.Sequence = 2 },
		"another archive":            func(r *Receipt) { r.ArchiveSHA256 = strings.Repeat("0", 64) },
		"another phone": func(r *Receipt) {
			r.PhoneTransportID = "DQB4YVC-VNAIUQE-UNBOI3L-YIZRPME-WG6DM7S-GSGGKBY-BGA7SBN-Q2OHOAZ"
		},
	} {
		_, e = ReadReceipt(resign(change, w.phone), phoneKey, w.sent)
		refused(t, name, e, ErrOther)
	}
	for name, change := range map[string]func(*Receipt){
		"an outcome v1 does not have": func(r *Receipt) { r.Outcome = "refused" },
		"no time":                     func(r *Receipt) { r.At = 0 },
	} {
		_, e = ReadReceipt(resign(change, w.phone), phoneKey, w.sent)
		refused(t, name, e, ErrFields)
	}
	if _, e = SealReceipt([]byte(`{"version":1}`), make([]byte, 64)); e == nil {
		t.Fatal("a payload that is not a receipt was sealed")
	}
}

// A process that holds the administrator key for one that does not signs exactly the grant
// payload it is handed — the golden grant, byte for byte — and only a grant, in form, for the
// organisation and profile it has verified, issued by now and, unless it revokes, not expired.
func TestAKeyHolderSignsExactlyTheGrantItIsHandedAndOnlyForItsOwnProfile(t *testing.T) {
	w := fixtureWorld(t)
	golden := string(w.files["office-publisher-grant-v1.json"])
	var e envelope
	_ = json.Unmarshal([]byte(golden), &e)
	payload := must(base64.StdEncoding.DecodeString(e.Payload))
	sign := func(message []byte) []byte { return ed25519.Sign(w.administrator, message) }
	signed, err := SignGrantPayload(payload, "fixture-organisation", "fixture-profile", sign, FixtureNow)
	if err != nil || signed != golden {
		t.Fatalf("%v\n%s\n%s", err, signed, golden)
	}
	changed := func(edit func(*Grant)) []byte {
		g := w.grant
		edit(&g)
		return must(json.Marshal(g))
	}
	// A revocation is signed whatever its dates: it is how an expired grant is still withdrawn.
	revoked := changed(func(g *Grant) { g.Status, g.Sequence = StatusRevoked, 2 })
	if _, err := SignGrantPayload(revoked, "fixture-organisation", "fixture-profile", sign, w.grant.ExpiresAt+1); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		payload                   []byte
		organizationID, profileID string
		sign                      func([]byte) []byte
		now                       int64
		want                      error
	}{
		"another organisation's profile":   {payload, "another-organisation", "fixture-profile", sign, FixtureNow, ErrOther},
		"another profile":                  {payload, "fixture-organisation", "another-profile", sign, FixtureNow, ErrOther},
		"no profile":                       {payload, "", "", sign, FixtureNow, ErrOther},
		"issued ahead":                     {payload, "fixture-organisation", "fixture-profile", sign, w.grant.IssuedAt - MaximumIssueSkew - 1, ErrTime},
		"already expired":                  {payload, "fixture-organisation", "fixture-profile", sign, w.grant.ExpiresAt, ErrTime},
		"another organisation's publisher": {changed(func(g *Grant) { g.PublisherID = "org.another-organisation" }), "fixture-organisation", "fixture-profile", sign, FixtureNow, ErrFields},
		"an assignment receipt": {must(base64.StdEncoding.DecodeString(func() string {
			var r envelope
			_ = json.Unmarshal(w.files["office-bulk-assignment-receipt-received-v1.json"], &r)
			return r.Payload
		}())), "fixture-organisation", "fixture-profile", sign, FixtureNow, ErrMalformed},
		"an extra member": {[]byte(strings.Replace(string(payload), `{"version"`, `{"extra":1,"version"`, 1)), "fixture-organisation", "fixture-profile", sign, FixtureNow, ErrMalformed},
		"a member twice":  {[]byte(strings.Replace(string(payload), `{"version":1,`, `{"version":1,"version":1,`, 1)), "fixture-organisation", "fixture-profile", sign, FixtureNow, ErrMalformed},
		"nothing":         {nil, "fixture-organisation", "fixture-profile", sign, FixtureNow, ErrMalformed},
		"no key":          {payload, "fixture-organisation", "fixture-profile", nil, FixtureNow, ErrSignature},
	} {
		_, err := SignGrantPayload(c.payload, c.organizationID, c.profileID, c.sign, c.now)
		refused(t, name, err, c.want)
	}
}
