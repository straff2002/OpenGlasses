// Package checkin is the reference implementation of the office check-in, renewal and removal
// contract (Contracts/office-check-in.md): the challenge an office sets, the check-in a phone
// answers with, the administrator-signed result that carries a renewed peer binding, and the
// administrator-signed removal with the phone's receipt.
//
// It is messages only. It opens no connection, stores nothing and holds no key: callers pass
// the key that signs, the key that must have signed, and the clock. What is durable — which
// challenge was used, which generation was issued, which enrolment was removed — belongs to
// the caller. Renew and Remove in holder.go are the two operations of the process that holds
// the administrator key.
package checkin

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

const (
	ChallengeDomain      = "Avenkin.OfficeCheckInChallenge.v1"
	CheckInDomain        = "Avenkin.OfficeCheckIn.v1"
	ResultDomain         = "Avenkin.OfficeCheckInResult.v1"
	RemovalDomain        = "Avenkin.OfficeRemoval.v1"
	RemovalReceiptDomain = "Avenkin.OfficeRemovalReceipt.v1"
	// BindingDomain is the peer binding's own domain (Contracts/README.md); a result carries a
	// binding unchanged, and this package reads it to compare it with the one it renews.
	BindingDomain = "Avenkin.OfficePeerBinding.v1"

	ChallengeKind      = "avenkin.office-check-in-challenge"
	CheckInKind        = "avenkin.office-check-in"
	ResultKind         = "avenkin.office-check-in-result"
	RemovalKind        = "avenkin.office-removal"
	RemovalReceiptKind = "avenkin.office-removal-receipt"
	bindingKind        = "avenkin.office-peer-binding"

	// OutcomeRenewed is the only outcome a result has in v1.
	OutcomeRenewed = "renewed"
	ReasonRemoved  = "removed"
	ReasonRevoked  = "revoked"

	// MaximumMessage caps every message but the result.
	MaximumMessage = 4096
	MaximumResult  = 65536
	maximumBinding = 32768

	// MaximumChallengeLifetime is how long a challenge may be live, in seconds.
	MaximumChallengeLifetime = 7 * 86400
	maximumBindingLifetime   = 30 * 86400
	// MaximumIssueSkew is how far ahead of the signer's clock a payload's issuedAt may be.
	MaximumIssueSkew = 300

	maximumSafeInteger = int64(9007199254740991)
)

var (
	ErrMalformed = errors.New("malformed check-in message")
	ErrSignature = errors.New("check-in message is not signed by the key it must be")
	ErrFields    = errors.New("invalid check-in message fields")
	ErrTime      = errors.New("check-in message is not currently valid")
	ErrOther     = errors.New("check-in message is for another binding or exchange")
	ErrBinding   = errors.New("the renewed binding is not a renewal of the binding held")
)

// Challenge is what the office sets in the control folder. It grants nothing; it makes the
// check-in that answers it fresh.
type Challenge struct {
	Version          int    `json:"version"`
	Kind             string `json:"kind"`
	ChallengeID      string `json:"challengeID"`
	Nonce            string `json:"nonce"`
	OrganizationID   string `json:"organizationID"`
	EnrolmentID      string `json:"enrolmentID"`
	OfficeID         string `json:"officeID"`
	PhoneTransportID string `json:"phoneTransportID"`
	Generation       int64  `json:"generation"`
	BindingSHA256    string `json:"bindingSHA256"`
	IssuedAt         int64  `json:"issuedAt"`
	ExpiresAt        int64  `json:"expiresAt"`
}

// CheckIn is the phone's answer, signed with its application key.
type CheckIn struct {
	Version          int    `json:"version"`
	Kind             string `json:"kind"`
	ChallengeID      string `json:"challengeID"`
	ChallengeSHA256  string `json:"challengeSHA256"`
	Nonce            string `json:"nonce"`
	OrganizationID   string `json:"organizationID"`
	EnrolmentID      string `json:"enrolmentID"`
	OfficeID         string `json:"officeID"`
	PhoneTransportID string `json:"phoneTransportID"`
	Generation       int64  `json:"generation"`
	BindingSHA256    string `json:"bindingSHA256"`
	LeaseRenewBy     int64  `json:"leaseRenewBy"`
	AppVersion       string `json:"appVersion"`
	AppBuild         string `json:"appBuild"`
	CreatedAt        int64  `json:"createdAt"`
}

