package manageddelivery

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "Contracts", "fixtures", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}
func fixtureTrust(t *testing.T) Trust {
	t.Helper()
	var keys struct{ OfficeApplicationKey, OfficeTransportID, PhoneTransportID string }
	if err := json.Unmarshal(fixture(t, "managed-job-fixture-keys.json"), &keys); err != nil {
		t.Fatal(err)
	}
	key, err := base64.StdEncoding.DecodeString(keys.OfficeApplicationKey)
	if err != nil {
		t.Fatal(err)
	}
	return Trust{"fixture-org", "fixture-phone", "fixture-office", keys.OfficeTransportID, keys.PhoneTransportID, 1, key}
}
func resign(t *testing.T, change func(*Job)) []byte {
	t.Helper()
	var envelope Envelope
	if err := json.Unmarshal(fixture(t, "managed-job-v1.json"), &envelope); err != nil {
		t.Fatal(err)
	}
	raw, err := base64.StdEncoding.DecodeString(envelope.Payload)
	if err != nil {
		t.Fatal(err)
	}
	var p Job
	if err := json.Unmarshal(raw, &p); err != nil {
		t.Fatal(err)
	}
	change(&p)
	seed := sha256.Sum256([]byte("Avenkin public fixture office key v1"))
	signed, err := Sign(p, ed25519.NewKeyFromSeed(seed[:]))
	if err != nil {
		t.Fatal(err)
	}
	return signed
}
func TestGoldenManagedJobAndExactBytes(t *testing.T) {
	trust := fixtureTrust(t)
	data := fixture(t, "managed-job-v1.json")
	v, err := Verify(data, trust, 1800000000, nil)
	if err != nil {
		t.Fatal(err)
	}
	if v.IsReplay || v.Payload.Sequence != 7 {
		t.Fatalf("unexpected verification: %+v", v)
	}
	if err := VerifyBytes(fixture(t, "managed-job-v1.ogjob"), v); err != nil {
		t.Fatal(err)
	}
	if err := VerifyBytes([]byte("tampered"), v); !errors.Is(err, ErrContent) {
		t.Fatal(err)
	}
	replay, err := Verify(data, trust, 1800000000, ptr(v.HighWater()))
	if err != nil || !replay.IsReplay {
		t.Fatalf("exact retry: %+v %v", replay, err)
	}
}
func ptr[T any](v T) *T { return &v }
func TestWrongBindingSignatureExpiryAndSequenceRefused(t *testing.T) {
	data := fixture(t, "managed-job-v1.json")
	trust := fixtureTrust(t)
	other := trust
	other.EnrolmentID = "another-phone"
	if _, err := Verify(data, other, 1800000000, nil); !errors.Is(err, ErrAuthority) {
		t.Fatal(err)
	}
	if _, err := Verify(data, trust, 1800003600, nil); !errors.Is(err, ErrTime) {
		t.Fatal(err)
	}
	var e Envelope
	if err := json.Unmarshal(data, &e); err != nil {
		t.Fatal(err)
	}
	e.Signature = base64.StdEncoding.EncodeToString(make([]byte, 64))
	bad, _ := json.Marshal(e)
	if _, err := Verify(bad, trust, 1800000000, nil); !errors.Is(err, ErrSignature) {
		t.Fatal(err)
	}
	v, err := Verify(data, trust, 1800000000, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Verify(resign(t, func(p *Job) { p.Sequence = 6 }), trust, 1800000000, ptr(v.HighWater())); !errors.Is(err, ErrRollback) {
		t.Fatal(err)
	}
	if _, err := Verify(resign(t, func(p *Job) { p.MessageID = "0123456789abcdef0123456789abcdef" }), trust, 1800000000, ptr(v.HighWater())); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
}
func TestClosedSchemaAndLimits(t *testing.T) {
	trust := fixtureTrust(t)
	for _, p := range [][]byte{
		resign(t, func(p *Job) { p.JobBytes = MaximumJobBytes + 1 }),
		resign(t, func(p *Job) { p.JobSHA256 = strings.ToUpper(p.JobSHA256) }),
		resign(t, func(p *Job) { p.OfficeTransportID = "not-a-device" }),
	} {
		if _, err := Verify(p, trust, 1800000000, nil); !errors.Is(err, ErrFields) && !errors.Is(err, ErrAuthority) {
			t.Fatal(err)
		}
	}
	data := fixture(t, "managed-job-v1.json")
	var e Envelope
	if err := json.Unmarshal(data, &e); err != nil {
		t.Fatal(err)
	}
	raw, _ := base64.StdEncoding.DecodeString(e.Payload)
	duplicate := strings.Replace(string(raw), `"version":1`, `"version":1,"version":1`, 1)
	seed := sha256.Sum256([]byte("Avenkin public fixture office key v1"))
	e.Payload = base64.StdEncoding.EncodeToString([]byte(duplicate))
	e.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(ed25519.NewKeyFromSeed(seed[:]), append([]byte(Domain), []byte(duplicate)...)))
	bad, _ := json.Marshal(e)
	if _, err := Verify(bad, trust, 1800000000, nil); !errors.Is(err, ErrMalformed) {
		t.Fatal(err)
	}
}

