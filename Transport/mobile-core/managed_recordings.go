package mobilecore

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"

	"avenkin.dev/mobilecore/officepreview"
	"avenkin.dev/mobilecore/recordingbundle"
	"github.com/syncthing/syncthing/lib/protocol"
)

// Recorded-job bundles (Contracts/recorded-session.md). The native caller seals a bundle and
// signs its manifest; this file publishes exactly the files that manifest lists under
// records/recordings/<bundleID>/, says how much of it the office still needs, and lists what
// the office has said about it. It never decides that a bundle has arrived: only the office's
// signed receipt, verified again by the native caller, says that.

const (
	// maximumRecordingsPublished bounds the bundles in records at once, and
	// maximumRecordingsListened the withdrawn ones still listened for.
	maximumRecordingsPublished = 16
	maximumRecordingsListened  = 64
	// maximumRecordingDocument is the transport's own ceiling on a bundle's timeline or
	// transcript, whatever its manifest says.
	maximumRecordingDocument = 16 << 20
	recordingManifestName    = "manifest.envelope.json"
)

var recordingStatuses = []string{recordingbundle.StatusReceived, recordingbundle.StatusRefused,
	recordingbundle.StatusReviewed, recordingbundle.StatusPublished, recordingbundle.StatusRejected}

// publishedRecording is one sealed bundle in records: its manifest's digest and generation,
// what the manifest lists, and which of those files have been published.
type publishedRecording struct {
	BundleID       string                 `json:"bundleID"`
	ManifestSHA256 string                 `json:"manifestSHA256"`
	Generation     int64                  `json:"generation"`
	Files          []recordingbundle.File `json:"files"`
	Published      map[string]bool        `json:"published"`
	// Withdrawn: its files are out of records and nothing of it is served, and the office's
	// later statuses for it are still listed.
	Withdrawn bool `json:"withdrawn,omitempty"`
}

type recordingProgress struct {
	BundleID string `json:"bundleID"`
	// TotalBytes is every file the manifest lists; PublishedBytes those in records;
	// ServedBytes those in records that the office no longer needs.
	TotalBytes     int64 `json:"totalBytes"`
	PublishedBytes int64 `json:"publishedBytes"`
	ServedBytes    int64 `json:"servedBytes"`
	// AllServed is true only when every listed file is published and the office needs none.
	// It is not the office saying it has the bundle.
	AllServed bool `json:"allServed"`
}

type recordingStatus struct {
	BundleID string `json:"bundleID"`
	Status   string `json:"status"`
	// Envelope is the exact bytes of the file, base64.
	Envelope string `json:"envelope"`
}

func recordingName(bundleID, path string) string { return "recordings/" + bundleID + "/" + path }

func (i *managedInbox) recording(bundleID string) *publishedRecording {
	for n := range i.state.Recordings {
		if i.state.Recordings[n].BundleID == bundleID {
			return &i.state.Recordings[n]
		}
	}
	return nil
}

// recordingTrust is the binding a manifest is read against. A manifest sealed under an earlier
// generation of this binding is still this phone's.
func (i *managedInbox) recordingTrust(key ed25519.PublicKey) recordingbundle.Trust {
	t := i.trust
	return recordingbundle.Trust{OrganizationID: t.OrganizationID, EnrolmentID: t.EnrolmentID, OfficeID: t.OfficeID,
		PhoneTransportID: t.PhoneTransportID, Generation: t.Generation, Key: key}
}

