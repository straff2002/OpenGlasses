package mobilecore

import (
	"crypto/ed25519"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"avenkin.dev/mobilecore/jobupdate"
)

// updateFixture is an inbox opened under the fixture binding, with the job-update fixtures.
type updateFixture struct {
	*checkInFixture
	files   map[string][]byte
	updates []jobupdate.Update
}

func newUpdateFixture(t *testing.T) *updateFixture {
	t.Helper()
	files, err := jobupdate.Fixtures()
	if err != nil {
		t.Fatal(err)
	}
	return &updateFixture{checkInFixture: newCheckInFixture(t), files: files, updates: jobupdate.FixtureUpdates()}
}

func (f *updateFixture) send(u jobupdate.Update, signer ed25519.PrivateKey) string {
	f.t.Helper()
	message, err := jobupdate.Sign(u, signer)
	if err != nil {
		f.t.Fatal(err)
	}
	f.put("updates/"+u.UpdateID+envelopeSuffix, []byte(message))
	return message
}

func (f *updateFixture) listed(now int64) []string {
	f.t.Helper()
	pending, err := f.inbox.updatesPending(now)
	if err != nil {
		f.t.Fatal(err)
	}
	var ids []string
	for _, p := range pending {
		ids = append(ids, p.ID)
	}
	return ids
}

func TestOnlyAnUpdateForThisPhoneThatIsCurrentIsListed(t *testing.T) {
	f := newUpdateFixture(t)
	now := jobupdate.FixtureNow
	if got := f.listed(now); len(got) != 0 {
		t.Fatalf("listed %v from an empty folder", got)
	}
	for _, kind := range []string{"parts", "schedule", "note"} {
		f.put("updates/"+f.updates[map[string]int{"parts": 0, "schedule": 1, "note": 2}[kind]].UpdateID+envelopeSuffix, f.files["job-update-"+kind+"-v1.json"])
	}
	if got := f.listed(now); len(got) != 3 {
		t.Fatalf("listed %v", got)
	}

	other := f.updates[2]
	change := func(id string, edit func(*jobupdate.Update), signer ed25519.PrivateKey) string {
		u := other
		u.UpdateID = strings.Repeat(id, 32)
		u.Sequence = 9
		edit(&u)
		f.send(u, signer)
		return u.UpdateID
	}
	notListed := map[string]string{
		"signed by another key":  change("a", func(*jobupdate.Update) {}, f.phone),
		"for another enrolment":  change("b", func(u *jobupdate.Update) { u.EnrolmentID = "another-enrolment" }, f.office),
		"for another generation": change("c", func(u *jobupdate.Update) { u.Generation = 2 }, f.office),
		"for another phone":      change("d", func(u *jobupdate.Update) { u.PhoneTransportID = u.OfficeTransportID }, f.office),
		"already expired":        change("e", func(u *jobupdate.Update) { u.IssuedAt, u.ExpiresAt = now-7200, now-3600 }, f.office),
		"not yet issued":         change("f", func(u *jobupdate.Update) { u.IssuedAt = now + 3600 }, f.office),
	}
	// Under another name than its own identifier, and something that is not an update at all.
	f.put("updates/"+strings.Repeat("1", 32)+envelopeSuffix, f.files["job-update-note-v1.json"])
	f.put("updates/"+strings.Repeat("2", 32)+envelopeSuffix, []byte(`{"payload":"e30=","signature":"AA=="}`))
	f.put("updates/not-an-identifier"+envelopeSuffix, f.files["job-update-note-v1.json"])
	got := f.listed(now)
	if len(got) != 3 {
		t.Fatalf("listed %v", got)
	}
	for name, id := range notListed {
		for _, listed := range got {
			if listed == id {
				t.Fatalf("an update %s was listed", name)
			}
		}
	}
	// What can never verify is remembered once; what is only not current waits and is listed
	// when its time comes.
	if len(f.inbox.state.Refused) != 1 {
		t.Fatalf("remembered %d refusals", len(f.inbox.state.Refused))
	}
	if got = f.listed(now + 3600); len(got) != 4 {
		t.Fatalf("listed %v once the later update was current", got)
	}
}

