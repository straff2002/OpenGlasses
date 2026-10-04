package recordingbundle

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func must[T any](v T, e error) T {
	if e != nil {
		panic(e)
	}
	return v
}

func refused(t *testing.T, name string, e error, want error) {
	t.Helper()
	if e == nil || !errors.Is(e, want) {
		t.Fatalf("%s: got %v, want %v", name, e, want)
	}
}

var (
	office = fixtureKey("Avenkin public fixture office key v1")
	phone  = fixtureKey("Avenkin public fixture phone key v1")
)

func phoneTrust() Trust  { return FixtureTrust(phone.Public().(ed25519.PublicKey)) }
func officeTrust() Trust { return FixtureTrust(office.Public().(ed25519.PublicKey)) }

// The bundle's two JSON files are the timeline and transcript fixtures themselves.
const (
	timelineFixture   = "recorded-session-timeline-v1.json"
	transcriptFixture = "recorded-session-transcript-v1.json"
)

func fixtureFile(t *testing.T, name string) []byte {
	t.Helper()
	data, e := os.ReadFile(filepath.Join("..", "..", "..", "Contracts", "fixtures", name))
	if e != nil {
		t.Fatal(e)
	}
	return data
}

func fixtures(t *testing.T) map[string][]byte {
	t.Helper()
	return must(Fixtures(fixtureFile(t, timelineFixture), fixtureFile(t, transcriptFixture)))
}

func manifest(t *testing.T) Manifest {
	t.Helper()
	return FixtureManifest(fixtureFile(t, timelineFixture), fixtureFile(t, transcriptFixture))
}

// resign changes a signed message's payload as text and signs the result, so a case can carry
// something the signer itself would refuse.
func resign(t *testing.T, message, domain string, key ed25519.PrivateKey, maximum int, old, new string) string {
	t.Helper()
	var e envelope
	if json.Unmarshal([]byte(message), &e) != nil {
		t.Fatal("not an envelope")
	}
	payload := string(must(base64.StdEncoding.DecodeString(e.Payload)))
	if !strings.Contains(payload, old) {
		t.Fatalf("%q is not in the payload", old)
	}
	changed := []byte(strings.Replace(payload, old, new, 1))
	return must(seal(changed, ed25519.Sign(key, SigningInput(domain, changed)), maximum))
}

func TestTheGoldenFixturesAreCurrentAndReadBack(t *testing.T) {
	files := fixtures(t)
	for name, want := range files {
		path := filepath.Join("..", "..", "..", "Contracts", "fixtures", name)
		if os.Getenv("RECORDING_WRITE_FIXTURES") == "1" {
			if e := os.WriteFile(path, want, 0644); e != nil {
				t.Fatal(e)
			}
		}
		got, e := os.ReadFile(path)
		if e != nil || string(got) != string(want) {
			t.Fatalf("%s is not what Fixtures makes; regenerate with RECORDING_WRITE_FIXTURES=1 (%v)", name, e)
		}
	}
	v := must(ReadManifest(string(files["recording-bundle-manifest-v1.json"]), phoneTrust()))
	m := v.Manifest
	if len(m.Files) != 6 || len(m.Parts) != 2 || len(m.Parts[0].Chunks) != 3 || len(m.Parts[1].Chunks) != 1 || m.ChunkBytes != FixtureChunkBytes {
		t.Fatalf("%+v", m)
	}
	// The bundle is exactly its files, and each part is exactly its chunks in order.
	if m.CheckFile(TimelinePath, fixtureFile(t, timelineFixture)) != nil || m.CheckFile(TranscriptPath, fixtureFile(t, transcriptFixture)) != nil {
		t.Fatal("the timeline and transcript fixtures are not the bundle's")
	}
	for n, content := range []string{FixtureVideoPart, FixtureAudioPart} {
		var joined []byte
		for k, chunk := range Chunks([]byte(content), FixtureChunkBytes) {
			if e := m.CheckFile(MediaPath(m.Parts[n].Chunks[k]), chunk); e != nil {
				t.Fatalf("part %d chunk %d: %v", n, k, e)
			}
			joined = append(joined, chunk...)
		}
		if e := m.CheckPart(m.Parts[n].PartID, Digest(joined), int64(len(joined))); e != nil {
			t.Fatal(e)
		}
	}
	for status, at := range map[string]int64{StatusReceived: FixtureNow + 7200, StatusRefused: FixtureNow + 7200, StatusPublished: FixtureNow + 3*86400} {
		r := must(ReadReceipt(string(files["recording-receipt-"+status+"-v1.json"]), officeTrust(), SentFor(v)))
		if r.Status != status || r.At != at {
			t.Fatalf("%s: %+v", status, r)
		}
	}
}

