package officereport

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

type world struct {
	office, phone ed25519.PrivateKey
	trust         Trust
	envelope      string
	report        Report
	record        []byte
	manifestRaw   []byte
	manifest      Manifest
	receipts      map[string]string
}

func fixtureWorld(t *testing.T) world {
	t.Helper()
	made := must(Fixtures())
	w := world{office: fixtureKey("Avenkin public fixture office key v1"), phone: fixtureKey("Avenkin public fixture phone key v1"),
		envelope: string(made["office-report-v1.json"]), record: made["office-report-record-v1.json"],
		manifestRaw: made["office-report-manifest-v1.json"], receipts: map[string]string{}}
	for _, stage := range []string{"pending", "record", "full"} {
		w.receipts[stage] = string(made["office-report-receipt-"+stage+"-v1.json"])
	}
	var e envelope
	_ = json.Unmarshal([]byte(w.envelope), &e)
	payload, _ := base64.StdEncoding.DecodeString(e.Payload)
	var named Report
	_ = json.Unmarshal(payload, &named)
	w.trust = Trust{named.OrganizationID, named.EnrolmentID, OfficeID(w.office.Public().(ed25519.PublicKey)), named.PhoneTransportID, w.phone.Public().(ed25519.PublicKey)}
	w.report = must(ReadReport(w.envelope, w.trust))
	w.manifest = must(w.report.Carries(w.record, w.manifestRaw))
	return w
}

func refused(t *testing.T, name string, e error, want error) {
	t.Helper()
	if e == nil || !errors.Is(e, want) {
		t.Fatalf("%s: got %v, want %v", name, e, want)
	}
}

// The checked-in fixtures are exactly what Fixtures makes. Run with REPORT_WRITE_FIXTURES=1 to
// write them.
func TestTheGoldenFixturesAreCurrentAndReadBack(t *testing.T) {
	made := must(Fixtures())
	root := filepath.Join("..", "..", "..", "Contracts", "fixtures")
	for name, want := range made {
		path := filepath.Join(root, name)
		if os.Getenv("REPORT_WRITE_FIXTURES") == "1" {
			if e := os.WriteFile(path, want, 0644); e != nil {
				t.Fatal(e)
			}
		}
		got, e := os.ReadFile(path)
		if e != nil {
			t.Fatalf("%s: %v", name, e)
		}
		if string(got) != string(want) {
			t.Fatalf("%s is not what Fixtures makes; regenerate with REPORT_WRITE_FIXTURES=1", name)
		}
	}
	w := fixtureWorld(t)
	if w.report.RecordKind != RecordWorkRecord || w.report.Revision != 1 || w.report.ReportID != ReportID(w.report.OperationID) || len(w.manifest.Attachments) != 3 {
		t.Fatalf("the report did not read back: %+v", w.report)
	}
	officeKey := w.office.Public().(ed25519.PublicKey)
	for stage, want := range map[string][3]any{
		"pending": {OutcomeEvidencePending, int64(0), int64(3)},
		"record":  {OutcomeRecordAccepted, int64(2), int64(1)},
		"full":    {OutcomeFullyAccepted, int64(3), int64(0)},
	} {
		r := must(ReadReceipt(w.receipts[stage], officeKey, w.envelope, w.report, w.manifest))
		if r.Outcome != want[0] || r.AttachmentsCommitted != want[1] || r.AttachmentsOutstanding != want[2] || Stage(r.Outcome) != stage {
			t.Fatalf("%s: %+v", stage, r)
		}
	}
}

func TestTheTwoStepReportIsTheOneStepReport(t *testing.T) {
	w := fixtureWorld(t)
	payload := must(ReportPayload(w.report))
	sealed := must(SealReport(payload, ed25519.Sign(w.phone, SigningInput(ReportDomain, payload))))
	if sealed != w.envelope {
		t.Fatal("signing in two steps gives another report")
	}
	if _, e := SealReport([]byte(`{"version":1}`), make([]byte, 64)); e == nil {
		t.Fatal("a payload that is not a report was sealed")
	}
}

