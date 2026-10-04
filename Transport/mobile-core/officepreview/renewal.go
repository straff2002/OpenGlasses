package officepreview

// Renewal and removal, for the holder of the administrator key (Contracts/office-check-in.md).
// The messages are package checkin's; what is here is what needs the key and the generation
// record: issuing the next generation of the latest binding, and never issuing one again for a
// removed enrolment.
import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
)

// Administrator is the administrator key on this computer, proven to be the one a
// vendor-signed profile names. Sign signs exact bytes; the key itself is not handed out.
type Administrator struct {
	PublicKey      ed25519.PublicKey
	OrganizationID string
	ProfileID      string
	Sign           func(message []byte) []byte
}

// Authority is an office's administrator key and generation record, under a set of vendor
// profile keys.
type Authority struct {
	office *Office
	keys   map[string]string
}

// Authority is the office's authority under the production vendor keys.
func (o *Office) Authority() Authority { return Authority{o, productionProfileKeys} }

// AuthorityWithVendorKeys is Authority under other vendor keys: for tests and fixtures, which
// have no profile a production vendor key signed. The connection helper never calls it.
func (o *Office) AuthorityWithVendorKeys(keys map[string]string) Authority { return Authority{o, keys} }

// IssuePeerBinding is the office's IssuePeerBinding under this authority's vendor keys.
func (a Authority) IssuePeerBinding(profileDocument, enrolmentID, officeTransportID, phoneTransportID, phoneApplicationKey string, now int64) (string, error) {
	return a.office.issuePeerBinding(profileDocument, enrolmentID, officeTransportID, phoneTransportID, phoneApplicationKey, now, a.keys)
}

// Administrator verifies the profile and that this computer's administrator key is the one it
// names.
func (a Authority) Administrator(profileDocument string, now int64) (Administrator, error) {
	profile, e := verifyOfficeProfile(profileDocument, a.keys, now)
	if e != nil {
		return Administrator{}, e
	}
	admin, e := administratorKey(a.office.Root, false)
	if e != nil {
		return Administrator{}, e
	}
	if public(admin) != profile.Authority.AdministratorPublicKey {
		return Administrator{}, errors.New("this computer's administrator key is not authorised by that profile")
	}
	return Administrator{admin.Public().(ed25519.PublicKey), profile.Authority.OrganizationID, profile.ProfileID,
		func(message []byte) []byte { return ed25519.Sign(admin, message) }}, nil
}

var peerBindingFields = []string{"version", "kind", "organizationID", "profileID", "enrolmentID", "officeID", "generation", "officeTransportID", "officeApplicationKey", "phoneTransportID", "phoneApplicationKey", "issuedAt", "expiresAt"}