func TestAManifestIsThePhonesForThisBindingInItsOneSpelling(t *testing.T) {
	message := string(fixtures(t)["recording-bundle-manifest-v1.json"])
	_, e := ReadManifest(message, officeTrust())
	refused(t, "signed by another key", e, ErrSignature)
	for name, change := range map[string]func(*Trust){
		"another organisation": func(x *Trust) { x.OrganizationID = "another-organisation" },
		"another enrolment":    func(x *Trust) { x.EnrolmentID = "another-enrolment" },
		"another office":       func(x *Trust) { x.OfficeID = "office-000000000000000000000000" },
		"another phone":        func(x *Trust) { x.PhoneTransportID = "DQB4YVC-VNAIUQE-UNBOI3L-YIZRPME-WG6DM7S-GSGGKBY-BGA7SBN-Q2OHOAZ" },
	} {
		changed := phoneTrust()
		change(&changed)
		_, e := ReadManifest(message, changed)
		refused(t, name, e, ErrAuthority)
	}
	// Sealed under an earlier generation of the same binding it is still that phone's; a
	// generation the office has not reached is not.
	later := phoneTrust()
	later.Generation = 4
	if _, e := ReadManifest(message, later); e != nil {
		t.Fatal(e)
	}
	_, e = ReadManifest(resign(t, message, Domain, phone, MaximumEnvelope, `"generation":1`, `"generation":2`), phoneTrust())
	refused(t, "a generation ahead of the binding", e, ErrAuthority)

	for name, text := range map[string]string{
		"an empty message":          ``,
		"an envelope with an extra": `{"payload":"e30=","signature":"AA==","extra":1}`,
		"an oversize message":       `{"payload":"` + strings.Repeat("A", MaximumEnvelope) + `","signature":"AA=="}`,
	} {
		_, e := ReadManifest(text, phoneTrust())
		refused(t, name, e, ErrMalformed)
	}
	// One spelling: whitespace, another order, a duplicate, an unknown member or a number
	// written another way is refused whoever signed it.
	for name, change := range map[string][2]string{
		"whitespace":            {`{"version":1,`, `{ "version":1,`},
		"an unknown member":     {`{"version":1,`, `{"version":1,"note":"x",`},
		"a duplicate member":    {`"blurred":false,`, `"blurred":false,"blurred":false,`},
		"a number as a decimal": {`"droppedFrames":0`, `"droppedFrames":0.0`},
		"a number as text":      {`"chunkBytes":32`, `"chunkBytes":"32"`},
		"a member out of order": {`"version":1,"kind":"avenkin.recording-bundle"`, `"kind":"avenkin.recording-bundle","version":1`},
		"a truth value as text": {`"blurred":false`, `"blurred":"false"`},
	} {
		_, e := ReadManifest(resign(t, message, Domain, phone, MaximumEnvelope, change[0], change[1]), phoneTrust())
		refused(t, name, e, ErrMalformed)
	}
}