func TestAnOfficeReadsOnlyAReportFromThePhoneItsBindingNames(t *testing.T) {
	w := fixtureWorld(t)
	resign := func(change func(*Report), key ed25519.PrivateKey) string {
		r := w.report
		change(&r)
		payload, _ := json.Marshal(r)
		return must(seal(payload, ed25519.Sign(key, SigningInput(ReportDomain, payload)), MaximumReport))
	}
	_, e := ReadReport(resign(func(*Report) {}, w.office), w.trust)
	refused(t, "signed by the office application key", e, ErrSignature)
	payload := must(ReportPayload(w.report))
	_, e = ReadReport(must(seal(payload, ed25519.Sign(w.phone, SigningInput(ReceiptDomain, payload)), MaximumReport)), w.trust)
	refused(t, "under the receipt's domain", e, ErrSignature)
	for name, change := range map[string]func(*Report){
		"another organisation": func(r *Report) { r.OrganizationID = "another-organisation" },
		"another enrolment":    func(r *Report) { r.EnrolmentID = "another-enrolment" },
		"another office":       func(r *Report) { r.OfficeID = "office-000000000000000000000000" },
		"another phone": func(r *Report) {
			r.PhoneTransportID = "DQB4YVC-VNAIUQE-UNBOI3L-YIZRPME-WG6DM7S-GSGGKBY-BGA7SBN-Q2OHOAZ"
		},
	} {
		_, e = ReadReport(resign(change, w.phone), w.trust)
		refused(t, name, e, ErrOther)
	}
	for name, change := range map[string]func(*Report){
		"an identifier that is not the operation's digest": func(r *Report) { r.ReportID = strings.Repeat("0", 64) },
		"a record kind v1 does not have":                   func(r *Report) { r.RecordKind = "photoUpload" },
		"revision zero":                                    func(r *Report) { r.Revision = 0 },
		"an empty record":                                  func(r *Report) { r.RecordBytes = 0 },
		"a record over the cap":                            func(r *Report) { r.RecordBytes = MaximumRecord + 1 },
		"a transcript state v1 does not have":              func(r *Report) { r.Transcript = "customer" },
		"a job reference that needs an escape":             func(r *Report) { r.JobReference = `JOB "1042"` },
		"an operation that is a path":                      func(r *Report) { r.OperationID = ".."; r.ReportID = ReportID("..") },
	} {
		_, e = ReadReport(resign(change, w.phone), w.trust)
		refused(t, name, e, ErrFields)
	}
	// Closed objects: extra, missing, duplicate, nested and fractional members, and trailing data.
	text := string(payload)
	for name, changed := range map[string]string{
		"an extra member":     strings.Replace(text, `{"version":1,`, `{"version":1,"generation":1,`, 1),
		"a missing member":    strings.Replace(text, `"revision":1,`, ``, 1),
		"a duplicate member":  strings.Replace(text, `{"version":1,`, `{"version":1,"version":1,`, 1),
		"a nested value":      strings.Replace(text, `"revision":1,`, `"revision":{"n":1},`, 1),
		"a fractional number": strings.Replace(text, `"revision":1,`, `"revision":1.0,`, 1),
		"trailing data":       text + "{}",
	} {
		if changed == text {
			t.Fatalf("%s: the payload was not changed", name)
		}
		_, e = ReadReport(must(seal([]byte(changed), ed25519.Sign(w.phone, SigningInput(ReportDomain, []byte(changed))), MaximumReport)), w.trust)
		refused(t, name, e, ErrMalformed)
	}
}

