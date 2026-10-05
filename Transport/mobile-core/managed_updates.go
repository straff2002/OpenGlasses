package mobilecore

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"avenkin.dev/mobilecore/jobupdate"
	"avenkin.dev/mobilecore/officepreview"
)

// Updates on a job the phone already has (Contracts/job-updates.md). The office puts a signed
// update in control/updates/; the native caller keeps it against the job it names and gives a
// receipt, which is published at records/updates/. Listing is not acting, and this file never
// decides what an update means: it reads, offers exact bytes to sign, and publishes.

// maximumUpdateReceipts bounds the receipts kept. A receipt is let go once the office has taken
// its update out of control, which it does after reading the receipt.
const maximumUpdateReceipts = 256

type updateReceiptRecord struct {
	UpdateID string `json:"updateID"`
	// Payload is the exact receipt bytes, base64, built once.
	Payload   string `json:"payload"`
	Published bool   `json:"published,omitempty"`
}

func updateReceiptName(updateID string) string {
	return "updates/" + updateID + envelopeSuffix
}

func (i *managedInbox) updateTrust() jobupdate.Trust {
	t := i.trust
	return jobupdate.Trust{OrganizationID: t.OrganizationID, EnrolmentID: t.EnrolmentID, OfficeID: t.OfficeID,
		OfficeTransportID: t.OfficeTransportID, PhoneTransportID: t.PhoneTransportID, Generation: t.Generation,
		OfficeApplicationKey: t.OfficeApplicationKey}
}

func (i *managedInbox) updateReceipt(updateID string) *updateReceiptRecord {
	for n := range i.state.UpdateReceipts {
		if r := &i.state.UpdateReceipts[n]; r.UpdateID == updateID {
			return r
		}
	}
	return nil
}

func (i *managedInbox) updateReceiptCount() int {
	i.mu.Lock()
	defer i.mu.Unlock()
	return len(i.state.UpdateReceipts)
}

// updatesPending lists the updates in control that read as their own messages for this phone
// now, and lets go of the receipts whose updates the office has taken away. The native caller
// verifies each again through its own gate before it keeps one.
func (i *managedInbox) updatesPending(now int64) ([]pendingEnvelope, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	out := []pendingEnvelope{}
	changed := false
	for _, id := range i.controlNames("updates", envelopeSuffix) {
		data, err := officepreview.ReadFile(filepath.Join(i.control, "updates", id+envelopeSuffix), jobupdate.MaximumMessage)
		if err != nil {
			continue
		}
		digest := jobupdate.Digest(data)
		if _, seen := i.state.Refused[digest]; seen {
			continue
		}
		verified, err := jobupdate.Read(string(data), i.updateTrust(), now)
		if err != nil {
			// Only what can never verify is remembered. One that is not current waits.
			if (errors.Is(err, jobupdate.ErrMalformed) || errors.Is(err, jobupdate.ErrFields)) && len(i.state.Refused) < maximumRefusedRemembered {
				i.state.Refused[digest], changed = err.Error(), true
			}
			continue
		}
		if verified.Payload.UpdateID == id {
			out = append(out, pendingEnvelope{id, base64.StdEncoding.EncodeToString(data)})
		}
	}
	// A receipt whose update is no longer in control has been read, or its update has run out
	// or been withdrawn: none of those needs it any more, published or not.
	var kept []updateReceiptRecord
	var gone []string
	for _, r := range i.state.UpdateReceipts {
		if _, err := os.Stat(filepath.Join(i.control, "updates", r.UpdateID+envelopeSuffix)); errors.Is(err, os.ErrNotExist) {
			gone = append(gone, r.UpdateID)
			continue
		}
		kept = append(kept, r)
	}
	if len(gone) > 0 {
		previous := i.state.UpdateReceipts
		i.state.UpdateReceipts = kept
		// The record first: what is no longer in the outbound list is no longer served.
		if err := i.save(); err != nil {
			i.state.UpdateReceipts = previous
			return out, err
		}
		for _, id := range gone {
			_ = os.Remove(i.recordsPath(updateReceiptName(id)))
		}
		return out, nil
	}
	if changed {
		return out, i.save()
	}
	return out, nil
}

