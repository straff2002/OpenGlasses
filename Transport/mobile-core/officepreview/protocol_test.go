package officepreview

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"github.com/syncthing/syncthing/lib/protocol"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func ident(s string) string { return protocol.NewDeviceID([]byte(s)).String() }
func paired(t *testing.T) (*Office, *Phone, string) {
	t.Helper()
	o, e := OpenOffice(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	p, e := OpenPhone(t.TempDir(), ident("fictional phone"))
	if e != nil {
		t.Fatal(e)
	}
	invite, e := o.Invite(ident("fictional office"), "tcp://192.168.1.2:23456", "fixture-device", 1000)
	if e != nil {
		t.Fatal(e)
	}
	response, code, e := p.Respond(invite, 1001)
	if e != nil {
		t.Fatal(e)
	}
	confirmation, e := o.Approve(response, code, 1002)
	if e != nil {
		t.Fatal(e)
	}
	if e = p.Confirm(confirmation, 1003); e != nil {
		t.Fatal(e)
	}
	return o, p, code
}
func TestPairingProofExpiryComparisonAndSingleUse(t *testing.T) {
	o, p, code := paired(t)
	if _, e := o.Approve(p.State.Response, code, 1004); e == nil {
		t.Fatal("consumed invitation accepted")
	}
	if _, _, e := ReadInvite(o.State.Invite, 1900); e == nil {
		t.Fatal("expired invitation accepted")
	}
	if _, _, e := ReadInvite(o.State.Invite, 999); e == nil {
		t.Fatal("future invitation accepted")
	}
	var r Response
	raw, _, _ := Raw(p.State.Response)
	_ = json.Unmarshal(raw, &r)
	r.PhoneID = ident("replacement")
	forged, _ := Sign(r, o.Key)
	i, ih, _ := ReadInvite(o.State.Invite, 1004)
	if _, _, e := CheckResponse(forged, i, ih); e == nil {
		t.Fatal("wrong possession key accepted")
	}
	o.State.Confirmation = ""
	if _, e := o.Approve(p.State.Response, "wrong code", 1004); e == nil {
		t.Fatal("wrong comparison accepted")
	}
	p2, e := OpenPhone(p.Root, p.State.PhoneID)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = p2.Binding(); e != nil {
		t.Fatal(e)
	}
	if _, e = OpenPhone(p.Root, ident("another phone")); e == nil {
		t.Fatal("identity replacement accepted")
	}
}
func TestClosedSignedSchemas(t *testing.T) {
	o, p, _ := paired(t)
	i, ih, _ := ReadInvite(o.State.Invite, 1004)
	raw, _, _ := Raw(p.State.Response)
	for _, b := range []string{strings.Replace(string(raw), "\"version\":1", "\"version\":1,\"version\":1", 1), strings.Replace(string(raw), "\"version\":1", "\"version\":1e0", 1), strings.Replace(string(raw), "\"version\":1", "\"version\":1,\"extra\":1", 1)} {
		s, _ := json.Marshal(Envelope{payload64([]byte(b)), payload64(ed25519.Sign(p.Key, append([]byte(Domain), []byte(b)...)))})
		if _, _, e := CheckResponse(string(s), i, ih); e == nil {
			t.Fatal("ambiguous payload accepted")
		}
	}
}
func TestDeliveryRequiresExactManualsAndSignedMatchingReceipt(t *testing.T) {
	o, p, _ := paired(t)
	content := t.TempDir()
	source := []byte("%PDF fictional bytes")
	text := []byte("Fictional label 42 PSI")
	_ = os.WriteFile(filepath.Join(content, Digest(source)), source, 0600)
	_ = os.WriteFile(filepath.Join(content, Digest(text)), text, 0600)
	ms := []Manual{{"manual", "Fictional manual", "fixture.pdf", "pdf", Digest(source), Digest(text), int64(len(source)), int64(len(text))}}
	j, _ := json.Marshal(Job{"job1", "Fictional inspection", "Fixture customer", "FX100", "Test only", ""})
	if _, e := o.Dispatch(string(j), ms, content, 1010); e != nil {
		t.Fatal(e)
	}
	i, _ := o.Binding()
	_, _, folder := Folders(i.PairID)
	missing := t.TempDir()
	if ready, e := p.Receive(o.State.Pending, missing, 1011); e != nil || ready {
		t.Fatalf("missing manual accepted: %v %v", ready, e)
	}
	if p.State.Receipt != "" {
		t.Fatal("receipt before manual commit")
	}
	if ready, e := p.Receive(o.State.Pending, filepath.Join(o.Root, folder), 1011); e != nil || !ready {
		t.Fatalf("delivery failed: %v %v", ready, e)
	}
	if e := o.VerifyReceipt(p.State.Receipt); e != nil {
		t.Fatal(e)
	}
	p2, e := OpenPhone(p.Root, p.State.PhoneID)
	if e != nil {
		t.Fatal(e)
	}
	if ready, e := p2.Receive(o.State.Pending, missing, 1012); e != nil || !ready {
		t.Fatal("exact replay did not retain committed result")
	}
	var r Receipt
	k := p.Key.Public().(ed25519.PublicKey)
	_, _ = Verify(p.State.Receipt, k, receiptFields, &r)
	r.PayloadSHA256 = strings.Repeat("0", 64)
	bad, _ := Sign(r, p.Key)
	if e = o.VerifyReceipt(bad); e == nil {
		t.Fatal("receipt for wrong bytes accepted")
	}
	r.PayloadSHA256 = p.State.PayloadSHA256
	bad, _ = Sign(r, o.Key)
	if e = o.VerifyReceipt(bad); e == nil {
		t.Fatal("receipt signed by office accepted")
	}
	old := o.State.Pending
	if _, e = o.Dispatch(string(j), []Manual{}, content, 1013); e != nil {
		t.Fatal(e)
	}
	if e = o.VerifyReceipt(p.State.Receipt); e == nil {
		t.Fatal("stale receipt accepted")
	}
	if _, e = p.Receive(o.State.Pending, missing, 1014); e != nil {
		t.Fatal(e)
	}
	if _, e = p.Receive(old, missing, 1015); e == nil {
		t.Fatal("rollback accepted")
	}
}
func TestCorruptManualAndRecipientNeverProduceReceipt(t *testing.T) {
	o, p, _ := paired(t)
	j, _ := json.Marshal(Job{"job1", "Fixture", "", "", "", ""})
	if _, e := o.Dispatch(string(j), []Manual{}, t.TempDir(), 1010); e != nil {
		t.Fatal(e)
	}
	var d Delivery
	_, _ = Verify(o.State.Pending, o.Key.Public().(ed25519.PublicKey), deliveryFields, &d)
	d.PhoneID = ident("wrong phone")
	bad, _ := Sign(d, o.Key)
	if _, e := p.Receive(bad, t.TempDir(), 1011); e == nil {
		t.Fatal("wrong recipient accepted")
	}
	d.PhoneID = p.State.PhoneID
	d.ManualsJSON = `[{"id":"manual","title":"Fixture","filename":"fixture.pdf","format":"pdf","sourceSha256":"` + Digest([]byte("expected")) + `","textSha256":"","bytes":8,"textBytes":0}]`
	bad, _ = Sign(d, o.Key)
	folder := t.TempDir()
	_ = os.WriteFile(filepath.Join(folder, Digest([]byte("expected"))), []byte("tampered"), 0600)
	if _, e := p.Receive(bad, folder, 1011); e == nil {
		t.Fatal("corrupt manual accepted")
	}
	if p.State.Receipt != "" {
		t.Fatal("invalid delivery generated a receipt")
	}
}

func payload64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func TestSavedBindingsRejectReplacedRecipientsAndConfirmations(t *testing.T) {
	o, p, _ := paired(t)
	o.State.PhoneID = ident("replacement phone")
	if _, e := o.Binding(); e == nil {
		t.Fatal("replaced saved recipient accepted")
	}
	var c Confirmation
	raw, _, _ := Raw(p.State.Confirmation)
	_ = json.Unmarshal(raw, &c)
	c.InviteSHA256 = strings.Repeat("0", 64)
	p.State.Confirmation, _ = Sign(c, o.Key)
	if _, e := p.Binding(); e == nil {
		t.Fatal("unbound saved confirmation accepted")
	}
}
func TestNestedManualSchemasRejectAmbiguity(t *testing.T) {
	for _, raw := range []string{
		`[{"id":"m","id":"n","title":"t","filename":"f.pdf","format":"pdf","sourceSha256":"` + strings.Repeat("0", 64) + `","textSha256":"","bytes":1,"textBytes":0}]`,
		`[] {}`, `[null]`, `[{"id":"m","title":"t","filename":"f.pdf","format":"pdf","sourceSha256":"` + strings.Repeat("0", 64) + `","textSha256":"","bytes":1e0,"textBytes":0}]`,
	} {
		if _, e := decodeManuals(raw); e == nil {
			t.Fatal("ambiguous nested manifest accepted")
		}
	}
}
func TestCommitFailureCannotAcknowledgeOrAdvanceSequence(t *testing.T) {
	o, p, _ := paired(t)
	j, _ := json.Marshal(Job{"job1", "Fixture", "", "", "", ""})
	if _, e := o.Dispatch(string(j), []Manual{}, t.TempDir(), 1010); e != nil {
		t.Fatal(e)
	}
	statePath := filepath.Join(p.Root, "phone-state.json")
	if e := os.Remove(statePath); e != nil {
		t.Fatal(e)
	}
	if e := os.Mkdir(statePath, 0700); e != nil {
		t.Fatal(e)
	}
	if ready, e := p.Receive(o.State.Pending, t.TempDir(), 1011); e == nil || ready {
		t.Fatal("failed commit acknowledged")
	}
	if p.State.Sequence != 0 || p.State.Receipt != "" {
		t.Fatal("failed commit advanced memory state")
	}
}
func TestMissingPrivateIdentityPreservesSavedStateAndRefusesReplacement(t *testing.T) {
	o, _, _ := paired(t)
	before, e := os.ReadFile(filepath.Join(o.Root, "office-state.json"))
	if e != nil {
		t.Fatal(e)
	}
	if e = os.Remove(filepath.Join(o.Root, "application-key")); e != nil {
		t.Fatal(e)
	}
	if _, e = OpenOffice(o.Root); e == nil {
		t.Fatal("silently replaced lost private identity")
	}
	after, _ := os.ReadFile(filepath.Join(o.Root, "office-state.json"))
	if string(before) != string(after) {
		t.Fatal("saved pairing modified")
	}
	if _, e = os.Stat(filepath.Join(o.Root, "application-key")); !os.IsNotExist(e) {
		t.Fatal("replacement key created")
	}
}

func TestSavedReceiptCannotFalselyRestoreCompletion(t *testing.T) {
	o, _, _ := paired(t)
	o.State.Receipt = "not a signed receipt"
	if e := o.persist(); e != nil {
		t.Fatal(e)
	}
	if _, e := OpenOffice(o.Root); e == nil {
		t.Fatal("invalid saved receipt restored as complete")
	}
}
func TestManualsAreSentAgainUnderTheJobTheDeviceHolds(t *testing.T) {
	o, p, _ := paired(t)
	content := t.TempDir()
	first := []byte("Fictional manual, first edition")
	second := []byte("Fictional manual, second edition")
	for _, b := range [][]byte{first, second} {
		_ = os.WriteFile(filepath.Join(content, Digest(b)), b, 0600)
	}
	manual := func(b []byte) []Manual {
		return []Manual{{"manual", "Fictional manual", "fixture.txt", "txt", Digest(b), Digest(b), int64(len(b)), int64(len(b))}}
	}
	if _, e := o.Dispatch("", manual(first), content, 1010); e == nil {
		t.Fatal("manuals sent before the device holds a job")
	}
	j, _ := json.Marshal(Job{"job1", "Fictional inspection", "Fixture customer", "FX100", "Test only", ""})
	if _, e := o.Dispatch(string(j), manual(first), content, 1010); e != nil {
		t.Fatal(e)
	}
	if _, e := o.Dispatch("", manual(second), content, 1011); e == nil {
		t.Fatal("manuals sent while a delivery still waits for its receipt")
	}
	i, _ := o.Binding()
	_, _, folder := Folders(i.PairID)
	source := filepath.Join(o.Root, folder)
	if ready, e := p.Receive(o.State.Pending, source, 1011); e != nil || !ready {
		t.Fatalf("delivery failed: %v %v", ready, e)
	}
	if e := o.VerifyReceipt(p.State.Receipt); e != nil {
		t.Fatal(e)
	}
	if _, e := o.Dispatch("", manual(second), content, 1012); e != nil {
		t.Fatal(e)
	}
	held := o.Public()["manuals"].([]map[string]string)
	if o.Public()["jobID"] != "job1" || len(held) != 1 || held[0]["sourceSha256"] != Digest(second) || o.Public()["receivedInCompanion"] != false {
		t.Fatalf("office does not report the manuals it sent: %v", o.Public())
	}
	if ready, e := p.Receive(o.State.Pending, source, 1013); e != nil || !ready {
		t.Fatalf("manual update failed: %v %v", ready, e)
	}
	if p.State.Job.ID != "job1" || len(p.State.Manuals) != 1 || p.State.Manuals[0].SourceSHA256 != Digest(second) {
		t.Fatal("device did not keep its job with the newer manual")
	}
	if e := o.VerifyReceipt(p.State.Receipt); e != nil {
		t.Fatal(e)
	}
}
