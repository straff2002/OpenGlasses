package mobilecore

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"avenkin.dev/mobilecore/officereport"
)

// reportFixture is an inbox opened under the fixture binding, with the golden report: its
// payload and the phone's signature taken apart, as the native caller hands them over.
type reportFixture struct {
	*checkInFixture
	files                                map[string][]byte
	payload, signature, record, manifest []byte
	report                               officereport.Report
	list                                 officereport.Manifest
}

func newReportFixture(t *testing.T) *reportFixture {
	t.Helper()
	files, err := officereport.Fixtures()
	if err != nil {
		t.Fatal(err)
	}
	f := &reportFixture{checkInFixture: newCheckInFixture(t), files: files,
		record: files["office-report-record-v1.json"], manifest: files["office-report-manifest-v1.json"]}
	var envelope struct{ Payload, Signature string }
	if err = json.Unmarshal(files["office-report-v1.json"], &envelope); err != nil {
		t.Fatal(err)
	}
	f.payload, _ = base64.StdEncoding.DecodeString(envelope.Payload)
	f.signature, _ = base64.StdEncoding.DecodeString(envelope.Signature)
	if f.report, err = officereport.ReadReport(string(files["office-report-v1.json"]), f.inbox.reportTrust()); err != nil {
		t.Fatal(err)
	}
	if f.list, err = f.report.Carries(f.record, f.manifest); err != nil {
		t.Fatal(err)
	}
	return f
}

// The fixture attachments' bytes are public sentences; only their digests are in the manifest.
var fixtureAttachmentBytes = map[string]string{
	officereport.RoleWorkOrder:  "Avenkin public fixture work order v1",
	officereport.RoleTranscript: "Avenkin public fixture transcript v1",
	officereport.RolePhoto:      "Avenkin public fixture photo v1",
}

func (f *reportFixture) attachment(role string) (digest, path string) {
	f.t.Helper()
	for _, a := range f.list.Attachments {
		if a.Role == role {
			path = filepath.Join(f.t.TempDir(), "source")
			if err := os.WriteFile(path, []byte(fixtureAttachmentBytes[role]), 0600); err != nil {
				f.t.Fatal(err)
			}
			return a.SHA256, path
		}
	}
	f.t.Fatal(role)
	return "", ""
}

func (f *reportFixture) inRecords(name string) bool {
	_, err := os.Stat(f.inbox.recordsPath(name))
	return err == nil
}