// publishRecording takes a manifest's exact bytes, the phone application key's signature over
// them, and the two JSON files it lists; checks all of it as the office will; and publishes the
// two files and then the manifest. A published name keeps its bytes: the same manifest again
// publishes nothing new, and another manifest under the same bundle is refused.
func (i *managedInbox) publishRecording(payload, signature, timeline, transcript []byte) ([]byte, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if len(signature) != ed25519.SignatureSize || !ed25519.Verify(i.phoneKey, recordingbundle.SigningInput(recordingbundle.Domain, payload), signature) {
		return nil, errors.New("the manifest signature is not this phone's")
	}
	envelope, err := recordingbundle.SealManifest(payload, signature)
	if err != nil {
		return nil, err
	}
	verified, err := recordingbundle.ReadManifest(envelope, i.recordingTrust(i.phoneKey))
	if err != nil {
		return nil, err
	}
	m := verified.Manifest
	if err = m.CheckFile(recordingbundle.TimelinePath, timeline); err != nil {
		return nil, err
	}
	if err = m.CheckFile(recordingbundle.TranscriptPath, transcript); err != nil {
		return nil, err
	}
	held := i.recording(m.BundleID)
	if held != nil && held.ManifestSHA256 != verified.ManifestSHA256 {
		return nil, errors.New("another manifest is published under that bundle")
	}
	if held != nil && !held.Withdrawn {
		if existing, e := officepreview.ReadFile(i.recordsPath(recordingName(m.BundleID, recordingManifestName)), recordingbundle.MaximumEnvelope); e == nil {
			return existing, nil
		}
	} else if i.recordingsInRecords() >= maximumRecordingsPublished {
		return nil, errors.New("too many recordings are waiting for the office")
	}
	// What the manifest lists first, the manifest last: it is never there without them.
	for name, data := range map[string][]byte{recordingbundle.TimelinePath: timeline, recordingbundle.TranscriptPath: transcript} {
		if err = i.publish(recordingName(m.BundleID, name), data); err != nil {
			return nil, err
		}
	}
	if err = i.publish(recordingName(m.BundleID, recordingManifestName), []byte(envelope)); err != nil {
		return nil, err
	}
	if held == nil || held.Withdrawn {
		previous := i.state.Recordings
		var kept []publishedRecording
		for _, r := range previous {
			if r.BundleID != m.BundleID {
				kept = append(kept, r)
			}
		}
		// Published afresh, or again after being withdrawn: only the two files are there.
		i.state.Recordings = append(kept, publishedRecording{BundleID: m.BundleID,
			ManifestSHA256: verified.ManifestSHA256, Generation: m.Generation, Files: m.Files,
			Published: map[string]bool{recordingbundle.TimelinePath: true, recordingbundle.TranscriptPath: true}})
		if err = i.save(); err != nil {
			i.state.Recordings = previous
			return nil, err
		}
	}
	return []byte(envelope), nil
}

// publishRecordingChunk publishes one media chunk a published manifest lists, from path: a file
// in the app's own storage holding exactly that chunk. The bytes are checked against the
// manifest first. The chunk is linked into records where the file system allows it, so a
// recording is not held twice, and copied where it does not.
func (i *managedInbox) publishRecordingChunk(bundleID, digest, path string) error {
	i.mu.Lock()
	defer i.mu.Unlock()
	r := i.recording(bundleID)
	if r == nil || r.Withdrawn || !lowerHex(bundleID, 32) || !lowerHex(digest, 64) {
		return errors.New("no published recording lists that chunk")
	}
	name := recordingbundle.MediaPath(digest)
	var size int64 = -1
	for _, f := range r.Files {
		if f.Role == recordingbundle.RoleMedia && f.Path == name {
			size = f.Bytes
		}
	}
	if size < 0 {
		return errors.New("no published recording lists that chunk")
	}
	destination := i.recordsPath(recordingName(bundleID, name))
	if r.Published[name] {
		if info, err := os.Lstat(destination); err == nil && info.Mode().IsRegular() && info.Size() == size {
			return nil
		}
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() != size {
		return errors.New("the chunk is not the bytes the manifest lists")
	}
	source, err := os.Open(path)
	if err != nil {
		return err
	}
	defer source.Close()
	hash := sha256.New()
	read, err := io.Copy(hash, io.LimitReader(source, size+1))
	if err != nil {
		return err
	}
	if read != size || hex.EncodeToString(hash.Sum(nil)) != digest {
		return errors.New("the chunk is not the bytes the manifest lists")
	}
	if err = os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
		return err
	}
	// Staged under a name the outbound list does not hold, then moved into place complete.
	staged := filepath.Join(i.private, "publish-chunk-"+bundleID+"-"+digest+".tmp")
	_ = os.Remove(staged)
	if err = os.Link(path, staged); err != nil {
		if err = copyExact(source, staged, size, digest); err != nil {
			return err
		}
	}
	if err = os.Rename(staged, destination); err != nil {
		_ = os.Remove(staged)
		return err
	}
	if !r.Published[name] {
		r.Published[name] = true
		return i.save()
	}
	return nil
}

// copyExact writes exactly size bytes of source, whose digest must be digest, to path.
func copyExact(source *os.File, path string, size int64, digest string) error {
	if _, err := source.Seek(0, io.SeekStart); err != nil {
		return err
	}
	out, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	hash := sha256.New()
	copied, err := io.Copy(io.MultiWriter(out, hash), io.LimitReader(source, size+1))
	if err == nil {
		err = out.Sync()
	}
	if closeErr := out.Close(); err == nil {
		err = closeErr
	}
	if err == nil && (copied != size || hex.EncodeToString(hash.Sum(nil)) != digest) {
		err = errors.New("the chunk is not the bytes the manifest lists")
	}
	if err != nil {
		_ = os.Remove(path)
	}
	return err
}

