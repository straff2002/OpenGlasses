package manageddelivery

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"

	"avenkin.dev/mobilecore/officepreview"
)

// A receipt is the phone's signed statement that it verified one managed job and committed its
// exact bytes durably to its own private store, ready for the technician's review. It is not
// the technician accepting or starting the job, and it is not produced by a file finishing
// its transfer.

const ReceiptDomain = "Avenkin.ManagedJobReceipt.v1\x00"
const ReceiptKind = "avenkin.managed-job-receipt"
const MaximumReceiptBytes = 8192

// OutcomeReceived is the only outcome in v1: verified and durably committed.
const OutcomeReceived = "received"

type Receipt struct {
	Version          int    `json:"version"`
	Kind             string `json:"kind"`
	MessageID        string `json:"messageID"`
	OrganizationID   string `json:"organizationID"`
	EnrolmentID      string `json:"enrolmentID"`
	OfficeID         string `json:"officeID"`
	Generation       int64  `json:"generation"`
	PhoneTransportID string `json:"phoneTransportID"`
	Sequence         int64  `json:"sequence"`
	PayloadSHA256    string `json:"payloadSHA256"`
	JobSHA256        string `json:"jobSHA256"`
	Outcome          string `json:"outcome"`
	ReceivedAt       int64  `json:"receivedAt"`
}

var receiptFields = []string{"version", "kind", "messageID", "organizationID", "enrolmentID", "officeID", "generation", "phoneTransportID", "sequence", "payloadSHA256", "jobSHA256", "outcome", "receivedAt"}

// ReceiptTrust must come from the freshly verified binding, never from the receipt: the phone
// application key the binding names, and the binding the job was sent under.
type ReceiptTrust struct {
	OrganizationID, EnrolmentID, OfficeID, PhoneTransportID string
	Generation                                              int64
	PhoneApplicationKey                                     ed25519.PublicKey
}

// ReceiptExpected is the office's own record of the message a receipt must be for.
type ReceiptExpected struct {
	MessageID     string
	Sequence      int64
	PayloadSHA256 string
	JobSHA256     string
}

var (
	ErrReceiptMalformed = errors.New("malformed managed job receipt")
	ErrReceiptSignature = errors.New("invalid managed job receipt signature")
	ErrReceiptAuthority = errors.New("managed job receipt is from another binding")
	ErrReceiptFields    = errors.New("invalid managed job receipt fields")
	ErrReceiptMessage   = errors.New("managed job receipt is for another message")
)

// ReceiptFor is the receipt a phone gives for a job it has verified and committed.
func ReceiptFor(verified Verified, receivedAt int64) Receipt {
	p := verified.Payload
	return Receipt{
		Version: 1, Kind: ReceiptKind, MessageID: p.MessageID,
		OrganizationID: p.OrganizationID, EnrolmentID: p.EnrolmentID, OfficeID: p.OfficeID,
		Generation: p.Generation, PhoneTransportID: p.PhoneTransportID, Sequence: p.Sequence,
		PayloadSHA256: verified.PayloadSHA256, JobSHA256: p.JobSHA256,
		Outcome: OutcomeReceived, ReceivedAt: receivedAt,
	}
}

// ReceiptPayload is the exact bytes a phone signs. The phone application key is held outside
// this package (device-only storage), so signing is the caller's: sign ReceiptDomain followed by
// these bytes, then SealReceipt.
func ReceiptPayload(r Receipt) ([]byte, error) {
	if !validReceipt(r) {
		return nil, ErrReceiptFields
	}
	return json.Marshal(r)
}

// SealReceipt wraps exact payload bytes and their signature. It checks the shape only; the
// signature is checked by whoever verifies.
func SealReceipt(raw, signature []byte) ([]byte, error) {
	if len(signature) != ed25519.SignatureSize || len(raw) == 0 || len(raw) > MaximumReceiptBytes || !officepreview.Flat(raw, receiptFields) {
		return nil, ErrReceiptMalformed
	}
	return json.Marshal(Envelope{
		Payload:   base64.StdEncoding.EncodeToString(raw),
		Signature: base64.StdEncoding.EncodeToString(signature),
	})
}

// SignReceipt signs with a key held in this process: fixtures, tests and stand-in phones.
func SignReceipt(r Receipt, privateKey ed25519.PrivateKey) ([]byte, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, ErrReceiptSignature
	}
	raw, err := ReceiptPayload(r)
	if err != nil {
		return nil, err
	}
	return SealReceipt(raw, ed25519.Sign(privateKey, append([]byte(ReceiptDomain), raw...)))
}

func validReceipt(r Receipt) bool {
	return r.Version == 1 && r.Kind == ReceiptKind && safeID(r.MessageID, 32) && safeID(r.PayloadSHA256, 64) && safeID(r.JobSHA256, 64) &&
		safeName(r.OrganizationID) && safeName(r.EnrolmentID) && safeName(r.OfficeID) && deviceID(r.PhoneTransportID) &&
		r.Generation > 0 && r.Generation <= maximumSafeInteger && r.Sequence > 0 && r.Sequence <= maximumSafeInteger &&
		r.Outcome == OutcomeReceived && r.ReceivedAt > 0 && r.ReceivedAt <= maximumSafeInteger
}

// VerifyReceipt checks a receipt as the office does: closed envelope and payload, the signature
// over the exact payload bytes under the phone application key the binding names, the binding,
// the field rules, and that it is for exactly the message the office sent.
func VerifyReceipt(data []byte, trust ReceiptTrust, expected ReceiptExpected) (Receipt, error) {
	var empty Receipt
	if len(data) > MaximumReceiptBytes || !officepreview.Flat(data, envelopeFields) {
		return empty, ErrReceiptMalformed
	}
	var envelope Envelope
	if json.Unmarshal(data, &envelope) != nil {
		return empty, ErrReceiptMalformed
	}
	raw, e := base64.StdEncoding.Strict().DecodeString(envelope.Payload)
	if e != nil || !officepreview.Flat(raw, receiptFields) {
		return empty, ErrReceiptMalformed
	}
	signature, e := base64.StdEncoding.Strict().DecodeString(envelope.Signature)
	if e != nil || len(signature) != ed25519.SignatureSize {
		return empty, ErrReceiptMalformed
	}
	if len(trust.PhoneApplicationKey) != ed25519.PublicKeySize || !ed25519.Verify(trust.PhoneApplicationKey, append([]byte(ReceiptDomain), raw...), signature) {
		return empty, ErrReceiptSignature
	}
	var r Receipt
	if json.Unmarshal(raw, &r) != nil {
		return empty, ErrReceiptMalformed
	}
	if r.OrganizationID != trust.OrganizationID || r.EnrolmentID != trust.EnrolmentID || r.OfficeID != trust.OfficeID || r.Generation != trust.Generation || r.PhoneTransportID != trust.PhoneTransportID {
		return empty, ErrReceiptAuthority
	}
	if !validReceipt(r) {
		return empty, ErrReceiptFields
	}
	if r.MessageID != expected.MessageID || r.Sequence != expected.Sequence || r.PayloadSHA256 != expected.PayloadSHA256 || r.JobSHA256 != expected.JobSHA256 {
		return empty, ErrReceiptMessage
	}
	return r, nil
}
