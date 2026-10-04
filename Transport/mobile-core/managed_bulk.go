package mobilecore

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"avenkin.dev/mobilecore/manualassignment"
	"avenkin.dev/mobilecore/officebulk"
	"avenkin.dev/mobilecore/officepreview"
	"github.com/syncthing/syncthing/lib/config"
)

// Bulk content in the managed folders (Contracts/office-bulk.md): the organisation's manuals
// and the files that go with a job. The bulk folder is how those bytes arrive, never why they
// are accepted. It takes only the files the native caller has asked for by digest and size —
// which it asks for only once an assignment, or a job the phone holds, names them — and it is
// paused until the native caller says the route is one large content may use. A file is handed
// over only as a private copy whose size and digest were checked. Nothing in it is ever served.

const (
	bulkVault      = "vault"
	bulkAttachment = "attachment"
	// maximumBulkWanted bounds how many files may be asked for at once.
	maximumBulkWanted = 64
	// maximumAssignmentArchive is the transport's own ceiling when it reads an assignment to list
	// it. The native caller applies the organisation's real one.
	maximumAssignmentArchive = int64(1) << 40
	maximumAssignmentsKept   = 64
)

// bulkItem is one file the native caller has asked for.
type bulkItem struct {
	Kind   string `json:"kind"`
	SHA256 string `json:"sha256"`
	Bytes  int64  `json:"bytes"`
	// Ready: its exact bytes are in private storage.
	Ready bool `json:"ready,omitempty"`
}

type bulkStatus struct {
	Kind   string `json:"kind"`
	SHA256 string `json:"sha256"`
	// State is "ready" (a checked private copy is here), "offered" (the office has put it in
	// the folder and it is not here yet) or "waiting" (the office has not offered it).
	State string `json:"state"`
}

type bulkPending struct {
	Grants      []pendingEnvelope `json:"grants"`
	Assignments []pendingEnvelope `json:"assignments"`
}

type assignmentReceiptRecord struct {
	AssignmentID string `json:"assignmentID"`
	Outcome      string `json:"outcome"`
	Payload      string `json:"payload"` // base64
	Published    bool   `json:"published"`
}

func bulkName(item bulkItem) string {
	if item.Kind == bulkVault {
		return "vaults/" + item.SHA256 + ".zip"
	}
	return "attachments/" + item.SHA256
}

func assignmentReceiptName(assignmentID, outcome string) string {
	return "assignments/" + assignmentID + "." + outcome + envelopeSuffix
}

// bulkIgnores is the bulk folder's whole ignore list: each wanted file, then everything else.
func bulkIgnores(wanted []bulkItem) []string {
	lines := make([]string, 0, len(wanted)+1)
	for _, item := range wanted {
		if !item.Ready {
			lines = append(lines, "!/"+bulkName(item))
		}
	}
	sort.Strings(lines)
	return append(lines, "*")
}

// writeBulkIgnores puts the ignore list in place before the engine starts, so nothing is taken
// in the moment before the first request.
func (i *managedInbox) writeBulkIgnores() error {
	i.mu.Lock()
	defer i.mu.Unlock()
	return officepreview.Atomic(filepath.Join(i.bulk, ".stignore"), []byte(strings.Join(bulkIgnores(i.state.Wanted), "\n")+"\n"))
}

