package mobilecore

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"avenkin.dev/mobilecore/jobfile"
	"avenkin.dev/mobilecore/jobupdate"
	"avenkin.dev/mobilecore/laboffice"
	"avenkin.dev/mobilecore/manageddelivery"
	"avenkin.dev/mobilecore/manualassignment"
	"avenkin.dev/mobilecore/officebulk"
	"avenkin.dev/mobilecore/officereport"
	"avenkin.dev/mobilecore/recordingbundle"
	"github.com/syncthing/syncthing/lib/protocol"
)

// engineWorld is a phone's real embedded engine connected to a synthetic office over BEP: the
// two ends of the managed folders, with the fixture application keys (public labels, no
// authority) and the transport identities the two ends really have.
type engineWorld struct {
	t                             *testing.T
	ctx                           context.Context
	client                        *Client
	office                        *laboffice.Office
	folders                       laboffice.Folders
	officeKey, phoneKey, adminKey ed25519.PrivateKey
	organizationID, enrolmentID   string
	officeID                      string
	now                           int64
	appDir                        string
}

const engineWait = 60 * time.Second

// newEngineWorld starts both ends, or skips: the phone dials only a private LAN address, so the
// test needs one named.
func newEngineWorld(t *testing.T) *engineWorld {
	t.Helper()
	ip := os.Getenv("AVENKIN_MANUAL_TEST_IP")
	if ip == "" {
		t.Skip("requires an explicit private interface: the managed phone dials only a private LAN address")
	}
	directory := t.TempDir()
	w := &engineWorld{t: t, officeKey: testKey("Avenkin public fixture office key v1"), phoneKey: testKey("Avenkin public fixture phone key v1"),
		adminKey: testKey("Avenkin public fixture administrator key v1"), organizationID: "fixture-organisation", enrolmentID: "fixture-enrolment",
		now: time.Now().Unix(), appDir: filepath.Join(directory, "app")}
	if err := os.MkdirAll(w.appDir, 0700); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(w.officeKey.Public().(ed25519.PublicKey))
	w.officeID = "office-" + hex.EncodeToString(sum[:12])
	var cancel context.CancelFunc
	w.ctx, cancel = context.WithTimeout(context.Background(), 3*time.Minute)
	t.Cleanup(cancel)

	client, err := NewClient(filepath.Join(directory, "phone"))
	if err != nil {
		t.Fatal(err)
	}
	w.client = client
	phone, err := protocol.DeviceIDFromString(client.DeviceID())
	if err != nil {
		t.Fatal(err)
	}
	if w.office, err = laboffice.Listen(filepath.Join(directory, "office"), ip+":0"); err != nil {
		t.Fatal(err)
	}
	w.folders = laboffice.Folders{
		Control: managedFolderID(w.organizationID, w.enrolmentID, w.officeID, roleControl),
		Records: managedFolderID(w.organizationID, w.enrolmentID, w.officeID, roleRecords),
		Bulk:    managedFolderID(w.organizationID, w.enrolmentID, w.officeID, roleBulk),
	}
	served := make(chan error, 1)
	go func() { served <- w.office.Serve(w.ctx, phone, w.folders) }()

	b64 := base64.StdEncoding.EncodeToString
	binding, err := json.Marshal(managedBinding{OrganizationID: w.organizationID, EnrolmentID: w.enrolmentID, OfficeID: w.officeID, Generation: 1,
		OfficeTransportID: w.office.ID.String(), OfficeApplicationKey: b64(w.officeKey.Public().(ed25519.PublicKey)),
		PhoneApplicationKey: b64(w.phoneKey.Public().(ed25519.PublicKey)), ProfileID: "fixture-profile",
		BindingSHA256: hex.EncodeToString(sum[:]), AdministratorKey: b64(w.adminKey.Public().(ed25519.PublicKey))})
	if err != nil {
		t.Fatal(err)
	}
	if err = client.StartManagedOfficeFolders(string(binding), managedPrivateLan, "tcp://"+w.office.Address); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		client.Stop()
		cancel()
		select {
		case <-served:
		case <-time.After(5 * time.Second):
		}
	})
	w.until("the phone to connect", func() bool {
		var status struct {
			Connected     bool   `json:"connected"`
			SharedFolders int    `json:"sharedFolders"`
			Type          string `json:"observedConnectionType"`
			Local         bool   `json:"observedConnectionLocal"`
		}
		raw, err := client.Snapshot()
		// Straight to the office on a private network: the engine says so, and says it is local.
		return err == nil && json.Unmarshal([]byte(raw), &status) == nil && status.Connected && status.SharedFolders == 3 &&
			strings.HasPrefix(status.Type, "tcp-") && status.Local
	})
	return w
}