func TestAManifestListsExactlyTheBundle(t *testing.T) {
	good := manifest(t)
	if _, e := good.Bytes(); e != nil {
		t.Fatal(e)
	}
	clone := func() Manifest {
		m := good
		m.Files = append([]File{}, good.Files...)
		m.Parts = append([]Part{}, good.Parts...)
		for n := range m.Parts {
			m.Parts[n].Chunks = append([]string{}, good.Parts[n].Chunks...)
		}
		return m
	}
	bad := map[string]func(*Manifest){
		"a version that is not 1":                func(m *Manifest) { m.Version = 2 },
		"another kind of message":                func(m *Manifest) { m.Kind = ReceiptKind },
		"an identifier that is not hex":          func(m *Manifest) { m.BundleID = strings.Repeat("G", 32) },
		"a session that is a path":               func(m *Manifest) { m.JobSessionID = "../session" },
		"a job number that needs an escape":      func(m *Manifest) { m.JobNumber = `JOB "1042"` },
		"a timeline version this is not":         func(m *Manifest) { m.TimelineVersion = 2 },
		"a transcript version this is not":       func(m *Manifest) { m.TranscriptVersion = 0 },
		"dropped frames with nothing blurred":    func(m *Manifest) { m.DroppedFrames = 3 },
		"consent after it was made":              func(m *Manifest) { m.ConsentAt = m.CreatedAt + 1 },
		"no consent":                             func(m *Manifest) { m.ConsentAt = 0 },
		"no chunk size":                          func(m *Manifest) { m.ChunkBytes = 0 },
		"a chunk size over the limit":            func(m *Manifest) { m.ChunkBytes = MaximumChunkBytes + 1 },
		"no timeline":                            func(m *Manifest) { m.Files = m.Files[1:] },
		"no transcript":                          func(m *Manifest) { m.Files = append(m.Files[:1:1], m.Files[2:]...) },
		"a timeline somewhere else":              func(m *Manifest) { m.Files[0].Path = "media/timeline.json" },
		"a file twice":                           func(m *Manifest) { m.Files = append(m.Files, m.Files[2]) },
		"a role the contract does not name":      func(m *Manifest) { m.Files[2].Role = "thumbnail" },
		"a chunk under a name of its own":        func(m *Manifest) { m.Files[2].Path = "media/first.chunk" },
		"a chunk under a path":                   func(m *Manifest) { m.Files[2].Path = "../" + m.Files[2].Path },
		"a chunk larger than the chunk size":     func(m *Manifest) { m.Files[2].Bytes = FixtureChunkBytes + 1 },
		"an empty file":                          func(m *Manifest) { m.Files[1].Bytes = 0 },
		"a short chunk that is not the last":     func(m *Manifest) { m.Files[2].Bytes = FixtureChunkBytes - 1; m.Parts[0].Bytes-- },
		"a part of a chunk that is not listed":   func(m *Manifest) { m.Parts[0].Chunks[1] = strings.Repeat("0", 64) },
		"a chunk in no part":                     func(m *Manifest) { m.Parts = m.Parts[:1] },
		"a part whose size is not its chunks'":   func(m *Manifest) { m.Parts[0].Bytes++ },
		"a part with no chunks":                  func(m *Manifest) { m.Parts[1].Chunks = nil },
		"two parts under one name":               func(m *Manifest) { m.Parts[1].PartID = m.Parts[0].PartID },
		"a track the contract does not name":     func(m *Manifest) { m.Parts[0].Track = "depth" },
		"a container the contract does not name": func(m *Manifest) { m.Parts[0].Container = "mkv" },
		"a part digest that is not hex":          func(m *Manifest) { m.Parts[0].SHA256 = "abc" },
	}
	for name, change := range bad {
		m := clone()
		change(&m)
		if _, e := SignManifest(m, phone); !errors.Is(e, ErrFields) {
			t.Fatalf("%s: signed (%v)", name, e)
		}
	}
	// A bundle with no media is a bundle: a job recorded and nothing kept is still said.
	bare := clone()
	bare.Files, bare.Parts = bare.Files[:2], nil
	v := must(ReadManifest(must(SignManifest(bare, phone)), phoneTrust()))
	if len(v.Manifest.Parts) != 0 || !strings.Contains(string(must(bare.Bytes())), `"parts":[]`) {
		t.Fatal("a bundle with no parts has another spelling")
	}
	// Blurred, with frames dropped and no job number.
	blurred := clone()
	blurred.Blurred, blurred.DroppedFrames, blurred.JobNumber = true, 12, ""
	if _, e := ReadManifest(must(SignManifest(blurred, phone)), phoneTrust()); e != nil {
		t.Fatal(e)
	}

	// Two steps, as a phone whose key is outside the transport signs.
	payload := must(good.Bytes())
	sealed := must(SealManifest(payload, ed25519.Sign(phone, SigningInput(Domain, payload))))
	if sealed != must(SignManifest(good, phone)) {
		t.Fatal("the two ways of signing differ")
	}
	if _, e := SealManifest(append(payload, ' '), make([]byte, ed25519.SignatureSize)); !errors.Is(e, ErrMalformed) {
		t.Fatal("sealed bytes that are not the one spelling")
	}

	// What arrived is checked against what was listed.
	refused(t, "other bytes of the same length", good.CheckFile(TimelinePath, []byte(strings.Repeat("x", int(good.Files[0].Bytes)))), ErrContent)
	refused(t, "a path the manifest does not list", good.CheckFile("media/extra.chunk", []byte("x")), ErrContent)
	refused(t, "a part of another size", good.CheckPart("video-1", good.Parts[0].SHA256, good.Parts[0].Bytes-1), ErrContent)
	refused(t, "a part of another digest", good.CheckPart("video-1", good.Parts[1].SHA256, good.Parts[0].Bytes), ErrContent)
	refused(t, "a part the manifest does not list", good.CheckPart("video-9", good.Parts[0].SHA256, good.Parts[0].Bytes), ErrContent)
}

