// Package jobupdate defines the signed update an office sends about a job a phone already has,
// and the phone's signed receipt for it (Contracts/job-updates.md).
//
// An update is information: a parts state, a new time, a note. Verifying one authorises keeping
// it and showing it against the job it names. It never edits a job, starts one, or changes
// what a phone is entitled to.
package jobupdate

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
	"unicode/utf8"

	"avenkin.dev/mobilecore/officepreview"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	// Domain and ReceiptDomain separate the two signatures from every other Avenkin signature.
	// The signed bytes are the domain, one zero byte, then the exact payload bytes.
	Domain        = "Avenkin.JobUpdate.v1"
	ReceiptDomain = "Avenkin.JobUpdateReceipt.v1"

	Kind        = "avenkin.job-update"
	ReceiptKind = "avenkin.job-update-receipt"

	// The kinds v1 defines. Any other well-formed kind word verifies and is shown as a note.
	KindParts    = "parts"
	KindSchedule = "schedule"
	KindNote     = "note"

	OutcomeReceived = "received"

	// What the phone held for the job at the moment it committed the update.
	JobHeld     = "held"
	JobFinished = "finished"
	JobUnknown  = "unknown"

	MaximumMessage      = 16384
	MaximumBodyBytes    = 4000
	MaximumPartBytes    = 200
	MaximumQuantity     = 1000000
	MaximumLifetime     = 30 * 86400
	MaximumIssueSkew    = 300
	maximumSafeInteger  = int64(9007199254740991)
	maximumKindWordSize = 32
)

// PartStates are the states a parts update may give.
var PartStates = []string{"ordered", "dispatched", "arrived", "substituted", "unavailable"}

var (
	ErrMalformed = errors.New("malformed job update message")
	ErrSignature = errors.New("invalid job update signature")
	ErrAuthority = errors.New("job update is for another binding")
	ErrFields    = errors.New("invalid job update fields")
	ErrTime      = errors.New("job update is not currently valid")
	ErrOther     = errors.New("job update receipt is for another update")
)

// Update is the closed payload. Every member is always present: a member that does not apply is
// the empty string or zero.
type Update struct {
	Version           int    `json:"version"`
	Kind              string `json:"kind"`
	UpdateID          string `json:"updateID"`
	OrganizationID    string `json:"organizationID"`
	EnrolmentID       string `json:"enrolmentID"`
	OfficeID          string `json:"officeID"`
	Generation        int64  `json:"generation"`
	OfficeTransportID string `json:"officeTransportID"`
	PhoneTransportID  string `json:"phoneTransportID"`
	JobID             string `json:"jobID"`
	Sequence          int64  `json:"sequence"`
	IssuedAt          int64  `json:"issuedAt"`
	ExpiresAt         int64  `json:"expiresAt"`
	UpdateKind        string `json:"updateKind"`
	Body              string `json:"body"`
	Part              string `json:"part"`
	Quantity          int64  `json:"quantity"`
	PartState         string `json:"partState"`
	ExpectedOn        string `json:"expectedOn"`
	ScheduledFor      int64  `json:"scheduledFor"`
	ScheduledUntil    int64  `json:"scheduledUntil"`
}

// Receipt is the phone's signed statement that it verified one update and committed it durably.
// It is not the technician having read it.
type Receipt struct {
	Version          int    `json:"version"`
	Kind             string `json:"kind"`
	UpdateID         string `json:"updateID"`
	UpdateSHA256     string `json:"updateSHA256"`
	OrganizationID   string `json:"organizationID"`
	EnrolmentID      string `json:"enrolmentID"`
	OfficeID         string `json:"officeID"`
	Generation       int64  `json:"generation"`
	PhoneTransportID string `json:"phoneTransportID"`
	JobID            string `json:"jobID"`
	Sequence         int64  `json:"sequence"`
	Outcome          string `json:"outcome"`
	JobState         string `json:"jobState"`
	ReceivedAt       int64  `json:"receivedAt"`
}

