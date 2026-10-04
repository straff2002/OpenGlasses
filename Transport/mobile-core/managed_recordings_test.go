package mobilecore

import (
	"crypto/ed25519"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"avenkin.dev/mobilecore/recordingbundle"
)

// recordingFixture is an inbox opened under the fixture binding, with the fixture bundle: its
// manifest, its two JSON files and its media chunks as files in the app's own storage.
type recordingFixture struct {
	*checkInFixture
	files      map[string][]byte
	manifest   recordingbundle.Manifest
	payload    []byte
	timeline   []byte
	transcript []byte
	chunks     map[string]string // digest → path in the app's storage
	sent       recordingbundle.Sent
}

func newRecordingFixture(t *testing.T) *recordingFixture {
	t.Helper()
	read := func(name string) []byte {
		data, err := os.ReadFile(filepath.Join("..", "..", "Contracts", "fixtures", name))
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	f := &recordingFixture{checkInFixture: newCheckInFixture(t), timeline: read("recorded-session-timeline-v1.json"),
		transcript: read("recorded-session-transcript-v1.json"), chunks: map[string]string{}}
	files, err := recordingbundle.Fixtures(f.timeline, f.transcript)
	if err != nil {
		t.Fatal(err)
	}
	f.files = files
	f.manifest = recordingbundle.FixtureManifest(f.timeline, f.transcript)
	if f.payload, err = f.manifest.Bytes(); err != nil {
		t.Fatal(err)
	}
	f.sent = recordingbundle.Sent{BundleID: f.manifest.BundleID, ManifestSHA256: recordingbundle.Digest(f.payload), Generation: 1}
	app := t.TempDir()
	for _, part := range []string{recordingbundle.FixtureVideoPart, recordingbundle.FixtureAudioPart} {
		for _, chunk := range recordingbundle.Chunks([]byte(part), recordingbundle.FixtureChunkBytes) {
			digest := recordingbundle.Digest(chunk)
			f.chunks[digest] = filepath.Join(app, digest)
			if err = os.WriteFile(f.chunks[digest], chunk, 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	return f
}

func (f *recordingFixture) sign(key ed25519.PrivateKey) []byte {
	return ed25519.Sign(key, recordingbundle.SigningInput(recordingbundle.Domain, f.payload))
}

func (f *recordingFixture) publish() []byte {
	f.t.Helper()
	envelope, err := f.inbox.publishRecording(f.payload, f.sign(f.phone), f.timeline, f.transcript)
	if err != nil {
		f.t.Fatal(err)
	}
	return envelope
}

func (f *recordingFixture) progress(needed func(string) bool) recordingProgress {
	f.t.Helper()
	p, err := f.inbox.recordingProgress(f.manifest.BundleID, needed)
	if err != nil {
		f.t.Fatal(err)
	}
	return p
}

func TestABundleIsPublishedOnlyAsExactlyWhatItsManifestLists(t *testing.T) {
	f := newRecordingFixture(t)
	id := f.manifest.BundleID
	if _, err := f.inbox.publishRecording(f.payload, f.sign(f.office), f.timeline, f.transcript); err == nil {
		t.Fatal("a signature that is not this phone's was accepted")
	}
	if _, err := f.inbox.publishRecording(f.payload, f.sign(f.phone), []byte(`{}`), f.transcript); err == nil {
		t.Fatal("another timeline was published")
	}
	if _, err := f.inbox.publishRecording(append(f.payload, ' '), f.sign(f.phone), f.timeline, f.transcript); err == nil {
		t.Fatal("bytes that are not the one spelling were published")
	}
	if f.inbox.outbound(recordingName(id, recordingManifestName)) {
		t.Fatal("a refused bundle is in the outbound list")
	}
	if err := f.inbox.publishRecordingChunk(id, f.manifest.Parts[0].Chunks[0], f.chunks[f.manifest.Parts[0].Chunks[0]]); err == nil {
		t.Fatal("a chunk was published before its manifest")
	}

	envelope := f.publish()
	// With the fixture's key it is the golden manifest, and the same manifest again is the same file.
	if string(envelope) != string(f.files["recording-bundle-manifest-v1.json"]) {
		t.Fatal("the envelope is not the golden manifest")
	}
	if again := f.publish(); string(again) != string(envelope) || len(f.inbox.state.Recordings) != 1 {
		t.Fatal("the same manifest twice is not one bundle")
	}
	for _, name := range []string{recordingManifestName, recordingbundle.TimelinePath, recordingbundle.TranscriptPath} {
		data, err := os.ReadFile(filepath.Join(f.inbox.records, "recordings", id, name))
		if err != nil || !f.inbox.outbound(recordingName(id, name)) {
			t.Fatalf("%s is not published and served: %v", name, err)
		}
		if name == recordingbundle.TimelinePath && string(data) != string(f.timeline) {
			t.Fatal("the timeline in records is not the one listed")
		}
	}
	// Another manifest under the same bundle is refused.
	other := f.manifest
	other.JobNumber = "JOB-1043"
	otherPayload, _ := other.Bytes()
	if _, err := f.inbox.publishRecording(otherPayload, ed25519.Sign(f.phone, recordingbundle.SigningInput(recordingbundle.Domain, otherPayload)), f.timeline, f.transcript); err == nil {
		t.Fatal("a second manifest replaced the first")
	}

	// Chunks: only one the manifest lists, only as its exact bytes, and served only once published.
	first := f.manifest.Parts[0].Chunks[0]
	if f.inbox.outbound(recordingName(id, recordingbundle.MediaPath(first))) {
		t.Fatal("a chunk is served before it is published")
	}
	if err := f.inbox.publishRecordingChunk(id, strings.Repeat("0", 64), f.chunks[first]); err == nil {
		t.Fatal("a chunk the manifest does not list was published")
	}
	if err := f.inbox.publishRecordingChunk(id, first, f.chunks[f.manifest.Parts[0].Chunks[1]]); err == nil {
		t.Fatal("other bytes of the same length were published as a chunk")
	}
	if err := f.inbox.publishRecordingChunk(id, first, f.chunks[f.manifest.Parts[0].Chunks[2]]); err == nil {
		t.Fatal("bytes of another length were published as a chunk")
	}
	if err := f.inbox.publishRecordingChunk(strings.Repeat("0", 32), first, f.chunks[first]); err == nil {
		t.Fatal("a chunk was published for a bundle that is not there")
	}
	for digest, path := range f.chunks {
		if err := f.inbox.publishRecordingChunk(id, digest, path); err != nil {
			t.Fatal(err)
		}
		if err := f.inbox.publishRecordingChunk(id, digest, path); err != nil {
			t.Fatalf("publishing a chunk twice: %v", err)
		}
		published, err := os.ReadFile(filepath.Join(f.inbox.records, "recordings", id, filepath.FromSlash(recordingbundle.MediaPath(digest))))
		if err != nil || f.manifest.CheckFile(recordingbundle.MediaPath(digest), published) != nil {
			t.Fatalf("the published chunk is not the one listed: %v", err)
		}
		if !f.inbox.outbound(recordingName(id, recordingbundle.MediaPath(digest))) {
			t.Fatal("a published chunk is not served")
		}
	}
	for _, refused := range []string{"recordings/" + id, "recordings/" + id + "/", "recordings/" + id + "/media/" + strings.Repeat("0", 64) + ".chunk",
		"recordings/" + id + "/../inbox.json", "recordings/" + strings.Repeat("0", 32) + "/" + recordingManifestName, "recordings/" + id + "/extra.json"} {
		if f.inbox.outbound(refused) {
			t.Fatalf("%s would be served", refused)
		}
	}
	// Reopened, the bundle is still the one published.
	reopened := f.open(1, f.bindingSHA256)
	if !reopened.outbound(recordingName(id, recordingbundle.MediaPath(first))) || len(reopened.state.Recordings) != 1 {
		t.Fatal("a relaunch forgot the bundle")
	}
}

func TestProgressCountsWhatTheOfficeNoLongerNeedsAndIsNeverAcknowledgement(t *testing.T) {
	f := newRecordingFixture(t)
	id := f.manifest.BundleID
	if _, err := f.inbox.recordingProgress(id, func(string) bool { return true }); err == nil {
		t.Fatal("progress was given for a bundle that is not published")
	}
	f.publish()
	var total int64
	for _, file := range f.manifest.Files {
		total += file.Bytes
	}
	documents := int64(len(f.timeline) + len(f.transcript))
	everything := func(string) bool { return true }
	nothing := func(string) bool { return false }

	p := f.progress(everything)
	if p.TotalBytes != total || p.PublishedBytes != documents || p.ServedBytes != 0 || p.AllServed {
		t.Fatalf("%+v", p)
	}
	// The office has everything published so far, and chunks are still to come.
	if p = f.progress(nothing); p.ServedBytes != documents || p.AllServed {
		t.Fatalf("%+v", p)
	}
	for digest, path := range f.chunks {
		if err := f.inbox.publishRecordingChunk(id, digest, path); err != nil {
			t.Fatal(err)
		}
	}
	last := recordingName(id, recordingbundle.MediaPath(f.manifest.Parts[1].Chunks[0]))
	p = f.progress(func(name string) bool { return name == last })
	if p.PublishedBytes != total || p.ServedBytes != total-int64(len(recordingbundle.FixtureAudioPart)) || p.AllServed {
		t.Fatalf("%+v", p)
	}
	// Everything but the manifest itself is not everything.
	if p = f.progress(func(name string) bool { return name == recordingName(id, recordingManifestName) }); p.AllServed {
		t.Fatal("served without the manifest")
	}
	if p = f.progress(nothing); !p.AllServed || p.ServedBytes != total {
		t.Fatalf("%+v", p)
	}
	// All served is not a receipt: nothing is listed until the office says so.
	if statuses, _ := f.inbox.recordingStatusList(); len(statuses) != 0 {
		t.Fatalf("%+v", statuses)
	}
}

func TestOnlyTheOfficesStatusForAPublishedBundleIsListed(t *testing.T) {
	f := newRecordingFixture(t)
	id := f.manifest.BundleID
	name := func(status string) string { return "recordings/" + id + "." + status + envelopeSuffix }
	// A receipt for a bundle this phone has not published is not listed.
	f.put(name("received"), f.files["recording-receipt-received-v1.json"])
	if statuses, _ := f.inbox.recordingStatusList(); len(statuses) != 0 {
		t.Fatalf("%+v", statuses)
	}
	f.publish()
	statuses, err := f.inbox.recordingStatusList()
	if err != nil || len(statuses) != 1 || statuses[0].Status != "received" || statuses[0].BundleID != id {
		t.Fatalf("%v %+v", err, statuses)
	}
	if raw, _ := base64.StdEncoding.DecodeString(statuses[0].Envelope); string(raw) != string(f.files["recording-receipt-received-v1.json"]) {
		t.Fatal("the envelope listed is not the file")
	}
	f.put(name("published"), f.files["recording-receipt-published-v1.json"])
	// A status under another status's name, one signed by another key, and one for another manifest.
	f.put(name("reviewed"), f.files["recording-receipt-refused-v1.json"])
	verified, err := recordingbundle.ReadManifest(string(f.files["recording-bundle-manifest-v1.json"]), f.inbox.recordingTrust(f.inbox.phoneKey))
	if err != nil {
		t.Fatal(err)
	}
	forged, err := recordingbundle.SignReceipt(recordingbundle.ReceiptFor(verified, recordingbundle.StatusRejected, recordingbundle.FixtureNow), f.phone)
	if err != nil {
		t.Fatal(err)
	}
	f.put(name("rejected"), []byte(forged))
	other := verified
	other.ManifestSHA256 = strings.Repeat("0", 64)
	refusal := recordingbundle.ReceiptFor(other, recordingbundle.StatusRefused, recordingbundle.FixtureNow)
	refusal.Reason = "policy"
	stale, err := recordingbundle.SignReceipt(refusal, f.office)
	if err != nil {
		t.Fatal(err)
	}
	f.put(name("refused"), []byte(stale))
	statuses, err = f.inbox.recordingStatusList()
	if err != nil || len(statuses) != 2 {
		t.Fatalf("%v %+v", err, statuses)
	}
	listed := map[string]bool{}
	for _, s := range statuses {
		listed[s.Status] = true
	}
	if !listed["received"] || !listed["published"] {
		t.Fatalf("%+v", statuses)
	}
	// Only the one that can never verify under its name is remembered.
	if len(f.inbox.state.Refused) != 1 {
		t.Fatalf("remembered %d refusals", len(f.inbox.state.Refused))
	}
	// The binding renewed since the bundle was sealed: the receipt is still the bundle's.
	renewed := f.open(2, f.bindingSHA256)
	if statuses, _ = renewed.recordingStatusList(); len(statuses) != 2 {
		t.Fatalf("after a renewal: %+v", statuses)
	}
}

func TestAWithdrawnBundleIsNoLongerServedAndItsFilesGo(t *testing.T) {
	f := newRecordingFixture(t)
	id := f.manifest.BundleID
	if err := f.inbox.withdrawRecording(id, true); err != nil {
		t.Fatal(err)
	}
	f.publish()
	for digest, path := range f.chunks {
		if err := f.inbox.publishRecordingChunk(id, digest, path); err != nil {
			t.Fatal(err)
		}
	}
	// Acknowledged: out of records and no longer served, and still listened for.
	f.put("recordings/"+id+".published"+envelopeSuffix, f.files["recording-receipt-published-v1.json"])
	if err := f.inbox.withdrawRecording(id, false); err != nil {
		t.Fatal(err)
	}
	first := f.manifest.Parts[0].Chunks[0]
	if f.inbox.outbound(recordingName(id, recordingManifestName)) || f.inbox.outbound(recordingName(id, recordingbundle.MediaPath(first))) {
		t.Fatal("a withdrawn bundle is still served")
	}
	if _, err := os.Stat(filepath.Join(f.inbox.records, "recordings", id)); !os.IsNotExist(err) {
		t.Fatal("a withdrawn bundle's files are still in records")
	}
	if statuses, _ := f.inbox.recordingStatusList(); len(statuses) != 1 || statuses[0].Status != "published" {
		t.Fatalf("a withdrawn bundle is not listened for: %+v", statuses)
	}
	if err := f.inbox.publishRecordingChunk(id, first, f.chunks[first]); err == nil {
		t.Fatal("a chunk was published for a withdrawn bundle")
	}
	if _, err := f.inbox.recordingProgress(id, func(string) bool { return false }); err == nil {
		t.Fatal("progress was given for a withdrawn bundle")
	}
	// The same manifest again puts it back, with only its two files published.
	f.publish()
	if !f.inbox.outbound(recordingName(id, recordingManifestName)) || f.inbox.outbound(recordingName(id, recordingbundle.MediaPath(first))) || len(f.inbox.state.Recordings) != 1 {
		t.Fatal("a bundle published again is not as it was first published")
	}
	// Forgotten: gone altogether.
	if err := f.inbox.withdrawRecording(id, true); err != nil {
		t.Fatal(err)
	}
	if statuses, _ := f.inbox.recordingStatusList(); len(statuses) != 0 || len(f.inbox.state.Recordings) != 0 {
		t.Fatal("a forgotten bundle is still listened for")
	}
	// The app's own chunks are untouched: withdrawing is not trimming.
	for digest, path := range f.chunks {
		data, err := os.ReadFile(path)
		if err != nil || recordingbundle.Digest(data) != digest {
			t.Fatalf("the app's own chunk was changed: %v", err)
		}
	}
	// Too many bundles at once are refused, not queued; withdrawn ones do not count.
	f.inbox.state.Recordings = make([]publishedRecording, maximumRecordingsPublished-1)
	f.inbox.state.Recordings = append(f.inbox.state.Recordings, publishedRecording{BundleID: strings.Repeat("9", 32), Withdrawn: true})
	if _, err := f.inbox.publishRecording(f.payload, f.sign(f.phone), f.timeline, f.transcript); err != nil {
		t.Fatalf("a withdrawn bundle counted against the limit: %v", err)
	}
	f.inbox.state.Recordings = make([]publishedRecording, maximumRecordingsPublished)
	if _, err := f.inbox.publishRecording(f.payload, f.sign(f.phone), f.timeline, f.transcript); err == nil {
		t.Fatal("a bundle was published past the limit")
	}
}
