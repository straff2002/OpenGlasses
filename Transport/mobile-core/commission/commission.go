// Package commission is the reference implementation of the office commissioning contract
// (Contracts/commissioning.md): the invitation an office shows as a QR code, the redemption a
// phone answers with, the comparison code both show, and the office's approval or refusal.
//
// It is messages only. It opens no connection, stores nothing and holds no key: callers pass
// the key that signs and the clock. Nothing here is authority. An approval carries the
// vendor-signed profile, the licence and the administrator-signed peer binding as opaque text,
// and the phone verifies each of those with the code it already has.
//
// The connection that carries these messages is the sibling package commission/bootstrap.
package commission

import (
	"avenkin.dev/mobilecore/officepreview"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"strconv"
	"strings"

	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	InvitationDomain = "Avenkin.CommissionInvitation.v1"
	RedemptionDomain = "Avenkin.CommissionRedemption.v1"
	ApprovalDomain   = "Avenkin.CommissionApproval.v1"
	ComparisonDomain = "Avenkin.CommissionComparison.v1"

	InvitationKind = "avenkin.commission-invitation"
	RedemptionKind = "avenkin.commission-redemption"
	ApprovalKind   = "avenkin.commission-approval"
	RefusalKind    = "avenkin.commission-refusal"

	// QRPrefix starts the text of an invitation QR code. It is not a URL scheme: the system
	// camera shows it as text, and only the in-app scanner acts on it.
	QRPrefix = "avenkin-commission:"

	// MaximumLifetime is how long an invitation may be valid, in seconds.
	MaximumLifetime = 900

	MaximumInvitation = 2048
	MaximumRedemption = 4096
	MaximumDecision   = 131072

	maximumProfile     = 32768
	maximumLicence     = 16384
	maximumPeerBinding = 32768
	maximumSafeInteger = int64(9007199254740991)
)

// Invitation is what the office shows. It lets a phone find the office and recognise it in the
// next two messages; it grants nothing.
type Invitation struct {
	Version              int    `json:"version"`
	Kind                 string `json:"kind"`
	Invitation           string `json:"invitation"`
	OrganizationID       string `json:"organizationID"`
	OfficeID             string `json:"officeID"`
	OfficeApplicationKey string `json:"officeApplicationKey"`
	OfficeTransportID    string `json:"officeTransportID"`
	Address              string `json:"address"`
	IssuedAt             int64  `json:"issuedAt"`
	ExpiresAt            int64  `json:"expiresAt"`
}

// Redemption is the phone's answer. Its signature is the proof that the phone holds the
// application key it presents, bound to one invitation by that invitation's digest.
type Redemption struct {
	Version             int    `json:"version"`
	Kind                string `json:"kind"`
	InvitationSHA256    string `json:"invitationSHA256"`
	Invitation          string `json:"invitation"`
	EnrolmentID         string `json:"enrolmentID"`
	PhoneTransportID    string `json:"phoneTransportID"`
	PhoneApplicationKey string `json:"phoneApplicationKey"`
	AppVersion          string `json:"appVersion"`
	AppBuild            string `json:"appBuild"`
	ExistingEnrolment   string `json:"existingEnrolment"`
	CreatedAt           int64  `json:"createdAt"`
}

// Approval carries the three artefacts the phone already knows how to verify, as their exact
// original text. The approval's own signature only says which office sent them.
type Approval struct {
	Version             int    `json:"version"`
	Kind                string `json:"kind"`
	InvitationSHA256    string `json:"invitationSHA256"`
	RedemptionSHA256    string `json:"redemptionSHA256"`
	EnrolmentID         string `json:"enrolmentID"`
	PhoneTransportID    string `json:"phoneTransportID"`
	PhoneApplicationKey string `json:"phoneApplicationKey"`
	ProfileDocument     string `json:"profileDocument"`
	LicenceCode         string `json:"licenceCode"`
	PeerBinding         string `json:"peerBinding"`
	IssuedAt            int64  `json:"issuedAt"`
}

// Refusal ends an exchange without artefacts.
type Refusal struct {
	Version          int    `json:"version"`
	Kind             string `json:"kind"`
	InvitationSHA256 string `json:"invitationSHA256"`
	RedemptionSHA256 string `json:"redemptionSHA256"`
	Reason           string `json:"reason"`
	IssuedAt         int64  `json:"issuedAt"`
}

