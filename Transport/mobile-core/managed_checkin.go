package mobilecore

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"avenkin.dev/mobilecore/checkin"
	"avenkin.dev/mobilecore/officepreview"
)

// Check-in, renewal and removal in the managed folders (Contracts/office-check-in.md §4 and §8).
// The office puts a challenge, a result and a removal in control; the phone publishes a check-in
// and a removal receipt in records. As with managed jobs, a folder grants nothing: every file is
// verified by its own contract, a peer-supplied name never selects a path, and nothing here acts
// on what it reads. The native caller answers, commits and revokes through its own gate; this
// only says what has arrived, builds the exact bytes to sign, and publishes them.

// checkInAuthority is what the native caller hands over beside the job trust, after it has
// re-verified them: the profile and administrator key the vendor-signed profile names, and the
// digest of the binding the phone holds.
type checkInAuthority struct {
	profileID, bindingSHA256                  string
	administratorKey                          ed25519.PublicKey
	officeApplicationKey, phoneApplicationKey string // as the binding spells them, base64
}

// checkInRecord is the one check-in this phone is waiting on: its exact bytes, kept so that the
// challenge is answered once.
type checkInRecord struct {
	ChallengeID     string `json:"challengeID"`
	ChallengeSHA256 string `json:"challengeSHA256"`
	Generation      int64  `json:"generation"`
	ExpiresAt       int64  `json:"expiresAt"`
	Payload         string `json:"payload"` // base64
	Published       bool   `json:"published"`
}

type removalRecord struct {
	RemovalID     string `json:"removalID"`
	RemovalSHA256 string `json:"removalSHA256"`
	Payload       string `json:"payload"` // base64
	Published     bool   `json:"published"`
}

type pendingEnvelope struct {
	ID string `json:"id"`
	// Envelope is the exact bytes of the file, base64.
	Envelope string `json:"envelope"`
}

type checkInPending struct {
	Challenges []pendingEnvelope `json:"challenges"`
	Results    []pendingEnvelope `json:"results"`
	Removals   []pendingEnvelope `json:"removals"`
}

const (
	challengeSuffix = ".challenge.envelope.json"
	resultSuffix    = ".result.envelope.json"
	envelopeSuffix  = ".envelope.json"
	// maximumControlEntries bounds how many names of one control directory a pass looks at.
	maximumControlEntries = 64
	maximumRemovalsKept   = 16
)

func checkInName(challengeID string) string { return "checkin/" + challengeID + envelopeSuffix }
func removalName(removalID string) string   { return "removal/" + removalID + envelopeSuffix }

// held is the binding the phone holds, as far as a renewal compares it: every identity and the
// generation. Its dates are the native caller's to check.
func (i *managedInbox) held() officepreview.PeerBinding {
	t, a := i.trust, i.authority
	return officepreview.PeerBinding{OrganizationID: t.OrganizationID, ProfileID: a.profileID, EnrolmentID: t.EnrolmentID,
		OfficeID: t.OfficeID, Generation: t.Generation, OfficeTransportID: t.OfficeTransportID,
		OfficeApplicationKey: a.officeApplicationKey, PhoneTransportID: t.PhoneTransportID, PhoneApplicationKey: a.phoneApplicationKey}
}

// controlNames lists the names in control/<dir> that are 32 lowercase hex characters followed by
// suffix, as their identifiers. Nothing else in the directory is opened.
func (i *managedInbox) controlNames(dir, suffix string) []string {
	entries, err := os.ReadDir(filepath.Join(i.control, dir))
	if err != nil {
		return nil
	}
	var ids []string
	for _, entry := range entries {
		if id, ok := strings.CutSuffix(entry.Name(), suffix); ok && lowerHex(id, 32) {
			ids = append(ids, id)
		}
		if len(ids) == maximumControlEntries {
			break
		}
	}
	return ids
}

// remember records a file that can never verify, once, by its digest. A file that is only not
// current — not yet valid, expired, for another generation — is not remembered: it waits.
func (i *managedInbox) remember(digest string, err error, changed *bool) {
	if (errors.Is(err, checkin.ErrMalformed) || errors.Is(err, checkin.ErrFields)) && len(i.state.Refused) < maximumRefusedRemembered {
		i.state.Refused[digest] = err.Error()
		*changed = true
	}
}

