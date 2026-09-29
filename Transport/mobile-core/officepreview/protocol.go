// Package officepreview provides explicitly reviewed desktop/companion pairing and
// signed local delivery. It grants no organisation, publisher or entitlement authority.
package officepreview

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/syncthing/syncthing/lib/protocol"
)

const Domain = "Avenkin.OfficePreview.v1\x00"
const MaximumEnvelope = 256 * 1024
const Infix = "avenkin-preview-"

type Envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}
type Invite struct {
	Version        int    `json:"version"`
	Kind           string `json:"kind"`
	PairID         string `json:"pairID"`
	OfficeID       string `json:"officeID"`
	OfficeKey      string `json:"officeKey"`
	DeviceRecordID string `json:"deviceRecordID"`
	Address        string `json:"address"`
	IssuedAt       int64  `json:"issuedAt"`
	ExpiresAt      int64  `json:"expiresAt"`
}
type Response struct {
	Version      int    `json:"version"`
	Kind         string `json:"kind"`
	PairID       string `json:"pairID"`
	InviteSHA256 string `json:"inviteSHA256"`
	PhoneID      string `json:"phoneID"`
	PhoneKey     string `json:"phoneKey"`
}
type Confirmation struct {
	Version        int    `json:"version"`
	Kind           string `json:"kind"`
	PairID         string `json:"pairID"`
	InviteSHA256   string `json:"inviteSHA256"`
	ResponseSHA256 string `json:"responseSHA256"`
	PhoneID        string `json:"phoneID"`
	PhoneKey       string `json:"phoneKey"`
}
type Delivery struct {
	Version     int    `json:"version"`
	Kind        string `json:"kind"`
	PairID      string `json:"pairID"`
	PhoneID     string `json:"phoneID"`
	MessageID   string `json:"messageID"`
	Sequence    int64  `json:"sequence"`
	IssuedAt    int64  `json:"issuedAt"`
	ExpiresAt   int64  `json:"expiresAt"`
	JobJSON     string `json:"jobJSON"`
	ManualsJSON string `json:"manualsJSON"`
}
type Receipt struct {
	Version       int    `json:"version"`
	Kind          string `json:"kind"`
	PairID        string `json:"pairID"`
	PhoneID       string `json:"phoneID"`
	MessageID     string `json:"messageID"`
	Sequence      int64  `json:"sequence"`
	PayloadSHA256 string `json:"payloadSHA256"`
	ManualCount   int    `json:"manualCount"`
}
type Job struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Customer string `json:"customer"`
	Asset    string `json:"asset"`
	Notes    string `json:"notes"`
	DueDate  string `json:"dueDate"`
}
type Manual struct {
	ID           string `json:"id"`
	Title        string `json:"title"`
	Filename     string `json:"filename"`
	Format       string `json:"format"`
	SourceSHA256 string `json:"sourceSha256"`
	TextSHA256   string `json:"textSha256"`
	Bytes        int64  `json:"bytes"`
	TextBytes    int64  `json:"textBytes"`
}

