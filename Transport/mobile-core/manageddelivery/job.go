// Package manageddelivery defines signed, recipient-bound job transport messages.
// Verification only authorizes staging the exact bytes for the phone's existing job review;
// it does not accept a job, grant an entitlement, or install a manual.
package manageddelivery

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"

	"avenkin.dev/mobilecore/officepreview"
	"github.com/syncthing/syncthing/lib/protocol"
)

const Domain = "Avenkin.ManagedJob.v1\x00"
const MaximumEnvelopeBytes = 131072
const MaximumJobBytes int64 = 65536
const maximumSafeInteger int64 = 9007199254740991

type Job struct {
	Version           int    `json:"version"`
	Kind              string `json:"kind"`
	MessageID         string `json:"messageID"`
	OrganizationID    string `json:"organizationID"`
	EnrolmentID       string `json:"enrolmentID"`
	OfficeID          string `json:"officeID"`
	Generation        int64  `json:"generation"`
	OfficeTransportID string `json:"officeTransportID"`
	PhoneTransportID  string `json:"phoneTransportID"`
	Sequence          int64  `json:"sequence"`
	IssuedAt          int64  `json:"issuedAt"`
	ExpiresAt         int64  `json:"expiresAt"`
	JobSHA256         string `json:"jobSHA256"`
	JobBytes          int64  `json:"jobBytes"`
}

type Envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

// Trust must come from a freshly verified vendor-rooted office peer binding, never the message.
type Trust struct {
	OrganizationID, EnrolmentID, OfficeID, OfficeTransportID, PhoneTransportID string
	Generation                                                                 int64
	OfficeApplicationKey                                                       ed25519.PublicKey
}
type HighWater struct {
	Generation    int64
	Sequence      int64
	PayloadSHA256 string
}
type Verified struct {
	Payload       Job
	PayloadSHA256 string
	IsReplay      bool
}

func (v Verified) HighWater() HighWater {
	return HighWater{v.Payload.Generation, v.Payload.Sequence, v.PayloadSHA256}
}

var fields = []string{"version", "kind", "messageID", "organizationID", "enrolmentID", "officeID", "generation", "officeTransportID", "phoneTransportID", "sequence", "issuedAt", "expiresAt", "jobSHA256", "jobBytes"}
var envelopeFields = []string{"payload", "signature"}

var (
	ErrMalformed = errors.New("malformed managed job")
	ErrSignature = errors.New("invalid managed job signature")
	ErrAuthority = errors.New("managed job targets another binding")
	ErrFields    = errors.New("invalid managed job fields")
	ErrTime      = errors.New("managed job is not currently valid")
	ErrRollback  = errors.New("managed job rollback")
	ErrConflict  = errors.New("managed job sequence conflict")
	ErrContent   = errors.New("job bytes differ from signed digest")
)

func Digest(data []byte) string { h := sha256.Sum256(data); return hex.EncodeToString(h[:]) }

func Sign(payload Job, privateKey ed25519.PrivateKey) ([]byte, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, ErrSignature
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	return json.Marshal(Envelope{
		Payload:   base64.StdEncoding.EncodeToString(raw),
		Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, append([]byte(Domain), raw...))),
	})
}