// liveChallenge is the challenge this phone may answer at now: signed by the office application
// key the binding names, set under exactly this binding, live, and of those the one with the
// latest issuedAt. The envelope is returned as the exact bytes read.
func (i *managedInbox) liveChallenge(now int64, changed *bool) (checkin.Challenge, []byte, bool) {
	var best checkin.Challenge
	var bestEnvelope []byte
	for _, id := range i.controlNames("checkin", challengeSuffix) {
		data, err := officepreview.ReadFile(filepath.Join(i.control, "checkin", id+challengeSuffix), checkin.MaximumMessage)
		if err != nil {
			continue
		}
		digest := checkin.Digest(string(data))
		if _, seen := i.state.Refused[digest]; seen {
			continue
		}
		challenge, err := checkin.ReadChallenge(string(data), i.trust.OfficeApplicationKey)
		if err != nil {
			i.remember(digest, err, changed)
			continue
		}
		if challenge.ChallengeID != id || !challenge.Names(i.held(), i.authority.bindingSHA256) || !challenge.Live(now) {
			continue
		}
		if bestEnvelope == nil || challenge.IssuedAt > best.IssuedAt || challenge.IssuedAt == best.IssuedAt && challenge.ChallengeID < best.ChallengeID {
			best, bestEnvelope = challenge, data
		}
	}
	return best, bestEnvelope, bestEnvelope != nil
}

// forgetCheckIn withdraws the check-in this phone was waiting on: its file leaves records and
// the outbound list with it.
func (i *managedInbox) forgetCheckIn() {
	if i.state.CheckIn == nil {
		return
	}
	_ = os.Remove(filepath.Join(i.records, filepath.FromSlash(checkInName(i.state.CheckIn.ChallengeID))))
	i.state.CheckIn = nil
}

func (i *managedInbox) checkInPending(now int64) (checkInPending, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	out := checkInPending{[]pendingEnvelope{}, []pendingEnvelope{}, []pendingEnvelope{}}
	if i.authority == nil {
		return out, nil
	}
	changed := false
	// A check-in whose challenge has expired, or that was made under another generation, renews
	// nothing any more.
	if c := i.state.CheckIn; c != nil && (now >= c.ExpiresAt || c.Generation != i.trust.Generation) {
		i.forgetCheckIn()
		changed = true
	}
	b64 := base64.StdEncoding.EncodeToString
	if challenge, envelope, ok := i.liveChallenge(now, &changed); ok {
		out.Challenges = append(out.Challenges, pendingEnvelope{challenge.ChallengeID, b64(envelope)})
	}
	if c := i.state.CheckIn; c != nil && c.Published {
		if result, ok := i.resultFor(*c, now, &changed); ok {
			out.Results = append(out.Results, pendingEnvelope{c.ChallengeID, b64(result)})
		}
	}
	for _, id := range i.controlNames("removal", envelopeSuffix) {
		if data, ok := i.removal(id, &changed); ok {
			out.Removals = append(out.Removals, pendingEnvelope{id, b64(data)})
		}
	}
	sort.Slice(out.Removals, func(a, b int) bool { return out.Removals[a].ID < out.Removals[b].ID })
	if changed {
		return out, i.save()
	}
	return out, nil
}

// resultFor reads the result for the check-in this phone published: signed by the administrator
// key, for exactly that check-in's bytes, and carrying a renewal of the binding held.
func (i *managedInbox) resultFor(c checkInRecord, now int64, changed *bool) ([]byte, bool) {
	data, err := officepreview.ReadFile(filepath.Join(i.control, "checkin", c.ChallengeID+resultSuffix), checkin.MaximumResult)
	if err != nil {
		return nil, false
	}
	digest := checkin.Digest(string(data))
	if _, seen := i.state.Refused[digest]; seen {
		return nil, false
	}
	published, err := officepreview.ReadFile(filepath.Join(i.records, filepath.FromSlash(checkInName(c.ChallengeID))), checkin.MaximumMessage)
	if err != nil {
		return nil, false
	}
	var waiting checkin.CheckIn
	payload, err := base64.StdEncoding.Strict().DecodeString(c.Payload)
	if err != nil || json.Unmarshal(payload, &waiting) != nil {
		return nil, false
	}
	if _, _, _, err = checkin.ReadResult(string(data), i.authority.administratorKey, string(published), waiting, i.held(), now); err != nil {
		i.remember(digest, err, changed)
		return nil, false
	}
	return data, true
}

