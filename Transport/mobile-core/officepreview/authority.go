package officepreview

// Organisation pairing authority is deliberately separate from the preview application's
// self-signed key. The vendor-signed profile names this public key; the secret never crosses
// the native helper boundary or enters the desktop renderer.
import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const peerBindingDomain = "Avenkin.OfficePeerBinding.v1\x00"
const profileDomain = "openglasses.org-profile.v1\n"
const maximumPeerBinding = 32768
const maximumSafeInteger int64 = 9007199254740991

var productionProfileKeys = map[string]string{
	"og-profile-2026-09": "XyEMx0oOtxilcQO7A+C/b5R51Ui85U56BTQ8lISb5v8=",
}

type signedProfile struct {
	Format        string `json:"format"`
	SchemaVersion int    `json:"schemaVersion"`
	KeyID         string `json:"keyId"`
	ProfileID     string `json:"profileId"`
	PolicyExpiry  string `json:"policyExpiry"`
	Authority     struct {
		OrganizationID         string `json:"organizationID"`
		AdministratorPublicKey string `json:"administratorPublicKey"`
		TransportPolicy        string `json:"transportPolicy"`
	} `json:"officeAuthority"`
}

type PeerBinding struct {
	Version              int    `json:"version"`
	Kind                 string `json:"kind"`
	OrganizationID       string `json:"organizationID"`
	ProfileID            string `json:"profileID"`
	EnrolmentID          string `json:"enrolmentID"`
	OfficeID             string `json:"officeID"`
	Generation           int64  `json:"generation"`
	OfficeTransportID    string `json:"officeTransportID"`
	OfficeApplicationKey string `json:"officeApplicationKey"`
	PhoneTransportID     string `json:"phoneTransportID"`
	PhoneApplicationKey  string `json:"phoneApplicationKey"`
	IssuedAt             int64  `json:"issuedAt"`
	ExpiresAt            int64  `json:"expiresAt"`
}

type bindingLedger struct {
	Version      int    `json:"version"`
	Generation   int64  `json:"generation"`
	Organization string `json:"organizationID"`
	Enrolment    string `json:"enrolmentID"`
}

func (o *Office) ManagedOfficeID() string {
	digest := sha256.Sum256(o.Key.Public().(ed25519.PublicKey))
	return "office-" + hex.EncodeToString(digest[:12])
}

