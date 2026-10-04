package jobupdate

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"

	"github.com/syncthing/syncthing/lib/protocol"
)

// FixtureNow is the clock every job-update fixture is made at.
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

// FixtureTrust is the binding the fixtures are signed under: the check-in fixtures' own.
func FixtureTrust() Trust {
	office := fixtureKey("Avenkin public fixture office key v1").Public().(ed25519.PublicKey)
	return Trust{OrganizationID: "fixture-organisation", EnrolmentID: "fixture-enrolment", OfficeID: OfficeID(office),
		OfficeTransportID: protocol.NewDeviceID([]byte("fixture-office-transport")).String(),
		PhoneTransportID:  protocol.NewDeviceID([]byte("fixture-phone-transport")).String(),
		Generation:        1, OfficeApplicationKey: office}
}

// FixtureUpdates are the three golden updates, on the golden format-2 job (`job-2031`), in
// sequence order: a part dispatched, the visit moved, and a note.
func FixtureUpdates() []Update {
	t := FixtureTrust()
	base := func(label string, sequence int64, kind string) Update {
		return Update{Version: 1, Kind: Kind, UpdateID: Digest([]byte(label))[:32], OrganizationID: t.OrganizationID,
			EnrolmentID: t.EnrolmentID, OfficeID: t.OfficeID, Generation: t.Generation, OfficeTransportID: t.OfficeTransportID,
			PhoneTransportID: t.PhoneTransportID, JobID: "job-2031", Sequence: sequence,
			IssuedAt: FixtureNow - 600 + sequence, ExpiresAt: FixtureNow + 7*86400, UpdateKind: kind}
	}
	parts := base("Avenkin public fixture job update parts v1", 1, KindParts)
	parts.Part, parts.Quantity, parts.PartState, parts.ExpectedOn = "Fan motor FX-90-M", 1, "dispatched", "2027-01-18"
	parts.Body = "Courier to the site, not the depot."
	schedule := base("Avenkin public fixture job update schedule v1", 2, KindSchedule)
	schedule.ScheduledFor, schedule.ScheduledUntil = FixtureNow+3*86400, FixtureNow+3*86400+7200
	note := base("Avenkin public fixture job update note v1", 3, KindNote)
	note.Body = "Gate code is now 4412.\nAsk for the duty manager."
	return []Update{parts, schedule, note}
}

// Fixtures returns the public golden fixtures of the job-update contract, by file name: three
// updates on one job and the phone's receipt for the first. The office and phone keys are the
// check-in fixtures' own, derived from public labels, and have no authority.
func Fixtures() (map[string][]byte, error) {
	office := fixtureKey("Avenkin public fixture office key v1")
	phone := fixtureKey("Avenkin public fixture phone key v1")
	out := map[string][]byte{}
	for _, u := range FixtureUpdates() {
		message, e := Sign(u, office)
		if e != nil {
			return nil, e
		}
		out["job-update-"+u.UpdateKind+"-v1.json"] = []byte(message)
		if u.UpdateKind != KindParts {
			continue
		}
		verified, e := Read(message, FixtureTrust(), FixtureNow)
		if e != nil {
			return nil, e
		}
		receipt, e := SignReceipt(ReceiptFor(verified, JobHeld, FixtureNow+60), phone)
		if e != nil {
			return nil, e
		}
		out["job-update-receipt-v1.json"] = []byte(receipt)
	}
	return out, nil
}