// setWanted replaces what is asked for. A file that was ready and is no longer wanted is let go
// of; one that is still wanted keeps its checked copy.
func (i *managedInbox) setWanted(items []bulkItem) ([]string, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if len(items) > maximumBulkWanted {
		return nil, errors.New("too much bulk content asked for at once")
	}
	seen := map[string]bool{}
	next := make([]bulkItem, 0, len(items))
	for _, item := range items {
		if item.Kind != bulkVault && item.Kind != bulkAttachment || !lowerHex(item.SHA256, 64) || item.Bytes <= 0 || seen[item.SHA256] {
			return nil, errors.New("invalid bulk request")
		}
		seen[item.SHA256] = true
		for _, held := range i.state.Wanted {
			if held.SHA256 == item.SHA256 && held.Kind == item.Kind && held.Bytes == item.Bytes {
				item.Ready = held.Ready
			}
		}
		next = append(next, bulkItem{item.Kind, item.SHA256, item.Bytes, item.Ready})
	}
	previous := i.state.Wanted
	i.state.Wanted = next
	if err := i.save(); err != nil {
		i.state.Wanted = previous
		return nil, err
	}
	for _, held := range previous {
		if !seen[held.SHA256] {
			_ = os.Remove(filepath.Join(i.private, "bulk", held.SHA256))
		}
	}
	lines := bulkIgnores(next)
	return lines, officepreview.Atomic(filepath.Join(i.bulk, ".stignore"), []byte(strings.Join(lines, "\n")+"\n"))
}

// takeIn copies one wanted file out of the bulk folder into private storage, when it is there
// in full: exactly the size and digest asked for. Anything else is left where it is.
func (i *managedInbox) takeIn(item bulkItem) bool {
	path := filepath.Join(i.bulk, filepath.FromSlash(bulkName(item)))
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() != item.Bytes {
		return false
	}
	source, err := os.Open(path)
	if err != nil {
		return false
	}
	defer source.Close()
	staged, err := os.CreateTemp(filepath.Join(i.private, "bulk"), ".avenkin-bulk-")
	if err != nil {
		return false
	}
	defer os.Remove(staged.Name())
	hash := sha256.New()
	copied, err := io.Copy(io.MultiWriter(staged, hash), io.LimitReader(source, item.Bytes+1))
	if err == nil {
		err = staged.Sync()
	}
	if closeErr := staged.Close(); err == nil {
		err = closeErr
	}
	if err != nil || copied != item.Bytes || hex.EncodeToString(hash.Sum(nil)) != item.SHA256 {
		return false
	}
	return os.Chmod(staged.Name(), 0600) == nil && os.Rename(staged.Name(), filepath.Join(i.private, "bulk", item.SHA256)) == nil
}

// status says where each wanted file is, taking in any that has arrived. offered answers
// whether the office has put a name in the folder.
func (i *managedInbox) status(offered func(name string) bool) ([]bulkStatus, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	out := make([]bulkStatus, 0, len(i.state.Wanted))
	changed := false
	for n := range i.state.Wanted {
		item := &i.state.Wanted[n]
		if !item.Ready && i.takeIn(*item) {
			item.Ready, changed = true, true
		}
		state := "waiting"
		if item.Ready {
			state = "ready"
		} else if offered != nil && offered(bulkName(*item)) {
			state = "offered"
		}
		out = append(out, bulkStatus{item.Kind, item.SHA256, state})
	}
	if changed {
		if err := i.save(); err != nil {
			return nil, err
		}
		// What is here is no longer asked of the office.
		_ = officepreview.Atomic(filepath.Join(i.bulk, ".stignore"), []byte(strings.Join(bulkIgnores(i.state.Wanted), "\n")+"\n"))
	}
	return out, nil
}

// file is the private path of a wanted file that is ready.
func (i *managedInbox) file(digest string) (string, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	for _, item := range i.state.Wanted {
		if item.SHA256 == digest && item.Ready {
			return filepath.Join(i.private, "bulk", digest), nil
		}
	}
	return "", errors.New("no such bulk content on this phone")
}

