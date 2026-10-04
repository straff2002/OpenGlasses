// Package recordingbundle defines the two signed messages of a recorded job
// (Contracts/recorded-session.md): the manifest a phone signs over a bundle it has sealed, and
// the receipt and later status an office signs for it.
//
// A manifest that verifies says exactly which bytes make up the bundle. It is not the bundle
// having arrived: an office gives a receipt only after it has every file and has checked every
// digest. A receipt that verifies is the only thing that lets a phone let go of a recording.
package recordingbundle

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
	// Domain and ReceiptDomain separate the two signatures from every other Avenkin signature.
	// The signed bytes are the domain, one zero byte, then the exact payload bytes.
	Domain        = "Avenkin.RecordingBundle.v1"
	ReceiptDomain = "Avenkin.RecordingReceipt.v1"

	Kind        = "avenkin.recording-bundle"
	ReceiptKind = "avenkin.recording-receipt"

	RoleTimeline   = "timeline"
	RoleTranscript = "transcript"
	RoleMedia      = "media"

	TimelinePath   = "timeline.json"
	TranscriptPath = "transcript.json"

	TrackVideo = "video"
	TrackAudio = "audio"

	// The statuses an office gives a bundle, one signed message each.
	StatusReceived  = "received"
	StatusRefused   = "refused"
	StatusReviewed  = "reviewed"
	StatusPublished = "published"
	StatusRejected  = "rejected"

	// MaximumEnvelope is the contract's cap on a manifest envelope; MaximumReceipt on a receipt.
	MaximumEnvelope = 1 << 20
	MaximumReceipt  = 8192
	// MaximumChunkBytes is the largest chunk a manifest may declare, and MaximumChunks the most
	// media chunks it may list.
	MaximumChunkBytes  = 64 << 20
	MaximumChunks      = 4096
	MaximumParts       = 256
	MaximumIssueSkew   = 300
	maximumSafeInteger = int64(9007199254740991)
)

// RefusalReasons are the reasons an office may give for refusing a bundle.
var RefusalReasons = []string{"signature", "binding", "digest", "too_large", "policy"}

// Containers are the media containers a part may be.
var Containers = []string{"mp4", "m4a"}

var (
	ErrMalformed = errors.New("malformed recording bundle message")
	ErrSignature = errors.New("invalid recording bundle signature")
	ErrAuthority = errors.New("recording bundle message is for another binding")
	ErrFields    = errors.New("invalid recording bundle fields")
	ErrTime      = errors.New("recording receipt is not currently valid")
	ErrOther     = errors.New("recording receipt is for another bundle")
	ErrContent   = errors.New("bytes differ from the manifest")
)

// File is one file of the bundle. A media file's path is "media/<sha256>.chunk".
type File struct {
	Path   string `json:"path"`
	Bytes  int64  `json:"bytes"`
	SHA256 string `json:"sha256"`
	Role   string `json:"role"`
}

// Part is one continuous piece of one track. Concatenating its chunks in order yields a file
// of Bytes bytes whose digest is SHA256.
type Part struct {
	PartID    string   `json:"partID"`
	Track     string   `json:"track"`
	Container string   `json:"container"`
	Chunks    []string `json:"chunks"`
	Bytes     int64    `json:"bytes"`
	SHA256    string   `json:"sha256"`
}

// Manifest is the closed payload a phone signs. Its one spelling is Bytes: members in this
// order, no whitespace, and no string that needs an escape.
type Manifest struct {
	Version           int    `json:"version"`
	Kind              string `json:"kind"`
	BundleID          string `json:"bundleID"`
	OrganizationID    string `json:"organizationID"`
	EnrolmentID       string `json:"enrolmentID"`
	OfficeID          string `json:"officeID"`
	Generation        int64  `json:"generation"`
	PhoneTransportID  string `json:"phoneTransportID"`
	JobSessionID      string `json:"jobSessionID"`
	JobNumber         string `json:"jobNumber"`
	CreatedAt         int64  `json:"createdAt"`
	TimelineVersion   int    `json:"timelineVersion"`
	TranscriptVersion int    `json:"transcriptVersion"`
	Blurred           bool   `json:"blurred"`
	DroppedFrames     int64  `json:"droppedFrames"`
	ConsentAt         int64  `json:"consentAt"`
	ChunkBytes        int64  `json:"chunkBytes"`
	Files             []File `json:"files"`
	Parts             []Part `json:"parts"`
}

