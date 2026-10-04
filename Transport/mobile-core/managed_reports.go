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
	"avenkin.dev/mobilecore/officereport"
)

// Reports in the managed folders (Contracts/office-reports.md). The phone publishes a signed
// report with the record and the manifest it names, and then each attachment, in records; the
// office answers with receipts in control. As everywhere here, a folder grants nothing and
// nothing acts on what it reads: the native caller decides what a receipt means. This verifies
// what it is asked to publish, serves exactly what it published, and lists the receipts that
// read as receipts for those reports.

// publishedReport is one report in the records folder, and which of its attachments are.
type publishedReport struct {
	ReportID       string           `json:"reportID"`
	RecordSHA256   string           `json:"recordSHA256"`
	ManifestSHA256 string           `json:"manifestSHA256"`
	Attachments    []reportEvidence `json:"attachments"`
	Published      map[string]bool  `json:"published,omitempty"` // attachment digest → in records
}

type reportEvidence struct {
	SHA256 string `json:"sha256"`
	Bytes  int64  `json:"bytes"`
}

type pendingReceipt struct {
	ReportID string `json:"reportID"`
	// Stage is the word in the receipt's file name: pending, record or full.
	Stage string `json:"stage"`
	// Envelope is the exact bytes of the file, base64.
	Envelope string `json:"envelope"`
}

const (
	// maximumReportsPublished bounds how many reports wait in records at once.
	maximumReportsPublished = 64
	recordSuffix            = ".record.json"
	manifestSuffix          = ".manifest.json"
)

func reportName(reportID string) string   { return "reports/" + reportID + envelopeSuffix }
func recordName(digest string) string     { return "reports/" + digest + recordSuffix }
func manifestName(digest string) string   { return "reports/" + digest + manifestSuffix }
func attachmentName(digest string) string { return "attachments/" + digest }

func (i *managedInbox) reportTrust() officereport.Trust {
	t := i.trust
	return officereport.Trust{OrganizationID: t.OrganizationID, EnrolmentID: t.EnrolmentID, OfficeID: t.OfficeID,
		PhoneTransportID: t.PhoneTransportID, PhoneApplicationKey: i.phoneKey}
}

func (i *managedInbox) report(reportID string) *publishedReport {
	for n := range i.state.Reports {
		if i.state.Reports[n].ReportID == reportID {
			return &i.state.Reports[n]
		}
	}
	return nil
}

func (i *managedInbox) recordsPath(name string) string {
	return filepath.Join(i.records, filepath.FromSlash(name))
}

