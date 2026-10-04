package checkin

import (
	"crypto/ed25519"

	"avenkin.dev/mobilecore/officepreview"
)

// Holder is the process that holds the administrator key and the record of what it has issued:
// officepreview's Authority. It is an interface so this package stays messages only.
type Holder interface {
	// Administrator verifies the vendor-signed profile and that the administrator key on this
	// computer is the one it names.
	Administrator(profileDocument string, now int64) (officepreview.Administrator, error)
	// RenewPeerBinding issues the next generation of the latest binding issued for an
	// enrolment, and refuses for a removed enrolment or a binding that is not the latest.
	RenewPeerBinding(profileDocument, heldBinding string, now int64) (string, error)
	// MarkRemoved records, durably, that no binding is issued for the enrolment again.
	MarkRemoved(organizationID, enrolmentID string) error
}

// Renew is the administrator key holder's renewal (contract §5, "Where the administrator key
// is"). It is given the exact challenge, check-in and current binding envelopes, verifies them
// itself, and only then has a renewed binding issued and signs the result that carries it. A
// caller cannot obtain a renewed binding by asking: only a phone's signed check-in for a live
// challenge of this office, under the latest binding, does it.
//
// The same request again, after the binding was issued and before the caller recorded it,
// returns the same renewed binding rather than a second generation.
func Renew(h Holder, officeKey ed25519.PrivateKey, profileDocument, challengeEnvelope, checkInEnvelope, bindingEnvelope string, now int64) (renewedBinding, result string, err error) {
	if len(officeKey) != ed25519.PrivateKeySize {
		return "", "", ErrSignature
	}
	administrator, err := h.Administrator(profileDocument, now)
	if err != nil {
		return "", "", err
	}
	exchange, err := Renewable(challengeEnvelope, checkInEnvelope, bindingEnvelope, officeKey.Public().(ed25519.PublicKey), administrator.PublicKey, now)
	if err != nil {
		return "", "", err
	}
	if exchange.Binding.OrganizationID != administrator.OrganizationID || exchange.Binding.ProfileID != administrator.ProfileID {
		return "", "", ErrOther
	}
	renewedBinding, err = h.RenewPeerBinding(profileDocument, bindingEnvelope, now)
	if err != nil {
		return "", "", err
	}
	// What was issued is checked as the phone will check it before it is put in a result.
	next, _, err := ReadBinding(renewedBinding, administrator.PublicKey)
	if err != nil {
		return "", "", err
	}
	if err = CheckRenewal(exchange.Binding, next, now); err != nil {
		return "", "", err
	}
	result, err = SignResultWith(ResultFor(exchange, checkInEnvelope, renewedBinding, now), administrator.Sign)
	if err != nil {
		return "", "", err
	}
	return renewedBinding, result, nil
}

// Remove is the administrator key holder's removal (contract §8). The caller sends the exact
// removal payload it built and recorded; it must be a closed, valid removal for this
// organisation, profile and office, issued no more than a few minutes ahead. The enrolment is
// marked removed before anything is signed, so a binding is never issued for it again even if
// the signed removal is lost. Asking again signs the same bytes again.
func Remove(h Holder, officeKey ed25519.PublicKey, profileDocument string, raw []byte, now int64) (string, error) {
	administrator, err := h.Administrator(profileDocument, now)
	if err != nil {
		return "", err
	}
	removal, err := ParseRemoval(raw)
	if err != nil {
		return "", err
	}
	if removal.OrganizationID != administrator.OrganizationID || removal.ProfileID != administrator.ProfileID ||
		len(officeKey) != ed25519.PublicKeySize || removal.OfficeID != OfficeID(officeKey) {
		return "", ErrOther
	}
	if removal.IssuedAt > now+MaximumIssueSkew {
		return "", ErrTime
	}
	if err = h.MarkRemoved(removal.OrganizationID, removal.EnrolmentID); err != nil {
		return "", err
	}
	return SealRemoval(raw, administrator.Sign(SigningInput(RemovalDomain, raw)))
}