func TestARecordOrManifestThatIsNotTheOneNamedIsRefused(t *testing.T) {
	w := fixtureWorld(t)
	_, e := w.report.Carries(append([]byte{}, w.record[:len(w.record)-1]...), w.manifestRaw)
	refused(t, "a truncated record", e, ErrContent)
	_, e = w.report.Carries([]byte(strings.Replace(string(w.record), "1042", "1043", 1)), w.manifestRaw)
	refused(t, "a changed record", e, ErrContent)
	_, e = w.report.Carries(w.record, []byte(strings.Replace(string(w.manifestRaw), "required", "optional", 1)))
	refused(t, "a changed manifest", e, ErrContent)

	// A manifest must be the canonical bytes of a valid manifest.
	good := string(w.manifestRaw)
	for name, changed := range map[string]string{
		"whitespace":              strings.Replace(good, `{"version":1,`, `{ "version":1,`, 1),
		"an extra member":         strings.Replace(good, `{"version":1,`, `{"version":1,"note":"x",`, 1),
		"a duplicate member":      strings.Replace(good, `{"version":1,`, `{"version":1,"version":1,`, 1),
		"members out of order":    strings.Replace(good, `{"version":1,"kind":"avenkin.office-report-manifest",`, `{"kind":"avenkin.office-report-manifest","version":1,`, 1),
		"no attachment list":      `{"version":1,"kind":"avenkin.office-report-manifest","attachments":null}`,
		"an escaped character":    strings.Replace(good, `job-JOB-1042.pdf`, "job-JOB"+string(rune(92))+"u002d1042.pdf", 1),
		"a name that is a path":   strings.Replace(good, `job-JOB-1042.pdf`, `../JOB-1042.pdf`, 1),
		"a hidden name":           strings.Replace(good, `job-JOB-1042.pdf`, `.job-JOB-1042.pdf`, 1),
		"a media type not listed": strings.Replace(good, `image/jpeg`, `text/html`, 1),
		"a role not listed":       strings.Replace(good, `"role":"photo"`, `"role":"manual"`, 1),
		"an empty attachment":     strings.Replace(good, `"bytes":31,`, `"bytes":0,`, 1),
		"a transcript for the customer": strings.Replace(good, `"role":"transcript","mediaType":"application/pdf","name":"job-JOB-1042-transcript.pdf","requirement":"required","audience":"office"`,
			`"role":"transcript","mediaType":"application/pdf","name":"job-JOB-1042-transcript.pdf","requirement":"required","audience":"customer"`, 1),
	} {
		if changed == good {
			t.Fatalf("%s: the manifest was not changed", name)
		}
		if _, e = ReadManifest([]byte(changed)); e == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
	// The same digest twice, or digests out of order.
	twice := w.manifest
	twice.Attachments = append(append([]Attachment{}, twice.Attachments...), twice.Attachments[0])
	if _, e = ManifestBytes(twice); e == nil {
		t.Fatal("a manifest naming one digest twice was written")
	}
	reversed := Manifest{1, ManifestKind, []Attachment{w.manifest.Attachments[1], w.manifest.Attachments[0]}}
	if _, e = ManifestBytes(reversed); e == nil {
		t.Fatal("a manifest out of digest order was written")
	}
	// The transcript is where the report says it is.
	without := ManifestFor([]Attachment{w.manifest.Attachments[0]})
	if without.has(RoleTranscript) {
		without = ManifestFor([]Attachment{w.manifest.Attachments[1]})
	}
	if without.has(RoleTranscript) {
		without = ManifestFor([]Attachment{w.manifest.Attachments[2]})
	}
	raw := must(ManifestBytes(without))
	claims := ReportFor(w.report, w.record, raw)
	_, e = claims.Carries(w.record, raw)
	refused(t, "a report that says attached with no transcript in the manifest", e, ErrContent)
	claims.Transcript = TranscriptOmitted
	if _, e = claims.Carries(w.record, raw); e != nil {
		t.Fatal(e)
	}
	omitted := ReportFor(w.report, w.record, w.manifestRaw)
	omitted.Transcript = TranscriptOmitted
	_, e = omitted.Carries(w.record, w.manifestRaw)
	refused(t, "a report that says omitted with a transcript in the manifest", e, ErrContent)
	// A report with no evidence still names a manifest: the empty one.
	empty := must(ManifestBytes(ManifestFor(nil)))
	if string(empty) != `{"version":1,"kind":"avenkin.office-report-manifest","attachments":[]}` {
		t.Fatalf("%s", empty)
	}
}

func TestTheOutcomeFollowsWhatIsCommitted(t *testing.T) {
	w := fixtureWorld(t)
	held := map[string]bool{}
	committed := func(d string) bool { return held[d] }
	role := func(r string) string {
		for _, a := range w.manifest.Attachments {
			if a.Role == r {
				return a.SHA256
			}
		}
		t.Fatal(r)
		return ""
	}
	check := func(want string, done, out int64) {
		t.Helper()
		if got, d, o := Outcome(w.manifest, committed); got != want || d != done || o != out {
			t.Fatalf("got %s %d %d, want %s %d %d", got, d, o, want, done, out)
		}
	}
	check(OutcomeEvidencePending, 0, 3)
	held[role(RolePhoto)] = true // an optional one alone does not make the record accepted
	check(OutcomeEvidencePending, 1, 2)
	held[role(RoleWorkOrder)] = true
	check(OutcomeEvidencePending, 2, 1)
	delete(held, role(RolePhoto))
	held[role(RoleTranscript)] = true
	check(OutcomeRecordAccepted, 2, 1)
	held[role(RolePhoto)] = true
	check(OutcomeFullyAccepted, 3, 0)
	// A report with no evidence is fully accepted as soon as its record is.
	if got, _, _ := Outcome(ManifestFor(nil), committed); got != OutcomeFullyAccepted {
		t.Fatal(got)
	}
}

func TestAPhoneAcceptsOnlyTheOfficesReceiptForExactlyTheReportItPublished(t *testing.T) {
	w := fixtureWorld(t)
	officeKey := w.office.Public().(ed25519.PublicKey)
	full := must(ReadReceipt(w.receipts["full"], officeKey, w.envelope, w.report, w.manifest))
	resign := func(change func(*Receipt), key ed25519.PrivateKey) string {
		r := full
		change(&r)
		payload, _ := json.Marshal(r)
		return must(seal(payload, ed25519.Sign(key, SigningInput(ReceiptDomain, payload)), MaximumReceipt))
	}
	_, e := ReadReceipt(resign(func(*Receipt) {}, w.phone), officeKey, w.envelope, w.report, w.manifest)
	refused(t, "signed by the phone application key", e, ErrSignature)
	payload, _ := json.Marshal(full)
	_, e = ReadReceipt(must(seal(payload, ed25519.Sign(w.office, SigningInput(ReportDomain, payload)), MaximumReceipt)), officeKey, w.envelope, w.report, w.manifest)
	refused(t, "under the report's domain", e, ErrSignature)
	if _, e = SignReceipt(full, w.phone); e == nil {
		t.Fatal("a receipt was signed by a key that is not that office's")
	}
	for name, change := range map[string]func(*Receipt){
		"another report":         func(r *Receipt) { r.ReportID = strings.Repeat("0", 64) },
		"another report's bytes": func(r *Receipt) { r.ReportSHA256 = strings.Repeat("0", 64) },
		"another record":         func(r *Receipt) { r.RecordSHA256 = strings.Repeat("0", 64) },
		"another manifest":       func(r *Receipt) { r.ManifestSHA256 = strings.Repeat("0", 64) },
		"another enrolment":      func(r *Receipt) { r.EnrolmentID = "another-enrolment" },
		"another phone": func(r *Receipt) {
			r.PhoneTransportID = "DQB4YVC-VNAIUQE-UNBOI3L-YIZRPME-WG6DM7S-GSGGKBY-BGA7SBN-Q2OHOAZ"
		},
		"another organisation":     func(r *Receipt) { r.OrganizationID = "another-organisation" },
		"another office's wording": func(r *Receipt) { r.OfficeID = "office-000000000000000000000000" },
	} {
		_, e = ReadReceipt(resign(change, w.office), officeKey, w.envelope, w.report, w.manifest)
		refused(t, name, e, ErrOther)
	}
	// A republished report has the same bytes, so the same receipt still fits; a later revision
	// is another report and the receipt does not.
	later := w.report
	later.Revision, later.OperationID = 2, "0E984725-C51C-4BF4-9960-E1C80E27ABA0"
	later.ReportID = ReportID(later.OperationID)
	laterEnvelope := must(SignReport(later, w.phone))
	_, e = ReadReceipt(w.receipts["full"], officeKey, laterEnvelope, later, w.manifest)
	refused(t, "a receipt for the revision before", e, ErrOther)
	for name, change := range map[string]func(*Receipt){
		"fully accepted with something outstanding": func(r *Receipt) { r.AttachmentsCommitted, r.AttachmentsOutstanding = 2, 1 },
		"pending with nothing outstanding":          func(r *Receipt) { r.Outcome = OutcomeEvidencePending },
		"counts that are not the manifest's":        func(r *Receipt) { r.AttachmentsCommitted = 2 },
		"record accepted with a required one out": func(r *Receipt) {
			r.Outcome, r.AttachmentsCommitted, r.AttachmentsOutstanding = OutcomeRecordAccepted, 1, 2
		},
		"an outcome v1 does not have": func(r *Receipt) { r.Outcome = "refused" },
		"a negative count":            func(r *Receipt) { r.AttachmentsCommitted, r.AttachmentsOutstanding = 4, -1 },
	} {
		_, e = ReadReceipt(resign(change, w.office), officeKey, w.envelope, w.report, w.manifest)
		refused(t, name, e, ErrFields)
	}
	// Evidence pending needs a required attachment to be pending on.
	optional := w.manifest
	optional.Attachments = append([]Attachment{}, optional.Attachments...)
	for i := range optional.Attachments {
		optional.Attachments[i].Requirement = Optional
	}
	pending := resign(func(r *Receipt) {
		r.Outcome, r.AttachmentsCommitted, r.AttachmentsOutstanding = OutcomeEvidencePending, 0, 3
	}, w.office)
	_, e = ReadReceipt(pending, officeKey, w.envelope, w.report, optional)
	refused(t, "evidence pending with nothing required", e, ErrFields)
}