// publishReport takes a report payload, the phone application key's signature over it, and the
// record and manifest it names; checks all of it as the office will; and publishes the three
// files complete under their final names. A published name keeps its bytes: publishing the same
// report again returns the envelope already there.
func (i *managedInbox) publishReport(payload, signature, record, manifest []byte) ([]byte, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if len(signature) != ed25519.SignatureSize || !ed25519.Verify(i.phoneKey, officereport.SigningInput(officereport.ReportDomain, payload), signature) {
		return nil, errors.New("the report signature is not this phone's")
	}
	envelope, err := officereport.SealReport(payload, signature)
	if err != nil {
		return nil, err
	}
	report, err := officereport.ReadReport(envelope, i.reportTrust())
	if err != nil {
		return nil, err
	}
	m, err := report.Carries(record, manifest)
	if err != nil {
		return nil, err
	}
	if held := i.report(report.ReportID); held != nil {
		if held.RecordSHA256 != report.RecordSHA256 || held.ManifestSHA256 != report.ManifestSHA256 {
			return nil, errors.New("another report is published under that operation")
		}
		if existing, e := officepreview.ReadFile(i.recordsPath(reportName(report.ReportID)), officereport.MaximumReport); e == nil {
			if _, e = officereport.ReadReport(string(existing), i.reportTrust()); e == nil {
				return existing, nil
			}
		}
	} else if len(i.state.Reports) >= maximumReportsPublished {
		return nil, errors.New("too many reports are waiting for the office")
	}
	// The companions first, the envelope last: a report is never there without what it names.
	for name, data := range map[string][]byte{recordName(report.RecordSHA256): record, manifestName(report.ManifestSHA256): manifest} {
		if err = i.publish(name, data); err != nil {
			return nil, err
		}
	}
	if err = i.publish(reportName(report.ReportID), []byte(envelope)); err != nil {
		return nil, err
	}
	if i.report(report.ReportID) == nil {
		evidence := make([]reportEvidence, 0, len(m.Attachments))
		for _, a := range m.Attachments {
			evidence = append(evidence, reportEvidence{a.SHA256, a.Bytes})
		}
		previous := i.state.Reports
		i.state.Reports = append(append([]publishedReport{}, previous...), publishedReport{ReportID: report.ReportID,
			RecordSHA256: report.RecordSHA256, ManifestSHA256: report.ManifestSHA256, Attachments: evidence, Published: map[string]bool{}})
		// An attachment another report already published is this report's too.
		added := &i.state.Reports[len(i.state.Reports)-1]
		for _, a := range evidence {
			if i.attachmentPublished(a.SHA256) {
				added.Published[a.SHA256] = true
			}
		}
		if err = i.save(); err != nil {
			i.state.Reports = previous
			return nil, err
		}
	}
	return []byte(envelope), nil
}

func (i *managedInbox) attachmentPublished(digest string) bool {
	for _, r := range i.state.Reports {
		if r.Published[digest] {
			return true
		}
	}
	return false
}

// publishAttachment copies one attachment a published report names from path, a file in the
// app's own storage, into records. The bytes must be exactly the size and digest the manifest
// gave; nothing else is ever copied in.
func (i *managedInbox) publishAttachment(digest, path string) error {
	i.mu.Lock()
	defer i.mu.Unlock()
	if !lowerHex(digest, 64) {
		return errors.New("no published report names that attachment")
	}
	var size int64 = -1
	for _, r := range i.state.Reports {
		for _, a := range r.Attachments {
			if a.SHA256 == digest {
				size = a.Bytes
			}
		}
	}
	if size < 0 {
		return errors.New("no published report names that attachment")
	}
	if !i.attachmentPublished(digest) {
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() != size {
			return errors.New("the attachment is not the bytes the report names")
		}
		source, err := os.Open(path)
		if err != nil {
			return err
		}
		defer source.Close()
		// Staged outside every shared folder, checked, then moved into place complete.
		staged, err := os.CreateTemp(i.private, ".avenkin-attachment-")
		if err != nil {
			return err
		}
		defer os.Remove(staged.Name())
		hash := sha256.New()
		copied, err := io.Copy(io.MultiWriter(staged, hash), io.LimitReader(source, size+1))
		if err == nil {
			err = staged.Sync()
		}
		if closeErr := staged.Close(); err == nil {
			err = closeErr
		}
		if err != nil {
			return err
		}
		if copied != size || hex.EncodeToString(hash.Sum(nil)) != digest {
			return errors.New("the attachment is not the bytes the report names")
		}
		destination := i.recordsPath(attachmentName(digest))
		if err = os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
			return err
		}
		if err = os.Chmod(staged.Name(), 0600); err != nil {
			return err
		}
		if err = os.Rename(staged.Name(), destination); err != nil {
			return err
		}
	}
	changed := false
	for n := range i.state.Reports {
		r := &i.state.Reports[n]
		for _, a := range r.Attachments {
			if a.SHA256 == digest && !r.Published[digest] {
				if r.Published == nil {
					r.Published = map[string]bool{}
				}
				r.Published[digest] = true
				changed = true
			}
		}
	}
	if changed {
		return i.save()
	}
	return nil
}