// progress says how much of a bundle is in records and how much of that the office no longer
// needs. needed says whether the office still needs a name in the records folder.
func (i *managedInbox) recordingProgress(bundleID string, needed func(name string) bool) (recordingProgress, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	r := i.recording(bundleID)
	if r == nil || r.Withdrawn {
		return recordingProgress{}, errors.New("no such recording is published")
	}
	out := recordingProgress{BundleID: bundleID, AllServed: !needed(recordingName(bundleID, recordingManifestName))}
	for _, f := range r.Files {
		out.TotalBytes += f.Bytes
		if !r.Published[f.Path] {
			out.AllServed = false
			continue
		}
		out.PublishedBytes += f.Bytes
		if needed(recordingName(bundleID, f.Path)) {
			out.AllServed = false
			continue
		}
		out.ServedBytes += f.Bytes
	}
	return out, nil
}

// recordingStatusList lists what the office has said about the bundles this phone has
// published: each status file in control that reads as the office's, for that bundle and the
// manifest published. The native caller verifies each again before it lets anything go.
func (i *managedInbox) recordingStatusList() ([]recordingStatus, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	out := []recordingStatus{}
	changed := false
	for _, r := range i.state.Recordings {
		sent := recordingbundle.Sent{BundleID: r.BundleID, ManifestSHA256: r.ManifestSHA256, Generation: r.Generation}
		for _, status := range recordingStatuses {
			data, err := officepreview.ReadFile(filepath.Join(i.control, "recordings", r.BundleID+"."+status+envelopeSuffix), recordingbundle.MaximumReceipt)
			if err != nil {
				continue
			}
			digest := recordingbundle.Digest(data)
			if _, seen := i.state.Refused[digest]; seen {
				continue
			}
			receipt, err := recordingbundle.ReadReceipt(string(data), i.recordingTrust(i.trust.OfficeApplicationKey), sent)
			if err == nil && receipt.Status != status {
				err = recordingbundle.ErrFields
			}
			if err != nil {
				if (errors.Is(err, recordingbundle.ErrMalformed) || errors.Is(err, recordingbundle.ErrFields)) && len(i.state.Refused) < maximumRefusedRemembered {
					i.state.Refused[digest], changed = err.Error(), true
				}
				continue
			}
			out = append(out, recordingStatus{r.BundleID, status, base64.StdEncoding.EncodeToString(data)})
		}
	}
	if changed {
		return out, i.save()
	}
	return out, nil
}

// recordingsInRecords counts the bundles whose files are in records. The caller holds the lock.
func (i *managedInbox) recordingsInRecords() int {
	n := 0
	for _, r := range i.state.Recordings {
		if !r.Withdrawn {
			n++
		}
	}
	return n
}

// withdrawRecording takes a bundle this phone published out of records. With forget it is gone
// altogether; without, the office's later statuses for it are still listed, which is what a
// bundle the office has acknowledged wants. Withdrawing one that is not there changes nothing.
func (i *managedInbox) withdrawRecording(bundleID string, forget bool) error {
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.recording(bundleID) == nil || !lowerHex(bundleID, 32) {
		return nil
	}
	var kept []publishedRecording
	listened := 0
	for _, r := range i.state.Recordings {
		if r.BundleID == bundleID {
			if forget {
				continue
			}
			r.Withdrawn, r.Published = true, map[string]bool{}
		}
		if r.Withdrawn {
			listened++
		}
		kept = append(kept, r)
	}
	// The oldest withdrawn ones go first when there are too many to listen for.
	for n := 0; listened > maximumRecordingsListened && n < len(kept); {
		if kept[n].Withdrawn && kept[n].BundleID != bundleID {
			kept = append(kept[:n], kept[n+1:]...)
			listened--
			continue
		}
		n++
	}
	previous := i.state.Recordings
	i.state.Recordings = kept
	// The record of it first: what is no longer in the outbound list is no longer served,
	// whether or not its files have gone yet.
	if err := i.save(); err != nil {
		i.state.Recordings = previous
		return err
	}
	return os.RemoveAll(i.recordsPath("recordings/" + bundleID))
}

// outboundRecording says whether name, in the records folder, is a file of a bundle this phone
// published. The caller holds the lock.
func (i *managedInbox) outboundRecording(name string) bool {
	rest, ok := strings.CutPrefix(name, "recordings/")
	if !ok {
		return false
	}
	bundleID, path, ok := strings.Cut(rest, "/")
	if !ok {
		return false
	}
	r := i.recording(bundleID)
	return r != nil && !r.Withdrawn && (path == recordingManifestName || r.Published[path])
}