func TestSignPayloadSignsExactBytesForItsOwnOfficeOnly(t *testing.T) {
	trust := fixtureTrust(t)
	var envelope Envelope
	if err := json.Unmarshal(fixture(t, "managed-job-v1.json"), &envelope); err != nil {
		t.Fatal(err)
	}
	raw, err := base64.StdEncoding.DecodeString(envelope.Payload)
	if err != nil {
		t.Fatal(err)
	}
	seed := sha256.Sum256([]byte("Avenkin public fixture office key v1"))
	key := ed25519.NewKeyFromSeed(seed[:])
	var p Job
	if err := json.Unmarshal(raw, &p); err != nil {
		t.Fatal(err)
	}
	now := p.IssuedAt + 10

	// The exact bytes are signed: the result is the fixture envelope, byte for byte.
	signed, err := SignPayload(raw, key, trust.OfficeID, now)
	if err != nil || string(signed) != strings.TrimSpace(string(fixture(t, "managed-job-v1.json"))) {
		t.Fatalf("golden: %v\n%s", err, signed)
	}
	if _, err = Verify(signed, trust, now, nil); err != nil {
		t.Fatal(err)
	}
	// Bytes that mean the same but are spelt differently are signed as they are, not re-encoded.
	spaced := []byte(strings.Replace(string(raw), `{"version":1,`, `{"version": 1,`, 1))
	other, err := SignPayload(spaced, key, trust.OfficeID, now)
	if err != nil || json.Unmarshal(other, &envelope) != nil {
		t.Fatal(err)
	}
	if kept, _ := base64.StdEncoding.DecodeString(envelope.Payload); string(kept) != string(spaced) {
		t.Fatal("payload bytes were re-encoded")
	}

	edit := func(change func(*Job)) []byte {
		q := p
		change(&q)
		b, _ := json.Marshal(q)
		return b
	}
	for name, c := range map[string]struct {
		raw    []byte
		office string
		now    int64
		want   error
	}{
		"another office":     {raw, "another-office", now, ErrAuthority},
		"no office":          {raw, "", now, ErrAuthority},
		"expired":            {raw, trust.OfficeID, p.ExpiresAt, ErrTime},
		"issued far ahead":   {raw, trust.OfficeID, p.IssuedAt - MaximumIssueSkewSeconds - 1, ErrTime},
		"unknown member":     {[]byte(strings.Replace(string(raw), "{", `{"extra":1,`, 1)), trust.OfficeID, now, ErrMalformed},
		"duplicate member":   {[]byte(strings.Replace(string(raw), "{", `{"version":1,`, 1)), trust.OfficeID, now, ErrMalformed},
		"not an object":      {[]byte("[]"), trust.OfficeID, now, ErrMalformed},
		"empty":              {nil, trust.OfficeID, now, ErrMalformed},
		"bad message id":     {edit(func(q *Job) { q.MessageID = "short" }), trust.OfficeID, now, ErrFields},
		"another kind":       {edit(func(q *Job) { q.Kind = "avenkin.manual-assignment" }), trust.OfficeID, now, ErrFields},
		"too long a window":  {edit(func(q *Job) { q.ExpiresAt = q.IssuedAt + 31*86400 }), trust.OfficeID, now, ErrFields},
		"job too large":      {edit(func(q *Job) { q.JobBytes = MaximumJobBytes + 1 }), trust.OfficeID, now, ErrFields},
		"non-canonical peer": {edit(func(q *Job) { q.PhoneTransportID = strings.ToLower(q.PhoneTransportID) }), trust.OfficeID, now, ErrFields},
	} {
		if _, err := SignPayload(c.raw, key, c.office, c.now); !errors.Is(err, c.want) {
			t.Fatalf("%s: %v", name, err)
		}
	}
	// Issued a little ahead of this clock is allowed: two processes on one computer.
	if _, err := SignPayload(raw, key, trust.OfficeID, p.IssuedAt-MaximumIssueSkewSeconds); err != nil {
		t.Fatal(err)
	}
	if _, err := SignPayload(raw, key[:10], trust.OfficeID, now); !errors.Is(err, ErrSignature) {
		t.Fatal("short key accepted")
	}
}
