// Package officereport is the reference implementation of the office report contract
// (Contracts/office-reports.md): the signed report a phone publishes for one queued record, the
// record body and attachment manifest it names by digest, and the office's signed receipts.
//
// It is messages only. It opens no connection, stores nothing and holds no key: callers pass
// the key that signs, the key that must have signed, and the clock. What is durable — which
// revision of a record is current, which attachments were committed — belongs to the caller.
package officereport

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"

	"avenkin.dev/mobilecore/officepreview"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	ReportDomain  = "Avenkin.OfficeReport.v1"
	ReceiptDomain = "Avenkin.OfficeReportReceipt.v1"

	ReportKind   = "avenkin.office-report"
	ManifestKind = "avenkin.office-report-manifest"
	ReceiptKind  = "avenkin.office-report-receipt"

	// What a report carries.
	RecordWorkRecord   = "workRecord"
	RecordPartsRequest = "partsRequest"
	RecordAddendum     = "addendum"

	// Where the transcript is.
	TranscriptAttached = "attached"
	TranscriptOmitted  = "omitted"
	TranscriptNone     = "none"

	RoleWorkOrder   = "workOrder"
	RoleAuditExport = "auditExport"
	RoleTranscript  = "transcript"
	RolePhoto       = "photo"
	RoleClip        = "clip"
	RoleClipPoster  = "clipPoster"
	RoleSignature   = "signature"
	RoleAddendum    = "addendum"

	Required = "required"
	Optional = "optional"

	AudienceOffice   = "office"
	AudienceCustomer = "customer"

	// The receipt's outcomes, in the order they can follow each other.
	OutcomeEvidencePending = "evidencePending"
	OutcomeRecordAccepted  = "recordAccepted"
	OutcomeFullyAccepted   = "fullyAccepted"

	MaximumReport      = 8192
	MaximumReceipt     = 8192
	MaximumRecord      = 1 << 20
	MaximumManifest    = 131072
	MaximumAttachments = 256
	// MaximumIssueSkew is how far ahead of the signer's clock a receipt's receivedAt may be.
	MaximumIssueSkew = 300

	maximumSafeInteger = int64(9007199254740991)
)

var (
	ErrMalformed = errors.New("malformed office report message")
	ErrSignature = errors.New("office report message is not signed by the key it must be")
	ErrFields    = errors.New("invalid office report message fields")
	ErrOther     = errors.New("office report message is for another binding or report")
	ErrContent   = errors.New("the record or manifest is not the one the report names")
	ErrTime      = errors.New("office report receipt is dated too far ahead of the clock")
)

// Report is the phone's signed statement that one record, at one revision, is exactly these
// bytes with exactly this evidence. It is flat: the record body and the manifest are separate
// files it names by digest.
type Report struct {
	Version          int    `json:"version"`
	Kind             string `json:"kind"`
	ReportID         string `json:"reportID"`
	OperationID      string `json:"operationID"`
	RecordKind       string `json:"recordKind"`
	RecordID         string `json:"recordID"`
	Revision         int64  `json:"revision"`
	OrganizationID   string `json:"organizationID"`
	EnrolmentID      string `json:"enrolmentID"`
	OfficeID         string `json:"officeID"`
	PhoneTransportID string `json:"phoneTransportID"`
	JobReference     string `json:"jobReference"`
	// JobID and JobRevision are the office's own identifier and revision of the job the record
	// was written against, from a format-2 job file; empty and 0 for any other job.
	JobID          string `json:"jobID"`
	JobRevision    int64  `json:"jobRevision"`
	RecordSHA256   string `json:"recordSHA256"`
	RecordBytes    int64  `json:"recordBytes"`
	ManifestSHA256 string `json:"manifestSHA256"`
	ManifestBytes  int64  `json:"manifestBytes"`
	Transcript     string `json:"transcript"`
	CreatedAt      int64  `json:"createdAt"`
}

