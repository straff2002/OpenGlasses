// Generate only public, fictional golden fixtures. Derived test keys have no authority.
package main

import (
	"archive/zip"
	"avenkin.dev/mobilecore/manageddelivery"
	"avenkin.dev/mobilecore/manualassignment"
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"

	"github.com/syncthing/syncthing/lib/protocol"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func digest(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }
func main() {
	root := "../../Contracts/fixtures"
	// Public labels derive reproducible fictional keys. No secret seed is checked in.
	officeSeed := sha256.Sum256([]byte("Avenkin public fixture office key v1"))
	publisherSeed := sha256.Sum256([]byte("Avenkin public fixture publisher key v1"))
	office := ed25519.NewKeyFromSeed(officeSeed[:])
	publisher := ed25519.NewKeyFromSeed(publisherSeed[:])
	files := map[string][]byte{
		"manifest.json":        []byte(`{"id":"fixture-vault","name":"Fictional Service Vault","version":"1.0.0","files":["faults.md"],"documents_dir":"documents","documents":[{"file":"manual.txt","title":"Fictional Service Manual","kind":"service_manual"}],"documents_included":true,"gating":{},"prompt_rules":["Never fabricate a value.","Cite the source file."],"source_attribution_format":"Source: {files}","source_attribution_required":true}`),
		"faults.md":            []byte("# Fictional fault codes\n\nFX100: inspect the fictional fixture.\n"),
		"documents/manual.txt": []byte("[Page 1]\nFICTIONAL TEST ONLY. FX100 means the synthetic fixture is waiting.\n"),
	}
	paths := make([]string, 0, len(files))
	for p := range files {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	entries := make([]map[string]any, 0, len(paths))
	total := 0
	for _, p := range paths {
		entries = append(entries, map[string]any{"path": p, "sha256": digest(files[p]), "bytes": len(files[p])})
		total += len(files[p])
	}
	header := map[string]any{"format_version": 1, "vault_id": "fixture-vault", "vault_name": "Fictional Service Vault", "vault_version": "1.0.0", "publisher_id": "fixture-publisher", "publisher_name": "Fictional Publisher", "files": entries, "total_bytes": total, "manual_text_included": true, "original_documents_included": false, "manuals": []map[string]any{{"title": "Fictional Service Manual", "has_original": false}}}
	canonical, err := json.Marshal(header)
	must(err)
	message := append([]byte{}, canonical...)
	for _, p := range paths {
		message = append(message, []byte("\nsha256("+p+")="+digest(files[p]))...)
	}
	signature := base64.StdEncoding.EncodeToString(ed25519.Sign(publisher, message))
	var buffer bytes.Buffer
	z := zip.NewWriter(&buffer)
	all := append([]string{"vault-archive.json", "vault-archive.sig"}, paths...)
	for _, p := range all {
		data := files[p]
		if p == "vault-archive.json" {
			data = canonical
		}
		if p == "vault-archive.sig" {
			data = []byte(signature)
		}
		entry, err := z.CreateHeader(&zip.FileHeader{Name: p, Method: zip.Store})
		must(err)
		_, err = entry.Write(data)
		must(err)
	}
	must(z.Close())
	archive := buffer.Bytes()
	p := manualassignment.Payload{Version: 1, Kind: "avenkin.manual-assignment", AssignmentID: "0123456789abcdef0123456789abcdef", OrganizationID: "fixture-org", EnrolmentID: "fixture-phone", OfficeID: "fixture-office", Generation: 1, SetID: "fixture-set", Sequence: 7, IssuedAt: 1799999000, ExpiresAt: 1800003600, VaultID: "fixture-vault", VaultVersion: "1.0.0", PublisherID: "fixture-publisher", ArchiveSHA256: digest(archive), ArchiveBytes: int64(len(archive))}
	envelope, err := manualassignment.Sign(p, office)
	must(err)
	must(os.MkdirAll(root, 0755))
	must(os.WriteFile(filepath.Join(root, "manual-assignment-v1.json"), append(envelope, '\n'), 0644))
	must(os.WriteFile(filepath.Join(root, "manual-vault-v1.zip"), archive, 0644))
	metadata, err := json.MarshalIndent(map[string]any{"fixtureOnly": true, "now": 1800000000, "officePublicKey": base64.StdEncoding.EncodeToString(office.Public().(ed25519.PublicKey)), "publisherPublicKey": base64.StdEncoding.EncodeToString(publisher.Public().(ed25519.PublicKey)), "archiveSHA256": digest(archive), "archiveBytes": len(archive)}, "", "  ")
	must(err)
	must(os.WriteFile(filepath.Join(root, "manual-fixture-keys.json"), append(metadata, '\n'), 0644))
	job := []byte("{\"format\":\"openglasses.job\",\"format_version\":1,\"job_reference\":\"FX-1007\",\"site\":{\"customer\":\"Fixture Service\"}}\n")
	officeTransportID := protocol.NewDeviceID([]byte("fixture-office-transport")).String()
	phoneTransportID := protocol.NewDeviceID([]byte("fixture-phone-transport")).String()
	managed := manageddelivery.Job{
		Version: 1, Kind: "avenkin.managed-job", MessageID: "fedcba9876543210fedcba9876543210",
		OrganizationID: "fixture-org", EnrolmentID: "fixture-phone", OfficeID: "fixture-office",
		Generation: 1, OfficeTransportID: officeTransportID, PhoneTransportID: phoneTransportID,
		Sequence: 7, IssuedAt: 1799999000, ExpiresAt: 1800003600,
		JobSHA256: manageddelivery.Digest(job), JobBytes: int64(len(job)),
	}
	managedEnvelope, err := manageddelivery.Sign(managed, office)
	must(err)
	must(os.WriteFile(filepath.Join(root, "managed-job-v1.json"), append(managedEnvelope, '\n'), 0644))
	must(os.WriteFile(filepath.Join(root, "managed-job-v1.ogjob"), job, 0644))
	// The phone's receipt for that job, signed by a fictional phone application key.
	phoneSeed := sha256.Sum256([]byte("Avenkin public fixture phone application key v1"))
	phone := ed25519.NewKeyFromSeed(phoneSeed[:])
	office_ := office.Public().(ed25519.PublicKey)
	verified, err := manageddelivery.Verify(managedEnvelope, manageddelivery.Trust{OrganizationID: "fixture-org", EnrolmentID: "fixture-phone", OfficeID: "fixture-office", OfficeTransportID: officeTransportID, PhoneTransportID: phoneTransportID, Generation: 1, OfficeApplicationKey: office_}, 1800000000, nil)
	must(err)
	receipt, err := manageddelivery.SignReceipt(manageddelivery.ReceiptFor(verified, 1800000100), phone)
	must(err)
	must(os.WriteFile(filepath.Join(root, "managed-job-receipt-v1.json"), append(receipt, '\n'), 0644))
	managedKeys, err := json.MarshalIndent(map[string]any{
		"fixtureOnly": true, "now": 1800000000,
		"officeApplicationKey": base64.StdEncoding.EncodeToString(office_),
		"officeTransportID":    officeTransportID, "phoneTransportID": phoneTransportID,
		"phoneApplicationKey": base64.StdEncoding.EncodeToString(phone.Public().(ed25519.PublicKey)),
	}, "", "  ")
	must(err)
	must(os.WriteFile(filepath.Join(root, "managed-job-fixture-keys.json"), append(managedKeys, '\n'), 0644))
}