// Receipt is the closed, flat payload an office signs: that it has the bundle, or what came of
// it. Every member is always present; one that does not apply is the empty string.
type Receipt struct {
	Version          int    `json:"version"`
	Kind             string `json:"kind"`
	BundleID         string `json:"bundleID"`
	ManifestSHA256   string `json:"manifestSHA256"`
	OrganizationID   string `json:"organizationID"`
	EnrolmentID      string `json:"enrolmentID"`
	OfficeID         string `json:"officeID"`
	Generation       int64  `json:"generation"`
	PhoneTransportID string `json:"phoneTransportID"`
	Status           string `json:"status"`
	Reason           string `json:"reason"`
	VaultID          string `json:"vaultID"`
	VaultVersion     string `json:"vaultVersion"`
	At               int64  `json:"at"`
}

var receiptFields = []string{"version", "kind", "bundleID", "manifestSHA256", "organizationID", "enrolmentID", "officeID", "generation", "phoneTransportID", "status", "reason", "vaultID", "vaultVersion", "at"}

type envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

// Trust must come from a freshly verified vendor-rooted peer binding, never from a message.
// An office reads a manifest with the phone application key; a phone reads a receipt with the
// office application key.
type Trust struct {
	OrganizationID, EnrolmentID, OfficeID, PhoneTransportID string
	Generation                                              int64
	Key                                                     ed25519.PublicKey
}

