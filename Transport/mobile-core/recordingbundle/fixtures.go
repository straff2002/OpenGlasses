package recordingbundle

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"

	"github.com/syncthing/syncthing/lib/protocol"
)

// FixtureNow is the clock every recording-bundle fixture is made at.
const FixtureNow = int64(1800000000)

// FixtureChunkBytes is the fixture's chunk size: small, so the media is a few public sentences.
const FixtureChunkBytes = 32

// The fixture bundle's media: each part's whole bytes are a public sentence, cut into chunks of
// FixtureChunkBytes. Only their digests and sizes travel in the manifest.
const (
	FixtureVideoPart = "Avenkin public fixture recording video part v1: eighty-two bytes of nothing at all"
	FixtureAudioPart = "Avenkin public fixture audio v1"
)

func fixtureKey(label string) ed25519.PrivateKey {
	seed := sha256.Sum256([]byte(label))
	return ed25519.NewKeyFromSeed(seed[:])
}

// OfficeID is the office identifier derived from an office application key, as in the peer
// binding.
func OfficeID(officeApplicationKey ed25519.PublicKey) string {
	sum := sha256.Sum256(officeApplicationKey)
	return "office-" + hex.EncodeToString(sum[:12])
}

// Chunks cuts a part's bytes into chunks of chunkBytes, the last one shorter or equal.
func Chunks(part []byte, chunkBytes int) [][]byte {
	var out [][]byte
	for len(part) > 0 {
		n := chunkBytes
		if len(part) < n {
			n = len(part)
		}
		out = append(out, part[:n])
		part = part[n:]
	}
	return out
}

// FixtureTrust is the binding the fixtures are under — the check-in fixtures' own — with the key
// a reader of that message needs: the phone application key for a manifest, the office
// application key for a receipt.
func FixtureTrust(key ed25519.PublicKey) Trust {
	office := fixtureKey("Avenkin public fixture office key v1").Public().(ed25519.PublicKey)
	return Trust{OrganizationID: "fixture-organisation", EnrolmentID: "fixture-enrolment", OfficeID: OfficeID(office),
		PhoneTransportID: protocol.NewDeviceID([]byte("fixture-phone-transport")).String(), Generation: 1, Key: key}
}

// FixtureManifest is the manifest of the fixture bundle: the timeline and transcript given, a
// video part of three chunks and an audio part of one.
func FixtureManifest(timeline, transcript []byte) Manifest {
	t := FixtureTrust(nil)
	m := Manifest{Version: 1, Kind: Kind, BundleID: Digest([]byte("Avenkin public fixture recording bundle v1"))[:32],
		OrganizationID: t.OrganizationID, EnrolmentID: t.EnrolmentID, OfficeID: t.OfficeID, Generation: t.Generation,
		PhoneTransportID: t.PhoneTransportID, JobSessionID: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", JobNumber: "JOB-1042",
		CreatedAt: FixtureNow, TimelineVersion: 1, TranscriptVersion: 1, ConsentAt: FixtureNow - 3600, ChunkBytes: FixtureChunkBytes,
		Files: []File{
			{TimelinePath, int64(len(timeline)), Digest(timeline), RoleTimeline},
			{TranscriptPath, int64(len(transcript)), Digest(transcript), RoleTranscript},
		}}
	for _, part := range []struct{ id, track, container, content string }{
		{"video-1", TrackVideo, "mp4", FixtureVideoPart},
		{"audio-1", TrackAudio, "m4a", FixtureAudioPart},
	} {
		p := Part{PartID: part.id, Track: part.track, Container: part.container, Bytes: int64(len(part.content)), SHA256: Digest([]byte(part.content))}
		for _, chunk := range Chunks([]byte(part.content), FixtureChunkBytes) {
			digest := Digest(chunk)
			p.Chunks = append(p.Chunks, digest)
			m.Files = append(m.Files, File{MediaPath(digest), int64(len(chunk)), digest, RoleMedia})
		}
		m.Parts = append(m.Parts, p)
	}
	return m
}

// Fixtures returns the public golden fixtures of the recording-bundle messages, by file name:
// the signed manifest of the fixture bundle and three things an office may say about it. The
// timeline and transcript are the bundle's own two JSON files, given by the caller so that
// they are the same bytes the timeline and transcript fixtures hold. The office and phone keys
// are the check-in fixtures' own, derived from public labels, and have no authority.
func Fixtures(timeline, transcript []byte) (map[string][]byte, error) {
	office := fixtureKey("Avenkin public fixture office key v1")
	phone := fixtureKey("Avenkin public fixture phone key v1")
	manifest, e := SignManifest(FixtureManifest(timeline, transcript), phone)
	if e != nil {
		return nil, e
	}
	verified, e := ReadManifest(manifest, FixtureTrust(phone.Public().(ed25519.PublicKey)))
	if e != nil {
		return nil, e
	}
	out := map[string][]byte{"recording-bundle-manifest-v1.json": []byte(manifest)}
	received := ReceiptFor(verified, StatusReceived, FixtureNow+7200)
	refused := ReceiptFor(verified, StatusRefused, FixtureNow+7200)
	refused.Reason = "digest"
	published := ReceiptFor(verified, StatusPublished, FixtureNow+3*86400)
	published.VaultID, published.VaultVersion = "fixture-organisation-vault", "1.0.0"
	for _, r := range []Receipt{received, refused, published} {
		message, e := SignReceipt(r, office)
		if e != nil {
			return nil, e
		}
		out["recording-receipt-"+r.Status+"-v1.json"] = []byte(message)
	}
	return out, nil
}
