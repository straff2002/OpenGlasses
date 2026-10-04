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
	return map[string][]byte{"job-file-v2.ogjob": signed}, nil
}