// Attachment is one piece of evidence a report names.
type Attachment struct {
	SHA256      string `json:"sha256"`
	Bytes       int64  `json:"bytes"`
	Role        string `json:"role"`
	MediaType   string `json:"mediaType"`
	Name        string `json:"name"`
	Requirement string `json:"requirement"`
	Audience    string `json:"audience"`
}

// Manifest lists a report's evidence. Its bytes are canonical: exactly what ManifestBytes
// writes, so the digest a report names has one spelling.
type Manifest struct {
	Version     int          `json:"version"`
	Kind        string       `json:"kind"`
	Attachments []Attachment `json:"attachments"`
}

// Receipt is the office's signed statement of how much of one report it has committed.
type Receipt struct {
	Version                int    `json:"version"`
	Kind                   string `json:"kind"`
	ReportID               string `json:"reportID"`
	ReportSHA256           string `json:"reportSHA256"`
	RecordSHA256           string `json:"recordSHA256"`
	ManifestSHA256         string `json:"manifestSHA256"`
	OrganizationID         string `json:"organizationID"`
	EnrolmentID            string `json:"enrolmentID"`
	OfficeID               string `json:"officeID"`
	PhoneTransportID       string `json:"phoneTransportID"`
	Outcome                string `json:"outcome"`
	AttachmentsCommitted   int64  `json:"attachmentsCommitted"`
	AttachmentsOutstanding int64  `json:"attachmentsOutstanding"`
	ReceivedAt             int64  `json:"receivedAt"`
}

var reportFields = []string{"version", "kind", "reportID", "operationID", "recordKind", "recordID", "revision", "organizationID", "enrolmentID", "officeID", "phoneTransportID", "jobReference", "jobID", "jobRevision", "recordSHA256", "recordBytes", "manifestSHA256", "manifestBytes", "transcript", "createdAt"}
var receiptFields = []string{"version", "kind", "reportID", "reportSHA256", "recordSHA256", "manifestSHA256", "organizationID", "enrolmentID", "officeID", "phoneTransportID", "outcome", "attachmentsCommitted", "attachmentsOutstanding", "receivedAt"}

var mediaTypes = map[string]bool{"application/pdf": true, "application/json": true, "image/jpeg": true, "image/png": true, "video/mp4": true, "video/quicktime": true}
var roles = map[string]bool{RoleWorkOrder: true, RoleAuditExport: true, RoleTranscript: true, RolePhoto: true, RoleClip: true, RoleClipPoster: true, RoleSignature: true, RoleAddendum: true}

type envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