// bulkPending lists the publisher grants and manual assignments in control that read as their
// own messages for this phone. The native caller verifies each again through its own gate.
func (i *managedInbox) bulkPending(now int64) (bulkPending, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	out := bulkPending{[]pendingEnvelope{}, []pendingEnvelope{}}
	changed := false
	b64 := base64.StdEncoding.EncodeToString
	if i.authority != nil {
		for _, id := range i.controlNames("publishers", envelopeSuffix) {
			data, err := officepreview.ReadFile(filepath.Join(i.control, "publishers", id+envelopeSuffix), officebulk.MaximumMessage)
			if err != nil {
				continue
			}
			digest := officebulk.Digest(data)
			if _, seen := i.state.Refused[digest]; seen {
				continue
			}
			grant, _, err := officebulk.ReadGrant(string(data), i.authority.administratorKey, i.trust.OrganizationID, i.authority.profileID)
			if err != nil {
				if (errors.Is(err, officebulk.ErrMalformed) || errors.Is(err, officebulk.ErrFields)) && len(i.state.Refused) < maximumRefusedRemembered {
					i.state.Refused[digest], changed = err.Error(), true
				}
				continue
			}
			if grant.GrantID == id {
				out.Grants = append(out.Grants, pendingEnvelope{id, b64(data)})
			}
		}
	}
	for _, id := range i.controlNames("assignments", envelopeSuffix) {
		data, err := officepreview.ReadFile(filepath.Join(i.control, "assignments", id+envelopeSuffix), manualassignment.MaximumEnvelopeBytes)
		if err != nil {
			continue
		}
		if verified, ok := i.assignment(data, now); ok && verified.Payload.AssignmentID == id {
			out.Assignments = append(out.Assignments, pendingEnvelope{id, b64(data)})
		}
	}
	if changed {
		return out, i.save()
	}
	return out, nil
}

// assignment reads one manual assignment against the binding handed over. The set is the
// assignment's own: which sets this phone takes is the native caller's to say.
func (i *managedInbox) assignment(data []byte, now int64) (manualassignment.Verified, bool) {
	var e manualassignment.Envelope
	var named struct {
		SetID string `json:"setID"`
	}
	if json.Unmarshal(data, &e) != nil {
		return manualassignment.Verified{}, false
	}
	payload, err := base64.StdEncoding.Strict().DecodeString(e.Payload)
	if err != nil || json.Unmarshal(payload, &named) != nil {
		return manualassignment.Verified{}, false
	}
	t := i.trust
	verified, err := manualassignment.Verify(data, manualassignment.Trust{OrganizationID: t.OrganizationID, EnrolmentID: t.EnrolmentID,
		OfficeID: t.OfficeID, SetID: named.SetID, Generation: t.Generation, MaximumArchiveBytes: maximumAssignmentArchive,
		PublicKey: t.OfficeApplicationKey}, now, nil)
	return verified, err == nil
}

func (i *managedInbox) assignmentReceipt(assignmentID, outcome string) *assignmentReceiptRecord {
	for n := range i.state.AssignmentReceipts {
		if r := &i.state.AssignmentReceipts[n]; r.AssignmentID == assignmentID && r.Outcome == outcome {
			return r
		}
	}
	return nil
}

