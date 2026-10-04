package jobfile

import (
	"crypto/ed25519"
	"crypto/sha256"
)

// FixtureKeyLabel derives the fictional organisation key the golden file is signed with:
// seed = SHA-256(label). It is public and has no authority.
const FixtureKeyLabel = "Avenkin public fixture organisation job key v1"

// FixtureJob is the golden job's exact bytes.
const FixtureJob = `{"job_id":"job-2031","revision":2,"job_reference":"FX-1007","site":{"customer":"Fixture Service","address":"14 Fixture Street"},"fault_report":"No heat. Display shows E200.","equipment":[{"model":"FX-90","serial":"0001"}],"scheduled_for":"2027-01-15T09:00:00Z","issued_by":"Fixture Service Ltd"}`

// FixtureAttachment is the exact bytes of the attachment FixtureJobWithNeeds names: a public
// sentence, not in the repository as a file.
const FixtureAttachment = "Avenkin public fixture job attachment v1"

// FixtureJobWithNeeds names an attachment by digest and a manual set, both of which follow the
// job in the bulk folder, and one attachment by name only.
const FixtureJobWithNeeds = `{"job_id":"job-2032","revision":1,"job_reference":"FX-1008","site":{"customer":"Fixture Service"},"fault_report":"Annual service.","attachments":[{"name":"Site plan","sha256":"7d0ec53b69a2325cf8a5c6e9033c6b5d47de24cc0c9a1ac63e4c4432f985e1e1","bytes":40,"media_type":"application/pdf"},{"name":"Previous invoice","reference":"INV-2231"}],"manuals":[{"set_id":"fixture-manuals"}]}`

func FixtureKey() ed25519.PrivateKey {
	seed := sha256.Sum256([]byte(FixtureKeyLabel))
	return ed25519.NewKeyFromSeed(seed[:])
}

// Fixtures returns the public golden fixture of job-file format 2, by file name.
func Fixtures() (map[string][]byte, error) {
	signed, e := Sign([]byte(FixtureJob), FixtureKey())
	if e != nil {
		return nil, e
	}
	needs, e := Sign([]byte(FixtureJobWithNeeds), FixtureKey())
	if e != nil {
		return nil, e
	}
	return map[string][]byte{"job-file-v2.ogjob": signed, "job-file-v2-needs.ogjob": needs}, nil
}