// until waits for something the two engines do in their own time.
func (w *engineWorld) until(what string, done func() bool) {
	w.t.Helper()
	deadline := time.Now().Add(engineWait)
	for time.Now().Before(deadline) {
		if done() {
			return
		}
		select {
		case <-w.ctx.Done():
			w.t.Fatalf("waiting for %s: %v", what, w.ctx.Err())
		case <-time.After(50 * time.Millisecond):
		}
	}
	w.t.Fatalf("timed out waiting for %s", what)
}

// fetch waits for the phone to announce a name in records and pulls it.
func (w *engineWorld) fetch(name string) []byte {
	w.t.Helper()
	var data []byte
	w.until("the phone to publish "+name, func() bool {
		for _, published := range w.office.Published() {
			if published == name {
				fetched, err := w.office.Fetch(w.ctx, name)
				if err != nil {
					return false
				}
				data = fetched
				return true
			}
		}
		return false
	})
	return data
}

// refusedToOffice asks the phone for a name as an office that should not be given it.
func (w *engineWorld) refusedToOffice(folder, name string) {
	w.t.Helper()
	data, err := w.office.Ask(w.ctx, folder, name, 16, nil)
	if len(data) != 0 || !errors.Is(err, protocol.ErrNoSuchFile) {
		w.t.Fatalf("%s in %s was not refused: %d bytes, %v", name, folder, len(data), err)
	}
}

func (w *engineWorld) sign(key ed25519.PrivateKey, message []byte) string {
	return base64.StdEncoding.EncodeToString(ed25519.Sign(key, message))
}