func TestAReportIsCheckedAsTheOfficeWillThenPublishedWithWhatItNames(t *testing.T) {
	f := newReportFixture(t)
	id := f.report.ReportID
	names := []string{reportName(id), recordName(f.report.RecordSHA256), manifestName(f.report.ManifestSHA256)}
	for _, name := range names {
		if f.inbox.outbound(name) {
			t.Fatalf("%s offered before publication", name)
		}
	}
	// Not this phone's signature, another phone's report, or a record or manifest that is not
	// the one named: nothing is published.
	other := f.report
	other.EnrolmentID = "another-enrolment"
	otherPayload, _ := json.Marshal(other)
	for name, c := range map[string][4][]byte{
		"the office's signature": {f.payload, ed25519.Sign(f.office, officereport.SigningInput(officereport.ReportDomain, f.payload)), f.record, f.manifest},
		"another domain":         {f.payload, ed25519.Sign(f.phone, officereport.SigningInput(officereport.ReceiptDomain, f.payload)), f.record, f.manifest},
		"another enrolment":      {otherPayload, ed25519.Sign(f.phone, officereport.SigningInput(officereport.ReportDomain, otherPayload)), f.record, f.manifest},
		"a changed record":       {f.payload, f.signature, []byte(strings.Replace(string(f.record), "1042", "1043", 1)), f.manifest},
		"a changed manifest":     {f.payload, f.signature, f.record, []byte(strings.Replace(string(f.manifest), "required", "optional", 1))},
		"a receipt as a report":  {[]byte(`{"version":1}`), ed25519.Sign(f.phone, officereport.SigningInput(officereport.ReportDomain, []byte(`{"version":1}`))), f.record, f.manifest},
	} {
		if _, err := f.inbox.publishReport(c[0], c[1], c[2], c[3]); err == nil {
			t.Fatalf("%s: published", name)
		}
	}
	if entries, _ := os.ReadDir(filepath.Join(f.inbox.records, "reports")); len(entries) != 0 || len(f.inbox.state.Reports) != 0 {
		t.Fatal("something was published")
	}
	envelope, err := f.inbox.publishReport(f.payload, f.signature, f.record, f.manifest)
	if err != nil {
		t.Fatal(err)
	}
	if string(envelope) != string(f.files["office-report-v1.json"]) {
		t.Fatal("what was published is not the golden report")
	}
	for name, want := range map[string][]byte{names[0]: envelope, names[1]: f.record, names[2]: f.manifest} {
		got, err := os.ReadFile(f.inbox.recordsPath(name))
		if err != nil || string(got) != string(want) || !f.inbox.outbound(name) {
			t.Fatalf("%s is not published as its exact bytes: %v", name, err)
		}
	}
	// Exactly those: nothing received, no other report, no attachment yet, no temporary name.
	for _, refused := range []string{"reports/" + id + ".pending.envelope.json", "receipts/" + id + ".full.envelope.json",
		reportName(strings.Repeat("0", 64)), recordName(f.report.ManifestSHA256), manifestName(f.report.RecordSHA256),
		attachmentName(f.list.Attachments[0].SHA256), "reports/../inbox.json", reportName(id) + ".tmp", "reports/" + id} {
		if f.inbox.outbound(refused) {
			t.Fatalf("%s would be served", refused)
		}
	}
	// A published name keeps its bytes: the same report again, and after a restart, is that file.
	again, err := f.inbox.publishReport(f.payload, f.signature, f.record, f.manifest)
	if err != nil || string(again) != string(envelope) || len(f.inbox.state.Reports) != 1 {
		t.Fatalf("republishing changed something: %v", err)
	}
	f.inbox = f.open(1, f.bindingSHA256)
	if !f.inbox.outbound(names[0]) || f.inbox.reportCount() != 1 {
		t.Fatal("the published report did not survive a restart")
	}
	// A renewal keeps every identity: the same report is still this phone's under generation 2.
	f.inbox = f.open(2, strings.Repeat("a", 64))
	if again, err = f.inbox.publishReport(f.payload, f.signature, f.record, f.manifest); err != nil || string(again) != string(envelope) {
		t.Fatalf("the report did not carry across a renewal: %v", err)
	}
}

func TestOnlyAnAttachmentAPublishedReportNamesIsCopiedInAndOnlyItsExactBytes(t *testing.T) {
	f := newReportFixture(t)
	digest, path := f.attachment(officereport.RoleWorkOrder)
	if f.inbox.publishAttachment(digest, path) == nil {
		t.Fatal("an attachment was published before any report named it")
	}
	if _, err := f.inbox.publishReport(f.payload, f.signature, f.record, f.manifest); err != nil {
		t.Fatal(err)
	}
	wrong := filepath.Join(t.TempDir(), "wrong")
	_ = os.WriteFile(wrong, []byte("Avenkin public fixture work order v2"), 0600) // the same size, other bytes
	short := filepath.Join(t.TempDir(), "short")
	_ = os.WriteFile(short, []byte("too short"), 0600)
	link := filepath.Join(t.TempDir(), "link")
	_ = os.Symlink(path, link)
	for name, c := range map[string][2]string{
		"other bytes of the same size": {digest, wrong},
		"another size":                 {digest, short},
		"a link":                       {digest, link},
		"no file":                      {digest, filepath.Join(t.TempDir(), "missing")},
		"a digest no report names":     {strings.Repeat("0", 64), path},
		"a name that is a path":        {"../" + digest, path},
	} {
		if f.inbox.publishAttachment(c[0], c[1]) == nil {
			t.Fatalf("%s: published", name)
		}
	}
	if f.inRecords(attachmentName(digest)) || f.inbox.outbound(attachmentName(digest)) {
		t.Fatal("something was published")
	}
	staged, _ := os.ReadDir(f.inbox.private)
	for _, e := range staged {
		if strings.HasPrefix(e.Name(), ".avenkin-attachment-") {
			t.Fatal("a staged attachment was left behind")
		}
	}
	if err := f.inbox.publishAttachment(digest, path); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(f.inbox.recordsPath(attachmentName(digest)))
	if string(got) != fixtureAttachmentBytes[officereport.RoleWorkOrder] || !f.inbox.outbound(attachmentName(digest)) {
		t.Fatal("the attachment is not published as its exact bytes")
	}
	// Again changes nothing, even with the source gone; the others are still not served.
	_ = os.Remove(path)
	if err := f.inbox.publishAttachment(digest, path); err != nil {
		t.Fatal(err)
	}
	photo, _ := f.attachment(officereport.RolePhoto)
	if f.inbox.outbound(attachmentName(photo)) {
		t.Fatal("an attachment that was never published would be served")
	}
}

