package commission

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/syncthing/syncthing/lib/protocol"
)

func keyFor(label string) ed25519.PrivateKey {
	seed := sha256.Sum256([]byte(label))
	return ed25519.NewKeyFromSeed(seed[:])
}
func public(k ed25519.PrivateKey) string {
	return base64.StdEncoding.EncodeToString(k.Public().(ed25519.PublicKey))
}
func transport(label string) string { return protocol.NewDeviceID([]byte(label)).String() }

var (
	officeKey = keyFor("test office application key")
	phoneKey  = keyFor("test phone application key")
	otherKey  = keyFor("test other key")
)

const now = int64(1800000000)

func invitation() Invitation {
	return Invitation{1, InvitationKind, base64.RawURLEncoding.EncodeToString(make([]byte, 32)), "fixture-organisation",
		OfficeID(officeKey.Public().(ed25519.PublicKey)), public(officeKey), transport("office"), "192.168.1.24:22443", now, now + 900}
}
func redemption(invitationEnvelope string) Redemption {
	return Redemption{1, RedemptionKind, Digest(invitationEnvelope), invitation().Invitation, "a1b2c3d4", transport("phone"),
		public(phoneKey), "2.4.0", "412", "", now + 5}
}
func approval(invitationEnvelope, redemptionEnvelope string) Approval {
	return Approval{1, ApprovalKind, Digest(invitationEnvelope), Digest(redemptionEnvelope), "a1b2c3d4", transport("phone"),
		public(phoneKey), "profile.signature", "licence.signature", `{"payload":"e30=","signature":"AA=="}`, now + 20}
}
func must[T any](v T, e error) T {
	if e != nil {
		panic(e)
	}
	return v
}
func exchange(t *testing.T) (string, string) {
	inv := must(SignInvitation(invitation(), officeKey))
	return inv, must(SignRedemption(redemption(inv), phoneKey))
}

// reseal signs an arbitrary payload, to present well-signed messages the contract refuses.
func reseal(t *testing.T, domain string, payload any, key ed25519.PrivateKey) string {
	t.Helper()
	return must(sign(domain, payload, key, MaximumDecision))
}
func fields(t *testing.T, v any) map[string]any {
	t.Helper()
	b, _ := json.Marshal(v)
	out := map[string]any{}
	if e := json.Unmarshal(b, &out); e != nil {
		t.Fatal(e)
	}
	return out
}

func TestAnExchangeFromScanToApproval(t *testing.T) {
	inv, red := exchange(t)
	scanned := must(ParseQRText(QRText(inv)))
	if scanned != inv {
		t.Fatal("the QR text does not carry the invitation exactly")
	}
	if len(QRText(inv)) > 1100 {
		t.Fatalf("QR text is %d characters", len(QRText(inv)))
	}
	read := must(ReadInvitation(scanned, now+1))
	if read != invitation() {
		t.Fatal("invitation changed in transit")
	}
	got := must(ReadRedemption(red, inv))
	if got != redemption(inv) {
		t.Fatal("redemption changed in transit")
	}
	office := must(Comparison(Digest(inv), Digest(red)))
	phone := must(Comparison(got.InvitationSHA256, Digest(red)))
	if office != phone || len(office) != 14 || strings.Count(office, "-") != 2 {
		t.Fatalf("comparison codes differ or are malformed: %q %q", office, phone)
	}
	decision := must(ReadDecision(must(SignApproval(approval(inv, red), officeKey)), inv, red))
	if decision.Refusal != nil || *decision.Approval != approval(inv, red) {
		t.Fatal("approval changed in transit")
	}
	refusal := Refusal{1, RefusalKind, Digest(inv), Digest(red), "refused_by_person", now + 20}
	decision = must(ReadDecision(must(SignRefusal(refusal, officeKey)), inv, red))
	if decision.Approval != nil || *decision.Refusal != refusal {
		t.Fatal("refusal changed in transit")
	}
}

