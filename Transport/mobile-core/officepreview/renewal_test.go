package officepreview

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
)

func TestARenewedBindingIsTheNextGenerationOfTheLatestOnly(t *testing.T) {
	root := t.TempDir()
	o, e := OpenOffice(root)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = AdministratorPublicKey(root, true); e != nil {
		t.Fatal(e)
	}
	admin, _ := administratorKey(root, false)
	vendorPublic, vendor, _ := ed25519.GenerateKey(rand.Reader)
	keys := map[string]string{"test-vendor": base64.StdEncoding.EncodeToString(vendorPublic)}
	profile := testProfile(t, vendor, admin, "2027-01-01T00:00:00Z")
	phonePublic, _, _ := ed25519.GenerateKey(rand.Reader)
	authority := o.AuthorityWithVendorKeys(keys)
	const now = int64(1790000000)
	first, e := authority.IssuePeerBinding(profile, "enrolment-1", ident("office transport"), ident("phone transport"),
		base64.StdEncoding.EncodeToString(phonePublic), now)
	if e != nil {
		t.Fatal(e)
	}
	read := func(envelope string) PeerBinding {
		t.Helper()
		payload, signature, e := Raw(envelope)
		var p PeerBinding
		if e != nil || !ed25519.Verify(admin.Public().(ed25519.PublicKey), append([]byte(peerBindingDomain), payload...), signature) ||
			json.Unmarshal(payload, &p) != nil {
			t.Fatal("binding does not verify under the administrator key", e)
		}
		return p
	}

	second, e := authority.RenewPeerBinding(profile, first, now+86400)
	if e != nil {
		t.Fatal(e)
	}
	was, is := read(first), read(second)
	want := was
	want.Generation, want.IssuedAt, want.ExpiresAt = 2, now+86400, now+86400+30*86400
	if is != want {
		t.Fatalf("renewed binding changed more than its generation and window: %+v", is)
	}
	// The same request again returns the same binding, and burns no generation.
	if again, e := authority.RenewPeerBinding(profile, first, now+86500); e != nil || again != second {
		t.Fatal("a repeated renewal did not return the binding already issued", e)
	}
	third, e := authority.RenewPeerBinding(profile, second, now+2*86400)
	if e != nil || read(third).Generation != 3 {
		t.Fatal("the renewed binding could not be renewed", e)
	}
	// Only the latest is renewed: an older generation is never issued from again.
	if _, e := authority.RenewPeerBinding(profile, first, now+2*86400+10); e == nil {
		t.Fatal("the first binding was renewed after a later one")
	}
	// A record behind the binding presented — a restore from an older backup — issues nothing.
	path := bindingLedgerPath(root, "org-1", "enrolment-1")
	var ledger bindingLedger
	if e = load(path, &ledger); e != nil || ledger.Generation != 3 {
		t.Fatal("ledger", e)
	}
	restored := ledger
	restored.Generation, restored.Binding, restored.RenewedFrom = 2, second, ""
	if e = save(path, restored); e != nil {
		t.Fatal(e)
	}
	if _, e = authority.RenewPeerBinding(profile, third, now+3*86400); e == nil {
		t.Fatal("a binding newer than the record was renewed")
	}
	if e = save(path, ledger); e != nil {
		t.Fatal(e)
	}

	// Outside its window, signed by another key, or for another office: nothing.
	if _, e = authority.RenewPeerBinding(profile, third, now+2*86400+30*86400); e == nil {
		t.Fatal("a lapsed binding was renewed")
	}
	_, stranger, _ := ed25519.GenerateKey(rand.Reader)
	forged, _ := signPeerBinding(read(third), stranger)
	if _, e = authority.RenewPeerBinding(profile, forged, now+3*86400); e == nil {
		t.Fatal("a binding the administrator did not sign was renewed")
	}
	foreign := read(third)
	foreign.OfficeID = "office-000000000000000000000000"
	otherOffice, _ := signPeerBinding(foreign, admin)
	if _, e = authority.RenewPeerBinding(profile, otherOffice, now+3*86400); e == nil {
		t.Fatal("a binding for another office was renewed")
	}
	if _, e = authority.RenewPeerBinding("not a profile", third, now+3*86400); e == nil {
		t.Fatal("renewed without a vendor-signed profile")
	}
	if _, e = o.Authority().RenewPeerBinding(profile, third, now+3*86400); e == nil {
		t.Fatal("renewed under a profile no production vendor key signed")
	}

	// Removal is final: no renewal and no new binding for that enrolment, here or after reopening.
	if e = authority.MarkRemoved("org-1", "never-paired"); e == nil {
		t.Fatal("an enrolment with no binding was marked removed")
	}
	if _, e = os.Stat(bindingLedgerPath(root, "org-1", "never-paired")); !os.IsNotExist(e) {
		t.Fatal("a record was created for an enrolment that was never paired")
	}
	if e = authority.MarkRemoved("org-1", "enrolment-1"); e != nil {
		t.Fatal(e)
	}
	if e = authority.MarkRemoved("org-1", "enrolment-1"); e != nil {
		t.Fatal("marking again failed", e)
	}
	reopened, _ := OpenOffice(root)
	authority = reopened.AuthorityWithVendorKeys(keys)
	if _, e = authority.RenewPeerBinding(profile, third, now+3*86400); e != errRemoved {
		t.Fatal("a removed enrolment was renewed", e)
	}
	if _, e = authority.IssuePeerBinding(profile, "enrolment-1", ident("office transport"), ident("phone transport"),
		base64.StdEncoding.EncodeToString(phonePublic), now+3*86400); e != errRemoved {
		t.Fatal("a binding was issued for a removed enrolment", e)
	}
	if e = load(path, &ledger); e != nil || ledger.Generation != 3 || !ledger.Removed {
		t.Fatal("the record moved after removal", e)
	}
}
