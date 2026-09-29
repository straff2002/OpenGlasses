// Package manualassignment implements the draft FX1 assignment contract. Authority is supplied
// by a previously verified commissioning binding; no key supplied by a message is trusted.
package manualassignment

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strconv"
)

const Domain = "Avenkin.ManualAssignment.v1\x00"
const MaximumEnvelopeBytes = 32768
const MaximumSafeInteger int64 = 9007199254740991

type Payload struct {
	Version        int    `json:"version"`
	Kind           string `json:"kind"`
	AssignmentID   string `json:"assignmentID"`
	OrganizationID string `json:"organizationID"`
	EnrolmentID    string `json:"enrolmentID"`
	OfficeID       string `json:"officeID"`
	Generation     int64  `json:"generation"`
	SetID          string `json:"setID"`
	Sequence       int64  `json:"sequence"`
	IssuedAt       int64  `json:"issuedAt"`
	ExpiresAt      int64  `json:"expiresAt"`
	VaultID        string `json:"vaultID"`
	VaultVersion   string `json:"vaultVersion"`
	PublisherID    string `json:"publisherID"`
	ArchiveSHA256  string `json:"archiveSHA256"`
	ArchiveBytes   int64  `json:"archiveBytes"`
}
type Envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}
type Trust struct {
	OrganizationID, EnrolmentID, OfficeID, SetID string
	Generation, MaximumArchiveBytes              int64
	PublicKey                                    ed25519.PublicKey
}
type HighWater struct {
	Generation    int64  `json:"generation"`
	Sequence      int64  `json:"sequence"`
	PayloadSHA256 string `json:"payloadSHA256"`
}
type Verified struct {
	Payload       Payload
	PayloadSHA256 string
	IsReplay      bool
}

func (v Verified) HighWater() HighWater {
	return HighWater{v.Payload.Generation, v.Payload.Sequence, v.PayloadSHA256}
}
func (v Verified) ScopeID() string {
	return digest([]byte(v.Payload.OrganizationID + "\x00" + v.Payload.EnrolmentID + "\x00" + v.Payload.SetID))
}

var (
	ErrMalformed = errors.New("malformed assignment")
	ErrSignature = errors.New("bad assignment signature")
	ErrVersion   = errors.New("unsupported assignment version")
	ErrAuthority = errors.New("wrong recipient or authority")
	ErrFields    = errors.New("invalid assignment fields")
	ErrTime      = errors.New("assignment not currently valid")
	ErrPolicy    = errors.New("assignment exceeds policy")
	ErrRollback  = errors.New("assignment rollback")
	ErrConflict  = errors.New("assignment sequence conflict")
)

func Verify(data []byte, trust Trust, now int64, previous *HighWater) (Verified, error) {
	var empty Verified
	var e Envelope
	if len(data) > MaximumEnvelopeBytes || !flatObject(data, []string{"payload", "signature"}) || json.Unmarshal(data, &e) != nil {
		return empty, ErrMalformed
	}
	raw, err := base64.StdEncoding.DecodeString(e.Payload)
	if err != nil {
		return empty, ErrMalformed
	}
	signature, err := base64.StdEncoding.DecodeString(e.Signature)
	if err != nil {
		return empty, ErrMalformed
	}
	if len(trust.PublicKey) != ed25519.PublicKeySize || !ed25519.Verify(trust.PublicKey, append([]byte(Domain), raw...), signature) {
		return empty, ErrSignature
	}
	var p Payload
	if !flatObject(raw, []string{"version", "kind", "assignmentID", "organizationID", "enrolmentID", "officeID", "generation", "setID", "sequence", "issuedAt", "expiresAt", "vaultID", "vaultVersion", "publisherID", "archiveSHA256", "archiveBytes"}) || json.Unmarshal(raw, &p) != nil {
		return empty, ErrMalformed
	}
	if p.Version != 1 || p.Kind != "avenkin.manual-assignment" {
		return empty, ErrVersion
	}
	if p.OrganizationID != trust.OrganizationID || p.EnrolmentID != trust.EnrolmentID || p.OfficeID != trust.OfficeID || p.Generation != trust.Generation || p.SetID != trust.SetID {
		return empty, ErrAuthority
	}
	for _, id := range []string{p.OrganizationID, p.EnrolmentID, p.OfficeID, p.SetID, p.VaultID, p.PublisherID} {
		if !safeID(id) {
			return empty, ErrFields
		}
	}
	if !isHex(p.AssignmentID, 32) || !isHex(p.ArchiveSHA256, 64) || !safeVersion(p.VaultVersion) || p.Generation <= 0 || p.Generation > MaximumSafeInteger || p.Sequence <= 0 || p.Sequence > MaximumSafeInteger || p.IssuedAt <= 0 || p.ExpiresAt <= p.IssuedAt || p.ExpiresAt > MaximumSafeInteger || p.ArchiveBytes <= 0 || p.ArchiveBytes > MaximumSafeInteger {
		return empty, ErrFields
	}
	if now < p.IssuedAt || now >= p.ExpiresAt {
		return empty, ErrTime
	}
	if p.ArchiveBytes > trust.MaximumArchiveBytes {
		return empty, ErrPolicy
	}
	v := Verified{Payload: p, PayloadSHA256: digest(raw)}
	if previous != nil {
		if p.Generation < previous.Generation || (p.Generation == previous.Generation && p.Sequence < previous.Sequence) {
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

// Sign runs only on the issuing desktop/test side. It does not grant vendor entitlements or
// publisher authority. The phone imports no private key and does not call this function.
func Sign(p Payload, privateKey ed25519.PrivateKey) ([]byte, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, ErrSignature
	}
	raw, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	return json.Marshal(Envelope{base64.StdEncoding.EncodeToString(raw), base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, append([]byte(Domain), raw...)))})
}
func digest(b []byte) string { sum := sha256.Sum256(b); return hex.EncodeToString(sum[:]) }
func safeID(s string) bool {
	if len(s) == 0 || len(s) > 80 || s == "." || s == ".." {
		return false
	}
	for _, c := range []byte(s) {
		if !(c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}
func safeVersion(s string) bool {
	if len(s) == 0 || len(s) > 80 {
		return false
	}
	for _, c := range []byte(s) {
		if c < 0x21 || c > 0x7e {
			return false
		}
	}
	return true
}
func isHex(s string, n int) bool {
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

// Closed flat schema: no duplicate/unknown keys, nested values or fractional/exponent integers.
func flatObject(data []byte, keys []string) bool {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	t, err := d.Token()
	if err != nil || t != json.Delim('{') {
		return false
	}
	expected := map[string]bool{}
	seen := map[string]bool{}
	for _, k := range keys {
		expected[k] = true
	}
	for d.More() {
		t, err = d.Token()
		if err != nil {
			return false
		}
		k, ok := t.(string)
		if !ok || !expected[k] || seen[k] {
			return false
		}
		seen[k] = true
		t, err = d.Token()
		if err != nil {
			return false
		}
		switch v := t.(type) {
		case string:
		case json.Number:
			if _, err = strconv.ParseInt(string(v), 10, 64); err != nil {
				return false
			}
		default:
			return false
		}
	}
	t, err = d.Token()
	if err != nil || t != json.Delim('}') || len(seen) != len(expected) {
		return false
	}
	_, err = d.Token()
	return err == io.EOF
}