func TestAnInvitationIsRefusedOutsideItsWindowOrWhenItNamesAnotherOffice(t *testing.T) {
	inv := must(SignInvitation(invitation(), officeKey))
	for _, at := range []int64{now - 1, now + 900, now + 901} {
		if _, e := ReadInvitation(inv, at); e == nil {
			t.Fatalf("invitation accepted at %d", at)
		}
	}
	change := func(edit func(*Invitation)) Invitation { i := invitation(); edit(&i); return i }
	for name, bad := range map[string]Invitation{
		"lives too long":       change(func(i *Invitation) { i.ExpiresAt = now + 901 }),
		"ends before it began": change(func(i *Invitation) { i.ExpiresAt = now }),
		"public address":       change(func(i *Invitation) { i.Address = "8.8.8.8:22443" }),
		"host name":            change(func(i *Invitation) { i.Address = "office.local:22443" }),
		"no port":              change(func(i *Invitation) { i.Address = "192.168.1.24" }),
		"short token":          change(func(i *Invitation) { i.Invitation = "AAAA" }),
		"office id of another": change(func(i *Invitation) { i.OfficeID = OfficeID(otherKey.Public().(ed25519.PublicKey)) }),
		"unsafe organisation":  change(func(i *Invitation) { i.OrganizationID = "../x" }),
		"bad transport":        change(func(i *Invitation) { i.OfficeTransportID = "not-a-device-id" }),
		"wrong kind":           change(func(i *Invitation) { i.Kind = RedemptionKind }),
	} {
		if _, e := SignInvitation(bad, officeKey); e == nil {
			t.Fatalf("signed an invitation that %s", name)
		}
		if _, e := ReadInvitation(reseal(t, InvitationDomain, bad, officeKey), now+1); e == nil {
			t.Fatalf("read an invitation that %s", name)
		}
	}
	// A code that names one office's key but was signed by another: the substitution case.
	if _, e := ReadInvitation(reseal(t, InvitationDomain, invitation(), otherKey), now+1); e == nil {
		t.Fatal("invitation signed by a key other than the one it names was accepted")
	}
	if _, e := SignInvitation(invitation(), otherKey); e == nil {
		t.Fatal("signed an invitation naming another key")
	}
	// The same bytes under another message's domain are not an invitation.
	if _, e := ReadInvitation(reseal(t, ApprovalDomain, invitation(), officeKey), now+1); e == nil {
		t.Fatal("invitation accepted under the approval domain")
	}
}

func TestTheQRTextIsExact(t *testing.T) {
	inv := must(SignInvitation(invitation(), officeKey))
	text := QRText(inv)
	for _, bad := range []string{"", inv, "og-admin:" + text, strings.TrimPrefix(text, QRPrefix), text + "=", text + " ",
		QRPrefix, QRPrefix + "!!!", strings.ToUpper(QRPrefix) + strings.TrimPrefix(text, QRPrefix),
		QRPrefix + base64.RawURLEncoding.EncodeToString(make([]byte, MaximumInvitation+1))} {
		if _, e := ParseQRText(bad); e == nil {
			t.Fatalf("accepted QR text %.40q", bad)
		}
	}
}