// assignmentReceiptPayload builds, once per assignment and outcome, the receipt for an
// assignment that verifies.
func (i *managedInbox) assignmentReceiptPayload(assignmentID, outcome string, at, now int64) ([]byte, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if !lowerHex(assignmentID, 32) || outcome != officebulk.OutcomeReceived && outcome != officebulk.OutcomeInstalled {
		return nil, errors.New("no such manual assignment on this phone")
	}
	if r := i.assignmentReceipt(assignmentID, outcome); r != nil {
		return base64.StdEncoding.Strict().DecodeString(r.Payload)
	}
	data, err := officepreview.ReadFile(filepath.Join(i.control, "assignments", assignmentID+envelopeSuffix), manualassignment.MaximumEnvelopeBytes)
	if err != nil {
		return nil, errors.New("no such manual assignment on this phone")
	}
	verified, ok := i.assignment(data, now)
	if !ok || verified.Payload.AssignmentID != assignmentID {
		return nil, errors.New("no such manual assignment on this phone")
	}
	p := verified.Payload
	payload, err := officebulk.ReceiptPayload(officebulk.Receipt{Version: 1, Kind: officebulk.ReceiptKind, AssignmentID: p.AssignmentID,
		AssignmentSHA256: verified.PayloadSHA256, OrganizationID: p.OrganizationID, EnrolmentID: p.EnrolmentID, OfficeID: p.OfficeID,
		Generation: p.Generation, PhoneTransportID: i.trust.PhoneTransportID, SetID: p.SetID, Sequence: p.Sequence,
		ArchiveSHA256: p.ArchiveSHA256, Outcome: outcome, At: at})
	if err != nil {
		return nil, err
	}
	if len(i.state.AssignmentReceipts) >= maximumAssignmentsKept*2 {
		return nil, errors.New("too many manual assignments on this phone")
	}
	previous := i.state.AssignmentReceipts
	i.state.AssignmentReceipts = append(append([]assignmentReceiptRecord{}, previous...),
		assignmentReceiptRecord{AssignmentID: assignmentID, Outcome: outcome, Payload: base64.StdEncoding.EncodeToString(payload)})
	if err = i.save(); err != nil {
		i.state.AssignmentReceipts = previous
		return nil, err
	}
	return payload, nil
}

func (i *managedInbox) publishAssignmentReceipt(assignmentID, outcome string, signature []byte) ([]byte, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	r := i.assignmentReceipt(assignmentID, outcome)
	if r == nil || !lowerHex(assignmentID, 32) {
		return nil, errors.New("no such manual assignment on this phone")
	}
	payload, err := base64.StdEncoding.Strict().DecodeString(r.Payload)
	if err != nil {
		return nil, err
	}
	if len(signature) != ed25519.SignatureSize || !ed25519.Verify(i.phoneKey, officebulk.SigningInput(officebulk.ReceiptDomain, payload), signature) {
		return nil, errors.New("the assignment receipt signature is not this phone's")
	}
	name := assignmentReceiptName(assignmentID, outcome)
	if r.Published {
		if existing, e := officepreview.ReadFile(i.recordsPath(name), officebulk.MaximumMessage); e == nil {
			return existing, nil
		}
	}
	envelope, err := officebulk.SealReceipt(payload, signature)
	if err != nil {
		return nil, err
	}
	if err = i.publish(name, []byte(envelope)); err != nil {
		return nil, err
	}
	if !r.Published {
		r.Published = true
		return []byte(envelope), i.save()
	}
	return []byte(envelope), nil
}

