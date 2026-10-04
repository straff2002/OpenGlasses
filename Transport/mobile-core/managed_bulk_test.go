package mobilecore

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"avenkin.dev/mobilecore/manualassignment"
	"avenkin.dev/mobilecore/officebulk"
)

// bulkFixture is an inbox opened under the fixture binding, with the bulk-content fixtures: a
// grant, a vault the granted key signed, and the office's assignment of it to this phone.
type bulkFixture struct {
	*checkInFixture
	files        map[string][]byte
	archive      []byte
	vault        bulkItem
	assignmentID string
	grantID      string
}

func newBulkFixture(t *testing.T) *bulkFixture {
	t.Helper()
	files, err := officebulk.Fixtures()
	if err != nil {
		t.Fatal(err)
	}
	f := &bulkFixture{checkInFixture: newCheckInFixture(t), files: files, archive: files["office-bulk-vault-v1.zip"]}
	f.vault = bulkItem{Kind: bulkVault, SHA256: officebulk.Digest(f.archive), Bytes: int64(len(f.archive))}
	verified, ok := f.inbox.assignment(files["office-bulk-assignment-v1.json"], officebulk.FixtureNow)
	if !ok {
		t.Fatal("the fixture assignment does not read under the fixture binding")
	}
	f.assignmentID = verified.Payload.AssignmentID
	grant, _, err := officebulk.ReadGrant(string(files["office-publisher-grant-v1.json"]), f.administrator.Public().(ed25519.PublicKey), "fixture-organisation", "fixture-profile")
	if err != nil {
		t.Fatal(err)
	}
	f.grantID = grant.GrantID
	return f
}

func (f *bulkFixture) offer(name string, data []byte) {
	f.t.Helper()
	path := filepath.Join(f.inbox.bulk, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		f.t.Fatal(err)
	}
}

func (f *bulkFixture) states() map[string]string {
	f.t.Helper()
	status, err := f.inbox.status(nil)
	if err != nil {
		f.t.Fatal(err)
	}
	out := map[string]string{}
	for _, s := range status {
		out[s.SHA256] = s.State
	}
	return out
}

func ignores(t *testing.T, inbox *managedInbox) []string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(inbox.bulk, ".stignore"))
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(raw)), "\n")
}