func TestARedemptionProvesThePhoneKeyAndAnswersOneInvitation(t *testing.T) {
	inv, red := exchange(t)
	otherInvitation := invitation()
	otherInvitation.Invitation = base64.RawURLEncoding.EncodeToString(append(make([]byte, 31), 1))
	other := must(SignInvitation(otherInvitation, officeKey))
	if _, e := ReadRedemption(red, other); e == nil {
		t.Fatal("redemption accepted for another invitation")
	}
	change := func(edit func(*Redemption)) Redemption { r := redemption(inv); edit(&r); return r }
	// Signed by a key other than the one presented: no proof of possession.
	if _, e := ReadRedemption(reseal(t, RedemptionDomain, redemption(inv), otherKey), inv); e == nil {
		t.Fatal("redemption signed by another key was accepted")
	}
	for name, bad := range map[string]Redemption{
		"wrong digest":          change(func(r *Redemption) { r.InvitationSHA256 = strings.Repeat("0", 64) }),
		"another token":         change(func(r *Redemption) { r.Invitation = otherInvitation.Invitation }),
		"unsafe enrolment":      change(func(r *Redemption) { r.EnrolmentID = "a/b" }),
		"empty enrolment":       change(func(r *Redemption) { r.EnrolmentID = "" }),
		"bad transport":         change(func(r *Redemption) { r.PhoneTransportID = "phone" }),
		"office's transport":    change(func(r *Redemption) { r.PhoneTransportID = transport("office") }),
		"control in version":    change(func(r *Redemption) { r.AppVersion = "2.4\n0" }),
		"unsafe existing":       change(func(r *Redemption) { r.ExistingEnrolment = "a b" }),
		"zero time":             change(func(r *Redemption) { r.CreatedAt = 0 }),
		"upper-case hex digest": change(func(r *Redemption) { r.InvitationSHA256 = strings.ToUpper(r.InvitationSHA256) }),
	} {
		if _, e := ReadRedemption(reseal(t, RedemptionDomain, bad, phoneKey), inv); e == nil {
			t.Fatalf("read a redemption with %s", name)
		}
	}
	// A phone presenting the office's own application key.
	mirror := redemption(inv)
	mirror.PhoneApplicationKey = public(officeKey)
	if _, e := ReadRedemption(reseal(t, RedemptionDomain, mirror, officeKey), inv); e == nil {
		t.Fatal("redemption presenting the office key was accepted")
	}
	// An already-enrolled phone says so; the office decides what to do with it.
	enrolled := must(SignRedemption(change(func(r *Redemption) { r.ExistingEnrolment = "another-organisation" }), phoneKey))
	if got := must(ReadRedemption(enrolled, inv)); got.ExistingEnrolment != "another-organisation" {
		t.Fatal("existing enrolment lost")
	}
}

// A phone whose key signs inside device storage makes the same envelope in two halves.
func TestARedemptionSignedOutsideThisCodeIsTheSameEnvelope(t *testing.T) {
	inv, red := exchange(t)
	payload, input, e := RedemptionSigningInput(redemption(inv))
	if e != nil {
		t.Fatal(e)
	}
	if string(input) != RedemptionDomain+"\x00"+string(payload) {
		t.Fatal("signing input is not the domain, a zero byte and the payload")
	}
	if sealed := must(SealRedemption(payload, ed25519.Sign(phoneKey, input), inv)); sealed != red {
		t.Fatal("sealed redemption differs from SignRedemption's")
	}
	otherInvitation := invitation()
	otherInvitation.Invitation = base64.RawURLEncoding.EncodeToString(append(make([]byte, 31), 1))
	other := must(SignInvitation(otherInvitation, officeKey))
	for name, attempt := range map[string]func() (string, error){
		"another key":        func() (string, error) { return SealRedemption(payload, ed25519.Sign(otherKey, input), inv) },
		"short signature":    func() (string, error) { return SealRedemption(payload, make([]byte, 63), inv) },
		"another invitation": func() (string, error) { return SealRedemption(payload, ed25519.Sign(phoneKey, input), other) },
		"edited payload": func() (string, error) {
			return SealRedemption(append([]byte(nil), payload[:len(payload)-1]...), ed25519.Sign(phoneKey, input), inv)
		},
	} {
		if _, e := attempt(); e == nil {
			t.Fatalf("sealed a redemption with %s", name)
		}
	}
	bad := redemption(inv)
	bad.EnrolmentID = "a/b"
	if _, _, e := RedemptionSigningInput(bad); e == nil {
		t.Fatal("made signing input for an invalid redemption")
	}
}