// removal reads one removal: signed by the administrator key and naming this phone's own
// organisation, profile, enrolment and transport identity.
func (i *managedInbox) removal(id string, changed *bool) ([]byte, bool) {
	data, err := officepreview.ReadFile(filepath.Join(i.control, "removal", id+envelopeSuffix), checkin.MaximumMessage)
	if err != nil {
		return nil, false
	}
	digest := checkin.Digest(string(data))
	if _, seen := i.state.Refused[digest]; seen {
		return nil, false
	}
	removal, err := checkin.ReadRemoval(string(data), i.authority.administratorKey, i.trust.OrganizationID, i.authority.profileID, i.trust.EnrolmentID, i.trust.PhoneTransportID)
	if err != nil {
		if changed != nil {
			i.remember(digest, err, changed)
		}
		return nil, false
	}
	return data, removal.RemovalID == id
}

// checkInPayload builds, once, the check-in that answers the live challenge.
func (i *managedInbox) checkInPayload(challengeID string, leaseRenewBy int64, appVersion, appBuild string, now int64) ([]byte, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.authority == nil {
		return nil, errors.New("these managed folders carry no check-in")
	}
	changed := false
	challenge, envelope, ok := i.liveChallenge(now, &changed)
	if !ok || challenge.ChallengeID != challengeID {
		return nil, errors.New("no such live check-in challenge")
	}
	digest := checkin.Digest(string(envelope))
	if c := i.state.CheckIn; c != nil && c.ChallengeID == challengeID && c.ChallengeSHA256 == digest {
		// Answered already: the same bytes, the same nonce.
		return base64.StdEncoding.Strict().DecodeString(c.Payload)
	}
	random := make([]byte, 32)
	if _, err := rand.Read(random); err != nil {
		return nil, err
	}
	payload, err := checkin.CheckInPayload(checkin.CheckInFor(string(envelope), challenge, base64.RawURLEncoding.EncodeToString(random), leaseRenewBy, appVersion, appBuild, now))
	if err != nil {
		return nil, err
	}
	// The phone waits on at most one check-in: a newer challenge withdraws the answer to an older.
	previous := i.state.CheckIn
	i.forgetCheckIn()
	i.state.CheckIn = &checkInRecord{ChallengeID: challengeID, ChallengeSHA256: digest, Generation: challenge.Generation,
		ExpiresAt: challenge.ExpiresAt, Payload: base64.StdEncoding.EncodeToString(payload)}
	if err = i.save(); err != nil {
		i.state.CheckIn = previous
		return nil, err
	}
	return payload, nil
}

// publish stages an envelope outside every shared folder and moves it into place complete.
func (i *managedInbox) publish(name string, envelope []byte) error {
	staged := filepath.Join(i.private, "publish-"+strings.ReplaceAll(name, "/", "-")+".tmp")
	if err := officepreview.Atomic(staged, envelope); err != nil {
		return err
	}
	destination := filepath.Join(i.records, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
		return err
	}
	return os.Rename(staged, destination)
}

// publishCheckIn takes the phone application key's signature over the check-in payload, checks
// it, and publishes the check-in under its final name. A published name keeps its bytes: a second
// signature for the same check-in publishes nothing new.
func (i *managedInbox) publishCheckIn(challengeID string, signature []byte) ([]byte, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	c := i.state.CheckIn
	if c == nil || c.ChallengeID != challengeID || !lowerHex(challengeID, 32) {
		return nil, errors.New("no check-in is waiting for that challenge")
	}
	payload, err := base64.StdEncoding.Strict().DecodeString(c.Payload)
	if err != nil {
		return nil, err
	}
	if len(signature) != ed25519.SignatureSize || !ed25519.Verify(i.phoneKey, checkin.SigningInput(checkin.CheckInDomain, payload), signature) {
		return nil, errors.New("the check-in signature is not this phone's")
	}
	name := checkInName(challengeID)
	if c.Published {
		if existing, e := officepreview.ReadFile(filepath.Join(i.records, filepath.FromSlash(name)), checkin.MaximumMessage); e == nil {
			return existing, nil
		}
	}
	envelope, err := checkin.SealCheckIn(payload, signature)
	if err != nil {
		return nil, err
	}
	if err = i.publish(name, []byte(envelope)); err != nil {
		return nil, err
	}
	if !c.Published {
		c.Published = true
		return []byte(envelope), i.save()
	}
	return []byte(envelope), nil
}