func TestAReceiptIsTheOfficesAndForExactlyTheBundleSealed(t *testing.T) {
	files := fixtures(t)
	v := must(ReadManifest(string(files["recording-bundle-manifest-v1.json"]), phoneTrust()))
	sent := SentFor(v)
	received := string(files["recording-receipt-received-v1.json"])

	_, e := ReadReceipt(received, phoneTrust(), sent)
	refused(t, "signed by another key", e, ErrSignature)
	// A manifest is not a receipt, whoever signed it.
	_, e = ReadReceipt(string(files["recording-bundle-manifest-v1.json"]), phoneTrust(), sent)
	refused(t, "a manifest offered as a receipt", e, ErrSignature)

	for name, change := range map[string]func(*Trust){
		"another organisation": func(x *Trust) { x.OrganizationID = "another-organisation" },
		"another enrolment":    func(x *Trust) { x.EnrolmentID = "another-enrolment" },
		"another office":       func(x *Trust) { x.OfficeID = "another-office" },
		"another phone":        func(x *Trust) { x.PhoneTransportID = "DQB4YVC-VNAIUQE-UNBOI3L-YIZRPME-WG6DM7S-GSGGKBY-BGA7SBN-Q2OHOAZ" },
	} {
		changed := officeTrust()
		change(&changed)
		_, e := ReadReceipt(received, changed, sent)
		refused(t, name, e, ErrAuthority)
	}
	// The binding has moved on since the bundle was sealed: the receipt is still the bundle's.
	renewed := officeTrust()
	renewed.Generation = 3
	if _, e := ReadReceipt(received, renewed, sent); e != nil {
		t.Fatal(e)
	}
	for name, change := range map[string]func(*Sent){
		"another bundle":     func(s *Sent) { s.BundleID = strings.Repeat("0", 32) },
		"another manifest":   func(s *Sent) { s.ManifestSHA256 = strings.Repeat("0", 64) },
		"another generation": func(s *Sent) { s.Generation = 2 },
	} {
		changed := sent
		change(&changed)
		_, e := ReadReceipt(received, officeTrust(), changed)
		refused(t, name, e, ErrOther)
	}

	sign := func(change func(*Receipt)) error {
		r := ReceiptFor(v, StatusReceived, FixtureNow+7200)
		change(&r)
		_, e := SignReceipt(r, office)
		return e
	}
	for name, change := range map[string]func(*Receipt){
		"a status the contract does not name":   func(r *Receipt) { r.Status = "seen" },
		"received with a reason":                func(r *Receipt) { r.Reason = "digest" },
		"received with a vault":                 func(r *Receipt) { r.VaultID, r.VaultVersion = "vault", "1.0.0" },
		"refused with no reason":                func(r *Receipt) { r.Status = StatusRefused },
		"refused for a reason of its own":       func(r *Receipt) { r.Status, r.Reason = StatusRefused, "busy" },
		"published with no vault":               func(r *Receipt) { r.Status = StatusPublished },
		"published with a vault that is a path": func(r *Receipt) { r.Status, r.VaultID, r.VaultVersion = StatusPublished, "../vault", "1.0.0" },
		"no time":                               func(r *Receipt) { r.At = 0 },
		"a manifest digest that is not hex":     func(r *Receipt) { r.ManifestSHA256 = "abc" },
	} {
		refused(t, name, sign(change), ErrFields)
	}
	for _, status := range []string{StatusReviewed, StatusRejected} {
		if e := sign(func(r *Receipt) { r.Status = status }); e != nil {
			t.Fatalf("%s: %v", status, e)
		}
	}
	// Signed by the office all the same, out of form or with a member the contract does not list.
	_, e = ReadReceipt(resign(t, received, ReceiptDomain, office, MaximumReceipt, `"status":"received"`, `"status":"seen"`), officeTrust(), sent)
	refused(t, "a signed status out of form", e, ErrFields)
	_, e = ReadReceipt(resign(t, received, ReceiptDomain, office, MaximumReceipt, `"version":1`, `"version":1,"trim":1`), officeTrust(), sent)
	refused(t, "an unlisted member", e, ErrMalformed)
	_, e = ReadReceipt(resign(t, received, ReceiptDomain, office, MaximumReceipt, `,"reason":""`, ``), officeTrust(), sent)
	refused(t, "a member left out", e, ErrMalformed)
}

