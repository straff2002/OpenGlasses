package manageddelivery

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func phoneKey() ed25519.PrivateKey {
	seed := sha256.Sum256([]byte("Avenkin public fixture phone application key v1"))
	return ed25519.NewKeyFromSeed(seed[:])
}

func verifiedFixture(t *testing.T) Verified {
	t.Helper()
	v, err := Verify(fixture(t, "managed-job-v1.json"), fixtureTrust(t), 1800000000, nil)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func receiptTrust(t *testing.T) ReceiptTrust {
	job := fixtureTrust(t)
	return ReceiptTrust{job.OrganizationID, job.EnrolmentID, job.OfficeID, job.PhoneTransportID, job.Generation, phoneKey().Public().(ed25519.PublicKey)}
}

func expected(v Verified) ReceiptExpected {
	return ReceiptExpected{v.Payload.MessageID, v.Payload.Sequence, v.PayloadSHA256, v.Payload.JobSHA256}
}

func TestGoldenReceiptAndSealedSignature(t *testing.T) {
	v := verifiedFixture(t)
	receipt := ReceiptFor(v, 1800000100)
	signed, err := SignReceipt(receipt, phoneKey())
	if err != nil {
		t.Fatal(err)
	}
	if string(signed) != strings.TrimSpace(string(fixture(t, "managed-job-receipt-v1.json"))) {
		t.Fatalf("receipt differs from the golden fixture:\n%s", signed)
	}
	got, err := VerifyReceipt(signed, receiptTrust(t), expected(v))
	if err != nil || got != receipt {
		t.Fatalf("%v %+v", err, got)
	}
	// A signer that holds the key elsewhere signs the payload bytes and seals: the same envelope.
	raw, err := ReceiptPayload(receipt)
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := SealReceipt(raw, ed25519.Sign(phoneKey(), append([]byte(ReceiptDomain), raw...)))
	if err != nil || string(sealed) != string(signed) {
		t.Fatalf("sealed differs: %v", err)
	}
	if _, err = SealReceipt(raw, []byte("short")); !errors.Is(err, ErrReceiptMalformed) {
		t.Fatal("short signature sealed")
	}
	// The job's own signature domain does not verify a receipt, and the office's key is not the phone's.
	wrongDomain, _ := SealReceipt(raw, ed25519.Sign(phoneKey(), append([]byte(Domain), raw...)))
	if _, err = VerifyReceipt(wrongDomain, receiptTrust(t), expected(v)); !errors.Is(err, ErrReceiptSignature) {
		t.Fatal("job domain accepted for a receipt")
	}
}

func TestReceiptRefusals(t *testing.T) {
	v := verifiedFixture(t)
	good := ReceiptFor(v, 1800000100)
	sign := func(change func(*Receipt)) []byte {
		r := good
		change(&r)
		raw, _ := json.Marshal(r)
		b, _ := json.Marshal(Envelope{base64.StdEncoding.EncodeToString(raw), base64.StdEncoding.EncodeToString(ed25519.Sign(phoneKey(), append([]byte(ReceiptDomain), raw...)))})
		return b
	}
	otherKey := receiptTrust(t)
	otherKey.PhoneApplicationKey = fixtureTrust(t).OfficeApplicationKey
	for name, c := range map[string]struct {
		data  []byte
		trust ReceiptTrust
		want  error
	}{
		"another key":        {sign(func(*Receipt) {}), otherKey, ErrReceiptSignature},
		"another enrolment":  {sign(func(r *Receipt) { r.EnrolmentID = "other-phone" }), receiptTrust(t), ErrReceiptAuthority},
		"another generation": {sign(func(r *Receipt) { r.Generation = 2 }), receiptTrust(t), ErrReceiptAuthority},
		"another message":    {sign(func(r *Receipt) { r.MessageID = strings.Repeat("0", 32) }), receiptTrust(t), ErrReceiptMessage},
		"another sequence":   {sign(func(r *Receipt) { r.Sequence++ }), receiptTrust(t), ErrReceiptMessage},
		"another payload":    {sign(func(r *Receipt) { r.PayloadSHA256 = strings.Repeat("0", 64) }), receiptTrust(t), ErrReceiptMessage},
		"another job":        {sign(func(r *Receipt) { r.JobSHA256 = strings.Repeat("0", 64) }), receiptTrust(t), ErrReceiptMessage},
		"unknown outcome":    {sign(func(r *Receipt) { r.Outcome = "accepted" }), receiptTrust(t), ErrReceiptFields},
		"another kind":       {sign(func(r *Receipt) { r.Kind = "avenkin.managed-job" }), receiptTrust(t), ErrReceiptFields},
		"no time":            {sign(func(r *Receipt) { r.ReceivedAt = 0 }), receiptTrust(t), ErrReceiptFields},
		"not an envelope":    {[]byte(`{"payload":"e30=","signature":"AA==","extra":1}`), receiptTrust(t), ErrReceiptMalformed},
		"too large":          {[]byte(strings.Repeat(" ", MaximumReceiptBytes+1)), receiptTrust(t), ErrReceiptMalformed},
	} {
		if _, err := VerifyReceipt(c.data, c.trust, expected(v)); !errors.Is(err, c.want) {
			t.Fatalf("%s: %v", name, err)
		}
	}
	// A payload with an unknown or repeated member is refused before its signature is looked at.
	raw, _ := ReceiptPayload(good)
	for _, bad := range []string{strings.Replace(string(raw), "{", `{"extra":1,`, 1), strings.Replace(string(raw), "{", `{"version":1,`, 1)} {
		b, _ := json.Marshal(Envelope{base64.StdEncoding.EncodeToString([]byte(bad)), base64.StdEncoding.EncodeToString(ed25519.Sign(phoneKey(), append([]byte(ReceiptDomain), bad...)))})
		if _, err := VerifyReceipt(b, receiptTrust(t), expected(v)); !errors.Is(err, ErrReceiptMalformed) {
			t.Fatalf("open payload: %v", err)
		}
	}
	bad := good
	bad.Outcome = "refused"
	if _, err := ReceiptPayload(bad); !errors.Is(err, ErrReceiptFields) {
		t.Fatal("unknown outcome given a payload")
	}
}