// Verified is a manifest that passed every check, and the digest of its exact payload bytes:
// what a receipt names.
type Verified struct {
	Manifest       Manifest
	ManifestSHA256 string
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

// MediaPath is where a media chunk with that digest sits in the bundle.
func MediaPath(digest string) string { return "media/" + digest + ".chunk" }

func seal(payload, signature []byte, maximum int) (string, error) {
	if len(signature) != ed25519.SignatureSize {
		return "", ErrSignature
	}
	out, e := json.Marshal(envelope{base64.StdEncoding.EncodeToString(payload), base64.StdEncoding.EncodeToString(signature)})
	if e != nil {
		return "", e
	}
	if len(out) > maximum {
		return "", ErrMalformed
	}
	return string(out), nil
}

// open checks the envelope's form and the signature over the exact payload bytes, and returns
// them. What the payload says is the caller's to check.
func open(text, domain string, key ed25519.PublicKey, maximum int) ([]byte, error) {
	if len(text) == 0 || len(text) > maximum || !officepreview.Flat([]byte(text), []string{"payload", "signature"}) {
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

// plain is printable ASCII that needs no JSON escape, so it has one spelling. Empty is plain.
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

func transportID(s string) bool {
	id, e := protocol.DeviceIDFromString(s)
	return e == nil && id != protocol.EmptyDeviceID && id.String() == s
}

func instant(n int64) bool { return n > 0 && n <= maximumSafeInteger }

func oneOf(s string, set []string) bool {
	for _, member := range set {
		if s == member {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------------------------
// The manifest
// ---------------------------------------------------------------------------------------------

func (m Manifest) valid() bool {
	if !(m.Version == 1 && m.Kind == Kind && lowerHex(m.BundleID, 32) && safeIdentifier(m.OrganizationID) &&
		safeIdentifier(m.EnrolmentID) && safeIdentifier(m.OfficeID) && instant(m.Generation) && transportID(m.PhoneTransportID) &&
		safeIdentifier(m.JobSessionID) && plain(m.JobNumber, 80) && instant(m.CreatedAt) &&
		m.TimelineVersion == 1 && m.TranscriptVersion == 1 && m.DroppedFrames >= 0 && m.DroppedFrames <= maximumSafeInteger &&
		(m.Blurred || m.DroppedFrames == 0) && instant(m.ConsentAt) && m.ConsentAt <= m.CreatedAt &&
		m.ChunkBytes > 0 && m.ChunkBytes <= MaximumChunkBytes) {
		return false
	}
	if len(m.Files) < 2 || len(m.Files) > MaximumChunks+2 || len(m.Parts) > MaximumParts {
		return false
	}
	// Every file once, at the one path its role and digest give it.
	media := map[string]int64{}
	paths := map[string]bool{}
	for _, f := range m.Files {
		if !lowerHex(f.SHA256, 64) || !instant(f.Bytes) || paths[f.Path] {
			return false
		}
		paths[f.Path] = true
		switch f.Role {
		case RoleTimeline:
			if f.Path != TimelinePath {
				return false
			}
		case RoleTranscript:
			if f.Path != TranscriptPath {
				return false
			}
		case RoleMedia:
			if f.Path != MediaPath(f.SHA256) || f.Bytes > m.ChunkBytes {
				return false
			}
			media[f.SHA256] = f.Bytes
		default:
			return false
		}
	}
	if !paths[TimelinePath] || !paths[TranscriptPath] {
		return false
	}
	// Every part is made of listed chunks, each full but the last, and every chunk is in a part.
	used := map[string]bool{}
	parts := map[string]bool{}
	for _, p := range m.Parts {
		if !safeIdentifier(p.PartID) || parts[p.PartID] || p.Track != TrackVideo && p.Track != TrackAudio ||
			!oneOf(p.Container, Containers) || !lowerHex(p.SHA256, 64) || !instant(p.Bytes) || len(p.Chunks) == 0 {
			return false
		}
		parts[p.PartID] = true
		var total int64
		for n, digest := range p.Chunks {
			size, listed := media[digest]
			if !listed || n < len(p.Chunks)-1 && size != m.ChunkBytes {
				return false
			}
			used[digest] = true
			total += size
		}
		if total != p.Bytes {
			return false
		}
	}
	return len(used) == len(media)
}

// Bytes is the one spelling of a manifest: the exact bytes a phone signs.
func (m Manifest) Bytes() ([]byte, error) {
	if !m.valid() {
		return nil, ErrFields
	}
	if m.Parts == nil {
		m.Parts = []Part{}
	}
	out, e := json.Marshal(m)
	if e != nil {
		return nil, e
	}
	if len(out) > MaximumEnvelope/2 {
		return nil, ErrMalformed
	}
	return out, nil
}

// SealManifest wraps exact manifest bytes with the signature the phone application key made
// over them under Domain. The phone's key lives in device-only storage outside the transport,
// so signing is in two steps: Bytes, signed (see SigningInput), then SealManifest.
func SealManifest(payload, signature []byte) (string, error) {
	if _, e := parseManifest(payload); e != nil {
		return "", e
	}
	return seal(payload, signature, MaximumEnvelope)
}

// SignManifest does both steps for a key held in process: fixtures, tests and stand-in phones.
func SignManifest(m Manifest, phoneKey ed25519.PrivateKey) (string, error) {
	if len(phoneKey) != ed25519.PrivateKeySize {
		return "", ErrSignature
	}
	payload, e := m.Bytes()
	if e != nil {
		return "", e
	}
	return seal(payload, ed25519.Sign(phoneKey, SigningInput(Domain, payload)), MaximumEnvelope)
}

// parseManifest accepts only the one spelling of a valid manifest.
func parseManifest(payload []byte) (Manifest, error) {
	var m Manifest
	if len(payload) == 0 || json.Unmarshal(payload, &m) != nil {
		return Manifest{}, ErrMalformed
	}
	canonical, e := m.Bytes()
	if e != nil {
		return Manifest{}, e
	}
	if string(canonical) != string(payload) {
		return Manifest{}, ErrMalformed
	}
	return m, nil
}

// ReadManifest is the office's check: the phone application key from the binding signed these
// exact bytes, they are the one spelling of a valid manifest, and it is for this binding.
// trust.Key is the phone application key and trust.Generation the binding's current generation.
// A bundle may take days to arrive, so a manifest sealed under an earlier generation of the same
// binding is still that phone's; one that names a later generation than the office has issued
// is not.
func ReadManifest(message string, trust Trust) (Verified, error) {
	payload, e := open(message, Domain, trust.Key, MaximumEnvelope)
	if e != nil {
		return Verified{}, e
	}
	m, e := parseManifest(payload)
	if e != nil {
		return Verified{}, e
	}
	if m.OrganizationID != trust.OrganizationID || m.EnrolmentID != trust.EnrolmentID || m.OfficeID != trust.OfficeID ||
		m.Generation > trust.Generation || m.PhoneTransportID != trust.PhoneTransportID {
		return Verified{}, ErrAuthority
	}
	return Verified{m, Digest(payload)}, nil
}

// CheckFile says whether data is exactly the file the manifest lists at path.
func (m Manifest) CheckFile(path string, data []byte) error {
	for _, f := range m.Files {
		if f.Path == path {
			if int64(len(data)) != f.Bytes || Digest(data) != f.SHA256 {
				return ErrContent
			}
			return nil
		}
	}
	return ErrContent
}

// CheckPart says whether a part's chunks, concatenated in order, are exactly the part the
// manifest lists. digest is the SHA-256 of the concatenation and size its length; an office
// computes both while it streams the chunks, each already checked with CheckFile.
func (m Manifest) CheckPart(partID, digest string, size int64) error {
	for _, p := range m.Parts {
		if p.PartID == partID {
			if size != p.Bytes || digest != p.SHA256 {
				return ErrContent
			}
			return nil
		}
	}
	return ErrContent
}

// ---------------------------------------------------------------------------------------------
// The receipt and later status
// ---------------------------------------------------------------------------------------------

func (r Receipt) valid() bool {
	if !(r.Version == 1 && r.Kind == ReceiptKind && lowerHex(r.BundleID, 32) && lowerHex(r.ManifestSHA256, 64) &&
		safeIdentifier(r.OrganizationID) && safeIdentifier(r.EnrolmentID) && safeIdentifier(r.OfficeID) && instant(r.Generation) &&
		transportID(r.PhoneTransportID) && instant(r.At)) {
		return false
	}
	noVault := r.VaultID == "" && r.VaultVersion == ""
	switch r.Status {
	case StatusReceived, StatusReviewed, StatusRejected:
		return r.Reason == "" && noVault
	case StatusRefused:
		return oneOf(r.Reason, RefusalReasons) && noVault
	case StatusPublished:
		return r.Reason == "" && safeIdentifier(r.VaultID) && safeIdentifier(r.VaultVersion)
	default:
		return false
	}
}

// ReceiptFor is the message an office gives a bundle it has read: status "received" only once
// it holds every file and has checked every digest.
func ReceiptFor(v Verified, status string, at int64) Receipt {
	m := v.Manifest
	return Receipt{Version: 1, Kind: ReceiptKind, BundleID: m.BundleID, ManifestSHA256: v.ManifestSHA256,
		OrganizationID: m.OrganizationID, EnrolmentID: m.EnrolmentID, OfficeID: m.OfficeID, Generation: m.Generation,
		PhoneTransportID: m.PhoneTransportID, Status: status, At: at}
}

// SignReceipt signs with a key held in process.
func SignReceipt(r Receipt, officeKey ed25519.PrivateKey) (string, error) {
	if len(officeKey) != ed25519.PrivateKeySize {
		return "", ErrSignature
	}
	if !r.valid() {
		return "", ErrFields
	}
	payload, e := json.Marshal(r)
	if e != nil {
		return "", e
	}
	return seal(payload, ed25519.Sign(officeKey, SigningInput(ReceiptDomain, payload)), MaximumReceipt)
}

// SignReceiptPayload signs exact payload bytes the caller built, so nothing is re-encoded
// between an office's record of a receipt and what a phone verifies. It is for a process that
// holds the office application key on behalf of one that does not: the payload is checked as a
// verifier would check it, must name officeID, and be dated no later than a few minutes from now.
func SignReceiptPayload(payload []byte, officeKey ed25519.PrivateKey, officeID string, now int64) (string, error) {
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
	if officeID == "" || r.OfficeID != officeID {
		return "", ErrAuthority
	}
	if r.At > now+MaximumIssueSkew {
		return "", ErrTime
	}
	return seal(payload, ed25519.Sign(officeKey, SigningInput(ReceiptDomain, payload)), MaximumReceipt)
}

// Sent is the phone's own record of the bundle a receipt must be for, and the generation its
// manifest was sealed under.
type Sent struct {
	BundleID, ManifestSHA256 string
	Generation               int64
}

// SentFor is the record a phone keeps of a manifest it sealed.
func SentFor(v Verified) Sent {
	return Sent{v.Manifest.BundleID, v.ManifestSHA256, v.Manifest.Generation}
}

// ReadReceipt is the phone's check: signed by the office application key from the binding, for
// this binding, in form, and for exactly the bundle the phone sealed. trust.Key is the office
// application key. A receipt names the generation of the manifest it answers, not the binding's
// current one, so trust.Generation is not consulted: a receipt for a bundle sealed before a
// renewal is still that bundle's. A receipt has no expiry: it is a statement of fact.
func ReadReceipt(message string, trust Trust, sent Sent) (Receipt, error) {
	payload, e := open(message, ReceiptDomain, trust.Key, MaximumReceipt)
	if e != nil {
		return Receipt{}, e
	}
	if !officepreview.Flat(payload, receiptFields) {
		return Receipt{}, ErrMalformed
	}
	var r Receipt
	if json.Unmarshal(payload, &r) != nil {
		return Receipt{}, ErrMalformed
	}
	if r.OrganizationID != trust.OrganizationID || r.EnrolmentID != trust.EnrolmentID || r.OfficeID != trust.OfficeID ||
		r.PhoneTransportID != trust.PhoneTransportID {
		return Receipt{}, ErrAuthority
	}
	if !r.valid() {
		return Receipt{}, ErrFields
	}
	if r.BundleID != sent.BundleID || r.ManifestSHA256 != sent.ManifestSHA256 || r.Generation != sent.Generation {
		return Receipt{}, ErrOther
	}
	return r, nil
}