// Result is the administrator's answer to one check-in. It carries the renewed binding.
type Result struct {
	Version          int    `json:"version"`
	Kind             string `json:"kind"`
	ChallengeID      string `json:"challengeID"`
	CheckInSHA256    string `json:"checkInSHA256"`
	OrganizationID   string `json:"organizationID"`
	EnrolmentID      string `json:"enrolmentID"`
	OfficeID         string `json:"officeID"`
	PhoneTransportID string `json:"phoneTransportID"`
	Outcome          string `json:"outcome"`
	PeerBinding      string `json:"peerBinding"`
	IssuedAt         int64  `json:"issuedAt"`
}

// Removal ends an enrolment. It has no expiry and no generation.
type Removal struct {
	Version          int    `json:"version"`
	Kind             string `json:"kind"`
	RemovalID        string `json:"removalID"`
	OrganizationID   string `json:"organizationID"`
	ProfileID        string `json:"profileID"`
	EnrolmentID      string `json:"enrolmentID"`
	OfficeID         string `json:"officeID"`
	PhoneTransportID string `json:"phoneTransportID"`
	Reason           string `json:"reason"`
	IssuedAt         int64  `json:"issuedAt"`
}

// RemovalReceipt is the phone's statement that it acted on a removal.
type RemovalReceipt struct {
	Version          int    `json:"version"`
	Kind             string `json:"kind"`
	RemovalID        string `json:"removalID"`
	RemovalSHA256    string `json:"removalSHA256"`
	OrganizationID   string `json:"organizationID"`
	EnrolmentID      string `json:"enrolmentID"`
	PhoneTransportID string `json:"phoneTransportID"`
	ActedAt          int64  `json:"actedAt"`
}

var challengeFields = []string{"version", "kind", "challengeID", "nonce", "organizationID", "enrolmentID", "officeID", "phoneTransportID", "generation", "bindingSHA256", "issuedAt", "expiresAt"}
var checkInFields = []string{"version", "kind", "challengeID", "challengeSHA256", "nonce", "organizationID", "enrolmentID", "officeID", "phoneTransportID", "generation", "bindingSHA256", "leaseRenewBy", "appVersion", "appBuild", "createdAt"}
var resultFields = []string{"version", "kind", "challengeID", "checkInSHA256", "organizationID", "enrolmentID", "officeID", "phoneTransportID", "outcome", "peerBinding", "issuedAt"}
var removalFields = []string{"version", "kind", "removalID", "organizationID", "profileID", "enrolmentID", "officeID", "phoneTransportID", "reason", "issuedAt"}
var removalReceiptFields = []string{"version", "kind", "removalID", "removalSHA256", "organizationID", "enrolmentID", "phoneTransportID", "actedAt"}
var bindingFields = []string{"version", "kind", "organizationID", "profileID", "enrolmentID", "officeID", "generation", "officeTransportID", "officeApplicationKey", "phoneTransportID", "phoneApplicationKey", "issuedAt", "expiresAt"}

type envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

// Digest is the lower-case hex SHA-256 of a message's exact envelope bytes.
func Digest(envelope string) string { return hexSHA256([]byte(envelope)) }