var updateFields = []string{"version", "kind", "updateID", "organizationID", "enrolmentID", "officeID", "generation", "officeTransportID", "phoneTransportID", "jobID", "sequence", "issuedAt", "expiresAt", "updateKind", "body", "part", "quantity", "partState", "expectedOn", "scheduledFor", "scheduledUntil"}
var receiptFields = []string{"version", "kind", "updateID", "updateSHA256", "organizationID", "enrolmentID", "officeID", "generation", "phoneTransportID", "jobID", "sequence", "outcome", "jobState", "receivedAt"}

type envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

// Trust must come from a freshly verified vendor-rooted office peer binding, never the message.
type Trust struct {
	OrganizationID, EnrolmentID, OfficeID, OfficeTransportID, PhoneTransportID string
	Generation                                                                 int64
	OfficeApplicationKey                                                       ed25519.PublicKey
}

// Verified is an update that passed every check, and the digest of its exact payload bytes.
type Verified struct {
	Payload       Update
	PayloadSHA256 string
}

// Digest is the lower-case hex SHA-256 of exact bytes.
func Digest(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// SigningInput is the exact bytes a signature covers: the domain, one zero byte, the payload.
func SigningInput(domain string, payload []byte) []byte {
	return append(append([]byte(domain), 0), payload...)
}

func seal(payload, signature []byte) (string, error) {
	if len(signature) != ed25519.SignatureSize {
		return "", ErrSignature
	}
	out, e := json.Marshal(envelope{base64.StdEncoding.EncodeToString(payload), base64.StdEncoding.EncodeToString(signature)})
	if e != nil {
		return "", e
	}
	if len(out) > MaximumMessage {
		return "", ErrMalformed
	}
	return string(out), nil
}

func open(text, domain string, key ed25519.PublicKey, fields []string) ([]byte, error) {
	if len(text) == 0 || len(text) > MaximumMessage || !officepreview.Flat([]byte(text), []string{"payload", "signature"}) {
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

func transportID(s string) bool {
	id, e := protocol.DeviceIDFromString(s)
	return e == nil && id != protocol.EmptyDeviceID && id.String() == s
}

func instant(n int64) bool { return n > 0 && n <= maximumSafeInteger }

// kindWord is a lower-case letter followed by lower-case letters, digits or hyphens.
func kindWord(s string) bool {
	if len(s) == 0 || len(s) > maximumKindWordSize || s[0] < 'a' || s[0] > 'z' {
		return false
	}
	for _, c := range []byte(s) {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

// text is valid UTF-8 within a byte limit with no control characters, except that a body may
// have line feeds. The empty string is text.
func text(s string, max int, lines bool) bool {
	if len(s) > max || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r == '\n' && lines {
			continue
		}
		if r < 0x20 || r >= 0x7f && r <= 0x9f || r == 0x2028 || r == 0x2029 {
			return false
		}
	}
	return true
}

// day is a calendar date written YYYY-MM-DD.
func day(s string) bool {
	t, e := time.Parse("2006-01-02", s)
	return e == nil && t.Format("2006-01-02") == s
}

func partState(s string) bool {
	for _, state := range PartStates {
		if s == state {
			return true
		}
	}
	return false
}

func (u Update) valid() bool {
	if !(u.Version == 1 && u.Kind == Kind && lowerHex(u.UpdateID, 32) && safeIdentifier(u.OrganizationID) &&
		safeIdentifier(u.EnrolmentID) && safeIdentifier(u.OfficeID) && instant(u.Generation) &&
		transportID(u.OfficeTransportID) && transportID(u.PhoneTransportID) && safeIdentifier(u.JobID) &&
		instant(u.Sequence) && instant(u.IssuedAt) && instant(u.ExpiresAt) && u.ExpiresAt > u.IssuedAt &&
		u.ExpiresAt-u.IssuedAt <= MaximumLifetime && kindWord(u.UpdateKind)) {
		return false
	}
	// Each member by its own rule, whatever the kind.
	if !(text(u.Body, MaximumBodyBytes, true) && text(u.Part, MaximumPartBytes, false) &&
		u.Quantity >= 0 && u.Quantity <= MaximumQuantity && (u.PartState == "" || partState(u.PartState)) &&
		(u.ExpectedOn == "" || day(u.ExpectedOn)) && u.ScheduledFor >= 0 && u.ScheduledFor <= maximumSafeInteger &&
		u.ScheduledUntil >= 0 && u.ScheduledUntil <= maximumSafeInteger &&
		(u.ScheduledUntil == 0 || u.ScheduledFor > 0 && u.ScheduledUntil > u.ScheduledFor)) {
		return false
	}
	noParts := u.Part == "" && u.Quantity == 0 && u.PartState == "" && u.ExpectedOn == ""
	noSchedule := u.ScheduledFor == 0 && u.ScheduledUntil == 0
	switch u.UpdateKind {
	case KindNote:
		return u.Body != "" && noParts && noSchedule
	case KindParts:
		return u.Part != "" && u.PartState != "" && noSchedule
	case KindSchedule:
		return u.ScheduledFor > 0 && noParts
	default:
		// A kind this version does not define: kept, and shown as a note.
		return true
	}
}

// Sign signs an update with a key held in process.
func Sign(u Update, officeKey ed25519.PrivateKey) (string, error) {
	if len(officeKey) != ed25519.PrivateKeySize {
		return "", ErrSignature
	}
	if !u.valid() {
		return "", ErrFields
	}
	payload, e := json.Marshal(u)
	if e != nil {
		return "", e
	}
	return seal(payload, ed25519.Sign(officeKey, SigningInput(Domain, payload)))
}

// SignPayload signs exact payload bytes the caller built, so nothing is re-encoded between an
// office's record of an update and what a phone verifies. It is for a process that holds the
// office application key on behalf of one that does not: the payload is checked as a verifier
// would check it, must name officeID, be issued no later than a few minutes from now, and not
// have expired.
func SignPayload(payload []byte, officeKey ed25519.PrivateKey, officeID string, now int64) (string, error) {
	if len(officeKey) != ed25519.PrivateKeySize {
		return "", ErrSignature
	}
	if len(payload) == 0 || len(payload) > MaximumMessage || !officepreview.Flat(payload, updateFields) {
		return "", ErrMalformed
	}
	var u Update
	if json.Unmarshal(payload, &u) != nil {
		return "", ErrMalformed
	}
	if !u.valid() {
		return "", ErrFields
	}
	if officeID == "" || u.OfficeID != officeID {
		return "", ErrAuthority
	}
	if u.IssuedAt > now+MaximumIssueSkew || now >= u.ExpiresAt {
		return "", ErrTime
	}
	return seal(payload, ed25519.Sign(officeKey, SigningInput(Domain, payload)))
}

// Read is the phone's check: the office application key from the binding signed these exact
// bytes, they are for this binding, every field is in form, and the update is inside its window.
func Read(message string, trust Trust, now int64) (Verified, error) {
	var empty Verified
	payload, e := open(message, Domain, trust.OfficeApplicationKey, updateFields)
	if e != nil {
		return empty, e
	}
	var u Update
	if json.Unmarshal(payload, &u) != nil {
		return empty, ErrMalformed
	}
	if u.OrganizationID != trust.OrganizationID || u.EnrolmentID != trust.EnrolmentID || u.OfficeID != trust.OfficeID ||
		u.Generation != trust.Generation || u.OfficeTransportID != trust.OfficeTransportID || u.PhoneTransportID != trust.PhoneTransportID {
		return empty, ErrAuthority
	}
	if !u.valid() {
		return empty, ErrFields
	}
	if now < u.IssuedAt || now >= u.ExpiresAt {
		return empty, ErrTime
	}
	return Verified{u, Digest(payload)}, nil
}

// Standing is where an arriving update stands to what a phone holds at the same job and
// sequence. Order means nothing: a lower sequence arriving after a higher one is still new.
type Standing int

const (
	// New: nothing is held at this job and sequence.
	New Standing = iota
	// Same: these exact bytes are held already. The same receipt is given again.
	Same
	// Conflict: other bytes are held at this job and sequence. The first stays; this is refused.
	Conflict
)

// Stands compares an arriving update with the payload digest held at its job and sequence, or
// the empty string when none is held.
func Stands(heldSHA256 string, arriving Verified) Standing {
	switch heldSHA256 {
	case "":
		return New
	case arriving.PayloadSHA256:
		return Same
	default:
		return Conflict
	}
}

// ---------------------------------------------------------------------------------------------
// The receipt
// ---------------------------------------------------------------------------------------------

func (r Receipt) valid() bool {
	return r.Version == 1 && r.Kind == ReceiptKind && lowerHex(r.UpdateID, 32) && lowerHex(r.UpdateSHA256, 64) &&
		safeIdentifier(r.OrganizationID) && safeIdentifier(r.EnrolmentID) && safeIdentifier(r.OfficeID) && instant(r.Generation) &&
		transportID(r.PhoneTransportID) && safeIdentifier(r.JobID) && instant(r.Sequence) && r.Outcome == OutcomeReceived &&
		(r.JobState == JobHeld || r.JobState == JobFinished || r.JobState == JobUnknown) && instant(r.ReceivedAt)
}

// ReceiptFor is the receipt a phone gives for an update it has verified and committed.
func ReceiptFor(v Verified, jobState string, receivedAt int64) Receipt {
	u := v.Payload
	return Receipt{1, ReceiptKind, u.UpdateID, v.PayloadSHA256, u.OrganizationID, u.EnrolmentID, u.OfficeID, u.Generation,
		u.PhoneTransportID, u.JobID, u.Sequence, OutcomeReceived, jobState, receivedAt}
}

// ReceiptPayload is the exact bytes a phone signs. The phone application key lives in device-only
// storage outside the transport, so signing is in two steps: these bytes, signed under
// ReceiptDomain (see SigningInput), then SealReceipt.
func ReceiptPayload(r Receipt) ([]byte, error) {
	if !r.valid() {
		return nil, ErrFields
	}
	return json.Marshal(r)
}

// SealReceipt wraps a receipt payload with the signature the phone application key made.
func SealReceipt(payload, signature []byte) (string, error) {
	var r Receipt
	if !officepreview.Flat(payload, receiptFields) || json.Unmarshal(payload, &r) != nil || !r.valid() {
		return "", ErrMalformed
	}
	return seal(payload, signature)
}

// SignReceipt does both steps for a key held in process.
func SignReceipt(r Receipt, phoneKey ed25519.PrivateKey) (string, error) {
	payload, e := ReceiptPayload(r)
	if e != nil || len(phoneKey) != ed25519.PrivateKeySize {
		return "", ErrFields
	}
	return seal(payload, ed25519.Sign(phoneKey, SigningInput(ReceiptDomain, payload)))
}

// Sent is the office's own record of the update a receipt must be for.
type Sent struct {
	UpdateID, UpdateSHA256                string
	OrganizationID, EnrolmentID, OfficeID string
	Generation                            int64
	PhoneTransportID, JobID               string
	Sequence                              int64
}

// SentFor is the record an office keeps of an update it signed.
func SentFor(v Verified) Sent {
	u := v.Payload
	return Sent{u.UpdateID, v.PayloadSHA256, u.OrganizationID, u.EnrolmentID, u.OfficeID, u.Generation, u.PhoneTransportID, u.JobID, u.Sequence}
}

// ReadReceipt is the office's check: signed by the phone application key from the binding,
// never from the receipt, and for exactly the update the office sent.
func ReadReceipt(message string, phoneKey ed25519.PublicKey, sent Sent) (Receipt, error) {
	var r Receipt
	payload, e := open(message, ReceiptDomain, phoneKey, receiptFields)
	if e != nil {
		return r, e
	}
	if json.Unmarshal(payload, &r) != nil {
		return Receipt{}, ErrMalformed
	}
	if !r.valid() {
		return Receipt{}, ErrFields
	}
	if r.UpdateID != sent.UpdateID || r.UpdateSHA256 != sent.UpdateSHA256 || r.OrganizationID != sent.OrganizationID ||
		r.EnrolmentID != sent.EnrolmentID || r.OfficeID != sent.OfficeID || r.Generation != sent.Generation ||
		r.PhoneTransportID != sent.PhoneTransportID || r.JobID != sent.JobID || r.Sequence != sent.Sequence {
		return Receipt{}, ErrOther
	}
	return r, nil
}