// Digest is the lower-case hex SHA-256 of exact bytes: an envelope's message digest, or a
// record's, a manifest's or an attachment's digest.
func Digest(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// ReportID is the identifier in a report's file name: the digest of its operation identifier.
func ReportID(operationID string) string { return Digest([]byte(operationID)) }

// OfficeID is the office identifier derived from an office application key, as in the peer
// binding.
func OfficeID(officeApplicationKey ed25519.PublicKey) string {
	sum := sha256.Sum256(officeApplicationKey)
	return "office-" + hex.EncodeToString(sum[:12])
}

// SigningInput is the exact bytes a signature covers: the domain, one zero byte, the payload.
func SigningInput(domain string, payload []byte) []byte {
	return append(append([]byte(domain), 0), payload...)
}

func seal(payload, signature []byte, limit int) (string, error) {
	if len(signature) != ed25519.SignatureSize {
		return "", ErrSignature
	}
	out, e := json.Marshal(envelope{base64.StdEncoding.EncodeToString(payload), base64.StdEncoding.EncodeToString(signature)})
	if e != nil {
		return "", e
	}
	if len(out) > limit {
		return "", ErrMalformed
	}
	return string(out), nil
}

func open(text, domain string, key ed25519.PublicKey, fields []string, limit int) ([]byte, error) {
	if len(text) == 0 || len(text) > limit || !officepreview.Flat([]byte(text), []string{"payload", "signature"}) {
		return nil, ErrMalformed
	}
	var e envelope
	if json.Unmarshal([]byte(text), &e) != nil {
		return nil, ErrMalformed
	}
	payload, err := base64.StdEncoding.Strict().DecodeString(e.Payload)
	if err != nil || base64.StdEncoding.EncodeToString(payload) != e.Payload {
		return nil, ErrMalformed
	}
	signature, err := base64.StdEncoding.Strict().DecodeString(e.Signature)
	if err != nil || len(signature) != ed25519.SignatureSize || base64.StdEncoding.EncodeToString(signature) != e.Signature {
		return nil, ErrMalformed
	}
	if len(key) != ed25519.PublicKeySize || !ed25519.Verify(key, SigningInput(domain, payload), signature) {
		return nil, ErrSignature
	}
	if !officepreview.Flat(payload, fields) {
		return nil, ErrMalformed
	}
	return payload, nil
}

func safeIdentifier(s string) bool {
	if len(s) == 0 || len(s) > 80 || s == "." || s == ".." {
		return false
	}
	for _, c := range []byte(s) {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// fileName is a display name: an identifier of up to 120 characters that does not begin with a
// dot. It is shown to a person and never selects a path.
func fileName(s string) bool {
	if len(s) == 0 || len(s) > 120 || s[0] == '.' {
		return false
	}
	for _, c := range []byte(s) {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func transportID(s string) bool {
	id, e := protocol.DeviceIDFromString(s)
	return e == nil && id != protocol.EmptyDeviceID && id.String() == s
}

func lowerHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, c := range []byte(s) {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// plain is printable ASCII that needs no JSON escape, so it has one spelling.
func plain(s string, max int) bool {
	if len(s) > max {
		return false
	}
	for _, c := range []byte(s) {
		if c < 0x20 || c >= 0x7f || c == '"' || c == '\\' || c == '<' || c == '>' || c == '&' {
			return false
		}
	}
	return true
}

func instant(n int64) bool { return n > 0 && n <= maximumSafeInteger }

// ---------------------------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------------------------

func (r Report) valid() bool {
	return r.Version == 1 && r.Kind == ReportKind && lowerHex(r.ReportID, 64) && safeIdentifier(r.OperationID) &&
		r.ReportID == ReportID(r.OperationID) &&
		(r.RecordKind == RecordWorkRecord || r.RecordKind == RecordPartsRequest || r.RecordKind == RecordAddendum) &&
		safeIdentifier(r.RecordID) && instant(r.Revision) &&
		safeIdentifier(r.OrganizationID) && safeIdentifier(r.EnrolmentID) && safeIdentifier(r.OfficeID) && transportID(r.PhoneTransportID) &&
		plain(r.JobReference, 120) &&
		(r.JobID == "" && r.JobRevision == 0 || safeIdentifier(r.JobID) && instant(r.JobRevision)) &&
		lowerHex(r.RecordSHA256, 64) && r.RecordBytes > 0 && r.RecordBytes <= MaximumRecord &&
		lowerHex(r.ManifestSHA256, 64) && r.ManifestBytes > 0 && r.ManifestBytes <= MaximumManifest &&
		(r.Transcript == TranscriptAttached || r.Transcript == TranscriptOmitted || r.Transcript == TranscriptNone) && instant(r.CreatedAt)
}

// ReportFor fills a report's digests from the exact record and manifest bytes it will name.
func ReportFor(r Report, record, manifest []byte) Report {
	r.Version, r.Kind, r.ReportID = 1, ReportKind, ReportID(r.OperationID)
	r.RecordSHA256, r.RecordBytes = Digest(record), int64(len(record))
	r.ManifestSHA256, r.ManifestBytes = Digest(manifest), int64(len(manifest))
	return r
}

// ReportPayload is the exact bytes a phone signs. The phone application key lives in device-only
// storage outside the transport, so signing is in two steps: these bytes, signed under
// ReportDomain (see SigningInput), then SealReport.
func ReportPayload(r Report) ([]byte, error) {
	if !r.valid() {
		return nil, ErrFields
	}
	return json.Marshal(r)
}

// SealReport wraps a report payload with the signature the phone application key made.
func SealReport(payload, signature []byte) (string, error) {
	var r Report
	if !officepreview.Flat(payload, reportFields) || json.Unmarshal(payload, &r) != nil || !r.valid() {
		return "", ErrMalformed
	}
	return seal(payload, signature, MaximumReport)
}

// SignReport does both steps for a key held in process, which only fixtures, tests and stand-in
// phones have.
func SignReport(r Report, phoneKey ed25519.PrivateKey) (string, error) {
	payload, e := ReportPayload(r)
	if e != nil || len(phoneKey) != ed25519.PrivateKeySize {
		return "", ErrFields
	}
	return seal(payload, ed25519.Sign(phoneKey, SigningInput(ReportDomain, payload)), MaximumReport)
}

// Trust is the binding a report is read against, from the office's own records: never from the
// report.
type Trust struct {
	OrganizationID, EnrolmentID, OfficeID, PhoneTransportID string
	PhoneApplicationKey                                     ed25519.PublicKey
}

// ReadReport is the office's check of a report: signed by the phone application key in the
// binding it holds, and naming that organisation, enrolment, office and transport identity. It
// does not look at the record or the manifest (see Carries), or at whether the revision is the
// latest it has for that record: that is the office's durable state.
func ReadReport(text string, trust Trust) (Report, error) {
	var r Report
	payload, e := open(text, ReportDomain, trust.PhoneApplicationKey, reportFields, MaximumReport)
	if e != nil {
		return r, e
	}
	if json.Unmarshal(payload, &r) != nil {
		return Report{}, ErrMalformed
	}
	if !r.valid() {
		return Report{}, ErrFields
	}
	if r.OrganizationID != trust.OrganizationID || r.EnrolmentID != trust.EnrolmentID || r.OfficeID != trust.OfficeID || r.PhoneTransportID != trust.PhoneTransportID {
		return Report{}, ErrOther
	}
	return r, nil
}

// ---------------------------------------------------------------------------------------------
// Manifest
// ---------------------------------------------------------------------------------------------

func (a Attachment) valid() bool {
	return lowerHex(a.SHA256, 64) && instant(a.Bytes) && roles[a.Role] && mediaTypes[a.MediaType] && fileName(a.Name) &&
		(a.Requirement == Required || a.Requirement == Optional) && (a.Audience == AudienceOffice || a.Audience == AudienceCustomer) &&
		// A transcript is never the customer's.
		(a.Role != RoleTranscript || a.Audience == AudienceOffice)
}

func (m Manifest) valid() bool {
	if m.Version != 1 || m.Kind != ManifestKind || len(m.Attachments) > MaximumAttachments {
		return false
	}
	for i, a := range m.Attachments {
		// Ascending by digest, so each digest appears once and the order has one spelling.
		if !a.valid() || i > 0 && m.Attachments[i-1].SHA256 >= a.SHA256 {
			return false
		}
	}
	return true
}

// ManifestFor puts attachments in the manifest's order.
func ManifestFor(attachments []Attachment) Manifest {
	sorted := append([]Attachment{}, attachments...)
	sort.Slice(sorted, func(a, b int) bool { return sorted[a].SHA256 < sorted[b].SHA256 })
	return Manifest{1, ManifestKind, sorted}
}

// ManifestBytes is the one spelling of a manifest: members in the contract's order, no
// whitespace, and no string that needs an escape.
func ManifestBytes(m Manifest) ([]byte, error) {
	if !m.valid() {
		return nil, ErrFields
	}
	if m.Attachments == nil {
		m.Attachments = []Attachment{}
	}
	out, e := json.Marshal(m)
	if e != nil || len(out) > MaximumManifest {
		return nil, ErrMalformed
	}
	return out, nil
}

// ReadManifest accepts only the canonical bytes of a valid manifest.
func ReadManifest(raw []byte) (Manifest, error) {
	var m Manifest
	if len(raw) == 0 || len(raw) > MaximumManifest || json.Unmarshal(raw, &m) != nil {
		return Manifest{}, ErrMalformed
	}
	canonical, e := ManifestBytes(m)
	if e != nil {
		return Manifest{}, e
	}
	if string(canonical) != string(raw) {
		return Manifest{}, ErrMalformed
	}
	return m, nil
}

func (m Manifest) has(role string) bool {
	for _, a := range m.Attachments {
		if a.Role == role {
			return true
		}
	}
	return false
}

// Carries checks the record body and the manifest against the report that names them: exact
// size and digest, a canonical manifest, and a transcript that is where the report says it is.
func (r Report) Carries(record, manifest []byte) (Manifest, error) {
	if int64(len(record)) != r.RecordBytes || Digest(record) != r.RecordSHA256 ||
		int64(len(manifest)) != r.ManifestBytes || Digest(manifest) != r.ManifestSHA256 {
		return Manifest{}, ErrContent
	}
	m, e := ReadManifest(manifest)
	if e != nil {
		return Manifest{}, e
	}
	if m.has(RoleTranscript) != (r.Transcript == TranscriptAttached) {
		return Manifest{}, ErrContent
	}
	return m, nil
}

// ---------------------------------------------------------------------------------------------
// Receipt
// ---------------------------------------------------------------------------------------------

// Outcome is how much of a report is committed, given which of its attachments are. committed
// answers for an attachment's digest, after its size and digest were checked.
func Outcome(m Manifest, committed func(sha256 string) bool) (outcome string, done, outstanding int64) {
	requiredOutstanding := false
	for _, a := range m.Attachments {
		if committed(a.SHA256) {
			done++
			continue
		}
		outstanding++
		if a.Requirement == Required {
			requiredOutstanding = true
		}
	}
	switch {
	case outstanding == 0:
		return OutcomeFullyAccepted, done, 0
	case requiredOutstanding:
		return OutcomeEvidencePending, done, outstanding
	default:
		return OutcomeRecordAccepted, done, outstanding
	}
}

// Stage is the word in a receipt's file name for its outcome. Each outcome has its own name, so
// a published receipt is never rewritten when a later one follows.
func Stage(outcome string) string {
	switch outcome {
	case OutcomeEvidencePending:
		return "pending"
	case OutcomeRecordAccepted:
		return "record"
	case OutcomeFullyAccepted:
		return "full"
	}
	return ""
}

func (r Receipt) valid() bool {
	return r.Version == 1 && r.Kind == ReceiptKind && lowerHex(r.ReportID, 64) && lowerHex(r.ReportSHA256, 64) &&
		lowerHex(r.RecordSHA256, 64) && lowerHex(r.ManifestSHA256, 64) &&
		safeIdentifier(r.OrganizationID) && safeIdentifier(r.EnrolmentID) && safeIdentifier(r.OfficeID) && transportID(r.PhoneTransportID) &&
		Stage(r.Outcome) != "" && r.AttachmentsCommitted >= 0 && r.AttachmentsOutstanding >= 0 &&
		// Each is bounded before they are added, so a sum that wraps cannot pass.
		r.AttachmentsCommitted <= MaximumAttachments && r.AttachmentsOutstanding <= MaximumAttachments &&
		r.AttachmentsCommitted+r.AttachmentsOutstanding <= MaximumAttachments &&
		(r.Outcome == OutcomeFullyAccepted) == (r.AttachmentsOutstanding == 0) && instant(r.ReceivedAt)
}

// ReceiptFor is the receipt for a report the office has read and whose record and manifest it
// has committed.
func ReceiptFor(reportEnvelope string, r Report, m Manifest, committed func(sha256 string) bool, receivedAt int64) Receipt {
	outcome, done, outstanding := Outcome(m, committed)
	return Receipt{1, ReceiptKind, r.ReportID, Digest([]byte(reportEnvelope)), r.RecordSHA256, r.ManifestSHA256,
		r.OrganizationID, r.EnrolmentID, r.OfficeID, r.PhoneTransportID, outcome, done, outstanding, receivedAt}
}

// SignReceiptWith signs a receipt with the office application key behind sign, which is given
// the exact bytes to sign.
func SignReceiptWith(r Receipt, sign func(message []byte) []byte) (string, error) {
	if !r.valid() || sign == nil {
		return "", ErrFields
	}
	payload, e := json.Marshal(r)
	if e != nil {
		return "", e
	}
	return seal(payload, sign(SigningInput(ReceiptDomain, payload)), MaximumReceipt)
}

// SignReceipt is SignReceiptWith for a key held in process. The receipt must name the office
// the key belongs to.
func SignReceipt(r Receipt, officeKey ed25519.PrivateKey) (string, error) {
	if len(officeKey) != ed25519.PrivateKeySize || r.OfficeID != OfficeID(officeKey.Public().(ed25519.PublicKey)) {
		return "", ErrFields
	}
	return SignReceiptWith(r, func(message []byte) []byte { return ed25519.Sign(officeKey, message) })
}

// SignReceiptPayload signs exact payload bytes the caller built, so nothing is re-encoded
// between an office's record of a receipt and what a phone verifies. It is for a process that
// holds the office application key on behalf of one that does not: the payload is checked as a
// verifier would check it, must name the office the key belongs to, and be dated no later than
// a few minutes from now. Whether the report it answers was read, and how much of it is
// committed, is the caller's record; the key holder does not see the report.
func SignReceiptPayload(payload []byte, officeKey ed25519.PrivateKey, now int64) (string, error) {
	if len(officeKey) != ed25519.PrivateKeySize {
		return "", ErrSignature
	}
	if len(payload) == 0 || len(payload) > MaximumReceipt || !officepreview.Flat(payload, receiptFields) {
		return "", ErrMalformed
	}
	var r Receipt
	if json.Unmarshal(payload, &r) != nil {
		return "", ErrMalformed
	}
	if !r.valid() {
		return "", ErrFields
	}
	if r.OfficeID != OfficeID(officeKey.Public().(ed25519.PublicKey)) {
		return "", ErrOther
	}
	if r.ReceivedAt > now+MaximumIssueSkew {
		return "", ErrTime
	}
	return seal(payload, ed25519.Sign(officeKey, SigningInput(ReceiptDomain, payload)), MaximumReceipt)
}

// ReadReceipt is the phone's check of a receipt: signed by the office application key its
// verified binding names, for exactly the report it published — the envelope's digest, the
// record and the manifest — and with counts that are possible for that manifest.
func ReadReceipt(text string, officeKey ed25519.PublicKey, reportEnvelope string, sent Report, m Manifest) (Receipt, error) {
	var r Receipt
	payload, e := open(text, ReceiptDomain, officeKey, receiptFields, MaximumReceipt)
	if e != nil {
		return r, e
	}
	if json.Unmarshal(payload, &r) != nil {
		return Receipt{}, ErrMalformed
	}
	if !r.valid() {
		return Receipt{}, ErrFields
	}
	if r.ReportID != sent.ReportID || r.ReportSHA256 != Digest([]byte(reportEnvelope)) || r.RecordSHA256 != sent.RecordSHA256 ||
		r.ManifestSHA256 != sent.ManifestSHA256 || r.OrganizationID != sent.OrganizationID || r.EnrolmentID != sent.EnrolmentID ||
		r.OfficeID != sent.OfficeID || r.PhoneTransportID != sent.PhoneTransportID {
		return Receipt{}, ErrOther
	}
	var optional int64
	for _, a := range m.Attachments {
		if a.Requirement == Optional {
			optional++
		}
	}
	total := int64(len(m.Attachments))
	if r.AttachmentsCommitted+r.AttachmentsOutstanding != total ||
		// Record accepted means every required attachment is in: only optional ones are out.
		r.Outcome == OutcomeRecordAccepted && r.AttachmentsOutstanding > optional ||
		// Evidence pending means a required attachment is out, so there must be one.
		r.Outcome == OutcomeEvidencePending && optional == total {
		return Receipt{}, ErrFields
	}
	return r, nil
}
