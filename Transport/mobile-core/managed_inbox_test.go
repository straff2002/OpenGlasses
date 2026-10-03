package mobilecore

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"avenkin.dev/mobilecore/manageddelivery"
	"github.com/syncthing/syncthing/lib/protocol"
)

const inboxNow int64 = 1800000000

type inboxFixture struct {
	t      *testing.T
	home   string
	inbox  *managedInbox
	office ed25519.PrivateKey
	phone  ed25519.PrivateKey
	trust  manageddelivery.Trust
}

func testKey(label string) ed25519.PrivateKey {
	seed := sha256.Sum256([]byte(label))
	return ed25519.NewKeyFromSeed(seed[:])
}

func newInboxFixture(t *testing.T) *inboxFixture {
	t.Helper()
	f := &inboxFixture{t: t, home: t.TempDir(), office: testKey("test office"), phone: testKey("test phone")}
	phoneID := protocol.NewDeviceID([]byte("test phone transport")).String()
	binding, _ := json.Marshal(managedBinding{
		OrganizationID: "org-harbour", EnrolmentID: "phone-a", OfficeID: "office-1", Generation: 1,
		OfficeTransportID:    protocol.NewDeviceID([]byte("test office transport")).String(),
		OfficeApplicationKey: base64.StdEncoding.EncodeToString(f.office.Public().(ed25519.PublicKey)),
		PhoneApplicationKey:  base64.StdEncoding.EncodeToString(f.phone.Public().(ed25519.PublicKey)),
	})
	trust, phoneKey, err := parseManagedBinding(string(binding), phoneID)
	if err != nil {
		t.Fatal(err)
	}
	f.trust = trust
	if f.inbox, err = openManagedInbox(f.home, trust, phoneKey); err != nil {
		t.Fatal(err)
	}
	return f
}

func messageID(sequence int64) string {
	return strings.Repeat("0", 31) + string(rune('0'+sequence))
}

// deliver puts a signed job in the control folder the way the office does, and returns its
// job bytes. change edits the payload before signing.
func (f *inboxFixture) deliver(sequence int64, change func(*manageddelivery.Job)) []byte {
	f.t.Helper()
	job := []byte(`{"format":"openglasses.job","format_version":1,"job_reference":"JOB-` + string(rune('0'+sequence)) + `"}` + "\n")
	p := manageddelivery.Job{
		Version: 1, Kind: "avenkin.managed-job", MessageID: messageID(sequence),
		OrganizationID: f.trust.OrganizationID, EnrolmentID: f.trust.EnrolmentID, OfficeID: f.trust.OfficeID,
		Generation: 1, OfficeTransportID: f.trust.OfficeTransportID, PhoneTransportID: f.trust.PhoneTransportID,
		Sequence: sequence, IssuedAt: inboxNow - 60, ExpiresAt: inboxNow + 3600,
		JobSHA256: manageddelivery.Digest(job), JobBytes: int64(len(job)),
	}
	if change != nil {
		change(&p)
	}
	envelope, err := manageddelivery.Sign(p, f.office)
	if err != nil {
		f.t.Fatal(err)
	}
	f.write("jobs/"+p.MessageID+".envelope.json", envelope)
	f.write("jobs/"+manageddelivery.Digest(job)+".ogjob", job)
	return job
}

func (f *inboxFixture) write(name string, data []byte) {
	path := filepath.Join(f.inbox.control, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		f.t.Fatal(err)
	}
}

func (f *inboxFixture) sweep() int {
	f.t.Helper()
	n, err := f.inbox.sweep(inboxNow)
	if err != nil {
		f.t.Fatal(err)
	}
	return n
}

func (f *inboxFixture) sign(job pendingJob) []byte {
	raw, _ := base64.StdEncoding.DecodeString(job.ReceiptPayload)
	return ed25519.Sign(f.phone, append([]byte(manageddelivery.ReceiptDomain), raw...))
}

func TestFolderIDIsTheContractsDigest(t *testing.T) {
	sum := sha256.Sum256([]byte("Avenkin.ManagedFolder.v1\x00org-harbour\x00phone-7\x00office-1\x00control"))
	want := "avenkin-control-" + strings.ToLower(encodeHex(sum[:16]))
	if got := managedFolderID("org-harbour", "phone-7", "office-1", "control"); got != want {
		t.Fatalf("%s != %s", got, want)
	}
	if managedFolderID("org-harbour", "phone-7", "office-1", "records") == want {
		t.Fatal("roles share an identifier")
	}
}

func encodeHex(b []byte) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 0, len(b)*2)
	for _, c := range b {
		out = append(out, digits[c>>4], digits[c&15])
	}
	return string(out)
}

