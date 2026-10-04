package officereport

import (
	"crypto/ed25519"
	"crypto/sha256"

	"github.com/syncthing/syncthing/lib/protocol"
)

// FixtureNow is the clock every report fixture is made at.
const FixtureNow = int64(1800000000)

func fixtureKey(label string) ed25519.PrivateKey {
	seed := sha256.Sum256([]byte(label))
	return ed25519.NewKeyFromSeed(seed[:])
}

// FixtureRecord is the fictional record body the golden report names. It stands in for a work
// record: the contract treats a record as opaque bytes.
const FixtureRecord = `{"job_reference":"JOB-1042","session_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","tasks":[]}` + "\n"

// fixtureAttachment is an attachment whose bytes are a public sentence: only its digest and
// size travel in the fixtures.
func fixtureAttachment(content, role, mediaType, name, requirement, audience string) Attachment {
	return Attachment{Digest([]byte(content)), int64(len(content)), role, mediaType, name, requirement, audience}
}

// Fixtures returns the public golden fixtures of the report contract, by file name: one report
// with its record and manifest, and the three receipts the office can give it. The office and
// phone keys are the check-in fixtures' own, derived from public labels, and have no authority.
// committed is, for each receipt, the attachment roles the office holds.
func Fixtures() (map[string][]byte, error) {
	office := fixtureKey("Avenkin public fixture office key v1")
	phone := fixtureKey("Avenkin public fixture phone key v1")
	phoneTransport := protocol.NewDeviceID([]byte("fixture-phone-transport")).String()

	manifest, e := ManifestBytes(ManifestFor([]Attachment{
		fixtureAttachment("Avenkin public fixture work order v1", RoleWorkOrder, "application/pdf", "job-JOB-1042.pdf", Required, AudienceCustomer),
		fixtureAttachment("Avenkin public fixture transcript v1", RoleTranscript, "application/pdf", "job-JOB-1042-transcript.pdf", Required, AudienceOffice),
		fixtureAttachment("Avenkin public fixture photo v1", RolePhoto, "image/jpeg", "2027-01-15T08-00-00Z_a1b2c3d4.jpg", Optional, AudienceCustomer),
	}))
	if e != nil {
		return nil, e
	}
	report := ReportFor(Report{OperationID: "7C9E6679-7425-40DE-944B-E07FC1F90AE7", RecordKind: RecordWorkRecord,
		RecordID: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", Revision: 1,
		OrganizationID: "fixture-organisation", EnrolmentID: "fixture-enrolment", OfficeID: OfficeID(office.Public().(ed25519.PublicKey)),
		PhoneTransportID: phoneTransport, JobReference: "JOB-1042", JobID: "job-2031", JobRevision: 2, Transcript: TranscriptAttached, CreatedAt: FixtureNow},
		[]byte(FixtureRecord), manifest)
	envelope, e := SignReport(report, phone)
	if e != nil {
		return nil, e
	}
	m, e := report.Carries([]byte(FixtureRecord), manifest)
	if e != nil {
		return nil, e
	}
	out := map[string][]byte{
		"office-report-v1.json":          []byte(envelope),
		"office-report-record-v1.json":   []byte(FixtureRecord),
		"office-report-manifest-v1.json": manifest,
	}
	// What the office holds at each step: nothing yet, then every required attachment, then all.
	for stage, held := range map[string]map[string]bool{
		"pending": {},
		"record":  {RoleWorkOrder: true, RoleTranscript: true},
		"full":    {RoleWorkOrder: true, RoleTranscript: true, RolePhoto: true},
	} {
		committed := func(digest string) bool {
			for _, a := range m.Attachments {
				if a.SHA256 == digest {
					return held[a.Role]
				}
			}
			return false
		}
		receipt, e := SignReceipt(ReceiptFor(envelope, report, m, committed, FixtureNow+120), office)
		if e != nil {
			return nil, e
		}
		out["office-report-receipt-"+stage+"-v1.json"] = []byte(receipt)
	}
	return out, nil
}
