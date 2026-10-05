// Package officebulk is the reference implementation of the bulk-content contract
// (Contracts/office-bulk.md): the administrator-signed grant that names an organisation's own
// publishing key, and the phone's signed receipts for a manual assignment.
//
// It is messages only. It opens no connection, stores nothing and holds no key: callers pass
// the key that signs, the key that must have signed, and the clock. The assignment itself is
// package manualassignment's; a job's own naming of what it needs is package jobfile's.
package officebulk

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"

	"avenkin.dev/mobilecore/officepreview"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	GrantDomain   = "Avenkin.OrganisationPublisher.v1"
	ReceiptDomain = "Avenkin.ManualAssignmentReceipt.v1"

	GrantKind   = "avenkin.organisation-publisher"
	ReceiptKind = "avenkin.manual-assignment-receipt"

	StatusActive  = "active"
	StatusRevoked = "revoked"

	// OutcomeReceived: the assignment verified and is committed; its archive is not installed.
	// OutcomeInstalled: the archive it names is verified and installed.
	OutcomeReceived  = "received"
	OutcomeInstalled = "installed"

	MaximumMessage = 4096
	// MaximumGrantLifetime is how long a grant may be valid, in seconds.
	MaximumGrantLifetime = 400 * 86400
	// MaximumIssueSkew is how far ahead of the signer's clock a grant's issuedAt may be.
	MaximumIssueSkew = 300
	// PublisherPrefix begins every organisation publisher's identifier, followed by the
	// organisation's own identifier. No other publisher's identifier may begin with it.
	PublisherPrefix = "org."

	maximumSafeInteger = int64(9007199254740991)
)

var (
	ErrMalformed = errors.New("malformed bulk-content message")
	ErrSignature = errors.New("bulk-content message is not signed by the key it must be")
	ErrFields    = errors.New("invalid bulk-content message fields")
	ErrOther     = errors.New("bulk-content message is for another organisation, phone or assignment")
	ErrTime      = errors.New("the publisher grant is not currently valid")
)

// Grant is the administrator's statement that one key signs this organisation's own vaults.
type Grant struct {
	Version        int    `json:"version"`
	Kind           string `json:"kind"`
	GrantID        string `json:"grantID"`
	OrganizationID string `json:"organizationID"`
	ProfileID      string `json:"profileID"`
	PublisherID    string `json:"publisherID"`
	PublisherName  string `json:"publisherName"`
	PublisherKey   string `json:"publisherKey"`
	Sequence       int64  `json:"sequence"`
	Status         string `json:"status"`
	IssuedAt       int64  `json:"issuedAt"`
	ExpiresAt      int64  `json:"expiresAt"`
}

// Receipt is the phone's statement of how far one manual assignment has got.
type Receipt struct {
	Version          int    `json:"version"`
	Kind             string `json:"kind"`
	AssignmentID     string `json:"assignmentID"`
	AssignmentSHA256 string `json:"assignmentSHA256"`
	OrganizationID   string `json:"organizationID"`
	EnrolmentID      string `json:"enrolmentID"`
	OfficeID         string `json:"officeID"`
	Generation       int64  `json:"generation"`
	PhoneTransportID string `json:"phoneTransportID"`
	SetID            string `json:"setID"`
	Sequence         int64  `json:"sequence"`
	ArchiveSHA256    string `json:"archiveSHA256"`
	Outcome          string `json:"outcome"`
	At               int64  `json:"at"`
}

var grantFields = []string{"version", "kind", "grantID", "organizationID", "profileID", "publisherID", "publisherName", "publisherKey", "sequence", "status", "issuedAt", "expiresAt"}
var receiptFields = []string{"version", "kind", "assignmentID", "assignmentSHA256", "organizationID", "enrolmentID", "officeID", "generation", "phoneTransportID", "setID", "sequence", "archiveSHA256", "outcome", "at"}

type envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
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

