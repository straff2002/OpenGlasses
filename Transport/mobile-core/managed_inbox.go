package mobilecore

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"avenkin.dev/mobilecore/manageddelivery"
	"avenkin.dev/mobilecore/officepreview"
)

// The managed office folders (Contracts/office-folders.md, draft v1): three per enrolment, named
// from the binding. Only control and records are used here; bulk follows with manuals.
const (
	roleControl = "control"
	roleRecords = "records"
)

// managedFolderID is the identifier both sides compute for a role.
func managedFolderID(organizationID, enrolmentID, officeID, role string) string {
	h := sha256.New()
	for i, part := range []string{"Avenkin.ManagedFolder.v1", organizationID, enrolmentID, officeID, role} {
		if i > 0 {
			h.Write([]byte{0})
		}
		h.Write([]byte(part))
	}
	return "avenkin-" + role + "-" + hex.EncodeToString(h.Sum(nil))[:32]
}

// managedBinding is what the native caller hands over after it has re-verified the saved
// vendor and administrator binding and the live entitlement. Nothing here verifies that chain.
type managedBinding struct {
	OrganizationID       string `json:"organizationID"`
	EnrolmentID          string `json:"enrolmentID"`
	OfficeID             string `json:"officeID"`
	Generation           int64  `json:"generation"`
	OfficeTransportID    string `json:"officeTransportID"`
	OfficeApplicationKey string `json:"officeApplicationKey"`
	PhoneApplicationKey  string `json:"phoneApplicationKey"`
}

var managedBindingFields = []string{"organizationID", "enrolmentID", "officeID", "generation", "officeTransportID", "officeApplicationKey", "phoneApplicationKey"}

func parseManagedBinding(raw, phoneTransportID string) (manageddelivery.Trust, ed25519.PublicKey, error) {
	var b managedBinding
	invalid := errors.New("invalid managed office binding")
	if len(raw) > 4096 || !officepreview.Flat([]byte(raw), managedBindingFields) || json.Unmarshal([]byte(raw), &b) != nil {
		return manageddelivery.Trust{}, nil, invalid
	}
	office, e1 := base64.StdEncoding.Strict().DecodeString(b.OfficeApplicationKey)
	phone, e2 := base64.StdEncoding.Strict().DecodeString(b.PhoneApplicationKey)
	if e1 != nil || e2 != nil || len(office) != ed25519.PublicKeySize || len(phone) != ed25519.PublicKeySize ||
		b.OrganizationID == "" || b.EnrolmentID == "" || b.OfficeID == "" || b.Generation <= 0 || b.OfficeTransportID == phoneTransportID {
		return manageddelivery.Trust{}, nil, invalid
	}
	return manageddelivery.Trust{
		OrganizationID: b.OrganizationID, EnrolmentID: b.EnrolmentID, OfficeID: b.OfficeID,
		OfficeTransportID: b.OfficeTransportID, PhoneTransportID: phoneTransportID,
		Generation: b.Generation, OfficeApplicationKey: office,
	}, phone, nil
}

// managedInbox takes managed jobs out of the control folder: verify against the binding, commit
// the exact bytes to private storage, and only then offer a receipt to be signed. It touches
// files only; the engine is told to look by its owner. A folder grants nothing — every file is
// verified by its own contract.
type managedInbox struct {
	mu       sync.Mutex
	trust    manageddelivery.Trust
	phoneKey ed25519.PublicKey
	control  string // the control folder (receive-only)
	records  string // the records folder (send-only)
	private  string // committed jobs and state; never shared
	state    inboxState
}

// inboxState is the durable record: the high-water mark and what was committed. It lives
// outside every shared folder, so removing a transported file removes nothing here.
type inboxState struct {
	Version   int                        `json:"version"`
	HighWater *manageddelivery.HighWater `json:"highWater,omitempty"`
	Jobs      []committedJob             `json:"jobs"`
	Refused   map[string]string          `json:"refused"` // envelope digest → bounded reason
}

type committedJob struct {
	MessageID        string `json:"messageID"`
	Sequence         int64  `json:"sequence"`
	Generation       int64  `json:"generation"`
	PayloadSHA256    string `json:"payloadSHA256"`
	JobSHA256        string `json:"jobSHA256"`
	ReceivedAt       int64  `json:"receivedAt"`
	ReceiptPublished bool   `json:"receiptPublished"`
}

const maximumRefusedRemembered = 256