func (i *managedInbox) removalRecord(removalID string) *removalRecord {
	for n := range i.state.Removals {
		if i.state.Removals[n].RemovalID == removalID {
			return &i.state.Removals[n]
		}
	}
	return nil
}

// removalReceiptPayload builds, once, the receipt for a removal that verifies.
func (i *managedInbox) removalReceiptPayload(removalID string, actedAt int64) ([]byte, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.authority == nil || !lowerHex(removalID, 32) {
		return nil, errors.New("no such removal on this phone")
	}
	data, ok := i.removal(removalID, nil)
	if !ok {
		return nil, errors.New("no such removal on this phone")
	}
	digest := checkin.Digest(string(data))
	if r := i.removalRecord(removalID); r != nil && r.RemovalSHA256 == digest {
		return base64.StdEncoding.Strict().DecodeString(r.Payload)
	}
	removal, err := checkin.ReadRemoval(string(data), i.authority.administratorKey, i.trust.OrganizationID, i.authority.profileID, i.trust.EnrolmentID, i.trust.PhoneTransportID)
	if err != nil {
		return nil, err
	}
	payload, err := checkin.RemovalReceiptPayload(checkin.RemovalReceiptFor(string(data), removal, actedAt))
	if err != nil {
		return nil, err
	}
	if len(i.state.Removals) >= maximumRemovalsKept {
		return nil, errors.New("too many removals on this phone")
	}
	previous := i.state.Removals
	i.state.Removals = append(append([]removalRecord{}, previous...), removalRecord{RemovalID: removalID, RemovalSHA256: digest, Payload: base64.StdEncoding.EncodeToString(payload)})
	if err = i.save(); err != nil {
		i.state.Removals = previous
		return nil, err
	}
	return payload, nil
}

func (i *managedInbox) publishRemovalReceipt(removalID string, signature []byte) ([]byte, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	r := i.removalRecord(removalID)
	if r == nil || !lowerHex(removalID, 32) {
		return nil, errors.New("no such removal on this phone")
	}
	payload, err := base64.StdEncoding.Strict().DecodeString(r.Payload)
	if err != nil {
		return nil, err
	}
	if len(signature) != ed25519.SignatureSize || !ed25519.Verify(i.phoneKey, checkin.SigningInput(checkin.RemovalReceiptDomain, payload), signature) {
		return nil, errors.New("the removal receipt signature is not this phone's")
	}
	name := removalName(removalID)
	if r.Published {
		if existing, e := officepreview.ReadFile(filepath.Join(i.records, filepath.FromSlash(name)), checkin.MaximumMessage); e == nil {
			return existing, nil
		}
	}
	envelope, err := checkin.SealRemovalReceipt(payload, signature)
	if err != nil {
		return nil, err
	}
	if err = i.publish(name, []byte(envelope)); err != nil {
		return nil, err
	}
	if !r.Published {
		r.Published = true
		return []byte(envelope), i.save()
	}
	return []byte(envelope), nil
}

// outboundCheckIn says whether name, in the records folder, is a check-in or a removal receipt
// this phone published and has not withdrawn. The caller holds the lock.
func (i *managedInbox) outboundCheckIn(name string) bool {
	if id, ok := strings.CutSuffix(name, envelopeSuffix); ok {
		if challengeID, ok := strings.CutPrefix(id, "checkin/"); ok && lowerHex(challengeID, 32) {
			c := i.state.CheckIn
			return c != nil && c.Published && c.ChallengeID == challengeID
		}
		if removalID, ok := strings.CutPrefix(id, "removal/"); ok && lowerHex(removalID, 32) {
			r := i.removalRecord(removalID)
			return r != nil && r.Published
		}
	}
	return false
}