func TestADecisionIsForOneExchangeOnePhoneAndOneOffice(t *testing.T) {
	inv, red := exchange(t)
	good := approval(inv, red)
	if _, e := ReadDecision(reseal(t, ApprovalDomain, good, otherKey), inv, red); e == nil {
		t.Fatal("approval signed by another office was accepted")
	}
	if _, e := ReadDecision(reseal(t, RedemptionDomain, good, officeKey), inv, red); e == nil {
		t.Fatal("approval accepted under the redemption domain")
	}
	change := func(edit func(*Approval)) Approval { a := good; edit(&a); return a }
	for name, bad := range map[string]Approval{
		"another phone transport": change(func(a *Approval) { a.PhoneTransportID = transport("another phone") }),
		"another phone key":       change(func(a *Approval) { a.PhoneApplicationKey = public(otherKey) }),
		"another enrolment":       change(func(a *Approval) { a.EnrolmentID = "ffffffff" }),
		"another invitation":      change(func(a *Approval) { a.InvitationSHA256 = strings.Repeat("1", 64) }),
		"another redemption":      change(func(a *Approval) { a.RedemptionSHA256 = strings.Repeat("1", 64) }),
		"no profile":              change(func(a *Approval) { a.ProfileDocument = "" }),
		"no licence":              change(func(a *Approval) { a.LicenceCode = "" }),
		"no binding":              change(func(a *Approval) { a.PeerBinding = "" }),
		"oversized profile":       change(func(a *Approval) { a.ProfileDocument = strings.Repeat("p", maximumProfile+1) }),
	} {
		if _, e := ReadDecision(reseal(t, ApprovalDomain, bad, officeKey), inv, red); e == nil {
			t.Fatalf("read an approval with %s", name)
		}
	}
	// A different redemption of the same invitation cannot use this approval.
	second := redemption(inv)
	second.EnrolmentID = "ffffffff"
	if _, e := ReadDecision(must(SignApproval(good, officeKey)), inv, must(SignRedemption(second, phoneKey))); e == nil {
		t.Fatal("approval accepted against another redemption")
	}
	for _, reason := range RefusalReasons {
		r := Refusal{1, RefusalKind, Digest(inv), Digest(red), reason, now + 20}
		if d, e := ReadDecision(must(SignRefusal(r, officeKey)), inv, red); e != nil || d.Refusal.Reason != reason {
			t.Fatalf("refusal %q not read: %v", reason, e)
		}
	}
	unknown := Refusal{1, RefusalKind, Digest(inv), Digest(red), "because", now + 20}
	if _, e := SignRefusal(unknown, officeKey); e == nil {
		t.Fatal("signed a refusal with an unknown reason")
	}
	if _, e := ReadDecision(reseal(t, ApprovalDomain, unknown, officeKey), inv, red); e == nil {
		t.Fatal("read a refusal with an unknown reason")
	}
}

func TestPayloadsAndEnvelopesAreClosed(t *testing.T) {
	inv, red := exchange(t)
	extra := fields(t, invitation())
	extra["licenceCode"] = "anything"
	if _, e := ReadInvitation(reseal(t, InvitationDomain, extra, officeKey), now+1); e == nil {
		t.Fatal("invitation with an extra field was accepted")
	}
	missing := fields(t, invitation())
	delete(missing, "address")
	if _, e := ReadInvitation(reseal(t, InvitationDomain, missing, officeKey), now+1); e == nil {
		t.Fatal("invitation with a missing field was accepted")
	}
	nested := fields(t, redemption(inv))
	nested["appVersion"] = map[string]any{"major": 2}
	if _, e := ReadRedemption(reseal(t, RedemptionDomain, nested, phoneKey), inv); e == nil {
		t.Fatal("redemption with a nested value was accepted")
	}
	fraction := fields(t, redemption(inv))
	fraction["createdAt"] = 1800000005.5
	if _, e := ReadRedemption(reseal(t, RedemptionDomain, fraction, phoneKey), inv); e == nil {
		t.Fatal("redemption with a fractional time was accepted")
	}
	// Hand-written envelopes: a duplicate key, an unknown key, padding games, trailing data.
	payload, signature, _ := open(inv, MaximumInvitation)
	p, s := base64.StdEncoding.EncodeToString(payload), base64.StdEncoding.EncodeToString(signature)
	for name, text := range map[string]string{
		"duplicate key":   `{"payload":"` + p + `","payload":"` + p + `","signature":"` + s + `"}`,
		"unknown key":     `{"payload":"` + p + `","signature":"` + s + `","note":"x"}`,
		"trailing data":   inv + "{}",
		"url alphabet":    `{"payload":"` + base64.URLEncoding.EncodeToString(payload) + `_","signature":"` + s + `"}`,
		"short sig":       `{"payload":"` + p + `","signature":"` + base64.StdEncoding.EncodeToString(signature[:63]) + `"}`,
		"empty":           ``,
		"array":           `[]`,
		"flipped sig":     `{"payload":"` + p + `","signature":"` + base64.StdEncoding.EncodeToString(append([]byte{signature[0] ^ 1}, signature[1:]...)) + `"}`,
		"altered payload": `{"payload":"` + base64.StdEncoding.EncodeToString(append([]byte(" "), payload...)) + `","signature":"` + s + `"}`,
	} {
		if _, e := ReadInvitation(text, now+1); e == nil {
			t.Fatalf("invitation envelope with %s was accepted", name)
		}
	}
	if Digest(red) == Digest(red+" ") {
		t.Fatal("digest ignores bytes")
	}
}