// OrganisationPublisher says whether publisherID is one an organisation may grant: "org." and
// the organisation's identifier, alone or followed by a dot and a name of its own.
func OrganisationPublisher(publisherID, organizationID string) bool {
	own := PublisherPrefix + organizationID
	return safeIdentifier(publisherID) && (publisherID == own || strings.HasPrefix(publisherID, own+"."))
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

// plain is printable ASCII that needs no JSON escape, so it has one spelling.
func plain(s string, max int) bool {
	if len(s) == 0 || len(s) > max {
		return false
	}
	for _, c := range []byte(s) {
		if c < 0x20 || c >= 0x7f || c == '"' || c == '\\' || c == '<' || c == '>' || c == '&' {
			return false
		}
	}
	return true
}

func publicKey(text string) bool {
	b, e := base64.StdEncoding.Strict().DecodeString(text)
	return e == nil && len(b) == ed25519.PublicKeySize && base64.StdEncoding.EncodeToString(b) == text
}

func transportID(s string) bool {
	id, e := protocol.DeviceIDFromString(s)
	return e == nil && id != protocol.EmptyDeviceID && id.String() == s
}

func instant(n int64) bool { return n > 0 && n <= maximumSafeInteger }

// ---------------------------------------------------------------------------------------------
// The publisher grant
// ---------------------------------------------------------------------------------------------

func (g Grant) valid() bool {
	return g.Version == 1 && g.Kind == GrantKind && lowerHex(g.GrantID, 32) && safeIdentifier(g.OrganizationID) &&
		safeIdentifier(g.ProfileID) && OrganisationPublisher(g.PublisherID, g.OrganizationID) && plain(g.PublisherName, 120) &&
		publicKey(g.PublisherKey) && instant(g.Sequence) && (g.Status == StatusActive || g.Status == StatusRevoked) &&
		instant(g.IssuedAt) && instant(g.ExpiresAt) && g.ExpiresAt > g.IssuedAt && g.ExpiresAt-g.IssuedAt <= MaximumGrantLifetime
}

// Live says whether an active grant may be relied on at now.
func (g Grant) Live(now int64) bool {
	return g.Status == StatusActive && now >= g.IssuedAt && now < g.ExpiresAt
}

// SignGrantWith signs a grant with the administrator key behind sign, which is given the exact
// bytes to sign.
func SignGrantWith(g Grant, sign func(message []byte) []byte) (string, error) {
	if !g.valid() || sign == nil {
		return "", ErrFields
	}
	payload, e := json.Marshal(g)
	if e != nil {
		return "", e
	}
	return seal(payload, sign(SigningInput(GrantDomain, payload)))
}

// SignGrant is SignGrantWith for a key held in process.
func SignGrant(g Grant, administratorKey ed25519.PrivateKey) (string, error) {
	if len(administratorKey) != ed25519.PrivateKeySize {
		return "", ErrSignature
	}
	return SignGrantWith(g, func(message []byte) []byte { return ed25519.Sign(administratorKey, message) })
}

// SignGrantPayload signs exact payload bytes the caller built, so nothing is re-encoded between
// an office's record of a grant and what a phone verifies. It is for a process that holds the
// administrator key on behalf of one that does not. organizationID and profileID are those of
// the vendor-signed profile the key holder has verified names its key; the grant must name
// both, be in form, be issued no later than a few minutes from now and, unless it is a
// revocation, not have expired. sign is given the exact bytes to sign.
func SignGrantPayload(payload []byte, organizationID, profileID string, sign func(message []byte) []byte, now int64) (string, error) {
	if sign == nil {
		return "", ErrSignature
	}
	if len(payload) == 0 || len(payload) > MaximumMessage || !officepreview.Flat(payload, grantFields) {
		return "", ErrMalformed
	}
	var g Grant
	if json.Unmarshal(payload, &g) != nil {
		return "", ErrMalformed
	}
	if !g.valid() {
		return "", ErrFields
	}
	if organizationID == "" || profileID == "" || g.OrganizationID != organizationID || g.ProfileID != profileID {
		return "", ErrOther
	}
	if g.IssuedAt > now+MaximumIssueSkew || (g.Status == StatusActive && now >= g.ExpiresAt) {
		return "", ErrTime
	}
	return seal(payload, sign(SigningInput(GrantDomain, payload)))
}

// ReadGrant is the phone's check of a grant: signed by the administrator key from its
// vendor-verified profile, and naming its own organisation and profile. It returns the grant and
// the digest of its payload. It does not look at the clock (see Live): a revocation is read
// whenever it arrives.
func ReadGrant(text string, administratorKey ed25519.PublicKey, organizationID, profileID string) (Grant, string, error) {
	var g Grant
	payload, e := open(text, GrantDomain, administratorKey, grantFields)
	if e != nil {
		return g, "", e
	}
	if json.Unmarshal(payload, &g) != nil {
		return Grant{}, "", ErrMalformed
	}
	if !g.valid() {
		return Grant{}, "", ErrFields
	}
	if g.OrganizationID != organizationID || g.ProfileID != profileID {
		return Grant{}, "", ErrOther
	}
	return g, Digest(payload), nil
}

// Standing is how a grant that has arrived stands to the one a phone holds for the same
// publisher: a higher sequence replaces it, the same sequence is the same grant only with the
// same bytes, and a lower one never replaces a higher.
type Standing int

const (
	Newer Standing = iota
	Same
	Older
	Conflict
)

func Stands(heldSequence int64, heldSHA256 string, arriving Grant, arrivingSHA256 string) Standing {
	switch {
	case arriving.Sequence > heldSequence:
		return Newer
	case arriving.Sequence < heldSequence:
		return Older
	case arrivingSHA256 == heldSHA256:
		return Same
	default:
		return Conflict
	}
}

// ---------------------------------------------------------------------------------------------
// The assignment receipt
// ---------------------------------------------------------------------------------------------

func (r Receipt) valid() bool {
	return r.Version == 1 && r.Kind == ReceiptKind && lowerHex(r.AssignmentID, 32) && lowerHex(r.AssignmentSHA256, 64) &&
		safeIdentifier(r.OrganizationID) && safeIdentifier(r.EnrolmentID) && safeIdentifier(r.OfficeID) && instant(r.Generation) &&
		transportID(r.PhoneTransportID) && safeIdentifier(r.SetID) && instant(r.Sequence) && lowerHex(r.ArchiveSHA256, 64) &&
		(r.Outcome == OutcomeReceived || r.Outcome == OutcomeInstalled) && instant(r.At)
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

// Sent is the office's own record of the assignment a receipt must be for.
type Sent struct {
	AssignmentID, AssignmentSHA256        string
	OrganizationID, EnrolmentID, OfficeID string
	Generation                            int64
	PhoneTransportID, SetID               string
	Sequence                              int64
	ArchiveSHA256                         string
}

// ReadReceipt is the office's check: signed by the phone application key from the binding,
// never from the receipt, and for exactly the assignment the office sent.
func ReadReceipt(text string, phoneKey ed25519.PublicKey, sent Sent) (Receipt, error) {
	var r Receipt
	payload, e := open(text, ReceiptDomain, phoneKey, receiptFields)
	if e != nil {
		return r, e
	}
	if json.Unmarshal(payload, &r) != nil {
		return Receipt{}, ErrMalformed
	}
	if !r.valid() {
		return Receipt{}, ErrFields
	}
	if r.AssignmentID != sent.AssignmentID || r.AssignmentSHA256 != sent.AssignmentSHA256 || r.OrganizationID != sent.OrganizationID ||
		r.EnrolmentID != sent.EnrolmentID || r.OfficeID != sent.OfficeID || r.Generation != sent.Generation ||
		r.PhoneTransportID != sent.PhoneTransportID || r.SetID != sent.SetID || r.Sequence != sent.Sequence ||
		r.ArchiveSHA256 != sent.ArchiveSHA256 {
		return Receipt{}, ErrOther
	}
	return r, nil
}