func TestAJobIsCommittedThenReceiptedAndTheReceiptVerifiesAtTheOffice(t *testing.T) {
	f := newInboxFixture(t)
	job := f.deliver(1, nil)
	if f.sweep() != 1 || f.sweep() != 0 {
		t.Fatal("the job was not committed exactly once")
	}
	pending, err := f.inbox.pending()
	if err != nil || len(pending) != 1 || pending[0].MessageID != messageID(1) {
		t.Fatalf("%v %+v", err, pending)
	}
	committed, err := f.inbox.jobFile(messageID(1))
	if err != nil || string(committed) != string(job) {
		t.Fatal("the committed bytes are not the job's")
	}
	// Nothing may be served before a receipt is published, and never anything received.
	for _, name := range []string{"receipts/" + messageID(1) + ".envelope.json", "jobs/" + messageID(1) + ".envelope.json", "receipts/../inbox.json"} {
		if f.inbox.outbound(name) {
			t.Fatalf("%s offered before publication", name)
		}
	}
	// A signature that is not this phone's publishes nothing.
	if f.inbox.publishReceipt(messageID(1), ed25519.Sign(f.office, []byte("x"))) == nil {
		t.Fatal("a foreign signature was accepted")
	}
	if _, err = os.Stat(filepath.Join(f.inbox.records, "receipts")); !os.IsNotExist(err) {
		t.Fatal("something was published")
	}
	if err = f.inbox.publishReceipt(messageID(1), f.sign(pending[0])); err != nil {
		t.Fatal(err)
	}
	receipt, err := os.ReadFile(filepath.Join(f.inbox.records, "receipts", messageID(1)+".envelope.json"))
	if err != nil {
		t.Fatal(err)
	}
	// The office's check, against exactly the message it sent.
	envelope, _ := os.ReadFile(filepath.Join(f.inbox.control, "jobs", messageID(1)+".envelope.json"))
	sent, _ := manageddelivery.Verify(envelope, f.trust, inboxNow, nil)
	got, err := manageddelivery.VerifyReceipt(receipt,
		manageddelivery.ReceiptTrust{OrganizationID: "org-harbour", EnrolmentID: "phone-a", OfficeID: "office-1", PhoneTransportID: f.trust.PhoneTransportID, Generation: 1, PhoneApplicationKey: f.phone.Public().(ed25519.PublicKey)},
		manageddelivery.ReceiptExpected{MessageID: messageID(1), Sequence: 1, PayloadSHA256: sent.PayloadSHA256, JobSHA256: sent.Payload.JobSHA256})
	if err != nil || got.ReceivedAt != inboxNow {
		t.Fatalf("%v %+v", err, got)
	}
	if !f.inbox.outbound("receipts/"+messageID(1)+".envelope.json") || f.inbox.outbound("receipts/"+messageID(2)+".envelope.json") {
		t.Fatal("the outbound list is not exactly the published receipt")
	}
	if pending, _ = f.inbox.pending(); len(pending) != 0 {
		t.Fatal("still pending after publication")
	}
	// The mailbox emptying changes nothing that was committed, and a restart remembers.
	_ = os.RemoveAll(filepath.Join(f.inbox.control, "jobs"))
	again, err := openManagedInbox(f.home, f.trust, f.phone.Public().(ed25519.PublicKey))
	if err != nil {
		t.Fatal(err)
	}
	if c, p := again.counts(); c != 1 || p != 1 {
		t.Fatalf("after restart: %d committed, %d published", c, p)
	}
	if b, err := again.jobFile(messageID(1)); err != nil || string(b) != string(job) {
		t.Fatal("the committed job did not survive")
	}
}

func TestJobsAreTakenInSequenceOrderAndALowerOneAfterwardsIsRefused(t *testing.T) {
	f := newInboxFixture(t)
	f.deliver(3, nil)
	f.deliver(2, nil)
	if f.sweep() != 2 {
		t.Fatal("both jobs should commit")
	}
	if f.inbox.state.Jobs[0].Sequence != 2 || f.inbox.state.Jobs[1].Sequence != 3 || f.inbox.state.HighWater.Sequence != 3 {
		t.Fatalf("%+v", f.inbox.state.Jobs)
	}
	// Sequence 1 arrives late: it is refused, remembered, and never offered a receipt.
	f.deliver(1, nil)
	if f.sweep() != 0 || f.inbox.committed(messageID(1)) != nil || len(f.inbox.state.Refused) != 1 {
		t.Fatalf("a lower sequence was taken: %+v", f.inbox.state)
	}
	if f.sweep() != 0 || len(f.inbox.state.Refused) != 1 {
		t.Fatal("a refused file was looked at again")
	}
}

