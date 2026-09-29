package manualassignment

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// Public label derives a reproducible fictional key; no secret seed is stored.
func testKey() ed25519.PrivateKey {
	seed := sha256.Sum256([]byte("Avenkin public fixture office key v1"))
	return ed25519.NewKeyFromSeed(seed[:])
}
func trust() Trust {
	return Trust{"fixture-org", "fixture-phone", "fixture-office", "fixture-set", 1, 1048576, testKey().Public().(ed25519.PublicKey)}
}
func fixture(t *testing.T) ([]byte, Payload) {
	t.Helper()
	raw, err := os.ReadFile("../../../Contracts/fixtures/manual-assignment-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var e Envelope
	var p Payload
	if json.Unmarshal(raw, &e) != nil {
		t.Fatal("bad golden envelope")
	}
	b, _ := base64.StdEncoding.DecodeString(e.Payload)
	if json.Unmarshal(b, &p) != nil {
		t.Fatal("bad golden payload")
	}
	return raw, p
}
func TestSharedGoldenAndReplay(t *testing.T) {
	raw, _ := fixture(t)
	v, err := Verify(raw, trust(), 1800000000, nil)
	if err != nil {
		t.Fatal(err)
	}
	state := v.HighWater()
	replay, err := Verify(raw, trust(), 1800000000, &state)
	if err != nil || !replay.IsReplay || v.ScopeID() != replay.ScopeID() {
		t.Fatal("exact replay was not classified")
	}
}
func TestAuthorityTimeAndPolicyRefusals(t *testing.T) {
	raw, p := fixture(t)
	cases := []struct {
		name   string
		change func(*Payload)
		want   error
	}{
		{"foreign recipient", func(p *Payload) { p.EnrolmentID = "another-phone" }, ErrAuthority},
		{"wrong organization", func(p *Payload) { p.OrganizationID = "another-org" }, ErrAuthority},
		{"wrong office", func(p *Payload) { p.OfficeID = "another-office" }, ErrAuthority},
		{"wrong generation", func(p *Payload) { p.Generation = 2 }, ErrAuthority},
		{"wrong set", func(p *Payload) { p.SetID = "another-set" }, ErrAuthority},
		{"expired", func(p *Payload) { p.ExpiresAt = 1800000000 }, ErrTime},
		{"future", func(p *Payload) { p.IssuedAt = 1800000001 }, ErrTime},
		{"oversize", func(p *Payload) { p.ArchiveBytes = 1048577 }, ErrPolicy},
		{"unsafe vault", func(p *Payload) { p.VaultID = "../escape" }, ErrFields},
		{"uppercase hash", func(p *Payload) { p.ArchiveSHA256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }, ErrFields},
		{"unsupported", func(p *Payload) { p.Version = 2 }, ErrVersion},
		{"zero sequence", func(p *Payload) { p.Sequence = 0 }, ErrFields},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			changed := p
			c.change(&changed)
			message, _ := Sign(changed, testKey())
			_, err := Verify(message, trust(), 1800000000, nil)
			if err != c.want {
				t.Fatalf("got %v, wanted %v", err, c.want)
			}
		})
	}
	var e Envelope
	_ = json.Unmarshal(raw, &e)
	e.Signature = base64.StdEncoding.EncodeToString(make([]byte, 64))
	bad, _ := json.Marshal(e)
	if _, err := Verify(bad, trust(), 1800000000, nil); err != ErrSignature {
		t.Fatal("modified signature accepted")
	}
}
func TestRollbackAndEquivocation(t *testing.T) {
	raw, p := fixture(t)
	v, _ := Verify(raw, trust(), 1800000000, nil)
	state := v.HighWater()
	p.Sequence--
	older, _ := Sign(p, testKey())
	if _, err := Verify(older, trust(), 1800000000, &state); err != ErrRollback {
		t.Fatal("rollback accepted")
	}
	_, p = fixture(t)
	p.VaultVersion = "9.0"
	changed, _ := Sign(p, testKey())
	if _, err := Verify(changed, trust(), 1800000000, &state); err != ErrConflict {
		t.Fatal("same sequence changed payload accepted")
	}
	oldTrust := trust()
	state.Generation = 2
	if _, err := Verify(raw, oldTrust, 1800000000, &state); err != ErrRollback {
		t.Fatal("older commissioning generation accepted")
	}
}

func TestAmbiguousOrExtendedJSONIsRejected(t *testing.T) {
	raw, _ := fixture(t)
	var e Envelope
	_ = json.Unmarshal(raw, &e)
	body, _ := base64.StdEncoding.DecodeString(e.Payload)
	text := string(body)
	variants := []string{
		strings.Replace(text, `"enrolmentID":"fixture-phone"`, `"enrolmentID":"foreign","enrolmentID":"fixture-phone"`, 1),
		strings.Replace(text, `"version":1`, `"version":1.0`, 1),
		strings.Replace(text, `"version":1`, `"version":1e0`, 1),
		strings.Replace(text, `"version":1`, `"version":01`, 1),
		strings.Replace(text, `"version":1`, `"undeclaredClaim":"ignored","version":1`, 1),
	}
	for _, v := range variants {
		if v == text {
			t.Fatal("negative test did not change its input")
		}
		sig := ed25519.Sign(testKey(), append([]byte(Domain), []byte(v)...))
		message, _ := json.Marshal(Envelope{base64.StdEncoding.EncodeToString([]byte(v)), base64.StdEncoding.EncodeToString(sig)})
		if _, err := Verify(message, trust(), 1800000000, nil); err != ErrMalformed {
			t.Fatalf("ambiguous signed JSON accepted: %v", err)
		}
	}
	duplicate := strings.Replace(string(raw), `"payload":`, `"payload":"ignored","payload":`, 1)
	if _, err := Verify([]byte(duplicate), trust(), 1800000000, nil); err != ErrMalformed {
		t.Fatal("ambiguous envelope accepted")
	}
}