// RenewPeerBinding issues the next generation of a binding this office issued: the same
// identities, a new validity window. held must be the latest binding issued for its enrolment,
// signed by this administrator key, naming this office, and still inside its window; a removed
// enrolment is refused. It does not decide whether a renewal is due — the caller has verified
// the phone's check-in (checkin.Renew).
//
// Asking again with the same held binding returns the binding already issued from it, so a
// caller that lost the reply does not burn a second generation.
func (a Authority) RenewPeerBinding(profileDocument, held string, now int64) (string, error) {
	profile, e := verifyOfficeProfile(profileDocument, a.keys, now)
	if e != nil {
		return "", e
	}
	admin, e := administratorKey(a.office.Root, false)
	if e != nil {
		return "", e
	}
	if public(admin) != profile.Authority.AdministratorPublicKey {
		return "", errors.New("this computer's administrator key is not authorised by that profile")
	}
	payload, signature, e := Raw(held)
	if e != nil || len(held) > maximumPeerBinding || !Flat(payload, peerBindingFields) ||
		!ed25519.Verify(admin.Public().(ed25519.PublicKey), append([]byte(peerBindingDomain), payload...), signature) {
		return "", errors.New("that binding was not issued by this computer's administrator key")
	}
	var p PeerBinding
	if json.Unmarshal(payload, &p) != nil || p.Version != 1 || p.Kind != "avenkin.office-peer-binding" ||
		p.OrganizationID != profile.Authority.OrganizationID || p.ProfileID != profile.ProfileID ||
		p.OfficeID != a.office.ManagedOfficeID() || p.OfficeApplicationKey != public(a.office.Key) ||
		!safeIdentifier(p.EnrolmentID) || !validID(p.OfficeTransportID) || !validID(p.PhoneTransportID) ||
		!canonicalPublic(p.PhoneApplicationKey) || now <= 0 || now > maximumSafeInteger-30*86400 {
		return "", errors.New("that binding is not this office's under that profile")
	}
	if now < p.IssuedAt || now >= p.ExpiresAt {
		return "", errors.New("that binding is outside its validity window; the device must be paired again")
	}
	ledgerPath := bindingLedgerPath(a.office.Root, p.OrganizationID, p.EnrolmentID)
	var ledger bindingLedger
	if e = load(ledgerPath, &ledger); e != nil {
		return "", errors.New("no binding has been issued for that enrolment")
	}
	if ledger.Version != 1 || ledger.Organization != p.OrganizationID || ledger.Enrolment != p.EnrolmentID ||
		ledger.Generation <= 0 || ledger.Generation >= maximumSafeInteger {
		return "", errors.New("pairing generation record is invalid")
	}
	if ledger.Removed {
		return "", errRemoved
	}
	heldDigest := Digest(payload)
	if ledger.Generation == p.Generation+1 && ledger.RenewedFrom == heldDigest && ledger.Binding != "" {
		return ledger.Binding, nil
	}
	if ledger.Generation != p.Generation {
		return "", errors.New("that binding is not the latest issued for that enrolment")
	}
	expires, e := bindingExpiry(profile, now)
	if e != nil {
		return "", e
	}
	ledger.Generation++
	p.Generation, p.IssuedAt, p.ExpiresAt = ledger.Generation, now, expires
	envelope, e := signPeerBinding(p, admin)
	if e != nil {
		return "", e
	}
	ledger.Binding, ledger.RenewedFrom = envelope, heldDigest
	if e = save(ledgerPath, ledger); e != nil {
		return "", e
	}
	return envelope, nil
}

// MarkRemoved records that an enrolment has been removed: no binding is issued or renewed for
// it again. Only an enrolment this office has issued a binding for can be removed. Marking it
// again changes nothing.
func (a Authority) MarkRemoved(organizationID, enrolmentID string) error {
	if !safeIdentifier(organizationID) || !safeIdentifier(enrolmentID) {
		return errors.New("invalid organisation or enrolment")
	}
	ledgerPath := bindingLedgerPath(a.office.Root, organizationID, enrolmentID)
	var ledger bindingLedger
	if e := load(ledgerPath, &ledger); e != nil {
		if os.IsNotExist(e) {
			return errors.New("no binding has been issued for that enrolment")
		}
		return e
	}
	if ledger.Version != 1 || ledger.Organization != organizationID || ledger.Enrolment != enrolmentID || ledger.Generation <= 0 {
		return errors.New("pairing generation record is invalid")
	}
	if ledger.Removed {
		return nil
	}
	ledger.Removed = true
	return save(ledgerPath, ledger)
}

var errRemoved = errors.New("that device has been removed; no binding is issued for its enrolment again")

func signPeerBinding(p PeerBinding, admin ed25519.PrivateKey) (string, error) {
	bytes, e := json.Marshal(p)
	if e != nil {
		return "", e
	}
	signature := ed25519.Sign(admin, append([]byte(peerBindingDomain), bytes...))
	envelope, e := json.Marshal(Envelope{base64.StdEncoding.EncodeToString(bytes), base64.StdEncoding.EncodeToString(signature)})
	if e != nil || len(envelope) > maximumPeerBinding {
		return "", errors.New("signed binding exceeds size limit")
	}
	return string(envelope), nil
}