// Decision is what the phone reads back: exactly one of the two is set.
type Decision struct {
	Approval *Approval
	Refusal  *Refusal
}

var invitationFields = []string{"version", "kind", "invitation", "organizationID", "officeID", "officeApplicationKey", "officeTransportID", "address", "issuedAt", "expiresAt"}
var redemptionFields = []string{"version", "kind", "invitationSHA256", "invitation", "enrolmentID", "phoneTransportID", "phoneApplicationKey", "appVersion", "appBuild", "existingEnrolment", "createdAt"}
var approvalFields = []string{"version", "kind", "invitationSHA256", "redemptionSHA256", "enrolmentID", "phoneTransportID", "phoneApplicationKey", "profileDocument", "licenceCode", "peerBinding", "issuedAt"}
var refusalFields = []string{"version", "kind", "invitationSHA256", "redemptionSHA256", "reason", "issuedAt"}

// RefusalReasons is the closed set a refusal may give.
var RefusalReasons = []string{"expired", "already_used", "wrong_organisation", "refused_by_person", "policy"}

type envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

// Digest is the lower-case hex SHA-256 of a message's exact envelope bytes.
func Digest(envelope string) string {
	sum := sha256.Sum256([]byte(envelope))
	return hex.EncodeToString(sum[:])
}

// OfficeID is the office identifier a phone derives from an office application key: the same
// derivation the peer binding uses.
func OfficeID(officeApplicationKey ed25519.PublicKey) string {
	sum := sha256.Sum256(officeApplicationKey)
	return "office-" + hex.EncodeToString(sum[:12])
}

func sign(domain string, v any, key ed25519.PrivateKey, limit int) (string, error) {
	if len(key) != ed25519.PrivateKeySize {
		return "", errors.New("missing signing identity")
	}
	payload, e := json.Marshal(v)
	if e != nil {
		return "", e
	}
	return seal(payload, ed25519.Sign(key, signingInput(domain, payload)), limit)
}

// signingInput is the exact bytes a message's signature covers: the domain, one zero byte, the
// payload.
func signingInput(domain string, payload []byte) []byte {
	return append(append([]byte(domain), 0), payload...)
}

func seal(payload, signature []byte, limit int) (string, error) {
	out, e := json.Marshal(envelope{base64.StdEncoding.EncodeToString(payload), base64.StdEncoding.EncodeToString(signature)})
	if e != nil {
		return "", e
	}
	if len(out) > limit {
		return "", errors.New("message is too large")
	}
	return string(out), nil
}

// open returns the payload bytes of an envelope after the closed-object and encoding checks.
// It does not check the signature: the key that must have signed is often inside the payload.
func open(text string, limit int) (payload, signature []byte, err error) {
	if len(text) == 0 || len(text) > limit || !officepreview.Flat([]byte(text), []string{"payload", "signature"}) {
		return nil, nil, errors.New("invalid signed envelope")
	}
	var e envelope
	if json.Unmarshal([]byte(text), &e) != nil {
		return nil, nil, errors.New("invalid signed envelope")
	}
	payload, err = base64.StdEncoding.Strict().DecodeString(e.Payload)
	if err != nil || base64.StdEncoding.EncodeToString(payload) != e.Payload {
		return nil, nil, errors.New("invalid payload encoding")
	}
	signature, err = base64.StdEncoding.Strict().DecodeString(e.Signature)
	if err != nil || len(signature) != ed25519.SignatureSize || base64.StdEncoding.EncodeToString(signature) != e.Signature {
		return nil, nil, errors.New("invalid signature encoding")
	}
	return payload, signature, nil
}