// outboundAssignmentReceipt says whether name, in the records folder, is an assignment receipt
// this phone published. The caller holds the lock.
func (i *managedInbox) outboundAssignmentReceipt(name string) bool {
	rest, ok := strings.CutPrefix(name, "assignments/")
	if !ok {
		return false
	}
	for _, r := range i.state.AssignmentReceipts {
		if r.Published && rest == r.AssignmentID+"."+r.Outcome+envelopeSuffix {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------------------------
// The bridge
// ---------------------------------------------------------------------------------------------

func (c *Client) bulkFolderID() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.inbox == nil || c.app == nil {
		return "", errors.New("no managed office folders are open")
	}
	t := c.inbox.trust
	return managedFolderID(t.OrganizationID, t.EnrolmentID, t.OfficeID, roleBulk), nil
}

// ManagedBulkPending lists the publisher grants and manual assignments the office has put in
// control that read as their own messages for this phone, as a JSON object {grants,
// assignments}, each an array of {id, envelope}. Listing is not acting: the native caller
// verifies each again through its own gate before it trusts a publisher or asks for an archive.
func (c *Client) ManagedBulkPending() (string, error) {
	c.mu.Lock()
	inbox := c.inbox
	c.mu.Unlock()
	if inbox == nil {
		return stringJSON(bulkPending{[]pendingEnvelope{}, []pendingEnvelope{}})
	}
	pending, err := inbox.bulkPending(officepreview.Now())
	if err != nil {
		return "", err
	}
	return stringJSON(pending)
}

// SetManagedBulkWanted says exactly which files the bulk folder may take: a JSON array of
// {kind, sha256, bytes}, kind "vault" or "attachment". It replaces what was asked for before.
// The native caller asks only for an archive a verified assignment names, or an attachment a
// job this phone holds names. Everything else in the folder stays ignored.
func (c *Client) SetManagedBulkWanted(wantedJSON string) error {
	var items []bulkItem
	if len(wantedJSON) > 1<<16 || json.Unmarshal([]byte(wantedJSON), &items) != nil {
		return errors.New("invalid bulk request")
	}
	folder, err := c.bulkFolderID()
	if err != nil {
		return err
	}
	c.mu.Lock()
	inbox, app := c.inbox, c.app
	c.mu.Unlock()
	lines, err := inbox.setWanted(items)
	if err != nil {
		return err
	}
	return app.Internals.SetIgnores(folder, lines)
}

// ManagedBulkStatus says where each wanted file is, as a JSON array of {kind, sha256, state}:
// "ready" (a private copy with exactly the size and digest asked for is here), "offered" (the
// office has put it in the folder and it has not arrived) or "waiting". A finished transfer of
// other bytes is never ready.
func (c *Client) ManagedBulkStatus() (string, error) {
	folder, err := c.bulkFolderID()
	if err != nil {
		return "[]", nil
	}
	c.mu.Lock()
	inbox, app := c.inbox, c.app
	c.mu.Unlock()
	status, err := inbox.status(func(name string) bool {
		_, found, e := app.Internals.GlobalFileInfo(folder, name)
		return e == nil && found
	})
	if err != nil {
		return "", err
	}
	return stringJSON(status)
}

// ManagedBulkFile returns the private path of a wanted file that is ready: a copy whose size
// and digest were checked, outside every shared folder.
func (c *Client) ManagedBulkFile(sha256Hex string) (string, error) {
	inbox, err := c.openInbox()
	if err != nil {
		return "", err
	}
	return inbox.file(sha256Hex)
}

// SetManagedBulkPaused pauses or resumes the bulk folder. It starts paused: large content moves
// only once the native caller says the route is one it may use.
func (c *Client) SetManagedBulkPaused(paused bool) error {
	folder, err := c.bulkFolderID()
	if err != nil {
		return err
	}
	c.mu.Lock()
	wrapper := c.wrapper
	c.mu.Unlock()
	if wrapper == nil {
		return errors.New("no managed office folders are open")
	}
	_, err = wrapper.Modify(func(conf *config.Configuration) {
		for n := range conf.Folders {
			if conf.Folders[n].ID == folder {
				conf.Folders[n].Paused = paused
			}
		}
	})
	return err
}

// ManagedAssignmentReceiptPayload returns the exact bytes (base64) of the receipt for one manual
// assignment and outcome ("received" or "installed"), for the phone application key to sign
// under the assignment-receipt domain. at is when the native caller reached that outcome;
// asking again returns the same bytes.
func (c *Client) ManagedAssignmentReceiptPayload(assignmentID, outcome string, at int64) (string, error) {
	inbox, err := c.openInbox()
	if err != nil {
		return "", err
	}
	payload, err := inbox.assignmentReceiptPayload(assignmentID, outcome, at, officepreview.Now())
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(payload), nil
}

// PublishManagedAssignmentReceipt publishes that receipt at records/assignments/ and returns the
// exact envelope published.
func (c *Client) PublishManagedAssignmentReceipt(assignmentID, outcome, signatureBase64 string) (string, error) {
	return c.publishRecord(signatureBase64, func(inbox *managedInbox, signature []byte) ([]byte, error) {
		return inbox.publishAssignmentReceipt(assignmentID, outcome, signature)
	})
}