// withdrawReport takes a report out of records: after the office has fully accepted it, or
// when a later revision replaces it. A file another published report still names stays.
func (i *managedInbox) withdrawReport(reportID string) error {
	i.mu.Lock()
	defer i.mu.Unlock()
	gone := i.report(reportID)
	if gone == nil || !lowerHex(reportID, 64) {
		return nil
	}
	removed := *gone
	var kept []publishedReport
	for _, r := range i.state.Reports {
		if r.ReportID != reportID {
			kept = append(kept, r)
		}
	}
	previous := i.state.Reports
	i.state.Reports = kept
	// The record of it first: what is no longer in the outbound list is no longer served,
	// whether or not its files have gone yet.
	if err := i.save(); err != nil {
		i.state.Reports = previous
		return err
	}
	_ = os.Remove(i.recordsPath(reportName(reportID)))
	stillNamed := func(match func(publishedReport) bool) bool {
		for _, r := range kept {
			if match(r) {
				return true
			}
		}
		return false
	}
	if !stillNamed(func(r publishedReport) bool { return r.RecordSHA256 == removed.RecordSHA256 }) {
		_ = os.Remove(i.recordsPath(recordName(removed.RecordSHA256)))
	}
	if !stillNamed(func(r publishedReport) bool { return r.ManifestSHA256 == removed.ManifestSHA256 }) {
		_ = os.Remove(i.recordsPath(manifestName(removed.ManifestSHA256)))
	}
	for digest := range removed.Published {
		if !stillNamed(func(r publishedReport) bool { return r.Published[digest] }) {
			_ = os.Remove(i.recordsPath(attachmentName(digest)))
		}
	}
	return nil
}

// reportReceipts lists the office's receipts for the reports this phone has published: signed
// by the office application key the binding names, for exactly the report in records, and
// under the name its outcome has.
func (i *managedInbox) reportReceipts() ([]pendingReceipt, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	out := []pendingReceipt{}
	changed := false
	for _, r := range i.state.Reports {
		envelope, err := officepreview.ReadFile(i.recordsPath(reportName(r.ReportID)), officereport.MaximumReport)
		if err != nil {
			continue
		}
		report, err := officereport.ReadReport(string(envelope), i.reportTrust())
		if err != nil {
			continue
		}
		manifestRaw, err := officepreview.ReadFile(i.recordsPath(manifestName(r.ManifestSHA256)), officereport.MaximumManifest)
		if err != nil {
			continue
		}
		manifest, err := officereport.ReadManifest(manifestRaw)
		if err != nil {
			continue
		}
		for _, stage := range []string{"pending", "record", "full"} {
			data, err := officepreview.ReadFile(filepath.Join(i.control, "receipts", r.ReportID+"."+stage+envelopeSuffix), officereport.MaximumReceipt)
			if err != nil {
				continue
			}
			digest := officereport.Digest(data)
			if _, seen := i.state.Refused[digest]; seen {
				continue
			}
			receipt, err := officereport.ReadReceipt(string(data), i.trust.OfficeApplicationKey, string(envelope), report, manifest)
			if err == nil && officereport.Stage(receipt.Outcome) != stage {
				err = officereport.ErrFields
			}
			if err != nil {
				if (errors.Is(err, officereport.ErrMalformed) || errors.Is(err, officereport.ErrFields)) && len(i.state.Refused) < maximumRefusedRemembered {
					i.state.Refused[digest] = err.Error()
					changed = true
				}
				continue
			}
			out = append(out, pendingReceipt{r.ReportID, stage, base64.StdEncoding.EncodeToString(data)})
		}
	}
	if changed {
		return out, i.save()
	}
	return out, nil
}

