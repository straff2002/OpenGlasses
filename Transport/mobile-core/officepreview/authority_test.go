package officepreview

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func testProfile(t *testing.T, vendor, administrator ed25519.PrivateKey, expiry string) string {
	t.Helper()
	payload, e := json.Marshal(map[string]any{
		"format": "openglasses.org-profile", "schemaVersion": 2,
		"keyId": "test-vendor", "profileId": "profile-1", "policyExpiry": expiry,
		"officeAuthority": map[string]string{"organizationID": "org-1",
			"administratorPublicKey": public(administrator), "transportPolicy": "privateLan"},
	})
	if e != nil {
		t.Fatal(e)
	}
	signature := ed25519.Sign(vendor, append([]byte(profileDomain), payload...))
	return base64.StdEncoding.EncodeToString(payload) + "." + base64.StdEncoding.EncodeToString(signature)
}

func TestAdministratorBindingIsVendorRootedAndMonotonic(t *testing.T) {
	root := t.TempDir()
	o, e := OpenOffice(root)
	if e != nil {
		t.Fatal(e)
	}
	adminPublic, e := AdministratorPublicKey(root, true)
	if e != nil {
		t.Fatal(e)
	}
	admin, e := administratorKey(root, false)
	if e != nil || public(admin) != adminPublic {
		t.Fatal("administrator identity changed", e)
	}
	info, e := os.Stat(filepath.Join(root, "administrator-key"))
	if e != nil || (runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0) {
		t.Fatal("administrator seed has unsafe permissions", e)
	}
	vendorPublic, vendor, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	keys := map[string]string{"test-vendor": base64.StdEncoding.EncodeToString(vendorPublic)}
	profile := testProfile(t, vendor, admin, "2027-01-01T00:00:00Z")
	phonePublic, _, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	phoneKey := base64.StdEncoding.EncodeToString(phonePublic)
	issue := func(document string) (string, error) {
		return o.issuePeerBinding(document, "enrolment-1", ident("office transport"),
			ident("phone transport"), phoneKey, 1790000000, keys)
	}
	first, e := issue(profile)
	if e != nil {
		t.Fatal(e)
	}
	second, e := issue(profile)
	if e != nil {
		t.Fatal(e)
	}
	for index, signed := range []string{first, second} {
		var envelope Envelope
		if e := json.Unmarshal([]byte(signed), &envelope); e != nil {
			t.Fatal(e)
		}
		bytes, _ := base64.StdEncoding.DecodeString(envelope.Payload)
		signature, _ := base64.StdEncoding.DecodeString(envelope.Signature)
		if !ed25519.Verify(admin.Public().(ed25519.PublicKey), append([]byte(peerBindingDomain), bytes...), signature) {
			t.Fatal("binding signature did not verify")
		}
		var binding PeerBinding
		if e := json.Unmarshal(bytes, &binding); e != nil {
			t.Fatal(e)
		}
		if binding.Generation != int64(index+1) || binding.OfficeID != o.ManagedOfficeID() ||
			binding.PhoneTransportID != ident("phone transport") ||
			binding.OfficeApplicationKey != public(o.Key) || binding.ExpiresAt-binding.IssuedAt > 30*86400 {
			t.Fatal("incorrect signed binding", binding)
		}
	}
	if _, e := issue(profile + "tampered"); e == nil {
		t.Fatal("tampered vendor profile accepted")
	}
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	if _, e := issue(testProfile(t, vendor, other, "2027-01-01T00:00:00Z")); e == nil {
		t.Fatal("foreign administrator key accepted")
	}
	if _, e := issue(testProfile(t, vendor, admin, "2026-01-01T00:00:00Z")); e == nil {
		t.Fatal("expired vendor profile accepted")
	}
}