func TestTheBulkFolderTakesOnlyWhatWasAskedForAndOnlyItsExactBytes(t *testing.T) {
	f := newBulkFixture(t)
	if err := f.inbox.writeBulkIgnores(); err != nil {
		t.Fatal(err)
	}
	if got := ignores(t, f.inbox); !reflect.DeepEqual(got, []string{"*"}) {
		t.Fatalf("with nothing asked for, something is not ignored: %v", got)
	}
	// An unassigned archive in the folder is never taken in, whatever it is.
	f.offer(bulkName(f.vault), f.archive)
	if len(f.states()) != 0 {
		t.Fatal("something was taken in that was never asked for")
	}
	attachment := bulkItem{Kind: bulkAttachment, SHA256: officebulk.Digest([]byte("site plan")), Bytes: 9}
	lines, err := f.inbox.setWanted([]bulkItem{f.vault, attachment})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"!/attachments/" + attachment.SHA256, "!/vaults/" + f.vault.SHA256 + ".zip", "*"}
	if !reflect.DeepEqual(lines, want) || !reflect.DeepEqual(ignores(t, f.inbox), want) {
		t.Fatalf("the ignore list is not exactly what was asked for, then everything: %v", lines)
	}
	for name, items := range map[string][]bulkItem{
		"a kind not listed":     {{Kind: "manual", SHA256: f.vault.SHA256, Bytes: 1}},
		"a name that is a path": {{Kind: bulkVault, SHA256: "../" + f.vault.SHA256, Bytes: 1}},
		"no size":               {{Kind: bulkVault, SHA256: f.vault.SHA256}},
		"one digest twice":      {f.vault, {Kind: bulkAttachment, SHA256: f.vault.SHA256, Bytes: 1}},
		"too many":              make([]bulkItem, maximumBulkWanted+1),
	} {
		if _, err = f.inbox.setWanted(items); err == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
	// The archive is there in full: taken in as a private copy. The attachment is other bytes
	// of the right size: never ready.
	f.offer(bulkName(attachment), []byte("site plot"))
	states := f.states()
	if states[f.vault.SHA256] != "ready" || states[attachment.SHA256] != "waiting" {
		t.Fatalf("%v", states)
	}
	path, err := f.inbox.file(f.vault.SHA256)
	copied, _ := os.ReadFile(path)
	if err != nil || string(copied) != string(f.archive) || strings.HasPrefix(path, f.inbox.bulk) {
		t.Fatalf("the ready file is not a private copy of the exact bytes: %v", err)
	}
	if _, err = f.inbox.file(attachment.SHA256); err == nil {
		t.Fatal("a file that is not ready was handed over")
	}
	// What is here is no longer asked of the office; and a change in the folder afterwards
	// changes nothing that was taken in.
	if got := ignores(t, f.inbox); !reflect.DeepEqual(got, []string{"!/attachments/" + attachment.SHA256, "*"}) {
		t.Fatalf("%v", got)
	}
	f.offer(bulkName(f.vault), []byte("replaced"))
	again, _ := os.ReadFile(path)
	if f.states()[f.vault.SHA256] != "ready" || string(again) != string(f.archive) {
		t.Fatal("a later change in the folder reached the private copy")
	}
	// A truncated or over-long file, a link, and the right bytes at last.
	for _, wrong := range [][]byte{[]byte("site pla"), []byte("site plan and more")} {
		f.offer(bulkName(attachment), wrong)
		if f.states()[attachment.SHA256] != "waiting" {
			t.Fatal("a file of another size was taken in")
		}
	}
	link := filepath.Join(f.inbox.bulk, filepath.FromSlash(bulkName(attachment)))
	_ = os.Remove(link)
	target := filepath.Join(t.TempDir(), "outside")
	_ = os.WriteFile(target, []byte("site plan"), 0600)
	_ = os.Symlink(target, link)
	if f.states()[attachment.SHA256] != "waiting" {
		t.Fatal("a link was followed")
	}
	_ = os.Remove(link)
	f.offer(bulkName(attachment), []byte("site plan"))
	if f.states()[attachment.SHA256] != "ready" {
		t.Fatal("the exact bytes were not taken in")
	}
	// A restart remembers; letting go of a file removes its copy.
	f.inbox = f.open(1, f.bindingSHA256)
	if f.states()[f.vault.SHA256] != "ready" {
		t.Fatal("a ready file did not survive a restart")
	}
	if _, err = f.inbox.setWanted([]bulkItem{attachment}); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("a file no longer wanted kept its copy")
	}
	// Nothing in bulk, and no private copy, is ever served.
	for _, name := range []string{bulkName(f.vault), bulkName(attachment), "bulk/" + attachment.SHA256} {
		if f.inbox.outbound(name) {
			t.Fatalf("%s would be served", name)
		}
	}
}

