package officepreview

import (
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

type Office struct {
	Root  string
	Key   ed25519.PrivateKey
	State OfficeState
}
type OfficeState struct {
	Version      int    `json:"version"`
	Invite       string `json:"invite"`
	Confirmation string `json:"confirmation"`
	PhoneID      string `json:"phoneID"`
	PhoneKey     string `json:"phoneKey"`
	Sequence     int64  `json:"sequence"`
	Pending      string `json:"pending"`
	Receipt      string `json:"receipt"`
}

func OpenOffice(root string) (*Office, error) {
	k, e := PrivateKey(root)
	if e != nil {
		return nil, e
	}
	o := &Office{Root: root, Key: k, State: OfficeState{Version: 1}}
	e = load(filepath.Join(root, "office-state.json"), &o.State)
	if e != nil && !os.IsNotExist(e) {
		return nil, e
	}
	if o.State.Version != 1 {
		return nil, errors.New("unsupported office connection state")
	}
	if o.State.Confirmation != "" {
		if _, e = o.Binding(); e != nil {
			return nil, e
		}
		if o.State.Receipt != "" {
			if e = o.checkReceipt(o.State.Receipt); e != nil {
				return nil, e
			}
		}
	}
	return o, nil
}
func (o *Office) persist() error { return save(filepath.Join(o.Root, "office-state.json"), o.State) }
func (o *Office) Invite(officeID, address, deviceRecordID string, now int64) (string, error) {
	if o.State.Confirmation != "" {
		return "", errors.New("a phone is already paired; replacement requires a separate revocation flow")
	}
	id, e := randomID()
	if e != nil {
		return "", e
	}
	i := Invite{1, "avenkin.preview-invite", id, officeID, public(o.Key), deviceRecordID, address, now, now + 900}
	s, e := Sign(i, o.Key)
	if e != nil {
		return "", e
	}
	if _, _, e = ReadInvite(s, now); e != nil {
		return "", e
	}
	o.State.Invite = s
	if e = o.persist(); e != nil {
		return "", e
	}
	return s, nil
}
func (o *Office) Review(response string, now int64) (Response, string, error) {
	i, ih, e := ReadInvite(o.State.Invite, now)
	if e != nil {
		return Response{}, "", e
	}
	r, rh, e := CheckResponse(response, i, ih)
	return r, Comparison(ih, rh), e
}
func (o *Office) Approve(response, comparison string, now int64) (string, error) {
	if o.State.Confirmation != "" {
		return "", errors.New("invitation was already consumed")
	}
	i, ih, e := ReadInvite(o.State.Invite, now)
	if e != nil {
		return "", e
	}
	r, rh, e := CheckResponse(response, i, ih)
	if e != nil {
		return "", e
	}
	if comparison != Comparison(ih, rh) {
		return "", errors.New("comparison code does not match phone response")
	}
	confirmation, e := Sign(Confirmation{1, "avenkin.preview-confirmation", i.PairID, ih, rh, r.PhoneID, r.PhoneKey}, o.Key)
	if e != nil {
		return "", e
	}
	o.State.Confirmation = confirmation
	o.State.PhoneID = r.PhoneID
	o.State.PhoneKey = r.PhoneKey
	if e = o.persist(); e != nil {
		return "", e
	}
	return confirmation, nil
}
func (o *Office) Binding() (Invite, error) {
	var i Invite
	if _, e := Verify(o.State.Invite, o.Key.Public().(ed25519.PublicKey), inviteFields, &i); e != nil {
		return i, e
	}
	i, ih, e := ReadInvite(o.State.Invite, i.IssuedAt)
	if e != nil || i.OfficeKey != public(o.Key) {
		return i, errors.New("saved office invitation does not match identity")
	}
	var c Confirmation
	if _, e = Verify(o.State.Confirmation, o.Key.Public().(ed25519.PublicKey), confirmationFields, &c); e != nil {
		return i, e
	}
	if c.Version != 1 || c.Kind != "avenkin.preview-confirmation" || c.PairID != i.PairID || c.InviteSHA256 != ih || !isHex(c.ResponseSHA256, 64) || c.PhoneID != o.State.PhoneID || c.PhoneKey != o.State.PhoneKey || !validID(c.PhoneID) {
		return i, errors.New("saved pairing does not match approved phone")
	}
	if _, e = key(c.PhoneKey); e != nil {
		return i, e
	}
	return i, nil
}
func (o *Office) Dispatch(jobRaw string, manuals []Manual, contentRoot string, now int64) (string, error) {
	i, e := o.Binding()
	if e != nil {
		return "", e
	}
	if o.State.Pending != "" && o.State.Receipt == "" {
		return "", errors.New("another delivery is still waiting for its verified receipt")
	}
	// An empty job sends the device's manuals again under the job it already holds: the
	// companion replaces its manual list with each delivery, and a delivery always names a job.
	if jobRaw == "" {
		var last Delivery
		if _, e = Verify(o.State.Pending, o.Key.Public().(ed25519.PublicKey), deliveryFields, &last); e != nil {
			return "", errors.New("send a job to this device first; manuals travel with the job it holds")
		}
		jobRaw = last.JobJSON
	}
	if _, e = validateJob(jobRaw); e != nil {
		return "", e
	}
	if e = ValidateManuals(manuals); e != nil {
		return "", e
	}
	_, _, folder := Folders(i.PairID)
	for _, m := range manuals {
		for _, spec := range []struct {
			digest string
			limit  int64
		}{{m.SourceSHA256, m.Bytes}, {m.TextSHA256, m.TextBytes}} {
			if spec.digest == "" {
				continue
			}
			b, e := ReadFile(filepath.Join(contentRoot, spec.digest), spec.limit)
			if e != nil {
				return "", e
			}
			if int64(len(b)) != spec.limit || Digest(b) != spec.digest {
				return "", errors.New("manual integrity check failed")
			}
			if e = Atomic(filepath.Join(o.Root, folder, spec.digest), b); e != nil {
				return "", e
			}
		}
	}
	if o.State.Sequence >= 9007199254740991 {
		return "", errors.New("delivery sequence exhausted")
	}
	seq := o.State.Sequence + 1
	id, e := randomID()
	if e != nil {
		return "", e
	}
	mb, e := json.Marshal(manuals)
	if e != nil {
		return "", e
	}
	s, e := Sign(Delivery{1, "avenkin.preview-delivery", i.PairID, o.State.PhoneID, id, seq, now, now + 30*86400, jobRaw, string(mb)}, o.Key)
	if e != nil {
		return "", e
	}
	o.State.Sequence = seq
	o.State.Pending = s
	o.State.Receipt = ""
	if e = o.persist(); e != nil {
		return "", e
	}
	if e = o.Publish(); e != nil {
		return "", e
	}
	return id, nil
}
func (o *Office) Publish() error {
	if o.State.Pending == "" {
		return nil
	}
	i, e := o.Binding()
	if e != nil {
		return e
	}
	in, _, _ := Folders(i.PairID)
	return Atomic(filepath.Join(o.Root, in, "delivery.json"), []byte(o.State.Pending))
}
func (o *Office) checkReceipt(raw string) error {
	if o.State.Pending == "" {
		return errors.New("no pending delivery")
	}
	k, e := key(o.State.PhoneKey)
	if e != nil {
		return e
	}
	var r Receipt
	if _, e = Verify(raw, k, receiptFields, &r); e != nil {
		return e
	}
	var d Delivery
	h, e := Verify(o.State.Pending, o.Key.Public().(ed25519.PublicKey), deliveryFields, &d)
	if e != nil {
		return e
	}
	manuals, e := decodeManuals(d.ManualsJSON)
	if e != nil {
		return e
	}
	if r.Version != 1 || r.Kind != "avenkin.preview-receipt" || r.PairID != d.PairID || r.PhoneID != d.PhoneID || r.MessageID != d.MessageID || r.Sequence != d.Sequence || r.PayloadSHA256 != h || r.ManualCount != len(manuals) {
		return errors.New("receipt does not match this delivery")
	}
	return nil
}
func (o *Office) VerifyReceipt(raw string) error {
	if _, e := o.Binding(); e != nil {
		return e
	}
	if e := o.checkReceipt(raw); e != nil {
		return e
	}
	candidate := o.State
	candidate.Receipt = raw
	if e := save(filepath.Join(o.Root, "office-state.json"), candidate); e != nil {
		return e
	}
	o.State = candidate
	return nil
}
func (o *Office) Public() map[string]any {
	out := map[string]any{"paired": o.State.Confirmation != "", "phoneID": o.State.PhoneID, "officeApplicationKey": public(o.Key), "managedOfficeID": o.ManagedOfficeID(), "sequence": o.State.Sequence, "pending": o.State.Pending != "", "receivedInCompanion": o.State.Receipt != "", "productionAcceptance": false}
	if o.State.Confirmation != "" {
		if i, e := o.Binding(); e == nil {
			out["officeID"] = i.OfficeID
			out["deviceRecordID"] = i.DeviceRecordID
			out["pairID"] = i.PairID
			out["confirmation"] = o.State.Confirmation
			var d Delivery
			if _, e = Verify(o.State.Pending, o.Key.Public().(ed25519.PublicKey), deliveryFields, &d); e == nil {
				out["messageID"] = d.MessageID
				var j Job
				if json.Unmarshal([]byte(d.JobJSON), &j) == nil {
					out["jobID"] = j.ID
				}
				// What the last delivery carried, so the office can tell which manuals the
				// device holds and whether they are the current ones.
				if ms, e := decodeManuals(d.ManualsJSON); e == nil {
					held := make([]map[string]string, 0, len(ms))
					for _, m := range ms {
						held = append(held, map[string]string{"id": m.ID, "sourceSha256": m.SourceSHA256, "textSha256": m.TextSHA256})
					}
					out["manuals"] = held
				}
			}
		}
	}
	return out
}
func Now() int64 { return time.Now().Unix() }