func Verify(data []byte, trust Trust, now int64, previous *HighWater) (Verified, error) {
	var empty Verified
	if len(data) > MaximumEnvelopeBytes || !officepreview.Flat(data, envelopeFields) {
		return empty, ErrMalformed
	}
	var envelope Envelope
	if json.Unmarshal(data, &envelope) != nil {
		return empty, ErrMalformed
	}
	raw, e := base64.StdEncoding.Strict().DecodeString(envelope.Payload)
	if e != nil || len(raw) > MaximumEnvelopeBytes || !officepreview.Flat(raw, fields) {
		return empty, ErrMalformed
	}
	signature, e := base64.StdEncoding.Strict().DecodeString(envelope.Signature)
	if e != nil || len(signature) != ed25519.SignatureSize {
		return empty, ErrMalformed
	}
	if len(trust.OfficeApplicationKey) != ed25519.PublicKeySize || !ed25519.Verify(trust.OfficeApplicationKey, append([]byte(Domain), raw...), signature) {
		return empty, ErrSignature
	}
	var p Job
	if json.Unmarshal(raw, &p) != nil {
		return empty, ErrMalformed
	}
	if p.OrganizationID != trust.OrganizationID || p.EnrolmentID != trust.EnrolmentID || p.OfficeID != trust.OfficeID || p.Generation != trust.Generation || p.OfficeTransportID != trust.OfficeTransportID || p.PhoneTransportID != trust.PhoneTransportID {
		return empty, ErrAuthority
	}
	if !validFields(p) {
		return empty, ErrFields
	}
	if now < p.IssuedAt || now >= p.ExpiresAt {
		return empty, ErrTime
	}
	v := Verified{Payload: p, PayloadSHA256: Digest(raw)}
	if previous != nil {
		if p.Generation < previous.Generation || p.Generation == previous.Generation && p.Sequence < previous.Sequence {
			return empty, ErrRollback
		}
		if p.Generation == previous.Generation && p.Sequence == previous.Sequence {
			if v.PayloadSHA256 != previous.PayloadSHA256 {
				return empty, ErrConflict
			}
			v.IsReplay = true
		}
	}
	return v, nil
}

func validFields(p Job) bool {
	return p.Version == 1 && p.Kind == "avenkin.managed-job" && safeID(p.MessageID, 32) && safeID(p.JobSHA256, 64) && safeName(p.OrganizationID) && safeName(p.EnrolmentID) && safeName(p.OfficeID) && deviceID(p.OfficeTransportID) && deviceID(p.PhoneTransportID) && p.Sequence > 0 && p.Sequence <= maximumSafeInteger && p.Generation > 0 && p.Generation <= maximumSafeInteger && p.IssuedAt > 0 && p.ExpiresAt > p.IssuedAt && p.ExpiresAt <= maximumSafeInteger && p.ExpiresAt-p.IssuedAt <= 30*86400 && p.JobBytes > 0 && p.JobBytes <= MaximumJobBytes
}

// MaximumIssueSkewSeconds is how far ahead of the signer's clock a payload's issuedAt may be.
const MaximumIssueSkewSeconds = 300

// SignPayload signs exact payload bytes that the caller built, so no JSON is re-encoded between
// the office's record of a message and what a phone verifies. It is for a process that holds
// the office application key on behalf of another that does not: the key holder checks the
// payload as a verifier would before lending its signature.
//
// The payload must be the closed, flat managed-job object with valid fields, name officeID (the
// identity of the key that is about to sign), be issued no later than a few minutes from now,
// and not have expired. The reply is the same envelope Sign produces for those bytes.
func SignPayload(raw []byte, privateKey ed25519.PrivateKey, officeID string, now int64) ([]byte, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, ErrSignature
	}
	if len(raw) == 0 || len(raw) > MaximumEnvelopeBytes || !officepreview.Flat(raw, fields) {
		return nil, ErrMalformed
	}
	var p Job
	if json.Unmarshal(raw, &p) != nil {
		return nil, ErrMalformed
	}
	if !validFields(p) {
		return nil, ErrFields
	}
	if officeID == "" || p.OfficeID != officeID {
		return nil, ErrAuthority
	}
	if p.IssuedAt > now+MaximumIssueSkewSeconds || now >= p.ExpiresAt {
		return nil, ErrTime
	}
	return json.Marshal(Envelope{
		Payload:   base64.StdEncoding.EncodeToString(raw),
		Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, append([]byte(Domain), raw...))),
	})
}

func VerifyBytes(job []byte, verified Verified) error {
	if int64(len(job)) != verified.Payload.JobBytes || Digest(job) != verified.Payload.JobSHA256 {
		return ErrContent
	}
	return nil
}
func safeID(s string, n int) bool {
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
func safeName(s string) bool {
	if len(s) == 0 || len(s) > 80 || s == "." || s == ".." {
		return false
	}
	for _, c := range []byte(s) {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}
func deviceID(s string) bool {
	id, err := protocol.DeviceIDFromString(s)
	return err == nil && id != protocol.EmptyDeviceID && id.String() == s
}