func TestWhatDoesNotVerifyIsNeverCommitted(t *testing.T) {
	for name, arrange := range map[string]func(*inboxFixture){
		"another phone":   func(f *inboxFixture) { f.deliver(1, func(p *manageddelivery.Job) { p.EnrolmentID = "phone-b" }) },
		"another binding": func(f *inboxFixture) { f.deliver(1, func(p *manageddelivery.Job) { p.Generation = 2 }) },
		"expired":         func(f *inboxFixture) { f.deliver(1, func(p *manageddelivery.Job) { p.ExpiresAt = inboxNow - 1 }) },
		"another signer": func(f *inboxFixture) {
			f.office = testKey("someone else")
			f.deliver(1, nil)
		},
		"changed job bytes": func(f *inboxFixture) {
			job := f.deliver(1, nil)
			f.write("jobs/"+manageddelivery.Digest(job)+".ogjob", []byte("something else"))
		},
		"job file not here yet": func(f *inboxFixture) {
			job := f.deliver(1, nil)
			_ = os.Remove(filepath.Join(f.inbox.control, "jobs", manageddelivery.Digest(job)+".ogjob"))
		},
		"misnamed envelope": func(f *inboxFixture) {
			f.deliver(1, nil)
			from := filepath.Join(f.inbox.control, "jobs", messageID(1)+".envelope.json")
			_ = os.Rename(from, filepath.Join(f.inbox.control, "jobs", messageID(9)+".envelope.json"))
		},
		"names the contract gives no place": func(f *inboxFixture) {
			f.write("jobs/job.json", []byte("{}"))
			f.write("jobs/"+strings.Repeat("A", 32)+".envelope.json", []byte("{}"))
			f.write("other/"+messageID(1)+".envelope.json", []byte("{}"))
		},
	} {
		f := newInboxFixture(t)
		arrange(f)
		if n := f.sweep(); n != 0 {
			t.Fatalf("%s: committed %d", name, n)
		}
		if pending, _ := f.inbox.pending(); len(pending) != 0 {
			t.Fatalf("%s: a receipt was offered", name)
		}
		if entries, _ := os.ReadDir(filepath.Join(f.inbox.private, "jobs")); len(entries) != 0 {
			t.Fatalf("%s: bytes were kept", name)
		}
	}
	// A job whose file arrives later is committed then.
	f := newInboxFixture(t)
	job := f.deliver(1, nil)
	path := filepath.Join(f.inbox.control, "jobs", manageddelivery.Digest(job)+".ogjob")
	_ = os.Remove(path)
	if f.sweep() != 0 {
		t.Fatal("committed without its job file")
	}
	_ = os.WriteFile(path, job, 0600)
	if f.sweep() != 1 {
		t.Fatal("not committed once the job file arrived")
	}
}

func TestABindingMustBeCompleteAndClosed(t *testing.T) {
	f := newInboxFixture(t)
	good := map[string]any{
		"organizationID": "org-harbour", "enrolmentID": "phone-a", "officeID": "office-1", "generation": 1,
		"officeTransportID":    f.trust.OfficeTransportID,
		"officeApplicationKey": base64.StdEncoding.EncodeToString(f.office.Public().(ed25519.PublicKey)),
		"phoneApplicationKey":  base64.StdEncoding.EncodeToString(f.phone.Public().(ed25519.PublicKey)),
	}
	encode := func(change func(map[string]any)) string {
		copy := map[string]any{}
		for k, v := range good {
			copy[k] = v
		}
		change(copy)
		raw, _ := json.Marshal(copy)
		return string(raw)
	}
	if _, _, err := parseManagedBinding(encode(func(map[string]any) {}), f.trust.PhoneTransportID); err != nil {
		t.Fatal(err)
	}
	for name, raw := range map[string]string{
		"unknown member":   encode(func(m map[string]any) { m["extra"] = 1 }),
		"no office key":    encode(func(m map[string]any) { delete(m, "officeApplicationKey") }),
		"short phone key":  encode(func(m map[string]any) { m["phoneApplicationKey"] = "AAAA" }),
		"zero generation":  encode(func(m map[string]any) { m["generation"] = 0 }),
		"no enrolment":     encode(func(m map[string]any) { m["enrolmentID"] = "" }),
		"office is itself": encode(func(m map[string]any) { m["officeTransportID"] = f.trust.PhoneTransportID }),
		"not json":         "binding",
	} {
		if _, _, err := parseManagedBinding(raw, f.trust.PhoneTransportID); err == nil {
			t.Fatalf("%s accepted", name)
		}
	}
}
