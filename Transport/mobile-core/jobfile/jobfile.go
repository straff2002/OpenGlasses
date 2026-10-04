// Package jobfile is the reference implementation of job-file format 2
// (Contracts/job-file.md): a job an office sends to a technician's phone, with an
// office-assigned identifier and revision, signed over its exact bytes.
//
// It reads and writes the outer file and checks the job's identity. The limits on what a job
// may say to a technician — lengths, plain text, no markup — are the phone's validator's and are
// written down in the contract; an office that wants its files accepted keeps to them.
package jobfile

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
)

const (
	// Format is the wire identifier every job file carries, in every version.
	Format = "openglasses.job"
	// Version is the format version this package writes.
	Version = 2
	// Domain separates a format-2 signature from every other signature the organisation's key
	// makes, a format-1 job file's included.
	Domain = "Avenkin.JobFile.v2"
	// MaximumBytes caps the whole file.
	MaximumBytes = 64 * 1024

	maximumSafeInteger = int64(9007199254740991)
)

var (
	ErrMalformed = errors.New("malformed job file")
	ErrVersion   = errors.New("not a format-2 job file")
	ErrFields    = errors.New("invalid job file fields")
	ErrSignature = errors.New("job file is not signed by the organisation's key")
	ErrUnsigned  = errors.New("job file is not signed")
)

// The members a format-2 job may have. A member this version does not know is refused: a file
// that carries something the phone cannot show is a file whose review would not be the whole
// truth.
var jobMembers = map[string]bool{"job_id": true, "revision": true, "job_reference": true, "site": true, "fault_report": true,
	"equipment": true, "scheduled_for": true, "notes": true, "attachments": true, "issued_by": true}

// Identity is what makes two files the same job, and orders them.
type Identity struct {
	JobID    string
	Revision int64
	// SHA256 is the digest of the job's exact bytes: two files with the same identifier and
	// revision are one job only when this is the same too.
	SHA256 string
}

type signature struct {
	Algorithm string `json:"algorithm"`
	Value     string `json:"value"`
}

type file struct {
	Format        string     `json:"format"`
	FormatVersion int        `json:"format_version"`
	Job           string     `json:"job"`
	Signature     *signature `json:"signature,omitempty"`
}

// SigningInput is the exact bytes a format-2 signature covers: the domain, one zero byte, the
// job's bytes.
func SigningInput(job []byte) []byte {
	return append(append([]byte(Domain), 0), job...)
}