func openManagedInbox(home string, trust manageddelivery.Trust, phoneKey ed25519.PublicKey) (*managedInbox, error) {
	root := filepath.Join(home, "managed")
	inbox := &managedInbox{
		trust: trust, phoneKey: phoneKey,
		control: filepath.Join(root, roleControl), records: filepath.Join(root, roleRecords),
		// Scoped to the binding: a different office or enrolment starts with its own record.
		private: filepath.Join(root, "private-"+managedFolderID(trust.OrganizationID, trust.EnrolmentID, trust.OfficeID, "inbox")[len("avenkin-inbox-"):]),
	}
	for _, dir := range []string{inbox.control, inbox.records, filepath.Join(inbox.private, "jobs")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return nil, err
		}
	}
	raw, err := officepreview.ReadFile(filepath.Join(inbox.private, "inbox.json"), 1<<20)
	switch {
	case os.IsNotExist(err):
		inbox.state = inboxState{Version: 1, Refused: map[string]string{}}
	case err != nil:
		return nil, err
	default:
		if json.Unmarshal(raw, &inbox.state) != nil || inbox.state.Version != 1 {
			return nil, errors.New("the managed job record on this phone cannot be read")
		}
		if inbox.state.Refused == nil {
			inbox.state.Refused = map[string]string{}
		}
	}
	return inbox, nil
}

func (i *managedInbox) save() error {
	raw, err := json.Marshal(i.state)
	if err != nil {
		return err
	}
	return officepreview.Atomic(filepath.Join(i.private, "inbox.json"), raw)
}