func signed(domain string, key ed25519.PublicKey, payload, signature []byte) bool {
	return len(key) == ed25519.PublicKeySize && ed25519.Verify(key, append(append([]byte(domain), 0), payload...), signature)
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
	for _, c := range s {
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

func hexDigest(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// token is 256 random bits as 43 characters of URL-safe base64 without padding.
func token(s string) bool {
	b, e := base64.RawURLEncoding.Strict().DecodeString(s)
	return e == nil && len(b) == 32 && base64.RawURLEncoding.EncodeToString(b) == s
}

// privateAddress accepts only `a.b.c.d:port` on a private IPv4 network. It is a route hint.
func privateAddress(s string) bool {
	host, port, e := net.SplitHostPort(s)
	if e != nil {
		return false
	}
	ip := net.ParseIP(host)
	n, e := strconv.Atoi(port)
	return ip != nil && ip.To4() != nil && ip.To4().String() == host && ip.IsPrivate() && e == nil && n >= 1 && n <= 65535 && strconv.Itoa(n) == port
}

func printable(s string, max int) bool {
	if len(s) > max {
		return false
	}
	for _, c := range s {
		if c < 0x20 || c == 0x7f {
			return false
		}
	}
	return true
}

func instant(n int64) bool { return n > 0 && n <= maximumSafeInteger }

func (i Invitation) valid() bool {
	key, ok := publicKey(i.OfficeApplicationKey)
	return ok && i.Version == 1 && i.Kind == InvitationKind && token(i.Invitation) &&
		safeIdentifier(i.OrganizationID) && i.OfficeID == OfficeID(key) && transportID(i.OfficeTransportID) &&
		privateAddress(i.Address) && instant(i.IssuedAt) && instant(i.ExpiresAt) &&
		i.ExpiresAt > i.IssuedAt && i.ExpiresAt-i.IssuedAt <= MaximumLifetime
}

// SignInvitation signs an invitation with the office application key it names.
func SignInvitation(i Invitation, officeKey ed25519.PrivateKey) (string, error) {
	if !i.valid() || len(officeKey) != ed25519.PrivateKeySize ||
		base64.StdEncoding.EncodeToString(officeKey.Public().(ed25519.PublicKey)) != i.OfficeApplicationKey {
		return "", errors.New("invalid invitation")
	}
	return sign(InvitationDomain, i, officeKey, MaximumInvitation)
}

// QRText is the text of the QR code for an invitation envelope.
func QRText(invitationEnvelope string) string {
	return QRPrefix + base64.RawURLEncoding.EncodeToString([]byte(invitationEnvelope))
}

// ParseQRText returns the invitation envelope inside scanned text, or an error when the text
// is not an invitation code.
func ParseQRText(text string) (string, error) {
	rest, found := strings.CutPrefix(text, QRPrefix)
	if !found {
		return "", errors.New("not a commissioning code")
	}
	b, e := base64.RawURLEncoding.Strict().DecodeString(rest)
	if e != nil || len(b) == 0 || len(b) > MaximumInvitation || base64.RawURLEncoding.EncodeToString(b) != rest {
		return "", errors.New("invalid commissioning code")
	}
	return string(b), nil
}

// ReadInvitation checks an invitation as the phone does before it connects: well formed, signed
// by the key it names, and live at `now`. That signature is not trust — anyone can make an
// invitation — it only fixes which office the next two messages must come from.
func ReadInvitation(invitationEnvelope string, now int64) (Invitation, error) {
	var i Invitation
	payload, signature, e := open(invitationEnvelope, MaximumInvitation)
	if e != nil || !officepreview.Flat(payload, invitationFields) || json.Unmarshal(payload, &i) != nil || !i.valid() {
		return Invitation{}, errors.New("invalid invitation")
	}
	key, _ := publicKey(i.OfficeApplicationKey)
	if !signed(InvitationDomain, key, payload, signature) {
		return Invitation{}, errors.New("invitation is not signed by the office it names")
	}
	if now < i.IssuedAt || now >= i.ExpiresAt {
		return Invitation{}, errors.New("invitation is not live")
	}
	return i, nil
}

func (r Redemption) valid() bool {
	_, ok := publicKey(r.PhoneApplicationKey)
	return ok && r.Version == 1 && r.Kind == RedemptionKind && hexDigest(r.InvitationSHA256) && token(r.Invitation) &&
		safeIdentifier(r.EnrolmentID) && transportID(r.PhoneTransportID) &&
		printable(r.AppVersion, 64) && printable(r.AppBuild, 64) &&
		(r.ExistingEnrolment == "" || safeIdentifier(r.ExistingEnrolment)) && instant(r.CreatedAt)
}

// SignRedemption signs a redemption with the phone application key it names.
func SignRedemption(r Redemption, phoneKey ed25519.PrivateKey) (string, error) {
	if !r.valid() || len(phoneKey) != ed25519.PrivateKeySize ||
		base64.StdEncoding.EncodeToString(phoneKey.Public().(ed25519.PublicKey)) != r.PhoneApplicationKey {
		return "", errors.New("invalid redemption")
	}
	return sign(RedemptionDomain, r, phoneKey, MaximumRedemption)
}

// RedemptionSigningInput is SignRedemption in two halves, for a phone whose application key
// signs inside device storage and never reaches this code. It returns the redemption's payload
// and the exact bytes the phone application key must sign (the redemption domain, one zero
// byte, the payload); SealRedemption then makes the envelope. The envelope is byte-identical to
// what SignRedemption makes with the same key.
func RedemptionSigningInput(r Redemption) (payload, input []byte, err error) {
	if !r.valid() {
		return nil, nil, errors.New("invalid redemption")
	}
	payload, err = json.Marshal(r)
	if err != nil {
		return nil, nil, err
	}
	return payload, signingInput(RedemptionDomain, payload), nil
}

// SealRedemption makes the redemption envelope from a payload of RedemptionSigningInput and the
// phone's signature over its signing input, then reads it back exactly as the office will
// against `invitationEnvelope`. Anything the office would refuse is refused here.
func SealRedemption(payload, signature []byte, invitationEnvelope string) (string, error) {
	if len(signature) != ed25519.SignatureSize {
		return "", errors.New("invalid signature")
	}
	out, e := seal(payload, signature, MaximumRedemption)
	if e != nil {
		return "", e
	}
	if _, e = ReadRedemption(out, invitationEnvelope); e != nil {
		return "", e
	}
	return out, nil
}

// ReadRedemption checks a redemption as the office does: well formed, signed by the phone key
// it presents (the proof of possession), and answering exactly `invitationEnvelope`. Whether
// the invitation is still unspent is the office ledger's question, not this function's.
func ReadRedemption(redemptionEnvelope, invitationEnvelope string) (Redemption, error) {
	var r Redemption
	payload, signature, e := open(redemptionEnvelope, MaximumRedemption)
	if e != nil || !officepreview.Flat(payload, redemptionFields) || json.Unmarshal(payload, &r) != nil || !r.valid() {
		return Redemption{}, errors.New("invalid redemption")
	}
	key, _ := publicKey(r.PhoneApplicationKey)
	if !signed(RedemptionDomain, key, payload, signature) {
		return Redemption{}, errors.New("redemption is not signed by the phone key it presents")
	}
	var i Invitation
	invitationPayload, _, e := open(invitationEnvelope, MaximumInvitation)
	if e != nil || json.Unmarshal(invitationPayload, &i) != nil {
		return Redemption{}, errors.New("invalid invitation")
	}
	if r.InvitationSHA256 != Digest(invitationEnvelope) || r.Invitation != i.Invitation {
		return Redemption{}, errors.New("redemption answers another invitation")
	}
	if r.PhoneTransportID == i.OfficeTransportID || r.PhoneApplicationKey == i.OfficeApplicationKey {
		return Redemption{}, errors.New("redemption presents the office's own identity")
	}
	return r, nil
}

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// Comparison is the code both screens show until a person decides: the first 60 bits of
// SHA-256(domain, 0x00, invitation digest, redemption digest) as three groups of four Crockford
// base32 characters. The digests are the 32 raw bytes, not their hex text.
func Comparison(invitationSHA256, redemptionSHA256 string) (string, error) {
	if !hexDigest(invitationSHA256) || !hexDigest(redemptionSHA256) {
		return "", errors.New("invalid digest")
	}
	a, _ := hex.DecodeString(invitationSHA256)
	b, _ := hex.DecodeString(redemptionSHA256)
	sum := sha256.Sum256(append(append(append([]byte(ComparisonDomain), 0), a...), b...))
	var bits uint64
	for _, c := range sum[:8] {
		bits = bits<<8 | uint64(c)
	}
	out := make([]byte, 0, 14)
	for n := 0; n < 12; n++ {
		if n > 0 && n%4 == 0 {
			out = append(out, '-')
		}
		out = append(out, crockford[(bits>>(59-5*uint(n)))&31])
	}
	return string(out), nil
}

func (a Approval) valid() bool {
	_, ok := publicKey(a.PhoneApplicationKey)
	return ok && a.Version == 1 && a.Kind == ApprovalKind && hexDigest(a.InvitationSHA256) && hexDigest(a.RedemptionSHA256) &&
		safeIdentifier(a.EnrolmentID) && transportID(a.PhoneTransportID) &&
		len(a.ProfileDocument) > 0 && len(a.ProfileDocument) <= maximumProfile &&
		len(a.LicenceCode) > 0 && len(a.LicenceCode) <= maximumLicence &&
		len(a.PeerBinding) > 0 && len(a.PeerBinding) <= maximumPeerBinding && instant(a.IssuedAt)
}

// SignApproval signs an approval with the office application key.
func SignApproval(a Approval, officeKey ed25519.PrivateKey) (string, error) {
	if !a.valid() {
		return "", errors.New("invalid approval")
	}
	return sign(ApprovalDomain, a, officeKey, MaximumDecision)
}

func (r Refusal) valid() bool {
	known := false
	for _, reason := range RefusalReasons {
		known = known || r.Reason == reason
	}
	return known && r.Version == 1 && r.Kind == RefusalKind && hexDigest(r.InvitationSHA256) && hexDigest(r.RedemptionSHA256) && instant(r.IssuedAt)
}

// SignRefusal signs a refusal with the office application key.
func SignRefusal(r Refusal, officeKey ed25519.PrivateKey) (string, error) {
	if !r.valid() {
		return "", errors.New("invalid refusal")
	}
	return sign(ApprovalDomain, r, officeKey, MaximumDecision)
}

// ReadDecision checks the office's answer as the phone does: signed by the office application
// key of the invitation the phone scanned, about exactly this invitation and this redemption,
// and — for an approval — for the identities the phone itself sent. The three artefacts in an
// approval are returned unverified: the caller verifies the profile and licence pair, shows the
// review, then verifies the peer binding, exactly as for a setup file and a binding file.
func ReadDecision(decisionEnvelope, invitationEnvelope, redemptionEnvelope string) (Decision, error) {
	var i Invitation
	var sent Redemption
	invitationPayload, _, e := open(invitationEnvelope, MaximumInvitation)
	if e != nil || json.Unmarshal(invitationPayload, &i) != nil {
		return Decision{}, errors.New("invalid invitation")
	}
	redemptionPayload, _, e := open(redemptionEnvelope, MaximumRedemption)
	if e != nil || json.Unmarshal(redemptionPayload, &sent) != nil {
		return Decision{}, errors.New("invalid redemption")
	}
	officeKey, ok := publicKey(i.OfficeApplicationKey)
	payload, signature, e := open(decisionEnvelope, MaximumDecision)
	if !ok || e != nil || !signed(ApprovalDomain, officeKey, payload, signature) {
		return Decision{}, errors.New("answer is not signed by the office that was scanned")
	}
	invitationSHA256, redemptionSHA256 := Digest(invitationEnvelope), Digest(redemptionEnvelope)
	if officepreview.Flat(payload, refusalFields) {
		var r Refusal
		if json.Unmarshal(payload, &r) != nil || !r.valid() || r.InvitationSHA256 != invitationSHA256 || r.RedemptionSHA256 != redemptionSHA256 {
			return Decision{}, errors.New("refusal is for another exchange")
		}
		return Decision{Refusal: &r}, nil
	}
	var a Approval
	if !officepreview.Flat(payload, approvalFields) || json.Unmarshal(payload, &a) != nil || !a.valid() {
		return Decision{}, errors.New("invalid approval")
	}
	if a.InvitationSHA256 != invitationSHA256 || a.RedemptionSHA256 != redemptionSHA256 {
		return Decision{}, errors.New("approval is for another exchange")
	}
	if a.EnrolmentID != sent.EnrolmentID || a.PhoneTransportID != sent.PhoneTransportID || a.PhoneApplicationKey != sent.PhoneApplicationKey {
		return Decision{}, errors.New("approval is for another phone")
	}
	return Decision{Approval: &a}, nil
}