// updateReceiptPayload builds, once per update, the receipt for an update that verifies now.
// jobState is what the native caller held for the job when it committed the update; the first
// answer is the one kept.
func (i *managedInbox) updateReceiptPayload(updateID, jobState string, at, now int64) ([]byte, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if !lowerHex(updateID, 32) {
		return nil, errors.New("no such job update on this phone")
	}
	if r := i.updateReceipt(updateID); r != nil {
		return base64.StdEncoding.Strict().DecodeString(r.Payload)
	}
	data, err := officepreview.ReadFile(filepath.Join(i.control, "updates", updateID+envelopeSuffix), jobupdate.MaximumMessage)
	if err != nil {
		return nil, errors.New("no such job update on this phone")
	}
	verified, err := jobupdate.Read(string(data), i.updateTrust(), now)
	if err != nil || verified.Payload.UpdateID != updateID {
		return nil, errors.New("no such job update on this phone")
	}
	payload, err := jobupdate.ReceiptPayload(jobupdate.ReceiptFor(verified, jobState, at))
	if err != nil {
		return nil, err
	}
	if len(i.state.UpdateReceipts) >= maximumUpdateReceipts {
		return nil, errors.New("too many job updates on this phone")
	}
	previous := i.state.UpdateReceipts
	i.state.UpdateReceipts = append(append([]updateReceiptRecord{}, previous...),
		updateReceiptRecord{UpdateID: updateID, Payload: base64.StdEncoding.EncodeToString(payload)})
	if err = i.save(); err != nil {
		i.state.UpdateReceipts = previous
		return nil, err
	}
	return payload, nil
}

func (i *managedInbox) publishUpdateReceipt(updateID string, signature []byte) ([]byte, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	r := i.updateReceipt(updateID)
	if r == nil || !lowerHex(updateID, 32) {
		return nil, errors.New("no such job update on this phone")
	}
	payload, err := base64.StdEncoding.Strict().DecodeString(r.Payload)
	if err != nil {
		return nil, err
	}
	if len(signature) != ed25519.SignatureSize || !ed25519.Verify(i.phoneKey, jobupdate.SigningInput(jobupdate.ReceiptDomain, payload), signature) {
		return nil, errors.New("the job update receipt signature is not this phone's")
	}
	name := updateReceiptName(updateID)
	if r.Published {
		if existing, e := officepreview.ReadFile(i.recordsPath(name), jobupdate.MaximumMessage); e == nil {
			return existing, nil
		}
	}
	envelope, err := jobupdate.SealReceipt(payload, signature)
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

// outboundUpdateReceipt says whether name, in the records folder, is an update receipt this
// phone published. The caller holds the lock.
func (i *managedInbox) outboundUpdateReceipt(name string) bool {
	rest, ok := strings.CutPrefix(name, "updates/")
	if !ok {
		return false
	}
	for _, r := range i.state.UpdateReceipts {
		if r.Published && rest == r.UpdateID+envelopeSuffix {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------------------------
// The bridge
// ---------------------------------------------------------------------------------------------

// ManagedJobUpdatesPending lists the job updates the office has put in control that read as
// their own messages for this phone now, as a JSON array of {id, envelope}. Listing is not
// acting: the native caller verifies each again through its own gate before it keeps one.
func (c *Client) ManagedJobUpdatesPending() (string, error) {
	c.mu.Lock()
	inbox := c.inbox
	c.mu.Unlock()
	if inbox == nil {
		return "[]", nil
	}
	before := inbox.updateReceiptCount()
	pending, err := inbox.updatesPending(officepreview.Now())
	if err != nil {
		return "", err
	}
	if inbox.updateReceiptCount() != before {
		// A receipt was let go: the engine is told now, rather than at its next rescan, so the
		// office sees it leave the folder.
		_ = c.scanRecords()
	}
	return stringJSON(pending)
}

// ManagedJobUpdateReceiptPayload returns the exact bytes (base64) of the receipt for one job
// update, for the phone application key to sign under the update-receipt domain. jobState is
// what the phone held for the job when it committed the update ("held", "finished" or
// "unknown") and at is when it did; asking again returns the same bytes.
func (c *Client) ManagedJobUpdateReceiptPayload(updateID, jobState string, at int64) (string, error) {
	inbox, err := c.openInbox()
	if err != nil {
		return "", err
	}
	payload, err := inbox.updateReceiptPayload(updateID, jobState, at, officepreview.Now())
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(payload), nil
}

// PublishManagedJobUpdateReceipt publishes that receipt at records/updates/ and returns the
// exact envelope published.
func (c *Client) PublishManagedJobUpdateReceipt(updateID, signatureBase64 string) (string, error) {
	return c.publishRecord(signatureBase64, func(inbox *managedInbox, signature []byte) ([]byte, error) {
		return inbox.publishUpdateReceipt(updateID, signature)
	})
}