func identifier(s string) bool {
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

// members returns a JSON object's members in order, refusing anything that is not exactly one
// object with no member named twice.
func members(raw []byte) (map[string]json.RawMessage, error) {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	if t, e := d.Token(); e != nil || t != json.Delim('{') {
		return nil, ErrMalformed
	}
	out := map[string]json.RawMessage{}
	for d.More() {
		t, e := d.Token()
		name, ok := t.(string)
		if e != nil || !ok {
			return nil, ErrMalformed
		}
		if _, twice := out[name]; twice {
			return nil, ErrMalformed
		}
		var value json.RawMessage
		if d.Decode(&value) != nil {
			return nil, ErrMalformed
		}
		out[name] = value
	}
	if t, e := d.Token(); e != nil || t != json.Delim('}') {
		return nil, ErrMalformed
	}
	if d.More() {
		return nil, ErrMalformed
	}
	if _, e := d.Token(); e == nil {
		return nil, ErrMalformed // trailing data
	}
	return out, nil
}

// unambiguous says raw is one JSON value in which no object, at any depth, names a member twice.
// A signature over exact bytes says nothing about which of two members a reader takes.
func unambiguous(raw []byte) bool {
	type frame struct {
		object    bool
		seen      map[string]bool
		expectKey bool
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var stack []frame
	for {
		t, e := d.Token()
		if e == io.EOF {
			return len(stack) == 0
		}
		if e != nil {
			return false
		}
		top := len(stack) - 1
		if top >= 0 && stack[top].object && stack[top].expectKey {
			if delim, closing := t.(json.Delim); closing && delim == '}' {
				stack = stack[:top]
				continue
			}
			name, ok := t.(string)
			if !ok || stack[top].seen[name] {
				return false
			}
			stack[top].seen[name], stack[top].expectKey = true, false
			continue
		}
		// A value: its object, if it is in one, expects a name next.
		if top >= 0 && stack[top].object {
			stack[top].expectKey = true
		}
		switch t {
		case json.Delim('{'):
			stack = append(stack, frame{object: true, seen: map[string]bool{}, expectKey: true})
		case json.Delim('['):
			stack = append(stack, frame{})
		case json.Delim(']'):
			if top < 0 {
				return false
			}
			stack = stack[:top]
		}
	}
}

// identity reads a job's identifier and revision from its exact bytes.
func identity(job []byte) (Identity, error) {
	if !unambiguous(job) {
		return Identity{}, ErrMalformed
	}
	fields, e := members(job)
	if e != nil {
		return Identity{}, e
	}
	for name := range fields {
		if !jobMembers[name] {
			return Identity{}, ErrFields
		}
	}
	var id string
	var revision json.Number
	if json.Unmarshal(fields["job_id"], &id) != nil || !identifier(id) {
		return Identity{}, ErrFields
	}
	if len(fields["revision"]) == 0 || json.Unmarshal(fields["revision"], &revision) != nil {
		return Identity{}, ErrFields
	}
	n, e := revision.Int64()
	// Plain decimal only: no fraction, exponent, sign or leading zero.
	if e != nil || n <= 0 || n > maximumSafeInteger || revision.String() != string(fields["revision"]) || revision.String()[0] == '0' {
		return Identity{}, ErrFields
	}
	sum := sha256.Sum256(job)
	return Identity{id, n, hex.EncodeToString(sum[:])}, nil
}

// Seal writes the file for exact job bytes and, when there is one, the signature the
// organisation's key made over SigningInput(job). An empty signature writes an unsigned file.
func Seal(job, sig []byte) ([]byte, error) {
	if _, e := identity(job); e != nil {
		return nil, e
	}
	f := file{Format, Version, base64.StdEncoding.EncodeToString(job), nil}
	if len(sig) != 0 {
		if len(sig) != ed25519.SignatureSize {
			return nil, ErrSignature
		}
		f.Signature = &signature{"ed25519", base64.StdEncoding.EncodeToString(sig)}
	}
	out, e := json.Marshal(f)
	if e != nil {
		return nil, e
	}
	if len(out) > MaximumBytes {
		return nil, ErrMalformed
	}
	return out, nil
}

// Sign writes a signed file for a key held in process.
func Sign(job []byte, organisationKey ed25519.PrivateKey) ([]byte, error) {
	if len(organisationKey) != ed25519.PrivateKeySize {
		return nil, ErrSignature
	}
	return Seal(job, ed25519.Sign(organisationKey, SigningInput(job)))
}

// Open reads a format-2 file: its closed outer form, the job's exact bytes and its identity.
// signed says whether the file carries a signature at all; it is not yet checked (see Verify).
func Open(data []byte) (job []byte, id Identity, signed bool, err error) {
	if len(data) == 0 || len(data) > MaximumBytes {
		return nil, Identity{}, false, ErrMalformed
	}
	if !unambiguous(data) {
		return nil, Identity{}, false, ErrMalformed
	}
	outer, e := members(data)
	if e != nil {
		return nil, Identity{}, false, e
	}
	var format string
	var version json.Number
	if json.Unmarshal(outer["format"], &format) != nil || format != Format {
		return nil, Identity{}, false, ErrMalformed
	}
	if json.Unmarshal(outer["format_version"], &version) != nil || version.String() != "2" {
		return nil, Identity{}, false, ErrVersion
	}
	for name := range outer {
		if name != "format" && name != "format_version" && name != "job" && name != "signature" {
			return nil, Identity{}, false, ErrFields
		}
	}
	var encoded string
	if json.Unmarshal(outer["job"], &encoded) != nil {
		return nil, Identity{}, false, ErrMalformed
	}
	job, e = base64.StdEncoding.Strict().DecodeString(encoded)
	if e != nil || base64.StdEncoding.EncodeToString(job) != encoded {
		return nil, Identity{}, false, ErrMalformed
	}
	if id, e = identity(job); e != nil {
		return nil, Identity{}, false, e
	}
	_, signed = outer["signature"]
	return job, id, signed, nil
}

// Verify reads a format-2 file and checks its signature under the organisation's key, over the
// domain and the job's exact bytes. An unsigned file is ErrUnsigned: whether one may be offered
// to a technician is the phone's policy, not this check's.
func Verify(data []byte, organisationKey ed25519.PublicKey) ([]byte, Identity, error) {
	job, id, signed, e := Open(data)
	if e != nil {
		return nil, Identity{}, e
	}
	if !signed {
		return nil, Identity{}, ErrUnsigned
	}
	outer, _ := members(data)
	sigFields, e := members(outer["signature"])
	if e != nil || len(sigFields) != 2 {
		return nil, Identity{}, ErrMalformed
	}
	var s signature
	if json.Unmarshal(outer["signature"], &s) != nil || s.Algorithm != "ed25519" {
		return nil, Identity{}, ErrMalformed
	}
	sig, e := base64.StdEncoding.Strict().DecodeString(s.Value)
	if e != nil || len(sig) != ed25519.SignatureSize || base64.StdEncoding.EncodeToString(sig) != s.Value {
		return nil, Identity{}, ErrMalformed
	}
	if len(organisationKey) != ed25519.PublicKeySize || !ed25519.Verify(organisationKey, SigningInput(job), sig) {
		return nil, Identity{}, ErrSignature
	}
	return job, id, nil
}

// Supersedes says what a phone that holds one revision of a job does with another file for the
// same identifier: Newer replaces it, Same is the job it already has, and anything else is
// refused — an Older revision never replaces a newer one, and a second, different file at one
// revision is a Conflict.
type Relation int

const (
	Unrelated Relation = iota
	Newer
	Same
	Older
	Conflict
)

// Relate compares an arriving file's identity with the one held.
func Relate(held, arriving Identity) Relation {
	switch {
	case held.JobID != arriving.JobID:
		return Unrelated
	case arriving.Revision > held.Revision:
		return Newer
	case arriving.Revision < held.Revision:
		return Older
	case arriving.SHA256 == held.SHA256:
		return Same
	default:
		return Conflict
	}
}