func TestTheKeyHolderSignsOnlyAReceiptItWouldAccept(t *testing.T) {
	files := fixtures(t)
	v := must(ReadManifest(string(files["recording-bundle-manifest-v1.json"]), phoneTrust()))
	r := ReceiptFor(v, StatusReceived, FixtureNow+7200)
	payload := must(json.Marshal(r))
	message := must(SignReceiptPayload(payload, office, r.OfficeID, FixtureNow+7200))
	if message != string(files["recording-receipt-received-v1.json"]) {
		t.Fatal("the key holder's receipt is not the golden receipt")
	}
	_, e := SignReceiptPayload(payload, office, "office-000000000000000000000000", FixtureNow+7200)
	refused(t, "another office's identity", e, ErrAuthority)
	_, e = SignReceiptPayload(payload, office, r.OfficeID, r.At-MaximumIssueSkew-1)
	refused(t, "dated in the future", e, ErrTime)
	_, e = SignReceiptPayload(payload, office[:10], r.OfficeID, FixtureNow+7200)
	refused(t, "no key", e, ErrSignature)
	_, e = SignReceiptPayload([]byte(`{"version":1}`), office, r.OfficeID, FixtureNow+7200)
	refused(t, "not the closed payload", e, ErrMalformed)
	r.Status = "seen"
	_, e = SignReceiptPayload(must(json.Marshal(r)), office, r.OfficeID, FixtureNow+7200)
	refused(t, "out of form", e, ErrFields)
}

func TestChunksAreFullButTheLast(t *testing.T) {
	chunks := Chunks([]byte(FixtureVideoPart), FixtureChunkBytes)
	if len(chunks) != 3 || len(chunks[0]) != 32 || len(chunks[1]) != 32 || len(chunks[2]) != 18 {
		t.Fatalf("%d chunks", len(chunks))
	}
	if exact := Chunks([]byte(strings.Repeat("a", 64)), 32); len(exact) != 2 || len(exact[1]) != 32 {
		t.Fatal("a part that is a whole number of chunks has no empty last chunk")
	}
	if len(Chunks(nil, 32)) != 0 {
		t.Fatal("nothing has no chunks")
	}
}