func TestTheComparisonCodeIsFixed(t *testing.T) {
	a, b := strings.Repeat("00", 32), strings.Repeat("ff", 32)
	code := must(Comparison(a, b))
	// SHA-256("Avenkin.CommissionComparison.v1" 0x00 32x00 32xff), first 60 bits, Crockford.
	sum := sha256.Sum256(append(append(append([]byte(ComparisonDomain), 0), make([]byte, 32)...), []byte(strings.Repeat("\xff", 32))...))
	var want []byte
	bits := uint64(0)
	for _, c := range sum[:8] {
		bits = bits<<8 | uint64(c)
	}
	for n := 0; n < 12; n++ {
		if n > 0 && n%4 == 0 {
			want = append(want, '-')
		}
		want = append(want, crockford[(bits>>(59-5*uint(n)))&31])
	}
	if code != string(want) {
		t.Fatalf("comparison %q, want %q", code, want)
	}
	if other := must(Comparison(b, a)); other == code {
		t.Fatal("comparison ignores order")
	}
	for _, bad := range []string{"", "00", strings.Repeat("0", 63) + "g", strings.ToUpper(b)} {
		if _, e := Comparison(bad, b); e == nil {
			t.Fatalf("comparison accepted digest %q", bad)
		}
	}
	for _, c := range strings.ReplaceAll(code, "-", "") {
		if !strings.ContainsRune(crockford, c) {
			t.Fatalf("comparison uses %q", c)
		}
	}
}

// The checked-in fixtures are exactly what Fixtures makes, and read back as one exchange. Run
// with COMMISSION_WRITE_FIXTURES=1 to write them.
func TestTheGoldenFixturesAreCurrentAndReadBack(t *testing.T) {
	made := must(Fixtures())
	root := filepath.Join("..", "..", "..", "Contracts", "fixtures")
	for name, want := range made {
		path := filepath.Join(root, name)
		if os.Getenv("COMMISSION_WRITE_FIXTURES") == "1" {
			if e := os.WriteFile(path, want, 0644); e != nil {
				t.Fatal(e)
			}
		}
		got, e := os.ReadFile(path)
		if e != nil {
			t.Fatalf("%s: %v", name, e)
		}
		if string(got) != string(want) {
			t.Fatalf("%s is not what Fixtures makes; regenerate with COMMISSION_WRITE_FIXTURES=1", name)
		}
	}
	inv := must(ParseQRText(string(made["commission-qr-v1.txt"])))
	red := string(made["commission-redemption-v1.json"])
	if inv != string(made["commission-invitation-v1.json"]) {
		t.Fatal("the QR fixture is not the invitation fixture")
	}
	must(ReadInvitation(inv, FixtureNow+1))
	must(ReadRedemption(red, inv))
	if must(Comparison(Digest(inv), Digest(red))) != string(made["commission-comparison-v1.txt"]) {
		t.Fatal("comparison fixture differs")
	}
	if d := must(ReadDecision(string(made["commission-approval-v1.json"]), inv, red)); d.Approval == nil {
		t.Fatal("approval fixture did not read as an approval")
	}
	if d := must(ReadDecision(string(made["commission-refusal-v1.json"]), inv, red)); d.Refusal == nil {
		t.Fatal("refusal fixture did not read as a refusal")
	}
}