func hexSHA256(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// OfficeID is the office identifier derived from an office application key, as in the peer
// binding.
func OfficeID(officeApplicationKey ed25519.PublicKey) string {
	sum := sha256.Sum256(officeApplicationKey)
	return "office-" + hex.EncodeToString(sum[:12])
}

// SigningInput is the exact bytes a message's signature covers: the domain, one zero byte, the
// payload.
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

func sign(domain string, v any, key ed25519.PrivateKey, limit int) (string, error) {
	if len(key) != ed25519.PrivateKeySize {
		return "", ErrSignature
	}
	payload, e := json.Marshal(v)
	if e != nil {
		return "", e
	}
	return seal(payload, ed25519.Sign(key, SigningInput(domain, payload)), limit)
}

// open returns an envelope's payload after the closed-object and encoding checks and the
// signature check under key.
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

func publicKey(text string) (ed25519.PublicKey, bool) {
	b, e := base64.StdEncoding.Strict().DecodeString(text)
	if e != nil || len(b) != ed25519.PublicKeySize || base64.StdEncoding.EncodeToString(b) != text {
		return nil, false
	}
	return ed25519.PublicKey(b), true
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

// nonce is 256 random bits as 43 characters of URL-safe base64 without padding.
func nonce(s string) bool {
	b, e := base64.RawURLEncoding.Strict().DecodeString(s)
	return e == nil && len(b) == 32 && base64.RawURLEncoding.EncodeToString(b) == s
}

func printable(s string, max int) bool {
	if len(s) > max {
		return false
	}
	for _, c := range []byte(s) {
		if c < 0x20 || c >= 0x7f {
			return false
		}
	}
	return true
}

func instant(n int64) bool { return n > 0 && n <= maximumSafeInteger }

// ---------------------------------------------------------------------------------------------
// The peer binding, as far as a renewal needs to read it
// ---------------------------------------------------------------------------------------------

// ReadBinding checks a peer-binding envelope's form and its administrator signature and returns
// its payload and binding digest (the SHA-256 of the payload bytes). It does not look at the
// clock, and it is not the phone's binding gate: that also compares the binding with the
// phone's own keys and the office identities a person reviewed.
func ReadBinding(text string, administratorKey ed25519.PublicKey) (officepreview.PeerBinding, string, error) {
	var b officepreview.PeerBinding
	payload, e := open(text, BindingDomain, administratorKey, bindingFields, maximumBinding)
	if e != nil {
		return b, "", e
	}
	if json.Unmarshal(payload, &b) != nil {
		return b, "", ErrMalformed
	}
	_, officeKey := publicKey(b.OfficeApplicationKey)
	_, phoneKey := publicKey(b.PhoneApplicationKey)
	if b.Version != 1 || b.Kind != bindingKind || !safeIdentifier(b.OrganizationID) || !safeIdentifier(b.ProfileID) ||
		!safeIdentifier(b.EnrolmentID) || !safeIdentifier(b.OfficeID) || !instant(b.Generation) ||
		!transportID(b.OfficeTransportID) || !transportID(b.PhoneTransportID) || !officeKey || !phoneKey ||
		!instant(b.IssuedAt) || !instant(b.ExpiresAt) || b.ExpiresAt <= b.IssuedAt || b.ExpiresAt-b.IssuedAt > maximumBindingLifetime {
		return b, "", ErrFields
	}
	return b, hexSHA256(payload), nil
}

// CheckRenewal says whether next is a renewal of held (contract §6): every identity the same, a
// higher generation, and inside its own validity window at now.
func CheckRenewal(held, next officepreview.PeerBinding, now int64) error {
	if next.OrganizationID != held.OrganizationID || next.ProfileID != held.ProfileID || next.EnrolmentID != held.EnrolmentID ||
		next.OfficeID != held.OfficeID || next.OfficeTransportID != held.OfficeTransportID ||
		next.OfficeApplicationKey != held.OfficeApplicationKey || next.PhoneTransportID != held.PhoneTransportID ||
		next.PhoneApplicationKey != held.PhoneApplicationKey || next.Generation <= held.Generation {
		return ErrBinding
	}
	if now < next.IssuedAt || now >= next.ExpiresAt {
		return ErrTime
	}
	return nil
}

// ---------------------------------------------------------------------------------------------
// Challenge
// ---------------------------------------------------------------------------------------------

func (c Challenge) valid() bool {
	return c.Version == 1 && c.Kind == ChallengeKind && lowerHex(c.ChallengeID, 32) && nonce(c.Nonce) &&
		safeIdentifier(c.OrganizationID) && safeIdentifier(c.EnrolmentID) && safeIdentifier(c.OfficeID) &&
		transportID(c.PhoneTransportID) && instant(c.Generation) && lowerHex(c.BindingSHA256, 64) &&
		instant(c.IssuedAt) && instant(c.ExpiresAt) && c.ExpiresAt > c.IssuedAt && c.ExpiresAt-c.IssuedAt <= MaximumChallengeLifetime
}

// Live says whether the challenge may be answered, or renewed against, at now.
func (c Challenge) Live(now int64) bool { return now >= c.IssuedAt && now < c.ExpiresAt }

// SignChallenge signs a challenge with the office application key. For a key held in process.
func SignChallenge(c Challenge, officeKey ed25519.PrivateKey) (string, error) {
	if !c.valid() || len(officeKey) != ed25519.PrivateKeySize || c.OfficeID != OfficeID(officeKey.Public().(ed25519.PublicKey)) {
		return "", ErrFields
	}
	return sign(ChallengeDomain, c, officeKey, MaximumMessage)
}

// SignChallengePayload signs exact challenge payload bytes a caller built, so the office's
// record of a challenge and what a phone verifies are the same bytes. It is for the process
// that holds the office application key on behalf of another: the payload must be a closed,
// valid challenge that names the office the key belongs to, issued no more than a few minutes
// ahead and not expired.
func SignChallengePayload(raw []byte, officeKey ed25519.PrivateKey, now int64) (string, error) {
	if len(officeKey) != ed25519.PrivateKeySize {
		return "", ErrSignature
	}
	var c Challenge
	if len(raw) == 0 || len(raw) > MaximumMessage || !officepreview.Flat(raw, challengeFields) || json.Unmarshal(raw, &c) != nil {
		return "", ErrMalformed
	}
	if !c.valid() {
		return "", ErrFields
	}
	if c.OfficeID != OfficeID(officeKey.Public().(ed25519.PublicKey)) {
		return "", ErrOther
	}
	if c.IssuedAt > now+MaximumIssueSkew || now >= c.ExpiresAt {
		return "", ErrTime
	}
	return seal(raw, ed25519.Sign(officeKey, SigningInput(ChallengeDomain, raw)), MaximumMessage)
}

// ReadChallenge checks a challenge's form and its signature under the office application key
// the binding names. It does not look at the clock (see Live) or at which binding it names
// (see Names).
func ReadChallenge(text string, officeKey ed25519.PublicKey) (Challenge, error) {
	var c Challenge
	payload, e := open(text, ChallengeDomain, officeKey, challengeFields, MaximumMessage)
	if e != nil {
		return c, e
	}
	if json.Unmarshal(payload, &c) != nil {
		return Challenge{}, ErrMalformed
	}
	if !c.valid() || c.OfficeID != OfficeID(officeKey) {
		return Challenge{}, ErrFields
	}
	return c, nil
}

// Names says whether the challenge is set under exactly this binding: its organisation,
// enrolment, office, phone transport identity, generation and binding digest.
func (c Challenge) Names(b officepreview.PeerBinding, bindingSHA256 string) bool {
	return c.OrganizationID == b.OrganizationID && c.EnrolmentID == b.EnrolmentID && c.OfficeID == b.OfficeID &&
		c.PhoneTransportID == b.PhoneTransportID && c.Generation == b.Generation && c.BindingSHA256 == bindingSHA256
}

// ---------------------------------------------------------------------------------------------
// Check-in
// ---------------------------------------------------------------------------------------------

func (c CheckIn) valid() bool {
	return c.Version == 1 && c.Kind == CheckInKind && lowerHex(c.ChallengeID, 32) && lowerHex(c.ChallengeSHA256, 64) &&
		nonce(c.Nonce) && safeIdentifier(c.OrganizationID) && safeIdentifier(c.EnrolmentID) && safeIdentifier(c.OfficeID) &&
		transportID(c.PhoneTransportID) && instant(c.Generation) && lowerHex(c.BindingSHA256, 64) &&
		instant(c.LeaseRenewBy) && printable(c.AppVersion, 64) && printable(c.AppBuild, 64) && instant(c.CreatedAt)
}

// CheckInFor fills a check-in's addressing from the challenge it answers. The caller has
// already checked that the challenge names the binding the phone holds; nonce is the phone's
// own.
func CheckInFor(challengeEnvelope string, c Challenge, nonce string, leaseRenewBy int64, appVersion, appBuild string, createdAt int64) CheckIn {
	return CheckIn{1, CheckInKind, c.ChallengeID, Digest(challengeEnvelope), nonce, c.OrganizationID, c.EnrolmentID, c.OfficeID,
		c.PhoneTransportID, c.Generation, c.BindingSHA256, leaseRenewBy, appVersion, appBuild, createdAt}
}

// CheckInPayload is the exact bytes a phone signs. The phone application key lives in
// device-only storage outside the transport, so signing is in two steps: these bytes, signed
// under CheckInDomain (see SigningInput), then SealCheckIn.
func CheckInPayload(c CheckIn) ([]byte, error) {
	if !c.valid() {
		return nil, ErrFields
	}
	return json.Marshal(c)
}

// SealCheckIn wraps a check-in payload with the signature the phone application key made.
func SealCheckIn(payload, signature []byte) (string, error) {
	var c CheckIn
	if !officepreview.Flat(payload, checkInFields) || json.Unmarshal(payload, &c) != nil || !c.valid() {
		return "", ErrMalformed
	}
	return seal(payload, signature, MaximumMessage)
}

// SignCheckIn does both steps for a key held in process, which only fixtures, tests and
// stand-in phones have.
func SignCheckIn(c CheckIn, phoneKey ed25519.PrivateKey) (string, error) {
	if !c.valid() {
		return "", ErrFields
	}
	return sign(CheckInDomain, c, phoneKey, MaximumMessage)
}

// ReadCheckIn checks a check-in's form and its signature under the phone application key the
// binding names — never a key from the check-in.
func ReadCheckIn(text string, phoneKey ed25519.PublicKey) (CheckIn, error) {
	var c CheckIn
	payload, e := open(text, CheckInDomain, phoneKey, checkInFields, MaximumMessage)
	if e != nil {
		return c, e
	}
	if json.Unmarshal(payload, &c) != nil {
		return CheckIn{}, ErrMalformed
	}
	if !c.valid() {
		return CheckIn{}, ErrFields
	}
	return c, nil
}

// Answers says whether the check-in answers exactly this challenge: its identifier and message
// digest, and the same binding.
func (c CheckIn) Answers(challengeEnvelope string, ch Challenge) bool {
	return c.ChallengeID == ch.ChallengeID && c.ChallengeSHA256 == Digest(challengeEnvelope) &&
		c.OrganizationID == ch.OrganizationID && c.EnrolmentID == ch.EnrolmentID && c.OfficeID == ch.OfficeID &&
		c.PhoneTransportID == ch.PhoneTransportID && c.Generation == ch.Generation && c.BindingSHA256 == ch.BindingSHA256
}

// Exchange is one verified challenge and check-in under one binding.
type Exchange struct {
	Challenge     Challenge
	CheckIn       CheckIn
	Binding       officepreview.PeerBinding
	BindingSHA256 string
}

// Renewable is the office's check before a renewal (contract §5, conditions 1 to 4), on the
// exact envelopes it holds: the binding is the administrator's and names this office
// application key; the challenge is this office's, live at now and set under that binding; the
// check-in is signed by the phone application key in that binding and answers that challenge;
// and the binding is still inside its validity window.
//
// It cannot know whether the challenge was already used or withdrawn, whether this is the
// latest binding issued, or whether the enrolment was removed: those are the caller's durable
// records.
func Renewable(challengeEnvelope, checkInEnvelope, bindingEnvelope string, officeKey, administratorKey ed25519.PublicKey, now int64) (Exchange, error) {
	binding, digest, e := ReadBinding(bindingEnvelope, administratorKey)
	if e != nil {
		return Exchange{}, e
	}
	if binding.OfficeApplicationKey != base64.StdEncoding.EncodeToString(officeKey) || binding.OfficeID != OfficeID(officeKey) {
		return Exchange{}, ErrOther
	}
	challenge, e := ReadChallenge(challengeEnvelope, officeKey)
	if e != nil {
		return Exchange{}, e
	}
	if !challenge.Names(binding, digest) {
		return Exchange{}, ErrOther
	}
	phoneKey, _ := publicKey(binding.PhoneApplicationKey)
	checkIn, e := ReadCheckIn(checkInEnvelope, phoneKey)
	if e != nil {
		return Exchange{}, e
	}
	if !checkIn.Answers(challengeEnvelope, challenge) {
		return Exchange{}, ErrOther
	}
	if !challenge.Live(now) || now < binding.IssuedAt || now >= binding.ExpiresAt {
		return Exchange{}, ErrTime
	}
	return Exchange{challenge, checkIn, binding, digest}, nil
}

// ---------------------------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------------------------

func (r Result) valid() bool {
	return r.Version == 1 && r.Kind == ResultKind && lowerHex(r.ChallengeID, 32) && lowerHex(r.CheckInSHA256, 64) &&
		safeIdentifier(r.OrganizationID) && safeIdentifier(r.EnrolmentID) && safeIdentifier(r.OfficeID) &&
		transportID(r.PhoneTransportID) && r.Outcome == OutcomeRenewed &&
		len(r.PeerBinding) > 0 && len(r.PeerBinding) <= maximumBinding && instant(r.IssuedAt)
}

// ResultFor is the result that answers a verified exchange with a renewed binding.
func ResultFor(x Exchange, checkInEnvelope, renewedBinding string, issuedAt int64) Result {
	return Result{1, ResultKind, x.Challenge.ChallengeID, Digest(checkInEnvelope), x.Binding.OrganizationID, x.Binding.EnrolmentID,
		x.Binding.OfficeID, x.Binding.PhoneTransportID, OutcomeRenewed, renewedBinding, issuedAt}
}

// SignResultWith signs a result with the administrator key behind sign, which is given the
// exact bytes to sign.
func SignResultWith(r Result, sign func(message []byte) []byte) (string, error) {
	if !r.valid() || sign == nil {
		return "", ErrFields
	}
	payload, e := json.Marshal(r)
	if e != nil {
		return "", e
	}
	return seal(payload, sign(SigningInput(ResultDomain, payload)), MaximumResult)
}

// SignResult is SignResultWith for a key held in process.
func SignResult(r Result, administratorKey ed25519.PrivateKey) (string, error) {
	if len(administratorKey) != ed25519.PrivateKeySize {
		return "", ErrSignature
	}
	return SignResultWith(r, func(message []byte) []byte { return ed25519.Sign(administratorKey, message) })
}

// ReadResult is the phone's check of a result (contract §7, steps 1 to 3 as far as the messages
// go): signed by the administrator key, for exactly the check-in the phone is waiting on, and
// carrying a binding that is a renewal of the one the phone holds, valid at now. It returns the
// renewed binding's payload and digest.
//
// It is not the whole of step 3: the phone must still put the renewed binding through its own
// gate — its own keys, the office identities a person reviewed, the generation high-water mark
// — and recheck the profile, licence and lease before it commits anything.
func ReadResult(text string, administratorKey ed25519.PublicKey, checkInEnvelope string, waiting CheckIn, held officepreview.PeerBinding, now int64) (Result, officepreview.PeerBinding, string, error) {
	var r Result
	var none officepreview.PeerBinding
	payload, e := open(text, ResultDomain, administratorKey, resultFields, MaximumResult)
	if e != nil {
		return r, none, "", e
	}
	if json.Unmarshal(payload, &r) != nil {
		return Result{}, none, "", ErrMalformed
	}
	if !r.valid() {
		return Result{}, none, "", ErrFields
	}
	if r.ChallengeID != waiting.ChallengeID || r.CheckInSHA256 != Digest(checkInEnvelope) ||
		r.OrganizationID != held.OrganizationID || r.EnrolmentID != held.EnrolmentID ||
		r.OfficeID != held.OfficeID || r.PhoneTransportID != held.PhoneTransportID {
		return Result{}, none, "", ErrOther
	}
	next, digest, e := ReadBinding(r.PeerBinding, administratorKey)
	if e != nil {
		return Result{}, none, "", e
	}
	if e = CheckRenewal(held, next, now); e != nil {
		return Result{}, none, "", e
	}
	return r, next, digest, nil
}

// ---------------------------------------------------------------------------------------------
// Removal
// ---------------------------------------------------------------------------------------------

func (r Removal) valid() bool {
	return r.Version == 1 && r.Kind == RemovalKind && lowerHex(r.RemovalID, 32) && safeIdentifier(r.OrganizationID) &&
		safeIdentifier(r.ProfileID) && safeIdentifier(r.EnrolmentID) && safeIdentifier(r.OfficeID) &&
		transportID(r.PhoneTransportID) && (r.Reason == ReasonRemoved || r.Reason == ReasonRevoked) && instant(r.IssuedAt)
}

// ParseRemoval reads exact removal payload bytes a caller built: closed and valid.
func ParseRemoval(raw []byte) (Removal, error) {
	var r Removal
	if len(raw) == 0 || len(raw) > MaximumMessage || !officepreview.Flat(raw, removalFields) || json.Unmarshal(raw, &r) != nil {
		return Removal{}, ErrMalformed
	}
	if !r.valid() {
		return Removal{}, ErrFields
	}
	return r, nil
}

// SealRemoval wraps removal payload bytes with the administrator's signature over them.
func SealRemoval(raw, signature []byte) (string, error) {
	if _, e := ParseRemoval(raw); e != nil {
		return "", e
	}
	return seal(raw, signature, MaximumMessage)
}

// SignRemoval signs a removal with an administrator key held in process.
func SignRemoval(r Removal, administratorKey ed25519.PrivateKey) (string, error) {
	if !r.valid() {
		return "", ErrFields
	}
	return sign(RemovalDomain, r, administratorKey, MaximumMessage)
}

// ReadRemoval is the phone's check of a removal: signed by the administrator key from its
// vendor-verified profile, and naming its own organisation, profile, enrolment and transport
// identity. There is no clock and no generation: a removal is final, and an exact repeat
// changes nothing.
func ReadRemoval(text string, administratorKey ed25519.PublicKey, organizationID, profileID, enrolmentID, phoneTransportID string) (Removal, error) {
	payload, e := open(text, RemovalDomain, administratorKey, removalFields, MaximumMessage)
	if e != nil {
		return Removal{}, e
	}
	r, e := ParseRemoval(payload)
	if e != nil {
		return Removal{}, e
	}
	if r.OrganizationID != organizationID || r.ProfileID != profileID || r.EnrolmentID != enrolmentID || r.PhoneTransportID != phoneTransportID {
		return Removal{}, ErrOther
	}
	return r, nil
}

func (r RemovalReceipt) valid() bool {
	return r.Version == 1 && r.Kind == RemovalReceiptKind && lowerHex(r.RemovalID, 32) && lowerHex(r.RemovalSHA256, 64) &&
		safeIdentifier(r.OrganizationID) && safeIdentifier(r.EnrolmentID) && transportID(r.PhoneTransportID) && instant(r.ActedAt)
}

// RemovalReceiptFor is the receipt for a verified removal.
func RemovalReceiptFor(removalEnvelope string, r Removal, actedAt int64) RemovalReceipt {
	return RemovalReceipt{1, RemovalReceiptKind, r.RemovalID, Digest(removalEnvelope), r.OrganizationID, r.EnrolmentID, r.PhoneTransportID, actedAt}
}

// RemovalReceiptPayload is the exact bytes a phone signs under RemovalReceiptDomain.
func RemovalReceiptPayload(r RemovalReceipt) ([]byte, error) {
	if !r.valid() {
		return nil, ErrFields
	}
	return json.Marshal(r)
}

// SealRemovalReceipt wraps a receipt payload with the phone application key's signature.
func SealRemovalReceipt(payload, signature []byte) (string, error) {
	var r RemovalReceipt
	if !officepreview.Flat(payload, removalReceiptFields) || json.Unmarshal(payload, &r) != nil || !r.valid() {
		return "", ErrMalformed
	}
	return seal(payload, signature, MaximumMessage)
}

// SignRemovalReceipt does both steps for a key held in process.
func SignRemovalReceipt(r RemovalReceipt, phoneKey ed25519.PrivateKey) (string, error) {
	if !r.valid() {
		return "", ErrFields
	}
	return sign(RemovalReceiptDomain, r, phoneKey, MaximumMessage)
}

// ReadRemovalReceipt is the office's check: signed by the phone application key from the
// binding, never from the receipt, and for exactly the removal the office sent.
func ReadRemovalReceipt(text string, phoneKey ed25519.PublicKey, removalEnvelope string, sent Removal) (RemovalReceipt, error) {
	var r RemovalReceipt
	payload, e := open(text, RemovalReceiptDomain, phoneKey, removalReceiptFields, MaximumMessage)
	if e != nil {
		return r, e
	}
	if json.Unmarshal(payload, &r) != nil {
		return RemovalReceipt{}, ErrMalformed
	}
	if !r.valid() {
		return RemovalReceipt{}, ErrFields
	}
	if r.RemovalID != sent.RemovalID || r.RemovalSHA256 != Digest(removalEnvelope) || r.OrganizationID != sent.OrganizationID ||
		r.EnrolmentID != sent.EnrolmentID || r.PhoneTransportID != sent.PhoneTransportID {
		return RemovalReceipt{}, ErrOther
	}
	return r, nil
}