// outboundReport says whether name, in the records folder, is a file of a report this phone has
// published and not withdrawn. The caller holds the lock.
func (i *managedInbox) outboundReport(name string) bool {
	if digest, ok := strings.CutPrefix(name, "attachments/"); ok {
		return lowerHex(digest, 64) && i.attachmentPublished(digest)
	}
	rest, ok := strings.CutPrefix(name, "reports/")
	if !ok {
		return false
	}
	for _, r := range i.state.Reports {
		if rest == r.ReportID+envelopeSuffix || rest == r.RecordSHA256+recordSuffix || rest == r.ManifestSHA256+manifestSuffix {
			return true
		}
	}
	return false
}

func (i *managedInbox) reportCount() int {
	i.mu.Lock()
	defer i.mu.Unlock()
	return len(i.state.Reports)
}

// ---------------------------------------------------------------------------------------------
// The bridge
// ---------------------------------------------------------------------------------------------

func (c *Client) openInbox() (*managedInbox, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.inbox == nil {
		return nil, errors.New("no managed office folders are open")
	}
	return c.inbox, nil
}

func (c *Client) scanRecords() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.inbox == nil || c.app == nil {
		return errors.New("no managed office folders are open")
	}
	t := c.inbox.trust
	return c.app.Internals.ScanFolderSubdirs(managedFolderID(t.OrganizationID, t.EnrolmentID, t.OfficeID, roleRecords), nil)
}

// PublishManagedReport publishes one report at records/reports/ with the record and the
// manifest it names, and returns the exact envelope published. Each argument is standard base64:
// the report payload, the phone application key's signature over the report domain, one zero
// byte and that payload, the record's bytes and the manifest's. Everything is checked as the
// office will check it; anything that is not this phone's report for this office publishes
// nothing. Publishing the same report again returns the envelope already there.
func (c *Client) PublishManagedReport(payloadBase64, signatureBase64, recordBase64, manifestBase64 string) (string, error) {
	var parts [4][]byte
	for n, text := range []string{payloadBase64, signatureBase64, recordBase64, manifestBase64} {
		raw, err := base64.StdEncoding.Strict().DecodeString(text)
		if err != nil {
			return "", errors.New("malformed report")
		}
		parts[n] = raw
	}
	inbox, err := c.openInbox()
	if err != nil {
		return "", err
	}
	envelope, err := inbox.publishReport(parts[0], parts[1], parts[2], parts[3])
	if err != nil {
		return "", err
	}
	if err = c.scanRecords(); err != nil {
		return "", err
	}
	return string(envelope), nil
}

// PublishManagedReportAttachment publishes one attachment a published report names, at
// records/attachments/<sha256>, from path: a file in the app's own storage holding exactly the
// bytes the manifest gave. The transport copies it; it never reads any other path.
func (c *Client) PublishManagedReportAttachment(sha256Hex, path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("expected an absolute app-private path")
	}
	inbox, err := c.openInbox()
	if err != nil {
		return err
	}
	if err = inbox.publishAttachment(sha256Hex, path); err != nil {
		return err
	}
	return c.scanRecords()
}

// ManagedReportReceipts lists the office's receipts for the reports this phone has published,
// as a JSON array of {reportID, stage, envelope}: stage is pending, record or full, and envelope
// the exact bytes of the file, base64. Listing is not acting: the native caller verifies each
// again before it treats a record as delivered.
func (c *Client) ManagedReportReceipts() (string, error) {
	c.mu.Lock()
	inbox := c.inbox
	c.mu.Unlock()
	if inbox == nil {
		return "[]", nil
	}
	receipts, err := inbox.reportReceipts()
	if err != nil {
		return "", err
	}
	return stringJSON(receipts)
}

// WithdrawManagedReport takes a report this phone published out of records, with the record,
// manifest and attachments no other published report names. Withdrawing one that is not there
// changes nothing.
func (c *Client) WithdrawManagedReport(reportID string) error {
	inbox, err := c.openInbox()
	if err != nil {
		return err
	}
	if err = inbox.withdrawReport(reportID); err != nil {
		return err
	}
	return c.scanRecords()
}