func TestAnUpdateIsReceiptedOnceAndOnlyItsReceiptServed(t *testing.T) {
	f := newUpdateFixture(t)
	now := jobupdate.FixtureNow
	parts := f.updates[0]
	if _, err := f.inbox.updateReceiptPayload(parts.UpdateID, jobupdate.JobHeld, now+60, now); err == nil {
		t.Fatal("a receipt was offered for an update that is not here")
	}
	f.put("updates/"+parts.UpdateID+envelopeSuffix, f.files["job-update-parts-v1.json"])
	if _, err := f.inbox.updateReceiptPayload(parts.UpdateID, "read", now+60, now); err == nil {
		t.Fatal("a receipt was offered for a job state the contract does not name")
	}
	if _, err := f.inbox.updateReceiptPayload(parts.UpdateID, jobupdate.JobHeld, now+60, parts.ExpiresAt); err == nil {
		t.Fatal("a receipt was offered for an update that has run out")
	}
	payload, err := f.inbox.updateReceiptPayload(parts.UpdateID, jobupdate.JobHeld, now+60, now)
	if err != nil {
		t.Fatal(err)
	}
	if again, _ := f.inbox.updateReceiptPayload(parts.UpdateID, jobupdate.JobFinished, now+900, now); string(again) != string(payload) {
		t.Fatal("a second receipt was built for one update")
	}
	name := updateReceiptName(parts.UpdateID)
	if _, err = f.inbox.publishUpdateReceipt(parts.UpdateID, ed25519.Sign(f.office, jobupdate.SigningInput(jobupdate.ReceiptDomain, payload))); err == nil || f.inbox.outbound(name) {
		t.Fatal("a signature that is not this phone's was accepted")
	}
	envelope, err := f.inbox.publishUpdateReceipt(parts.UpdateID, ed25519.Sign(f.phone, jobupdate.SigningInput(jobupdate.ReceiptDomain, payload)))
	if err != nil {
		t.Fatal(err)
	}
	// With the fixture's clock and key it is the golden receipt, and the office reads it.
	if string(envelope) != string(f.files["job-update-receipt-v1.json"]) {
		t.Fatal("the receipt is not the golden receipt")
	}
	verified, err := jobupdate.Read(string(f.files["job-update-parts-v1.json"]), jobupdate.FixtureTrust(), now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = jobupdate.ReadReceipt(string(envelope), f.phone.Public().(ed25519.PublicKey), jobupdate.SentFor(verified)); err != nil {
		t.Fatal(err)
	}
	published, err := os.ReadFile(filepath.Join(f.inbox.records, filepath.FromSlash(name)))
	if err != nil || string(published) != string(envelope) || !f.inbox.outbound(name) {
		t.Fatal("the receipt is not published and in the outbound list")
	}
	for _, refused := range []string{"updates/" + f.updates[1].UpdateID + envelopeSuffix, "updates/../inbox.json", "updates/" + parts.UpdateID + ".json"} {
		if f.inbox.outbound(refused) {
			t.Fatalf("%s would be served", refused)
		}
	}
	// Reopened, the receipt is still the one published.
	reopened := f.open(1, f.bindingSHA256)
	if !reopened.outbound(name) {
		t.Fatal("a relaunch forgot the receipt")
	}
}

func TestAReceiptIsLetGoOnceTheOfficeHasTakenItsUpdateAway(t *testing.T) {
	f := newUpdateFixture(t)
	now := jobupdate.FixtureNow
	parts, note := f.updates[0], f.updates[2]
	for _, u := range []jobupdate.Update{parts, note} {
		f.send(u, f.office)
		payload, err := f.inbox.updateReceiptPayload(u.UpdateID, jobupdate.JobHeld, now+60, now)
		if err != nil {
			t.Fatal(err)
		}
		if u.UpdateID == note.UpdateID {
			continue // built and never signed: it is not published
		}
		if _, err = f.inbox.publishUpdateReceipt(u.UpdateID, ed25519.Sign(f.phone, jobupdate.SigningInput(jobupdate.ReceiptDomain, payload))); err != nil {
			t.Fatal(err)
		}
	}
	// While the update is in control the receipt stays.
	f.listed(now)
	if !f.inbox.outbound(updateReceiptName(parts.UpdateID)) {
		t.Fatal("a receipt went while its update was still in control")
	}
	for _, u := range []jobupdate.Update{parts, note} {
		if err := os.Remove(filepath.Join(f.inbox.control, "updates", u.UpdateID+envelopeSuffix)); err != nil {
			t.Fatal(err)
		}
	}
	f.listed(now)
	if f.inbox.outbound(updateReceiptName(parts.UpdateID)) {
		t.Fatal("the receipt is still served")
	}
	if _, err := os.Stat(filepath.Join(f.inbox.records, "updates", parts.UpdateID+envelopeSuffix)); !os.IsNotExist(err) {
		t.Fatal("the receipt file is still in records")
	}
	// One built and never published goes too: there is no update left to receipt.
	if len(f.inbox.state.UpdateReceipts) != 0 {
		t.Fatalf("%+v", f.inbox.state.UpdateReceipts)
	}
}
