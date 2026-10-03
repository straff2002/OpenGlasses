package mobilecore

// Office commissioning for the phone (Contracts/commissioning.md): read the scanned code, make
// the redemption with a key that never leaves device storage, and run the pinned bootstrap
// exchange. These are free functions: commissioning happens before any office binding exists,
// and the phone's transport identity is a parameter (Client.DeviceID). Every result is JSON.

import (
	"context"
	"encoding/base64"
	"errors"
	"time"

	"avenkin.dev/mobilecore/commission"
	"avenkin.dev/mobilecore/commission/bootstrap"
)

// commissionDial is nil on the phone, which dials the invitation's address directly. Tests
// reach a loopback office through it.
var commissionDial bootstrap.Dial

// CommissionReadQR reads scanned text as an invitation, checked as the phone must before it
// connects: well formed, signed by the office key it names, and live at `now` (Unix seconds).
// It returns {"invitationEnvelope","invitationSHA256","organizationID","officeID",
// "officeApplicationKey","officeTransportID","address","issuedAt","expiresAt"}. The caller
// refuses here if the phone is already enrolled to another organisation.
func CommissionReadQR(qrText string, now int64) (string, error) {
	envelope, e := commission.ParseQRText(qrText)
	if e != nil {
		return "", e
	}
	i, e := commission.ReadInvitation(envelope, now)
	if e != nil {
		return "", e
	}
	return stringJSON(map[string]any{"invitationEnvelope": envelope, "invitationSHA256": commission.Digest(envelope),
		"organizationID": i.OrganizationID, "officeID": i.OfficeID, "officeApplicationKey": i.OfficeApplicationKey,
		"officeTransportID": i.OfficeTransportID, "address": i.Address, "issuedAt": i.IssuedAt, "expiresAt": i.ExpiresAt})
}

// CommissionRedemptionSigningInput makes the phone's redemption of a live invitation, unsigned.
// It returns {"payload","signingInput"}, both standard base64: the redemption payload, and the
// exact bytes the phone application key must sign with Ed25519 (the redemption domain, one zero
// byte, the payload). Pass the payload and the signature to CommissionSealRedemption.
// `existingEnrolment` is empty or the organisation the phone is already enrolled to.
func CommissionRedemptionSigningInput(invitationEnvelope, enrolmentID, phoneTransportID, phoneApplicationKey,
	appVersion, appBuild, existingEnrolment string, now int64) (string, error) {
	i, e := commission.ReadInvitation(invitationEnvelope, now)
	if e != nil {
		return "", e
	}
	if phoneTransportID == i.OfficeTransportID || phoneApplicationKey == i.OfficeApplicationKey {
		return "", errors.New("the phone's identities are the office's")
	}
	payload, input, e := commission.RedemptionSigningInput(commission.Redemption{Version: 1, Kind: commission.RedemptionKind,
		InvitationSHA256: commission.Digest(invitationEnvelope), Invitation: i.Invitation, EnrolmentID: enrolmentID,
		PhoneTransportID: phoneTransportID, PhoneApplicationKey: phoneApplicationKey, AppVersion: appVersion,
		AppBuild: appBuild, ExistingEnrolment: existingEnrolment, CreatedAt: now})
	if e != nil {
		return "", e
	}
	return stringJSON(map[string]string{"payload": base64.StdEncoding.EncodeToString(payload),
		"signingInput": base64.StdEncoding.EncodeToString(input)})
}

// CommissionSealRedemption makes the redemption envelope from the payload of
// CommissionRedemptionSigningInput and the phone's 64-byte Ed25519 signature over its signing
// input (both standard base64), and checks it exactly as the office will. Keep the envelope
// exactly: every repeat of the exchange sends these bytes, and different bytes are refused as
// a second use of the invitation.
func CommissionSealRedemption(invitationEnvelope, payloadBase64, signatureBase64 string) (string, error) {
	payload, e := base64.StdEncoding.Strict().DecodeString(payloadBase64)
	if e != nil {
		return "", errors.New("invalid payload encoding")
	}
	signature, e := base64.StdEncoding.Strict().DecodeString(signatureBase64)
	if e != nil {
		return "", errors.New("invalid signature encoding")
	}
	return commission.SealRedemption(payload, signature, invitationEnvelope)
}

// CommissionComparison is the code both screens show until the office decides.
func CommissionComparison(invitationEnvelope, redemptionEnvelope string) (string, error) {
	if _, e := commission.ReadRedemption(redemptionEnvelope, invitationEnvelope); e != nil {
		return "", e
	}
	return commission.Comparison(commission.Digest(invitationEnvelope), commission.Digest(redemptionEnvelope))
}

// CommissionExchange sends the redemption once to the office the invitation names, over TLS
// pinned to the invitation's officeTransportID, and returns its answer:
//
//	{"status":"awaiting"}
//	{"status":"approved","enrolmentID","profileDocument","licenceCode","peerBinding","officeAddress","decisionEnvelope"}
//	{"status":"refused","reason"}
//
// A decision is returned only after it is checked against this invitation and this redemption.
// The caller repeats the call with the same arguments about every two seconds while it is
// awaiting, until expiresAt. An approval's profile, licence and peer binding are not verified
// here: verify them with the existing setup-file and binding checks, show the review, then
// apply. officeAddress is the office sync engine's `a.b.c.d:port` on a private IPv4 network, a
// route hint: pass "tcp://" + officeAddress as the address of Client.StartManagedOffice, with the
// office transport identity from the verified peer binding. An error (no route, a certificate that is not the office's, an answer that does not
// verify) decides nothing; the caller may try again until expiresAt.
func CommissionExchange(invitationEnvelope, redemptionEnvelope string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	answer, e := bootstrap.Exchange(ctx, commissionDial, invitationEnvelope, redemptionEnvelope)
	if e != nil {
		return "", e
	}
	switch {
	case answer.Awaiting:
		return stringJSON(map[string]string{"status": "awaiting"})
	case answer.Decision.Approval != nil:
		a := answer.Decision.Approval
		return stringJSON(map[string]string{"status": "approved", "enrolmentID": a.EnrolmentID,
			"profileDocument": a.ProfileDocument, "licenceCode": a.LicenceCode, "peerBinding": a.PeerBinding, "officeAddress": a.OfficeAddress,
			"decisionEnvelope": answer.Envelope})
	case answer.Decision.Refusal != nil:
		return stringJSON(map[string]string{"status": "refused", "reason": answer.Decision.Refusal.Reason})
	default:
		return "", errors.New("the office gave no answer")
	}
}
