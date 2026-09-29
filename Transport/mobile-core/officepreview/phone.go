package officepreview

import (
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

type Phone struct {
	Root  string
	Key   ed25519.PrivateKey
	State PhoneState
}
type PhoneState struct {
	Version       int      `json:"version"`
	PhoneID       string   `json:"phoneID"`
	Invite        string   `json:"invite"`
	Response      string   `json:"response"`
	Confirmation  string   `json:"confirmation"`
	Sequence      int64    `json:"sequence"`
	PayloadSHA256 string   `json:"payloadSHA256"`
	Receipt       string   `json:"receipt"`
	Job           Job      `json:"job"`
	Manuals       []Manual `json:"manuals"`
}

func OpenPhone(root, phoneID string) (*Phone, error) {
	if !validID(phoneID) {
		return nil, errors.New("invalid phone transport identity")
	}
	k, e := PrivateKey(root)
	if e != nil {
		return nil, e
	}
	p := &Phone{Root: root, Key: k, State: PhoneState{Version: 1, PhoneID: phoneID}}
	e = load(filepath.Join(root, "phone-state.json"), &p.State)
	if e != nil && !os.IsNotExist(e) {
		return nil, e
	}
	if p.State.Version != 1 || p.State.PhoneID != phoneID {
		return nil, errors.New("phone connection state does not match identity")
	}
	return p, nil
}
func (p *Phone) persist() error { return save(filepath.Join(p.Root, "phone-state.json"), p.State) }
func (p *Phone) Respond(invite string, now int64) (string, string, error) {
	if p.State.Confirmation != "" {
		return "", "", errors.New("phone is already paired")
	}
	i, ih, e := ReadInvite(invite, now)
	if e != nil {
		return "", "", e
	}
	if p.State.Invite != "" && p.State.Invite != invite {
		return "", "", errors.New("another invitation is pending; clear it explicitly first")
	}
	if i.OfficeID == p.State.PhoneID {
		return "", "", errors.New("phone and office identities must differ")
	}
	s, e := Sign(Response{1, "avenkin.preview-response", i.PairID, ih, p.State.PhoneID, public(p.Key)}, p.Key)
	if e != nil {
		return "", "", e
	}
	_, rh, e := CheckResponse(s, i, ih)
	if e != nil {
		return "", "", e
	}
	p.State.Invite = invite
	p.State.Response = s
	if e = p.persist(); e != nil {
		return "", "", e
	}
	return s, Comparison(ih, rh), nil
}
func (p *Phone) Confirm(raw string, now int64) error {
	i, ih, e := ReadInvite(p.State.Invite, now)
	if e != nil {
		return e
	}
	k, e := key(i.OfficeKey)
	if e != nil {
		return e
	}
	var c Confirmation
	if _, e = Verify(raw, k, confirmationFields, &c); e != nil {
		return e
	}
	_, rh, e := CheckResponse(p.State.Response, i, ih)
	if e != nil {
		return e
	}
	if c.Version != 1 || c.Kind != "avenkin.preview-confirmation" || c.PairID != i.PairID || c.InviteSHA256 != ih || c.ResponseSHA256 != rh || c.PhoneID != p.State.PhoneID || c.PhoneKey != public(p.Key) {
		return errors.New("confirmation does not bind this phone")
	}
	if p.State.Confirmation != "" && p.State.Confirmation != raw {
		return errors.New("pairing confirmation conflict")
	}
	p.State.Confirmation = raw
	return p.persist()
}
func (p *Phone) Binding() (Invite, error) {
	var i Invite
	raw, _, e := Raw(p.State.Invite)
	if e != nil || json.Unmarshal(raw, &i) != nil {
		return i, errors.New("missing office invitation")
	}
	k, e := key(i.OfficeKey)
	if e != nil {
		return i, e
	}
	i, ih, e := ReadInvite(p.State.Invite, i.IssuedAt)
	if e != nil {
		return i, e
	}
	r, rh, e := CheckResponse(p.State.Response, i, ih)
	if e != nil {
		return i, e
	}
	var c Confirmation
	if _, e = Verify(p.State.Confirmation, k, confirmationFields, &c); e != nil {
		return i, e
	}
	if c.Version != 1 || c.Kind != "avenkin.preview-confirmation" || c.InviteSHA256 != ih || c.ResponseSHA256 != rh || r.PhoneID != p.State.PhoneID || r.PhoneKey != public(p.Key) || c.PhoneID != p.State.PhoneID || c.PhoneKey != public(p.Key) || c.PairID != i.PairID {
		return i, errors.New("saved pairing does not match phone identity")
	}
	return i, nil
}
func ValidateManuals(ms []Manual) error {
	if len(ms) > 16 {
		return errors.New("too many assigned manuals")
	}
	var total int64
	seen := map[string]bool{}
	for _, m := range ms {
		if m.ID == "" || len(m.ID) > 80 || seen[m.ID] || m.Title == "" || len(m.Title) > 640 || m.Filename == "" || len(m.Filename) > 640 || !(m.Format == "pdf" || m.Format == "txt" || m.Format == "md") || !isHex(m.SourceSHA256, 64) || m.Bytes <= 0 || m.Bytes > 16*1024*1024 || m.TextBytes < 0 || m.TextBytes > 2*1024*1024 || (m.TextSHA256 != "" && !isHex(m.TextSHA256, 64)) || (m.TextBytes > 0 && m.TextSHA256 == "") || (m.TextSHA256 != "" && m.TextBytes == 0) {
			return errors.New("invalid manual manifest")
		}
		seen[m.ID] = true
		total += m.Bytes + m.TextBytes
	}
	if total > 128*1024*1024 {
		return errors.New("assigned manuals exceed phone preview limit")
	}
	return nil
}
func (p *Phone) Receive(raw string, sourceFolder string, now int64) (bool, error) {
	i, e := p.Binding()
	if e != nil {
		return false, e
	}
	k, e := key(i.OfficeKey)
	if e != nil {
		return false, e
	}
	var d Delivery
	hash, e := Verify(raw, k, deliveryFields, &d)
	if e != nil {
		return false, e
	}
	if d.Version != 1 || d.Kind != "avenkin.preview-delivery" || d.PairID != i.PairID || d.PhoneID != p.State.PhoneID || !isHex(d.MessageID, 32) || d.Sequence <= 0 || d.Sequence > 9007199254740991 || d.IssuedAt <= 0 || d.ExpiresAt <= d.IssuedAt || d.ExpiresAt-d.IssuedAt > 30*86400 || now < d.IssuedAt || now >= d.ExpiresAt {
		return false, errors.New("delivery is expired or for another phone")
	}
	if d.Sequence < p.State.Sequence {
		return false, errors.New("older delivery refused")
	}
	if d.Sequence == p.State.Sequence {
		if hash != p.State.PayloadSHA256 {
			return false, errors.New("delivery revision conflict")
		}
		return true, nil
	}
	j, e := validateJob(d.JobJSON)
	if e != nil {
		return false, e
	}
	ms, e := decodeManuals(d.ManualsJSON)
	if e != nil {
		return false, e
	}
	for _, m := range ms {
		for _, spec := range []struct {
			digest string
			size   int64
		}{{m.SourceSHA256, m.Bytes}, {m.TextSHA256, m.TextBytes}} {
			if spec.digest == "" {
				continue
			}
			b, e := ReadFile(filepath.Join(sourceFolder, spec.digest), spec.size)
			if os.IsNotExist(e) {
				return false, nil
			}
			if e != nil {
				return false, e
			}
			if int64(len(b)) != spec.size || Digest(b) != spec.digest {
				return false, errors.New("downloaded manual does not match signed manifest")
			}
			if e = Atomic(filepath.Join(p.Root, "library", spec.digest), b); e != nil {
				return false, e
			}
		}
	}
	receipt, e := Sign(Receipt{1, "avenkin.preview-receipt", i.PairID, p.State.PhoneID, d.MessageID, d.Sequence, hash, len(ms)}, p.Key)
	if e != nil {
		return false, e
	}
	candidate := p.State
	candidate.Sequence = d.Sequence
	candidate.PayloadSHA256 = hash
	candidate.Receipt = receipt
	candidate.Job = j
	candidate.Manuals = ms
	if e = save(filepath.Join(p.Root, "phone-state.json"), candidate); e != nil {
		return false, e
	}
	p.State = candidate
	return true, nil
}
func (p *Phone) Public() map[string]any {
	return map[string]any{"paired": p.State.Confirmation != "", "response": p.State.Response, "comparison": func() string {
		raw, _, _ := Raw(p.State.Invite)
		r, _, _ := Raw(p.State.Response)
		if len(raw) == 0 || len(r) == 0 {
			return ""
		}
		return Comparison(Digest(raw), Digest(r))
	}(), "job": p.State.Job, "manuals": p.State.Manuals, "sequence": p.State.Sequence, "readyOffline": p.State.Receipt != "", "productionAcceptance": false}
}

func (p *Phone) CancelPending() error {
	if p.State.Confirmation != "" {
		return errors.New("paired devices cannot cancel a pending invitation")
	}
	p.State.Invite = ""
	p.State.Response = ""
	return p.persist()
}

func decodeManuals(raw string) ([]Manual, error) {
	var records []json.RawMessage
	if len(raw) > MaximumEnvelope || json.Unmarshal([]byte(raw), &records) != nil || len(records) > 16 {
		return nil, errors.New("invalid manual manifest array")
	}
	manuals := make([]Manual, 0, len(records))
	for _, record := range records {
		if !Flat(record, []string{"id", "title", "filename", "format", "sourceSha256", "textSha256", "bytes", "textBytes"}) {
			return nil, errors.New("ambiguous manual manifest")
		}
		var m Manual
		if e := json.Unmarshal(record, &m); e != nil {
			return nil, e
		}
		manuals = append(manuals, m)
	}
	return manuals, ValidateManuals(manuals)
}