func Digest(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func randomID() (string, error) {
	b := make([]byte, 16)
	_, err := rand.Read(b)
	return hex.EncodeToString(b), err
}
func isHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func validID(s string) bool {
	id, e := protocol.DeviceIDFromString(s)
	return e == nil && id != protocol.EmptyDeviceID && id.String() == s
}
func key(s string) (ed25519.PublicKey, error) {
	b, e := base64.StdEncoding.Strict().DecodeString(s)
	if e != nil || len(b) != 32 {
		return nil, errors.New("invalid application key")
	}
	return ed25519.PublicKey(b), nil
}
func Flat(data []byte, fields []string) bool {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	t, e := d.Token()
	if e != nil || t != json.Delim('{') {
		return false
	}
	seen := map[string]bool{}
	allowed := map[string]bool{}
	for _, f := range fields {
		allowed[f] = true
	}
	for d.More() {
		t, e = d.Token()
		if e != nil {
			return false
		}
		s, ok := t.(string)
		if !ok || seen[s] || !allowed[s] {
			return false
		}
		seen[s] = true
		t, e = d.Token()
		if e != nil {
			return false
		}
		switch v := t.(type) {
		case string:
		case json.Number:
			if _, e = strconv.ParseInt(string(v), 10, 64); e != nil {
				return false
			}
		default:
			return false
		}
	}
	t, e = d.Token()
	if e != nil || t != json.Delim('}') || len(seen) != len(allowed) {
		return false
	}
	_, e = d.Token()
	return e == io.EOF
}
func Sign(v any, k ed25519.PrivateKey) (string, error) {
	if len(k) != 64 {
		return "", errors.New("missing signing identity")
	}
	b, e := json.Marshal(v)
	if e != nil {
		return "", e
	}
	out, e := json.Marshal(Envelope{base64.StdEncoding.EncodeToString(b), base64.StdEncoding.EncodeToString(ed25519.Sign(k, append([]byte(Domain), b...)))})
	return string(out), e
}
func Raw(s string) ([]byte, []byte, error) {
	if len(s) > MaximumEnvelope || !Flat([]byte(s), []string{"payload", "signature"}) {
		return nil, nil, errors.New("invalid signed envelope")
	}
	var e Envelope
	_ = json.Unmarshal([]byte(s), &e)
	p, err := base64.StdEncoding.Strict().DecodeString(e.Payload)
	if err != nil {
		return nil, nil, err
	}
	sig, err := base64.StdEncoding.Strict().DecodeString(e.Signature)
	if err != nil || len(sig) != 64 {
		return nil, nil, errors.New("invalid signature encoding")
	}
	return p, sig, nil
}
func Verify(s string, k ed25519.PublicKey, fields []string, v any) (string, error) {
	p, sig, e := Raw(s)
	if e != nil || !Flat(p, fields) {
		return "", errors.New("invalid signed payload")
	}
	if len(k) != 32 || !ed25519.Verify(k, append([]byte(Domain), p...), sig) {
		return "", errors.New("signature does not match approved identity")
	}
	if e = json.Unmarshal(p, v); e != nil {
		return "", e
	}
	return Digest(p), nil
}

var inviteFields = []string{"version", "kind", "pairID", "officeID", "officeKey", "deviceRecordID", "address", "issuedAt", "expiresAt"}
var responseFields = []string{"version", "kind", "pairID", "inviteSHA256", "phoneID", "phoneKey"}
var confirmationFields = []string{"version", "kind", "pairID", "inviteSHA256", "responseSHA256", "phoneID", "phoneKey"}
var deliveryFields = []string{"version", "kind", "pairID", "phoneID", "messageID", "sequence", "issuedAt", "expiresAt", "jobJSON", "manualsJSON"}
var receiptFields = []string{"version", "kind", "pairID", "phoneID", "messageID", "sequence", "payloadSHA256", "manualCount"}

func ReadInvite(s string, now int64) (Invite, string, error) {
	var i Invite
	p, _, e := Raw(s)
	if e != nil {
		return i, "", e
	}
	if !Flat(p, inviteFields) || json.Unmarshal(p, &i) != nil {
		return i, "", errors.New("invalid invitation")
	}
	k, e := key(i.OfficeKey)
	if e != nil {
		return i, "", e
	}
	hash, e := Verify(s, k, inviteFields, &i)
	if e != nil {
		return i, "", e
	}
	u, e := url.Parse(i.Address)
	if e != nil || u.Scheme != "tcp" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || net.ParseIP(u.Hostname()) == nil || !net.ParseIP(u.Hostname()).IsPrivate() {
		return i, "", errors.New("pairing requires a private LAN address")
	}
	port, e := strconv.Atoi(u.Port())
	if e != nil || port < 1 || port > 65535 {
		return i, "", errors.New("invalid LAN port")
	}
	if i.Version != 1 || i.Kind != "avenkin.preview-invite" || !isHex(i.PairID, 32) || !validID(i.OfficeID) || len(i.DeviceRecordID) < 1 || len(i.DeviceRecordID) > 80 || i.IssuedAt <= 0 || i.ExpiresAt-i.IssuedAt != 900 || now < i.IssuedAt || now >= i.ExpiresAt {
		return i, "", errors.New("invitation is invalid or expired")
	}
	return i, hash, nil
}
func CheckResponse(s string, i Invite, inviteHash string) (Response, string, error) {
	var r Response
	p, _, e := Raw(s)
	if e != nil || !Flat(p, responseFields) || json.Unmarshal(p, &r) != nil {
		return r, "", errors.New("invalid phone response")
	}
	k, e := key(r.PhoneKey)
	if e != nil {
		return r, "", e
	}
	h, e := Verify(s, k, responseFields, &r)
	if e != nil {
		return r, "", e
	}
	if r.Version != 1 || r.Kind != "avenkin.preview-response" || r.PairID != i.PairID || r.InviteSHA256 != inviteHash || !validID(r.PhoneID) || r.PhoneID == i.OfficeID {
		return r, "", errors.New("response does not match invitation")
	}
	return r, h, nil
}
func Comparison(inviteHash, responseHash string) string {
	s := Digest([]byte(inviteHash + "\x00" + responseHash))[:32]
	return s[:8] + " " + s[8:16] + " " + s[16:24] + " " + s[24:32]
}
func Folders(id string) (string, string, string) {
	return Infix + id + "-in", Infix + id + "-out", Infix + id + "-manuals"
}
func PrivateKey(root string) (ed25519.PrivateKey, error) {
	if e := os.MkdirAll(root, 0700); e != nil {
		return nil, e
	}
	p := filepath.Join(root, "application-key")
	b, e := os.ReadFile(p)
	if e == nil {
		if len(b) != 32 {
			return nil, errors.New("application identity is corrupt; pairing refused")
		}
		return ed25519.NewKeyFromSeed(b), nil
	}
	if !os.IsNotExist(e) {
		return nil, e
	}
	for _, name := range []string{"office-state.json", "phone-state.json"} {
		if _, err := os.Lstat(filepath.Join(root, name)); err == nil || !os.IsNotExist(err) {
			return nil, errors.New("saved connection lost its application identity; refusing replacement")
		}
	}
	seed := make([]byte, 32)
	if _, e = rand.Read(seed); e != nil {
		return nil, e
	}
	f, e := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if e != nil {
		return nil, e
	}
	_, e = f.Write(seed)
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e != nil {
		return nil, e
	}
	if ce != nil {
		return nil, ce
	}
	return ed25519.NewKeyFromSeed(seed), nil
}
func ReadFile(path string, max int64) ([]byte, error) {
	info, e := os.Lstat(path)
	if e != nil {
		return nil, e
	}
	if !info.Mode().IsRegular() || info.Size() > max {
		return nil, errors.New("invalid or oversized local file")
	}
	f, e := os.Open(path)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	b, e := io.ReadAll(io.LimitReader(f, max+1))
	if int64(len(b)) > max {
		return nil, errors.New("local file exceeded limit")
	}
	return b, e
}
func Atomic(path string, data []byte) error {
	if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".avenkin-stage-")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	if e = f.Chmod(0600); e == nil {
		_, e = f.Write(data)
	}
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e != nil {
		return e
	}
	if ce != nil {
		return ce
	}
	return os.Rename(f.Name(), path)
}
func save(path string, v any) error {
	b, e := json.Marshal(v)
	if e != nil {
		return e
	}
	return Atomic(path, b)
}
func load(path string, v any) error {
	b, e := ReadFile(path, MaximumEnvelope)
	if e != nil {
		return e
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if e = d.Decode(v); e != nil {
		return e
	}
	if d.Decode(&struct{}{}) != io.EOF {
		return errors.New("trailing local state")
	}
	return nil
}
func public(k ed25519.PrivateKey) string {
	return base64.StdEncoding.EncodeToString(k.Public().(ed25519.PublicKey))
}
func validateJob(raw string) (Job, error) {
	var j Job
	if len(raw) > 65536 || !Flat([]byte(raw), []string{"id", "title", "customer", "asset", "notes", "dueDate"}) || json.Unmarshal([]byte(raw), &j) != nil {
		return j, errors.New("invalid job preview")
	}
	if j.ID == "" || len(j.ID) > 80 || j.Title == "" || len(j.Title) > 640 || len(j.Customer) > 1200 || len(j.Asset) > 1200 || len(j.Notes) > 40000 || len(j.DueDate) > 10 {
		return j, errors.New("job preview exceeds limits")
	}
	for _, s := range []string{j.ID, j.Title, j.Customer, j.Asset, j.Notes, j.DueDate} {
		if strings.ContainsRune(s, 0) {
			return j, errors.New("invalid job text")
		}
	}
	return j, nil
}