func (i *managedInbox) committed(messageID string) *committedJob {
	for n := range i.state.Jobs {
		if i.state.Jobs[n].MessageID == messageID {
			return &i.state.Jobs[n]
		}
	}
	return nil
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

// sweep looks at jobs/ in the control folder and commits what verifies, lowest sequence first.
// It returns how many jobs it committed. A job whose file has not arrived yet waits; a job that
// does not verify is remembered by its digest and left where it is.
func (i *managedInbox) sweep(now int64) (int, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	entries, err := os.ReadDir(filepath.Join(i.control, "jobs"))
	if os.IsNotExist(err) {
		return 0, nil
	} else if err != nil {
		return 0, err
	}
	type candidate struct {
		verified manageddelivery.Verified
		job      []byte
		envelope []byte
		digest   string
	}
	var candidates []candidate
	changed := false
	refuse := func(digest, reason string) {
		if len(i.state.Refused) < maximumRefusedRemembered {
			i.state.Refused[digest] = reason
			changed = true
		}
	}
	for _, entry := range entries {
		// Only the contract's names: <32 hex>.envelope.json. Anything else is not opened.
		id, ok := strings.CutSuffix(entry.Name(), ".envelope.json")
		if !ok || !lowerHex(id, 32) || i.committed(id) != nil {
			continue
		}
		data, err := officepreview.ReadFile(filepath.Join(i.control, "jobs", entry.Name()), manageddelivery.MaximumEnvelopeBytes)
		if err != nil {
			continue
		}
		digest := manageddelivery.Digest(data)
		if _, seen := i.state.Refused[digest]; seen {
			continue
		}
		// Verified here without the high-water mark; order is applied below.
		verified, err := manageddelivery.Verify(data, i.trust, now, nil)
		if err != nil {
			refuse(digest, err.Error())
			continue
		}
		if verified.Payload.MessageID != id {
			refuse(digest, "the envelope is not the message its name says")
			continue
		}
		job, err := officepreview.ReadFile(filepath.Join(i.control, "jobs", verified.Payload.JobSHA256+".ogjob"), manageddelivery.MaximumJobBytes)
		if os.IsNotExist(err) {
			continue // the companion has not arrived yet: waiting, not a failure
		} else if err != nil {
			refuse(digest, "the job file cannot be read")
			continue
		}
		if manageddelivery.VerifyBytes(job, verified) != nil {
			// Still arriving, or not the bytes that were signed. Never committed either way.
			continue
		}
		candidates = append(candidates, candidate{verified, job, data, digest})
	}
	sort.Slice(candidates, func(a, b int) bool {
		return candidates[a].verified.Payload.Sequence < candidates[b].verified.Payload.Sequence
	})
	committed := 0
	for _, c := range candidates {
		// Again, now against the high-water mark: a lower sequence after a higher one is refused.
		verified, err := manageddelivery.Verify(c.envelope, i.trust, now, i.state.HighWater)
		if err != nil {
			refuse(c.digest, err.Error())
			continue
		}
		p := verified.Payload
		// Bytes first, then the record that names them: the record is the commit point.
		if err = officepreview.Atomic(filepath.Join(i.private, "jobs", p.MessageID+".ogjob"), c.job); err != nil {
			return committed, err
		}
		if err = officepreview.Atomic(filepath.Join(i.private, "jobs", p.MessageID+".envelope.json"), c.envelope); err != nil {
			return committed, err
		}
		water := verified.HighWater()
		previous := i.state
		i.state.HighWater = &water
		i.state.Jobs = append(append([]committedJob{}, i.state.Jobs...), committedJob{
			MessageID: p.MessageID, Sequence: p.Sequence, Generation: p.Generation,
			PayloadSHA256: verified.PayloadSHA256, JobSHA256: p.JobSHA256, ReceivedAt: now,
		})
		if err = i.save(); err != nil {
			i.state = previous
			return committed, err
		}
		changed = false
		committed++
	}
	if changed {
		return committed, i.save()
	}
	return committed, nil
}

// pendingJob is a committed job that has no published receipt yet.
type pendingJob struct {
	MessageID string `json:"messageID"`
	Sequence  int64  `json:"sequence"`
	JobSHA256 string `json:"jobSHA256"`
	// ReceiptPayload is the exact bytes to sign with the phone application key, base64. The
	// signature is over ReceiptDomain followed by these bytes.
	ReceiptPayload string `json:"receiptPayload"`
}

func (i *managedInbox) receiptPayload(job committedJob) ([]byte, error) {
	return manageddelivery.ReceiptPayload(manageddelivery.Receipt{
		Version: 1, Kind: manageddelivery.ReceiptKind, MessageID: job.MessageID,
		OrganizationID: i.trust.OrganizationID, EnrolmentID: i.trust.EnrolmentID, OfficeID: i.trust.OfficeID,
		Generation: job.Generation, PhoneTransportID: i.trust.PhoneTransportID, Sequence: job.Sequence,
		PayloadSHA256: job.PayloadSHA256, JobSHA256: job.JobSHA256,
		Outcome: manageddelivery.OutcomeReceived, ReceivedAt: job.ReceivedAt,
	})
}

func (i *managedInbox) pending() ([]pendingJob, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	out := []pendingJob{}
	for _, job := range i.state.Jobs {
		if job.ReceiptPublished {
			continue
		}
		raw, err := i.receiptPayload(job)
		if err != nil {
			return nil, err
		}
		out = append(out, pendingJob{job.MessageID, job.Sequence, job.JobSHA256, base64.StdEncoding.EncodeToString(raw)})
	}
	return out, nil
}

// jobFile returns the committed bytes of a job, for the app's own job-file review.
func (i *managedInbox) jobFile(messageID string) ([]byte, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if !lowerHex(messageID, 32) || i.committed(messageID) == nil {
		return nil, errors.New("no such managed job on this phone")
	}
	return officepreview.ReadFile(filepath.Join(i.private, "jobs", messageID+".ogjob"), manageddelivery.MaximumJobBytes)
}

func receiptName(messageID string) string { return "receipts/" + messageID + ".envelope.json" }

// publishReceipt takes the signature the phone application key made over the receipt payload,
// checks it, and publishes the receipt complete under its final name in the records folder.
// Publishing the same receipt again changes nothing.
func (i *managedInbox) publishReceipt(messageID string, signature []byte) error {
	i.mu.Lock()
	defer i.mu.Unlock()
	job := i.committed(messageID)
	if job == nil || !lowerHex(messageID, 32) {
		return errors.New("no such managed job on this phone")
	}
	raw, err := i.receiptPayload(*job)
	if err != nil {
		return err
	}
	if len(signature) != ed25519.SignatureSize || !ed25519.Verify(i.phoneKey, append([]byte(manageddelivery.ReceiptDomain), raw...), signature) {
		return errors.New("the receipt signature is not this phone's")
	}
	envelope, err := manageddelivery.SealReceipt(raw, signature)
	if err != nil {
		return err
	}
	// Staged outside every shared folder, then moved into place complete.
	staged := filepath.Join(i.private, "receipt-"+messageID+".tmp")
	if err = officepreview.Atomic(staged, envelope); err != nil {
		return err
	}
	destination := filepath.Join(i.records, filepath.FromSlash(receiptName(messageID)))
	if err = os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
		return err
	}
	if err = os.Rename(staged, destination); err != nil {
		return err
	}
	if !job.ReceiptPublished {
		job.ReceiptPublished = true
		return i.save()
	}
	return nil
}

// outbound says whether name, in the records folder, is a file this phone published: the only
// thing the outbound guard may serve.
func (i *managedInbox) outbound(name string) bool {
	i.mu.Lock()
	defer i.mu.Unlock()
	id, ok := strings.CutSuffix(strings.TrimPrefix(name, "receipts/"), ".envelope.json")
	if !ok || !strings.HasPrefix(name, "receipts/") || !lowerHex(id, 32) {
		return false
	}
	job := i.committed(id)
	return job != nil && job.ReceiptPublished
}

func (i *managedInbox) counts() (committed, published int) {
	i.mu.Lock()
	defer i.mu.Unlock()
	for _, job := range i.state.Jobs {
		if job.ReceiptPublished {
			published++
		}
	}
	return len(i.state.Jobs), published
}
