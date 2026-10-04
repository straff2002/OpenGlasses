package officebulk

import (
	"archive/zip"
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"sort"

	"avenkin.dev/mobilecore/manualassignment"
	"github.com/syncthing/syncthing/lib/protocol"
)

// FixtureNow is the clock every bulk-content fixture is made at.
const FixtureNow = int64(1800000000)

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

// fixtureArchive is a small fictional vault signed by the organisation's own publishing key.
// Stored, not compressed, so its bytes do not depend on a compressor.
func fixtureArchive(publisherID, publisherName string, publisher ed25519.PrivateKey) ([]byte, error) {
	files := map[string][]byte{
		"manifest.json":        []byte(`{"id":"fixture-organisation-vault","name":"Fictional Organisation Manuals","version":"1.0.0","files":["faults.md"],"documents_dir":"documents","documents":[{"file":"manual.txt","title":"Fictional Site Manual","kind":"service_manual"}],"documents_included":true,"gating":{},"prompt_rules":["Never fabricate a value.","Cite the source file."],"source_attribution_format":"Source: {files}","source_attribution_required":true}`),
		"faults.md":            []byte("# Fictional site fault codes\n\nFX200: inspect the fictional site fixture.\n"),
		"documents/manual.txt": []byte("[Page 1]\nFICTIONAL TEST ONLY. FX200 means the synthetic site fixture is waiting.\n"),
	}
	paths := make([]string, 0, len(files))
	for p := range files {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	entries := make([]map[string]any, 0, len(paths))
	total := 0
	for _, p := range paths {
		entries = append(entries, map[string]any{"path": p, "sha256": Digest(files[p]), "bytes": len(files[p])})
		total += len(files[p])
	}
	header := map[string]any{"format_version": 1, "vault_id": "fixture-organisation-vault", "vault_name": "Fictional Organisation Manuals",
		"vault_version": "1.0.0", "publisher_id": publisherID, "publisher_name": publisherName, "files": entries, "total_bytes": total,
		"manual_text_included": true, "original_documents_included": false,
		"manuals": []map[string]any{{"title": "Fictional Site Manual", "has_original": false}}}
	canonical, err := json.Marshal(header)
	if err != nil {
		return nil, err
	}
	message := append([]byte{}, canonical...)
	for _, p := range paths {
		message = append(message, []byte("\nsha256("+p+")="+Digest(files[p]))...)
	}
	files["vault-archive.json"] = canonical
	files["vault-archive.sig"] = []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(publisher, message)))
	var buffer bytes.Buffer
	z := zip.NewWriter(&buffer)
	for _, p := range append([]string{"vault-archive.json", "vault-archive.sig"}, paths...) {
		entry, err := z.CreateHeader(&zip.FileHeader{Name: p, Method: zip.Store})
		if err != nil {
			return nil, err
		}
		if _, err = entry.Write(files[p]); err != nil {
			return nil, err
		}
	}
	if err = z.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

// Fixtures returns the public golden fixtures of the bulk-content contract, by file name: the
// grant for a fictional organisation's publishing key, a vault archive that key signed, the
// office's assignment of it to the fixture phone, and the phone's two receipts. Every key is
// derived from a public label and has no authority; the office, phone and administrator keys are
// the check-in fixtures' own.
func Fixtures() (map[string][]byte, error) {
	office := fixtureKey("Avenkin public fixture office key v1")
	phone := fixtureKey("Avenkin public fixture phone key v1")
	administrator := fixtureKey("Avenkin public fixture administrator key v1")
	publisher := fixtureKey("Avenkin public fixture organisation publisher key v1")
	officeID := OfficeID(office.Public().(ed25519.PublicKey))
	phoneTransport := protocol.NewDeviceID([]byte("fixture-phone-transport")).String()
	const organizationID, profileID, enrolmentID = "fixture-organisation", "fixture-profile", "fixture-enrolment"
	publisherID := PublisherPrefix + organizationID

	grant, err := SignGrant(Grant{1, GrantKind, Digest([]byte("Avenkin public fixture publisher grant v1"))[:32], organizationID, profileID,
		publisherID, "Fixture Organisation", base64.StdEncoding.EncodeToString(publisher.Public().(ed25519.PublicKey)),
		1, StatusActive, FixtureNow - 86400, FixtureNow + 90*86400}, administrator)
	if err != nil {
		return nil, err
	}
	archive, err := fixtureArchive(publisherID, "Fixture Organisation", publisher)
	if err != nil {
		return nil, err
	}
	assignment, err := manualassignment.Sign(manualassignment.Payload{Version: 1, Kind: "avenkin.manual-assignment",
		AssignmentID: Digest([]byte("Avenkin public fixture bulk assignment v1"))[:32], OrganizationID: organizationID, EnrolmentID: enrolmentID,
		OfficeID: officeID, Generation: 1, SetID: "fixture-manuals", Sequence: 1, IssuedAt: FixtureNow - 600, ExpiresAt: FixtureNow + 7*86400,
		VaultID: "fixture-organisation-vault", VaultVersion: "1.0.0", PublisherID: publisherID,
		ArchiveSHA256: Digest(archive), ArchiveBytes: int64(len(archive))}, office)
	if err != nil {
		return nil, err
	}
	verified, err := manualassignment.Verify(assignment, manualassignment.Trust{OrganizationID: organizationID, EnrolmentID: enrolmentID,
		OfficeID: officeID, SetID: "fixture-manuals", Generation: 1, MaximumArchiveBytes: 1 << 20,
		PublicKey: office.Public().(ed25519.PublicKey)}, FixtureNow, nil)
	if err != nil {
		return nil, err
	}
	out := map[string][]byte{
		"office-publisher-grant-v1.json": []byte(grant),
		"office-bulk-vault-v1.zip":       archive,
		"office-bulk-assignment-v1.json": assignment,
	}
	for outcome, at := range map[string]int64{OutcomeReceived: FixtureNow + 60, OutcomeInstalled: FixtureNow + 600} {
		p := verified.Payload
		receipt, err := SignReceipt(Receipt{1, ReceiptKind, p.AssignmentID, verified.PayloadSHA256, p.OrganizationID, p.EnrolmentID,
			p.OfficeID, p.Generation, phoneTransport, p.SetID, p.Sequence, p.ArchiveSHA256, outcome, at}, phone)
		if err != nil {
			return nil, err
		}
		out["office-bulk-assignment-receipt-"+outcome+"-v1.json"] = []byte(receipt)
	}
	return out, nil
}