func safeIdentifier(s string) bool {
	if len(s) < 1 || len(s) > 80 || s == "." || s == ".." {
		return false
	}
	for _, c := range []byte(s) {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func canonicalPublic(s string) bool {
	b, e := base64.StdEncoding.Strict().DecodeString(s)
	return e == nil && len(b) == ed25519.PublicKeySize && base64.StdEncoding.EncodeToString(b) == s
}

func verifyOfficeProfile(document string, keys map[string]string, now int64) (signedProfile, error) {
	var profile signedProfile
	if len(document) > maximumPeerBinding || strings.TrimSpace(document) == "" {
		return profile, errors.New("missing or oversized signed organisation profile")
	}
	parts := strings.Split(strings.TrimSpace(document), ".")
	if len(parts) != 2 {
		return profile, errors.New("invalid signed organisation profile")
	}
	payload, e := base64.StdEncoding.Strict().DecodeString(parts[0])
	if e != nil || len(payload) > maximumPeerBinding {
		return profile, errors.New("invalid profile payload")
	}
	signature, e := base64.StdEncoding.Strict().DecodeString(parts[1])
	if e != nil || len(signature) != ed25519.SignatureSize || json.Unmarshal(payload, &profile) != nil {
		return profile, errors.New("invalid profile signature or payload")
	}
	publicString, trusted := keys[profile.KeyID]
	publicBytes, e := base64.StdEncoding.Strict().DecodeString(publicString)
	if !trusted || e != nil || len(publicBytes) != ed25519.PublicKeySize ||
		!ed25519.Verify(publicBytes, append([]byte(profileDomain), payload...), signature) {
		return profile, errors.New("organisation profile is not signed by a trusted vendor key")
	}
	if profile.Format != "openglasses.org-profile" || profile.SchemaVersion != 2 ||
		!safeIdentifier(profile.ProfileID) || !safeIdentifier(profile.Authority.OrganizationID) ||
		!canonicalPublic(profile.Authority.AdministratorPublicKey) ||
		(profile.Authority.TransportPolicy != "privateLan" && profile.Authority.TransportPolicy != "automatic") {
		return profile, errors.New("profile does not authorise an Avenkin office")
	}
	if profile.PolicyExpiry != "" {
		expiry, e := time.Parse(time.RFC3339, profile.PolicyExpiry)
		if e != nil || now >= expiry.Unix() {
			return profile, errors.New("organisation profile has expired")
		}
	}
	return profile, nil
}

func administratorKey(root string, create bool) (ed25519.PrivateKey, error) {
	if e := os.MkdirAll(root, 0700); e != nil {
		return nil, e
	}
	path := filepath.Join(root, "administrator-key")
	info, e := os.Lstat(path)
	if os.IsNotExist(e) && create {
		seed := make([]byte, ed25519.SeedSize)
		if _, e = rand.Read(seed); e != nil {
			return nil, e
		}
		file, e := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return nil, e
		}
		_, e = file.Write(seed)
		if e == nil {
			e = file.Sync()
		}
		closeError := file.Close()
		if e != nil {
			return nil, e
		}
		if closeError != nil {
			return nil, closeError
		}
		info, e = os.Lstat(path)
	}
	if e != nil {
		return nil, errors.New("administrator key has not been created on this computer")
	}
	// Windows inherits the current user's AppData ACL; Go exposes only the read-only bit
	// there, not POSIX owner/group permissions.
	if !info.Mode().IsRegular() || info.Size() != ed25519.SeedSize ||
		(runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0) {
		return nil, errors.New("administrator key file is unsafe or corrupt")
	}
	seed, e := os.ReadFile(path)
	if e != nil || len(seed) != ed25519.SeedSize {
		return nil, errors.New("administrator key cannot be read")
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

func AdministratorPublicKey(root string, create bool) (string, error) {
	key, e := administratorKey(root, create)
	if e != nil {
		return "", e
	}
	return public(key), nil
}

// IssuePeerBinding consumes public phone details reviewed by the office operator. It never
// claims that the phone possesses those keys; the owner must separately verify and approve
// this exact binding on the phone. A persisted generation prevents signing a lower replacement.
func (o *Office) IssuePeerBinding(profileDocument, enrolmentID,
	officeTransportID, phoneTransportID, phoneApplicationKey string, now int64) (string, error) {
	return o.issuePeerBinding(profileDocument, enrolmentID, officeTransportID,
		phoneTransportID, phoneApplicationKey, now, productionProfileKeys)
}

func (o *Office) issuePeerBinding(profileDocument, enrolmentID,
	officeTransportID, phoneTransportID, phoneApplicationKey string, now int64,
	keys map[string]string) (string, error) {
	profile, e := verifyOfficeProfile(profileDocument, keys, now)
	if e != nil {
		return "", e
	}
	admin, e := administratorKey(o.Root, false)
	if e != nil {
		return "", e
	}
	if public(admin) != profile.Authority.AdministratorPublicKey {
		return "", errors.New("this computer's administrator key is not authorised by that profile")
	}
	if !safeIdentifier(enrolmentID) || !validID(officeTransportID) ||
		!validID(phoneTransportID) || officeTransportID == phoneTransportID ||
		!canonicalPublic(phoneApplicationKey) || now <= 0 || now > maximumSafeInteger-30*86400 {
		return "", errors.New("invalid office or phone pairing details")
	}
	nameHash := sha256.Sum256([]byte(profile.Authority.OrganizationID + "\x00" + enrolmentID))
	ledgerPath := filepath.Join(o.Root, "bindings", hex.EncodeToString(nameHash[:])+".json")
	ledger := bindingLedger{Version: 1, Organization: profile.Authority.OrganizationID, Enrolment: enrolmentID}
	if e = load(ledgerPath, &ledger); e != nil && !os.IsNotExist(e) {
		return "", e
	}
	if ledger.Version != 1 || ledger.Organization != profile.Authority.OrganizationID ||
		ledger.Enrolment != enrolmentID || ledger.Generation >= maximumSafeInteger {
		return "", errors.New("pairing generation record is invalid")
	}
	expires := now + 30*86400
	if profile.PolicyExpiry != "" {
		policyExpiry, _ := time.Parse(time.RFC3339, profile.PolicyExpiry)
		if policyExpiry.Unix() < expires {
			expires = policyExpiry.Unix()
		}
	}
	if expires <= now {
		return "", errors.New("profile expires before this binding can be issued")
	}
	ledger.Generation++
	payload := PeerBinding{1, "avenkin.office-peer-binding", profile.Authority.OrganizationID,
		profile.ProfileID, enrolmentID, o.ManagedOfficeID(), ledger.Generation, officeTransportID,
		public(o.Key), phoneTransportID, phoneApplicationKey, now, expires}
	bytes, e := json.Marshal(payload)
	if e != nil {
		return "", e
	}
	signature := ed25519.Sign(admin, append([]byte(peerBindingDomain), bytes...))
	envelope, e := json.Marshal(Envelope{base64.StdEncoding.EncodeToString(bytes), base64.StdEncoding.EncodeToString(signature)})
	if e != nil || len(envelope) > maximumPeerBinding {
		return "", errors.New("signed binding exceeds size limit")
	}
	if e = save(ledgerPath, ledger); e != nil {
		return "", e
	}
	return string(envelope), nil
}