func hexDigest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// A signed job put in the office's folder reaches the phone's private store through the real
// engine, and the phone's signed receipt comes back the same way and verifies at the office.
// Nothing else the phone holds can be asked for.
func TestAJobAndItsReceiptCrossTheRealEngine(t *testing.T) {
	w := newEngineWorld(t)
	job := []byte(strings.Join([]string{`{"format":"openglasses.job","format_version":2,"job":`, jobfile.FixtureJob, `}`}, ""))
	message := manageddelivery.Job{Version: 1, Kind: "avenkin.managed-job", MessageID: hexDigest([]byte("engine job"))[:32],
		OrganizationID: w.organizationID, EnrolmentID: w.enrolmentID, OfficeID: w.officeID, Generation: 1,
		OfficeTransportID: w.office.ID.String(), PhoneTransportID: w.client.DeviceID(), Sequence: 1,
		IssuedAt: w.now - 60, ExpiresAt: w.now + 86400, JobSHA256: hexDigest(job), JobBytes: int64(len(job))}
	envelope, err := manageddelivery.Sign(message, w.officeKey)
	if err != nil {
		t.Fatal(err)
	}
	// The job file first and its envelope second: arrival order means nothing.
	w.office.Put(w.folders.Control, "jobs/"+message.JobSHA256+".ogjob", job)
	w.office.Put(w.folders.Control, "jobs/"+message.MessageID+".envelope.json", envelope)

	var pending []struct {
		MessageID      string `json:"messageID"`
		ReceiptPayload string `json:"receiptPayload"`
	}
	w.until("the job to be committed", func() bool {
		raw, err := w.client.ManagedJobsPending()
		return err == nil && json.Unmarshal([]byte(raw), &pending) == nil && len(pending) == 1
	})
	committed, err := w.client.ManagedJobFile(message.MessageID)
	if err != nil {
		t.Fatal(err)
	}
	if held, _ := base64.StdEncoding.DecodeString(committed); string(held) != string(job) {
		t.Fatal("the committed job is not the bytes the office sent")
	}
	payload, err := base64.StdEncoding.DecodeString(pending[0].ReceiptPayload)
	if err != nil {
		t.Fatal(err)
	}
	// Before the receipt is published the office can have nothing.
	w.refusedToOffice(w.folders.Records, "receipts/"+message.MessageID+".envelope.json")
	if err = w.client.PublishManagedJobReceipt(message.MessageID, w.sign(w.phoneKey, append([]byte(manageddelivery.ReceiptDomain), payload...))); err != nil {
		t.Fatal(err)
	}
	receipt := w.fetch("receipts/" + message.MessageID + ".envelope.json")
	verified, err := manageddelivery.Verify(envelope, manageddelivery.Trust{OrganizationID: w.organizationID, EnrolmentID: w.enrolmentID,
		OfficeID: w.officeID, OfficeTransportID: w.office.ID.String(), PhoneTransportID: w.client.DeviceID(), Generation: 1,
		OfficeApplicationKey: w.officeKey.Public().(ed25519.PublicKey)}, w.now, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = manageddelivery.VerifyReceipt(receipt, manageddelivery.ReceiptTrust{OrganizationID: w.organizationID, EnrolmentID: w.enrolmentID,
		OfficeID: w.officeID, PhoneTransportID: w.client.DeviceID(), Generation: 1, PhoneApplicationKey: w.phoneKey.Public().(ed25519.PublicKey)},
		manageddelivery.ReceiptExpected{MessageID: message.MessageID, Sequence: 1, PayloadSHA256: verified.PayloadSHA256, JobSHA256: message.JobSHA256}); err != nil {
		t.Fatalf("the receipt the office pulled does not verify: %v", err)
	}

	// The office is served the receipt and nothing else: not the job it sent, not the phone's
	// private store, not another folder.
	w.refusedToOffice(w.folders.Records, "jobs/"+message.JobSHA256+".ogjob")
	w.refusedToOffice(w.folders.Records, "receipts/"+strings.Repeat("0", 32)+".envelope.json")
	w.refusedToOffice(w.folders.Control, "jobs/"+message.JobSHA256+".ogjob")
	w.refusedToOffice(w.folders.Control, "jobs/"+message.MessageID+".envelope.json")
	w.refusedToOffice(w.folders.Bulk, "vaults/"+strings.Repeat("0", 64)+".zip")
	w.refusedToOffice("another-folder", "receipts/"+message.MessageID+".envelope.json")
}

// A report, its record, its manifest and its evidence reach the office through the real engine;
// the office's signed receipts come back and verify on the phone; and an update on a job goes
// out and is receipted the same way.
func TestAReportItsReceiptsAndAnUpdateCrossTheRealEngine(t *testing.T) {
	w := newEngineWorld(t)
	b64 := base64.StdEncoding.EncodeToString
	phonePublic, officePublic := w.phoneKey.Public().(ed25519.PublicKey), w.officeKey.Public().(ed25519.PublicKey)

	record := []byte(officereport.FixtureRecord)
	evidence := []byte("Avenkin engine test work order: bytes that stand in for a document")
	manifest, err := officereport.ManifestBytes(officereport.ManifestFor([]officereport.Attachment{{SHA256: hexDigest(evidence), Bytes: int64(len(evidence)),
		Role: officereport.RoleWorkOrder, MediaType: "application/pdf", Name: "job-JOB-1042.pdf", Requirement: officereport.Required, Audience: officereport.AudienceCustomer}}))
	if err != nil {
		t.Fatal(err)
	}
	report := officereport.ReportFor(officereport.Report{OperationID: "7C9E6679-7425-40DE-944B-E07FC1F90AE7", RecordKind: officereport.RecordWorkRecord,
		RecordID: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", Revision: 1, OrganizationID: w.organizationID, EnrolmentID: w.enrolmentID, OfficeID: w.officeID,
		PhoneTransportID: w.client.DeviceID(), JobReference: "JOB-1042", JobID: "job-2031", JobRevision: 2, Transcript: officereport.TranscriptNone, CreatedAt: w.now},
		record, manifest)
	payload, err := officereport.ReportPayload(report)
	if err != nil {
		t.Fatal(err)
	}
	published, err := w.client.PublishManagedReport(b64(payload), w.sign(w.phoneKey, officereport.SigningInput(officereport.ReportDomain, payload)), b64(record), b64(manifest))
	if err != nil {
		t.Fatal(err)
	}

	// The office takes the three files and reads them as it would from a real phone.
	envelope := string(w.fetch("reports/" + report.ReportID + ".envelope.json"))
	if envelope != published {
		t.Fatal("the envelope the office pulled is not the one the phone published")
	}
	read, err := officereport.ReadReport(envelope, officereport.Trust{OrganizationID: w.organizationID, EnrolmentID: w.enrolmentID, OfficeID: w.officeID,
		PhoneTransportID: w.client.DeviceID(), PhoneApplicationKey: phonePublic})
	if err != nil {
		t.Fatal(err)
	}
	listed, err := read.Carries(w.fetch("reports/"+report.RecordSHA256+".record.json"), w.fetch("reports/"+report.ManifestSHA256+".manifest.json"))
	if err != nil {
		t.Fatalf("the record and manifest the office pulled are not the ones the report names: %v", err)
	}

	// The evidence is not there until the phone publishes it, and then it is exactly the bytes.
	w.refusedToOffice(w.folders.Records, "attachments/"+hexDigest(evidence))
	file := filepath.Join(w.appDir, "work-order.pdf")
	if err = os.WriteFile(file, evidence, 0600); err != nil {
		t.Fatal(err)
	}
	receipt := func(have bool, at int64) string {
		signed, err := officereport.SignReceipt(officereport.ReceiptFor(envelope, read, listed, func(string) bool { return have }, at), w.officeKey)
		if err != nil {
			t.Fatal(err)
		}
		return signed
	}
	pending := receipt(false, w.now+1)
	w.office.Put(w.folders.Control, "receipts/"+report.ReportID+".pending.envelope.json", []byte(pending))
	stages := func() map[string]string {
		var receipts []struct{ ReportID, Stage, Envelope string }
		raw, err := w.client.ManagedReportReceipts()
		if err != nil || json.Unmarshal([]byte(raw), &receipts) != nil {
			return nil
		}
		out := map[string]string{}
		for _, r := range receipts {
			if text, e := base64.StdEncoding.DecodeString(r.Envelope); e == nil && r.ReportID == report.ReportID {
				out[r.Stage] = string(text)
			}
		}
		return out
	}
	w.until("the office's first receipt to reach the phone", func() bool { return stages()["pending"] == pending })
	if err = w.client.PublishManagedReportAttachment(hexDigest(evidence), file); err != nil {
		t.Fatal(err)
	}
	if got := w.fetch("attachments/" + hexDigest(evidence)); string(got) != string(evidence) {
		t.Fatal("the evidence the office pulled is not the bytes the manifest names")
	}
	full := receipt(true, w.now+2)
	w.office.Put(w.folders.Control, "receipts/"+report.ReportID+".full.envelope.json", []byte(full))
	w.until("the office's last receipt to reach the phone", func() bool { return stages()["full"] == full })
	accepted, err := officereport.ReadReceipt(full, officePublic, envelope, report, listed)
	if err != nil || accepted.Outcome != officereport.OutcomeFullyAccepted {
		t.Fatalf("the receipt the phone holds does not say the office has everything: %+v %v", accepted, err)
	}
	// Withdrawn, the office is no longer served any of it.
	if err = w.client.WithdrawManagedReport(report.ReportID); err != nil {
		t.Fatal(err)
	}
	w.refusedToOffice(w.folders.Records, "reports/"+report.ReportID+".envelope.json")
	w.refusedToOffice(w.folders.Records, "attachments/"+hexDigest(evidence))

	// An update on a job: out in control, taken in, receipted in records.
	update := jobupdate.Update{Version: 1, Kind: jobupdate.Kind, UpdateID: hexDigest([]byte("engine update"))[:32], OrganizationID: w.organizationID,
		EnrolmentID: w.enrolmentID, OfficeID: w.officeID, Generation: 1, OfficeTransportID: w.office.ID.String(), PhoneTransportID: w.client.DeviceID(),
		JobID: "job-2031", Sequence: 1, IssuedAt: w.now - 60, ExpiresAt: w.now + 86400, UpdateKind: jobupdate.KindNote, Body: "Gate code is now 4412."}
	message, err := jobupdate.Sign(update, w.officeKey)
	if err != nil {
		t.Fatal(err)
	}
	w.office.Put(w.folders.Control, "updates/"+update.UpdateID+".envelope.json", []byte(message))
	w.until("the update to be listed", func() bool {
		var listed []struct{ ID, Envelope string }
		raw, err := w.client.ManagedJobUpdatesPending()
		return err == nil && json.Unmarshal([]byte(raw), &listed) == nil && len(listed) == 1 && listed[0].ID == update.UpdateID
	})
	receiptPayload, err := w.client.ManagedJobUpdateReceiptPayload(update.UpdateID, jobupdate.JobHeld, w.now)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := base64.StdEncoding.DecodeString(receiptPayload)
	if _, err = w.client.PublishManagedJobUpdateReceipt(update.UpdateID, w.sign(w.phoneKey, jobupdate.SigningInput(jobupdate.ReceiptDomain, raw))); err != nil {
		t.Fatal(err)
	}
	verified, err := jobupdate.Read(message, jobupdate.Trust{OrganizationID: w.organizationID, EnrolmentID: w.enrolmentID, OfficeID: w.officeID,
		OfficeTransportID: w.office.ID.String(), PhoneTransportID: w.client.DeviceID(), Generation: 1, OfficeApplicationKey: officePublic}, w.now)
	if err != nil {
		t.Fatal(err)
	}
	got, err := jobupdate.ReadReceipt(string(w.fetch("updates/"+update.UpdateID+".envelope.json")), phonePublic, jobupdate.SentFor(verified))
	if err != nil || got.JobState != jobupdate.JobHeld {
		t.Fatalf("the update receipt the office pulled does not verify: %+v %v", got, err)
	}
	// The office has read the receipt and takes its update away: the phone lets the receipt go,
	// and the office sees it leave the folder.
	w.office.Remove(w.folders.Control, "updates/"+update.UpdateID+".envelope.json")
	w.until("the receipt to leave the folder", func() bool {
		if _, err := w.client.ManagedJobUpdatesPending(); err != nil {
			return false
		}
		for _, name := range w.office.Published() {
			if name == "updates/"+update.UpdateID+".envelope.json" {
				return false
			}
		}
		return true
	})
	w.refusedToOffice(w.folders.Records, "updates/"+update.UpdateID+".envelope.json")
}

// An assigned manual and a job's attachment come through the bulk folder only once the phone
// has asked for exactly them and let the folder run; nothing else in the folder is taken, and
// nothing in it can be asked back.
func TestAManualAndAnAttachmentComeThroughBulkOnlyWhenAskedFor(t *testing.T) {
	w := newEngineWorld(t)
	phonePublic := w.phoneKey.Public().(ed25519.PublicKey)
	fixtures, err := officebulk.Fixtures()
	if err != nil {
		t.Fatal(err)
	}
	archive := fixtures["office-bulk-vault-v1.zip"]
	publisher := testKey("Avenkin public fixture organisation publisher key v1")
	publisherID := officebulk.PublisherPrefix + w.organizationID
	grant := officebulk.Grant{Version: 1, Kind: officebulk.GrantKind, GrantID: hexDigest([]byte("engine grant"))[:32], OrganizationID: w.organizationID,
		ProfileID: "fixture-profile", PublisherID: publisherID, PublisherName: "Fixture Organisation",
		PublisherKey: base64.StdEncoding.EncodeToString(publisher.Public().(ed25519.PublicKey)), Sequence: 1, Status: officebulk.StatusActive,
		IssuedAt: w.now - 600, ExpiresAt: w.now + 90*86400}
	signedGrant, err := officebulk.SignGrant(grant, w.adminKey)
	if err != nil {
		t.Fatal(err)
	}
	assignment := manualassignment.Payload{Version: 1, Kind: "avenkin.manual-assignment", AssignmentID: hexDigest([]byte("engine assignment"))[:32],
		OrganizationID: w.organizationID, EnrolmentID: w.enrolmentID, OfficeID: w.officeID, Generation: 1, SetID: "fixture-manuals", Sequence: 1,
		IssuedAt: w.now - 600, ExpiresAt: w.now + 7*86400, VaultID: "fixture-organisation-vault", VaultVersion: "1.0.0", PublisherID: publisherID,
		ArchiveSHA256: hexDigest(archive), ArchiveBytes: int64(len(archive))}
	signedAssignment, err := manualassignment.Sign(assignment, w.officeKey)
	if err != nil {
		t.Fatal(err)
	}
	w.office.Put(w.folders.Control, "publishers/"+grant.GrantID+".envelope.json", []byte(signedGrant))
	w.office.Put(w.folders.Control, "assignments/"+assignment.AssignmentID+".envelope.json", signedAssignment)
	w.until("the grant and the assignment to be listed", func() bool {
		var pending struct{ Grants, Assignments []struct{ ID string } }
		raw, err := w.client.ManagedBulkPending()
		return err == nil && json.Unmarshal([]byte(raw), &pending) == nil && len(pending.Grants) == 1 && len(pending.Assignments) == 1
	})

	// The office puts three things in bulk: the assigned archive, a job's attachment, and an
	// archive nobody assigned.
	attachment := []byte(jobfile.FixtureAttachment)
	stray := []byte("an archive nothing assigned to this phone")
	w.office.Put(w.folders.Bulk, "vaults/"+hexDigest(archive)+".zip", archive)
	w.office.Put(w.folders.Bulk, "attachments/"+hexDigest(attachment), attachment)
	w.office.Put(w.folders.Bulk, "vaults/"+hexDigest(stray)+".zip", stray)

	wanted, _ := json.Marshal([]map[string]any{
		{"kind": "attachment", "sha256": hexDigest(attachment), "bytes": len(attachment)},
		{"kind": "vault", "sha256": hexDigest(archive), "bytes": len(archive)},
	})
	if err = w.client.SetManagedBulkWanted(string(wanted)); err != nil {
		t.Fatal(err)
	}
	states := func() map[string]string {
		var status []struct{ SHA256, State string }
		raw, err := w.client.ManagedBulkStatus()
		if err != nil || json.Unmarshal([]byte(raw), &status) != nil {
			return nil
		}
		out := map[string]string{}
		for _, s := range status {
			out[s.SHA256] = s.State
		}
		return out
	}
	// The folder starts paused: asked for, and nothing moves.
	time.Sleep(2 * time.Second)
	if got := states(); got[hexDigest(archive)] == "ready" || got[hexDigest(attachment)] == "ready" {
		t.Fatalf("a paused folder fetched: %v", got)
	}
	if _, err = w.client.ManagedBulkFile(hexDigest(archive)); err == nil {
		t.Fatal("a paused folder handed over an archive")
	}
	if err = w.client.SetManagedBulkPaused(false); err != nil {
		t.Fatal(err)
	}
	w.until("the archive and the attachment to arrive", func() bool {
		got := states()
		return got[hexDigest(archive)] == "ready" && got[hexDigest(attachment)] == "ready"
	})
	for digest, want := range map[string][]byte{hexDigest(archive): archive, hexDigest(attachment): attachment} {
		path, err := w.client.ManagedBulkFile(digest)
		if err != nil {
			t.Fatal(err)
		}
		if got, _ := os.ReadFile(path); string(got) != string(want) {
			t.Fatalf("what was handed over for %s is not the bytes asked for", digest)
		}
		if strings.HasPrefix(path, w.client.inbox.bulk) {
			t.Fatal("the checked copy is inside the shared folder")
		}
	}
	// What was not asked for never arrives, however long the folder runs.
	time.Sleep(2 * time.Second)
	if _, err = os.Stat(filepath.Join(w.client.inbox.bulk, "vaults", hexDigest(stray)+".zip")); !os.IsNotExist(err) {
		t.Fatal("an archive nobody assigned was taken into the folder")
	}
	if _, err = w.client.ManagedBulkFile(hexDigest(stray)); err == nil {
		t.Fatal("an archive nobody asked for was handed over")
	}

	// The phone's receipt for the assignment reaches the office and verifies.
	receiptPayload, err := w.client.ManagedAssignmentReceiptPayload(assignment.AssignmentID, officebulk.OutcomeReceived, w.now)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := base64.StdEncoding.DecodeString(receiptPayload)
	if _, err = w.client.PublishManagedAssignmentReceipt(assignment.AssignmentID, officebulk.OutcomeReceived, w.sign(w.phoneKey, officebulk.SigningInput(officebulk.ReceiptDomain, raw))); err != nil {
		t.Fatal(err)
	}
	pulled := w.fetch("assignments/" + assignment.AssignmentID + ".received.envelope.json")
	verified, err := manualassignment.Verify(signedAssignment, manualassignment.Trust{OrganizationID: w.organizationID, EnrolmentID: w.enrolmentID, OfficeID: w.officeID,
		SetID: assignment.SetID, Generation: 1, MaximumArchiveBytes: 1 << 20, PublicKey: w.officeKey.Public().(ed25519.PublicKey)}, w.now, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = officebulk.ReadReceipt(string(pulled), phonePublic, officebulk.Sent{AssignmentID: assignment.AssignmentID, AssignmentSHA256: verified.PayloadSHA256,
		OrganizationID: w.organizationID, EnrolmentID: w.enrolmentID, OfficeID: w.officeID, Generation: 1, PhoneTransportID: w.client.DeviceID(),
		SetID: assignment.SetID, Sequence: 1, ArchiveSHA256: assignment.ArchiveSHA256}); err != nil {
		t.Fatalf("the assignment receipt the office pulled does not verify: %v", err)
	}

	// Nothing the phone received can be asked back, from any folder.
	w.refusedToOffice(w.folders.Bulk, "vaults/"+hexDigest(archive)+".zip")
	w.refusedToOffice(w.folders.Bulk, "attachments/"+hexDigest(attachment))
	w.refusedToOffice(w.folders.Records, "vaults/"+hexDigest(archive)+".zip")
	w.refusedToOffice(w.folders.Control, "assignments/"+assignment.AssignmentID+".envelope.json")
}

// A recorded-job bundle reaches the office through the real engine as exactly what its manifest
// lists; what the office has taken is counted as served and never as received; and only the
// office's signed receipt, back through control, is listed for the phone to act on.
func TestARecordedJobBundleAndItsReceiptCrossTheRealEngine(t *testing.T) {
	w := newEngineWorld(t)
	b64 := base64.StdEncoding.EncodeToString
	read := func(name string) []byte {
		data, err := os.ReadFile(filepath.Join("..", "..", "Contracts", "fixtures", name))
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	timeline, transcript := read("recorded-session-timeline-v1.json"), read("recorded-session-transcript-v1.json")
	m := recordingbundle.FixtureManifest(timeline, transcript)
	m.PhoneTransportID, m.CreatedAt, m.ConsentAt = w.client.DeviceID(), w.now, w.now-3600
	payload, err := m.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	paths := map[string]string{}
	write := func(name string, data []byte) string {
		path := filepath.Join(w.appDir, name)
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	var chunks [][]byte
	for _, part := range []string{recordingbundle.FixtureVideoPart, recordingbundle.FixtureAudioPart} {
		for _, chunk := range recordingbundle.Chunks([]byte(part), recordingbundle.FixtureChunkBytes) {
			chunks = append(chunks, chunk)
			paths[recordingbundle.Digest(chunk)] = write(recordingbundle.Digest(chunk)+".chunk", chunk)
		}
	}
	published, err := w.client.PublishManagedRecordingManifest(b64(payload), w.sign(w.phoneKey, recordingbundle.SigningInput(recordingbundle.Domain, payload)),
		write("timeline.json", timeline), write("transcript.json", transcript))
	if err != nil {
		t.Fatal(err)
	}
	progress := func() recordingProgress {
		var p recordingProgress
		raw, err := w.client.ManagedRecordingProgress(m.BundleID)
		if err != nil || json.Unmarshal([]byte(raw), &p) != nil {
			return recordingProgress{}
		}
		return p
	}
	prefix := "recordings/" + m.BundleID + "/"

	// The office reads the manifest as it would from a real phone, and takes the two files.
	envelope := string(w.fetch(prefix + "manifest.envelope.json"))
	if envelope != published {
		t.Fatal("the manifest the office pulled is not the one the phone published")
	}
	v, err := recordingbundle.ReadManifest(envelope, recordingbundle.Trust{OrganizationID: w.organizationID, EnrolmentID: w.enrolmentID, OfficeID: w.officeID,
		PhoneTransportID: w.client.DeviceID(), Generation: 1, Key: w.phoneKey.Public().(ed25519.PublicKey)})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{recordingbundle.TimelinePath, recordingbundle.TranscriptPath} {
		if err = v.Manifest.CheckFile(name, w.fetch(prefix+name)); err != nil {
			t.Fatalf("%s as the office pulled it is not the file listed: %v", name, err)
		}
	}
	documents := int64(len(timeline) + len(transcript))
	w.until("the engine to count the two files as served", func() bool { return progress().ServedBytes == documents })
	if progress().AllServed {
		t.Fatal("served before any media was published")
	}

	// A chunk is not there until it is published; then it is a link to the app's own file.
	first := recordingbundle.Digest(chunks[0])
	w.refusedToOffice(w.folders.Records, prefix+recordingbundle.MediaPath(first))
	for _, chunk := range chunks {
		digest := recordingbundle.Digest(chunk)
		if err = w.client.PublishManagedRecordingChunk(m.BundleID, digest, paths[digest]); err != nil {
			t.Fatal(err)
		}
		if err = v.Manifest.CheckFile(recordingbundle.MediaPath(digest), w.fetch(prefix+recordingbundle.MediaPath(digest))); err != nil {
			t.Fatalf("a chunk as the office pulled it is not the one listed: %v", err)
		}
	}
	own, _ := os.Stat(paths[first])
	inFolder, _ := os.Stat(filepath.Join(w.client.inbox.records, "recordings", m.BundleID, filepath.FromSlash(recordingbundle.MediaPath(first))))
	if own == nil || inFolder == nil || !os.SameFile(own, inFolder) {
		t.Fatal("the chunk in the office's folder is a second copy, not a link to the app's own")
	}
	w.until("everything to be counted as served", func() bool { return progress().AllServed })

	// All served is not received: nothing is listed until the office says so, signed.
	if raw, _ := w.client.ManagedRecordingStatuses(); raw != "[]" {
		t.Fatalf("a status was listed before the office gave one: %s", raw)
	}
	receipt, err := recordingbundle.SignReceipt(recordingbundle.ReceiptFor(v, recordingbundle.StatusReceived, w.now+1), w.officeKey)
	if err != nil {
		t.Fatal(err)
	}
	w.office.Put(w.folders.Control, "recordings/"+m.BundleID+".received.envelope.json", []byte(receipt))
	var statuses []struct{ BundleID, Status, Envelope string }
	w.until("the office's receipt to be listed", func() bool {
		raw, err := w.client.ManagedRecordingStatuses()
		return err == nil && json.Unmarshal([]byte(raw), &statuses) == nil && len(statuses) == 1
	})
	text, _ := base64.StdEncoding.DecodeString(statuses[0].Envelope)
	got, err := recordingbundle.ReadReceipt(string(text), recordingbundle.Trust{OrganizationID: w.organizationID, EnrolmentID: w.enrolmentID, OfficeID: w.officeID,
		PhoneTransportID: w.client.DeviceID(), Key: w.officeKey.Public().(ed25519.PublicKey)}, recordingbundle.SentFor(v))
	if err != nil || got.Status != recordingbundle.StatusReceived {
		t.Fatalf("the receipt the phone holds does not verify: %+v %v", got, err)
	}

	// Acknowledged, the bundle leaves the folder and is no longer served; the app's own chunks
	// are untouched; and what the office says later is still heard.
	if err = w.client.WithdrawManagedRecording(m.BundleID, false); err != nil {
		t.Fatal(err)
	}
	w.refusedToOffice(w.folders.Records, prefix+"manifest.envelope.json")
	w.refusedToOffice(w.folders.Records, prefix+recordingbundle.MediaPath(first))
	if kept, _ := os.ReadFile(paths[first]); string(kept) != string(chunks[0]) {
		t.Fatal("withdrawing the bundle touched the app's own chunk")
	}
	later := recordingbundle.ReceiptFor(v, recordingbundle.StatusPublished, w.now+2)
	later.VaultID, later.VaultVersion = "fixture-organisation-vault", "1.0.0"
	signedLater, err := recordingbundle.SignReceipt(later, w.officeKey)
	if err != nil {
		t.Fatal(err)
	}
	w.office.Put(w.folders.Control, "recordings/"+m.BundleID+".published.envelope.json", []byte(signedLater))
	w.until("the later status to be listed", func() bool {
		raw, err := w.client.ManagedRecordingStatuses()
		return err == nil && json.Unmarshal([]byte(raw), &statuses) == nil && len(statuses) == 2
	})
}