func TestOnlyAGrantAndAnAssignmentForThisPhoneAreListed(t *testing.T) {
	f := newBulkFixture(t)
	now := officebulk.FixtureNow
	pending := func() bulkPending {
		t.Helper()
		p, err := f.inbox.bulkPending(now)
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	f.put("publishers/"+f.grantID+envelopeSuffix, f.files["office-publisher-grant-v1.json"])
	f.put("assignments/"+f.assignmentID+envelopeSuffix, f.files["office-bulk-assignment-v1.json"])
	p := pending()
	if len(p.Grants) != 1 || p.Grants[0].ID != f.grantID || len(p.Assignments) != 1 || p.Assignments[0].ID != f.assignmentID {
		t.Fatalf("%+v", p)
	}
	for _, e := range []struct{ got, want string }{
		{p.Grants[0].Envelope, string(f.files["office-publisher-grant-v1.json"])},
		{p.Assignments[0].Envelope, string(f.files["office-bulk-assignment-v1.json"])},
	} {
		if raw, _ := base64.StdEncoding.DecodeString(e.got); string(raw) != e.want {
			t.Fatal("not listed as its exact bytes")
		}
	}
	// Misnamed, signed by another key, for another phone, expired, or not a message at all.
	other := strings.Repeat("e", 32)
	g := newBulkFixture(t)
	var envelope struct{ Payload string }
	_ = json.Unmarshal(g.files["office-bulk-assignment-v1.json"], &envelope)
	raw, _ := base64.StdEncoding.DecodeString(envelope.Payload)
	var payload manualassignment.Payload
	_ = json.Unmarshal(raw, &payload)
	forOther := payload
	forOther.EnrolmentID = "another-enrolment"
	otherPhone, _ := manualassignment.Sign(forOther, g.office)
	byPhone, _ := manualassignment.Sign(payload, g.phone)
	g.put("publishers/"+other+envelopeSuffix, g.files["office-publisher-grant-v1.json"])
	g.put("publishers/"+strings.Repeat("d", 32)+envelopeSuffix, g.files["office-bulk-assignment-v1.json"])
	g.put("publishers/grant.json", g.files["office-publisher-grant-v1.json"])
	g.put("assignments/"+other+envelopeSuffix, g.files["office-bulk-assignment-v1.json"])
	g.put("assignments/"+strings.Repeat("a", 32)+envelopeSuffix, otherPhone)
	g.put("assignments/"+strings.Repeat("b", 32)+envelopeSuffix, byPhone)
	g.put("assignments/"+strings.Repeat("c", 32)+envelopeSuffix, []byte("assignment"))
	if p, err := g.inbox.bulkPending(now); err != nil || len(p.Grants)+len(p.Assignments) != 0 {
		t.Fatalf("%v %+v", err, p)
	}
	g.put("assignments/"+g.assignmentID+envelopeSuffix, g.files["office-bulk-assignment-v1.json"])
	if p, _ := g.inbox.bulkPending(payload.ExpiresAt); len(p.Assignments) != 0 {
		t.Fatal("an expired assignment was listed")
	}
	// Under another generation the assignment is not this binding's.
	g.inbox = g.open(2, strings.Repeat("a", 64))
	if p, _ := g.inbox.bulkPending(now); len(p.Assignments) != 0 {
		t.Fatal("an assignment for the generation before was listed")
	}
	// Folders opened without the administrator key list no grant: there is nothing to check it with.
	f.inbox.authority = nil
	if p = pending(); len(p.Grants) != 0 || len(p.Assignments) != 1 {
		t.Fatalf("%+v", p)
	}
}

func TestAnAssignmentIsReceiptedOncePerOutcomeAndOnlyItsReceiptsServed(t *testing.T) {
	f := newBulkFixture(t)
	now := officebulk.FixtureNow
	if _, err := f.inbox.assignmentReceiptPayload(f.assignmentID, officebulk.OutcomeReceived, now+60, now); err == nil {
		t.Fatal("a receipt was offered for an assignment that is not here")
	}
	f.put("assignments/"+f.assignmentID+envelopeSuffix, f.files["office-bulk-assignment-v1.json"])
	if _, err := f.inbox.assignmentReceiptPayload(f.assignmentID, "refused", now+60, now); err == nil {
		t.Fatal("a receipt was offered for an outcome v1 does not have")
	}
	for outcome, at := range map[string]int64{officebulk.OutcomeReceived: now + 60, officebulk.OutcomeInstalled: now + 600} {
		payload, err := f.inbox.assignmentReceiptPayload(f.assignmentID, outcome, at, now)
		if err != nil {
			t.Fatal(err)
		}
		if again, _ := f.inbox.assignmentReceiptPayload(f.assignmentID, outcome, at+500, now); string(again) != string(payload) {
			t.Fatal("a second receipt was built for one outcome")
		}
		name := assignmentReceiptName(f.assignmentID, outcome)
		if _, err = f.inbox.publishAssignmentReceipt(f.assignmentID, outcome, ed25519.Sign(f.office, officebulk.SigningInput(officebulk.ReceiptDomain, payload))); err == nil || f.inbox.outbound(name) {
			t.Fatal("a signature that is not this phone's was accepted")
		}
		envelope, err := f.inbox.publishAssignmentReceipt(f.assignmentID, outcome, ed25519.Sign(f.phone, officebulk.SigningInput(officebulk.ReceiptDomain, payload)))
		if err != nil {
			t.Fatal(err)
		}
		// With the fixture's clock and key it is the golden receipt.
		if string(envelope) != string(f.files["office-bulk-assignment-receipt-"+outcome+"-v1.json"]) {
			t.Fatalf("the %s receipt is not the golden receipt", outcome)
		}
		if !f.inbox.outbound(name) {
			t.Fatal("the published receipt is not in the outbound list")
		}
	}
	for _, refused := range []string{"assignments/" + f.assignmentID + envelopeSuffix, assignmentReceiptName(strings.Repeat("0", 32), officebulk.OutcomeReceived),
		assignmentReceiptName(f.assignmentID, "refused"), "assignments/../inbox.json"} {
		if f.inbox.outbound(refused) {
			t.Fatalf("%s would be served", refused)
		}
	}
}

func TestTheBulkFolderStartsPausedReceiveOnlyAndIgnoringEverything(t *testing.T) {
	closedDiscovery(t)
	f := newBulkFixture(t)
	client, err := NewClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Stop)
	raw, _ := json.Marshal(managedBinding{OrganizationID: "fixture-organisation", EnrolmentID: "fixture-enrolment", OfficeID: f.held.OfficeID,
		Generation: 1, OfficeTransportID: f.held.OfficeTransportID, OfficeApplicationKey: f.held.OfficeApplicationKey,
		PhoneApplicationKey: f.held.PhoneApplicationKey})
	if err = client.StartManagedOfficeFolders(string(raw), "automatic", ""); err != nil {
		t.Fatal(err)
	}
	saved, err := os.ReadFile(filepath.Join(client.home, "config.xml"))
	if err != nil {
		t.Fatal(err)
	}
	var configuration struct {
		Folders []struct {
			ID     string `xml:"id,attr"`
			Label  string `xml:"label,attr"`
			Type   string `xml:"type,attr"`
			Paused bool   `xml:"paused"`
		} `xml:"folder"`
	}
	if err = xml.Unmarshal(saved, &configuration); err != nil || len(configuration.Folders) != 3 {
		t.Fatal("the managed connection does not have exactly three folders", err)
	}
	found := false
	for _, folder := range configuration.Folders {
		if folder.Label == roleBulk {
			found = folder.Paused && folder.Type == "receiveonly" && strings.HasPrefix(folder.ID, "avenkin-bulk-")
		} else if folder.Paused {
			t.Fatalf("%s started paused", folder.Label)
		}
	}
	if !found {
		t.Fatalf("the bulk folder is not paused and receive-only: %+v", configuration.Folders)
	}
	if got := ignores(t, client.inbox); !reflect.DeepEqual(got, []string{"*"}) {
		t.Fatalf("%v", got)
	}
	// Asking for a file, and resuming, go through to the engine.
	if err = client.SetManagedBulkWanted(`[{"kind":"vault","sha256":"` + f.vault.SHA256 + `","bytes":` + itoa(int(f.vault.Bytes)) + `}]`); err != nil {
		t.Fatal(err)
	}
	if err = client.SetManagedBulkPaused(false); err != nil {
		t.Fatal(err)
	}
	status, err := client.ManagedBulkStatus()
	if err != nil || !strings.Contains(status, `"state":"waiting"`) {
		t.Fatalf("%v %s", err, status)
	}
	if client.guard.allowedFolder == managedFolderID("fixture-organisation", "fixture-enrolment", f.held.OfficeID, roleBulk) {
		t.Fatal("the bulk folder may be served")
	}
	if err = client.SetManagedBulkWanted(`[{"kind":"vault","sha256":"../x","bytes":1}]`); err == nil {
		t.Fatal("a name that is a path was asked of the engine")
	}
}

// closedDiscovery points the managed connection's discovery at a closed local port, so a test
// that starts the engine asks nothing of the network.
func closedDiscovery(t *testing.T) {
	t.Helper()
	closed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := "https://" + closed.Addr().String() + "/v2/?noannounce"
	closed.Close()
	previous := managedDiscoveryServers
	managedDiscoveryServers = []string{server}
	t.Cleanup(func() { managedDiscoveryServers = previous })
}