// ---------------------------------------------------------------------------------------------
// The bridge
// ---------------------------------------------------------------------------------------------

// PublishManagedRecordingManifest publishes a sealed bundle's manifest at
// records/recordings/<bundleID>/ with the timeline and transcript it lists, and returns the
// exact envelope published. The payload and signature are standard base64: the manifest's one
// spelling, and the phone application key's signature over the recording-bundle domain, one
// zero byte and that payload. timelinePath and transcriptPath are files in the app's own
// storage. Everything is checked as the office will check it.
func (c *Client) PublishManagedRecordingManifest(payloadBase64, signatureBase64, timelinePath, transcriptPath string) (string, error) {
	payload, err := base64.StdEncoding.Strict().DecodeString(payloadBase64)
	if err != nil {
		return "", errors.New("malformed manifest")
	}
	signature, err := base64.StdEncoding.Strict().DecodeString(signatureBase64)
	if err != nil {
		return "", errors.New("malformed signature")
	}
	if !filepath.IsAbs(timelinePath) || !filepath.IsAbs(transcriptPath) {
		return "", errors.New("expected an absolute app-private path")
	}
	timeline, err := officepreview.ReadFile(timelinePath, maximumRecordingDocument)
	if err != nil {
		return "", err
	}
	transcript, err := officepreview.ReadFile(transcriptPath, maximumRecordingDocument)
	if err != nil {
		return "", err
	}
	inbox, err := c.openInbox()
	if err != nil {
		return "", err
	}
	envelope, err := inbox.publishRecording(payload, signature, timeline, transcript)
	if err != nil {
		return "", err
	}
	if err = c.scanRecords(); err != nil {
		return "", err
	}
	return string(envelope), nil
}

// PublishManagedRecordingChunk publishes one media chunk of a published bundle, from path: a
// file in the app's own storage holding exactly that chunk.
func (c *Client) PublishManagedRecordingChunk(bundleID, sha256Hex, path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("expected an absolute app-private path")
	}
	inbox, err := c.openInbox()
	if err != nil {
		return err
	}
	if err = inbox.publishRecordingChunk(bundleID, sha256Hex, path); err != nil {
		return err
	}
	return c.scanRecords()
}

// ManagedRecordingProgress says how much of a published bundle is in records and how much of
// that the office no longer needs, as JSON {bundleID, totalBytes, publishedBytes, servedBytes,
// allServed}. Served is what the engine reports of the office's copy of the folder. It is
// progress, never acknowledgement: only the office's signed receipt says it has the bundle.
func (c *Client) ManagedRecordingProgress(bundleID string) (string, error) {
	inbox, err := c.openInbox()
	if err != nil {
		return "", err
	}
	c.mu.Lock()
	app := c.app
	c.mu.Unlock()
	t := inbox.trust
	folder := managedFolderID(t.OrganizationID, t.EnrolmentID, t.OfficeID, roleRecords)
	needs := map[string]bool{}
	known := false
	if office, e := protocol.DeviceIDFromString(t.OfficeTransportID); e == nil && app != nil {
		known = true
		for page := 1; page <= 64; page++ {
			files, e := app.Internals.RemoteNeedFolderFiles(folder, office, page, 1024)
			if e != nil {
				known = false
				break
			}
			for _, f := range files {
				needs[f.Name] = true
			}
			if len(files) < 1024 {
				break
			}
		}
	}
	// What the engine cannot say the office has, the office is taken to need.
	progress, err := inbox.recordingProgress(bundleID, func(name string) bool { return !known || needs[name] })
	if err != nil {
		return "", err
	}
	return stringJSON(progress)
}

// ManagedRecordingStatuses lists what the office has said about the bundles this phone has
// published, as a JSON array of {bundleID, status, envelope}. Listing is not acting: the native
// caller verifies each again before it lets a recording go.
func (c *Client) ManagedRecordingStatuses() (string, error) {
	c.mu.Lock()
	inbox := c.inbox
	c.mu.Unlock()
	if inbox == nil {
		return "[]", nil
	}
	statuses, err := inbox.recordingStatusList()
	if err != nil {
		return "", err
	}
	return stringJSON(statuses)
}

// WithdrawManagedRecording takes a bundle this phone published out of records. The native
// caller does it once the office's receipt verifies — without forget, so what the office says
// later is still listed — or with forget when the recording is deleted or refused.
func (c *Client) WithdrawManagedRecording(bundleID string, forget bool) error {
	inbox, err := c.openInbox()
	if err != nil {
		return err
	}
	if err = inbox.withdrawRecording(bundleID, forget); err != nil {
		return err
	}
	return c.scanRecords()
}