func TestOnlyTheOfficesReceiptsForAPublishedReportAreListedUnderTheirOwnNames(t *testing.T) {
	f := newReportFixture(t)
	id := f.report.ReportID
	put := func(stage string, data []byte) { f.put("receipts/"+id+"."+stage+envelopeSuffix, data) }
	receipts := func() []pendingReceipt {
		t.Helper()
		out, err := f.inbox.reportReceipts()
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	// A receipt for a report this phone has not published is not listed.
	put("full", f.files["office-report-receipt-full-v1.json"])
	if len(receipts()) != 0 {
		t.Fatal("a receipt was listed with no report published")
	}
	if _, err := f.inbox.publishReport(f.payload, f.signature, f.record, f.manifest); err != nil {
		t.Fatal(err)
	}
	put("pending", f.files["office-report-receipt-pending-v1.json"])
	put("record", f.files["office-report-receipt-record-v1.json"])
	got := receipts()
	if len(got) != 3 || got[0].Stage != "pending" || got[1].Stage != "record" || got[2].Stage != "full" || got[0].ReportID != id {
		t.Fatalf("%+v", got)
	}
	for n, name := range []string{"pending", "record", "full"} {
		raw, _ := base64.StdEncoding.DecodeString(got[n].Envelope)
		if string(raw) != string(f.files["office-report-receipt-"+name+"-v1.json"]) {
			t.Fatalf("%s was not listed as its exact bytes", name)
		}
	}
	// Under another outcome's name, signed by the phone, or for another report's bytes.
	full, err := officereport.ReadReceipt(string(f.files["office-report-receipt-full-v1.json"]), f.office.Public().(ed25519.PublicKey),
		string(f.files["office-report-v1.json"]), f.report, f.list)
	if err != nil {
		t.Fatal(err)
	}
	byPhone, _ := officereport.SignReceiptWith(full, func(m []byte) []byte { return ed25519.Sign(f.phone, m) })
	other := full
	other.ReportSHA256 = strings.Repeat("0", 64)
	forOther, _ := officereport.SignReceipt(other, f.office)
	for name, c := range map[string][2]string{
		"a full receipt under the pending name": {"pending", string(f.files["office-report-receipt-full-v1.json"])},
		"signed by the phone":                   {"full", byPhone},
		"for another report's bytes":            {"full", forOther},
		"not json":                              {"full", "receipt"},
	} {
		g := newReportFixture(t)
		if _, err = g.inbox.publishReport(g.payload, g.signature, g.record, g.manifest); err != nil {
			t.Fatal(err)
		}
		g.put("receipts/"+id+"."+c[0]+envelopeSuffix, []byte(c[1]))
		if out, _ := g.inbox.reportReceipts(); len(out) != 0 {
			t.Fatalf("%s: listed", name)
		}
	}
	// Names the contract gives no place are not opened.
	f.put("receipts/"+id+".envelope.json", f.files["office-report-receipt-full-v1.json"])
	f.put("receipts/"+strings.Repeat("0", 64)+".full.envelope.json", f.files["office-report-receipt-full-v1.json"])
	if len(receipts()) != 3 {
		t.Fatal("a receipt under another name was listed")
	}
}

func TestWithdrawingAReportTakesItsFilesOutUnlessAnotherReportStillNamesThem(t *testing.T) {
	f := newReportFixture(t)
	if _, err := f.inbox.publishReport(f.payload, f.signature, f.record, f.manifest); err != nil {
		t.Fatal(err)
	}
	order, orderPath := f.attachment(officereport.RoleWorkOrder)
	photo, photoPath := f.attachment(officereport.RolePhoto)
	for digest, path := range map[string]string{order: orderPath, photo: photoPath} {
		if err := f.inbox.publishAttachment(digest, path); err != nil {
			t.Fatal(err)
		}
	}
	// A later revision of the same record: other bytes, the same work order, no photograph.
	record := []byte(strings.Replace(string(f.record), `"tasks":[]`, `"tasks":[],"debriefs":[]`, 1))
	var kept []officereport.Attachment
	for _, a := range f.list.Attachments {
		if a.Role != officereport.RolePhoto {
			kept = append(kept, a)
		}
	}
	manifest, err := officereport.ManifestBytes(officereport.ManifestFor(kept))
	if err != nil {
		t.Fatal(err)
	}
	later := f.report
	later.OperationID, later.RecordKind, later.Revision = "0E984725-C51C-4BF4-9960-E1C80E27ABA0", officereport.RecordAddendum, 2
	later = officereport.ReportFor(later, record, manifest)
	laterPayload, err := officereport.ReportPayload(later)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.inbox.publishReport(laterPayload, ed25519.Sign(f.phone, officereport.SigningInput(officereport.ReportDomain, laterPayload)), record, manifest); err != nil {
		t.Fatal(err)
	}
	// What the first report already published is the second's too.
	if !f.inbox.report(later.ReportID).Published[order] {
		t.Fatal("an attachment already in records was not counted for the later report")
	}
	if err = f.inbox.withdrawReport(f.report.ReportID); err != nil {
		t.Fatal(err)
	}
	for _, gone := range []string{reportName(f.report.ReportID), recordName(f.report.RecordSHA256), manifestName(f.report.ManifestSHA256), attachmentName(photo)} {
		if f.inRecords(gone) || f.inbox.outbound(gone) {
			t.Fatalf("%s is still in records after its report was withdrawn", gone)
		}
	}
	for _, stays := range []string{reportName(later.ReportID), recordName(later.RecordSHA256), manifestName(later.ManifestSHA256), attachmentName(order)} {
		if !f.inRecords(stays) || !f.inbox.outbound(stays) {
			t.Fatalf("%s was taken out though a published report names it", stays)
		}
	}
	// Withdrawing again, or one that was never there, changes nothing.
	if err = f.inbox.withdrawReport(f.report.ReportID); err != nil || f.inbox.reportCount() != 1 {
		t.Fatal(err)
	}
	if err = f.inbox.withdrawReport(later.ReportID); err != nil || f.inbox.reportCount() != 0 || f.inRecords(attachmentName(order)) {
		t.Fatalf("the last report's files were not taken out: %v", err)
	}
	// Committed jobs and check-in are untouched by any of it.
	if f.inbox.outbound(reportName(later.ReportID)) || f.inbox.outbound("receipts/"+messageID(1)+envelopeSuffix) {
		t.Fatal("something is still served")
	}
}

func TestTheNumberOfReportsWaitingIsBounded(t *testing.T) {
	f := newReportFixture(t)
	for n := 0; n <= maximumReportsPublished; n++ {
		r := f.report
		r.OperationID = "operation-" + strings.Repeat("0", 3-len(itoa(n))) + itoa(n)
		r = officereport.ReportFor(r, f.record, f.manifest)
		payload, err := officereport.ReportPayload(r)
		if err != nil {
			t.Fatal(err)
		}
		_, err = f.inbox.publishReport(payload, ed25519.Sign(f.phone, officereport.SigningInput(officereport.ReportDomain, payload)), f.record, f.manifest)
		if (err == nil) != (n < maximumReportsPublished) {
			t.Fatalf("report %d: %v", n, err)
		}
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	out := ""
	for ; n > 0; n /= 10 {
		out = string(rune('0'+n%10)) + out
	}
	return out
}
