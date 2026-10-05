package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"avenkin.dev/mobilecore/checkin"
	"avenkin.dev/mobilecore/commission"
	"avenkin.dev/mobilecore/commission/bootstrap"
	"avenkin.dev/mobilecore/jobupdate"
	"avenkin.dev/mobilecore/manualassignment"
	"avenkin.dev/mobilecore/officebulk"
	p "avenkin.dev/mobilecore/officepreview"
	"avenkin.dev/mobilecore/officereport"
	"avenkin.dev/mobilecore/recordingbundle"

	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/tlsutil"
)

func TestOneShotOperationsAreUnchanged(t *testing.T) {
	root := t.TempDir()
	for _, request := range []string{`{"op":"status"}`, "{\"op\":\"status\"}\n", "{\n\"op\": \"status\"\n}"} {
		var out bytes.Buffer
		if status := helper([]string{"helper", root}, strings.NewReader(request), &out); status != 0 {
			t.Fatalf("%q: exit %d, %s", request, status, out.String())
		}
		var reply map[string]any
		if json.Unmarshal(out.Bytes(), &reply) != nil || reply["paired"] != false || reply["managedOfficeID"] == "" {
			t.Fatalf("%q: %s", request, out.String())
		}
	}
	for request, want := range map[string]string{
		`{"op":"launch"}`:                        "unknown native operation",
		strings.Repeat(" ", p.MaximumEnvelope+1): "request too large",
	} {
		var out bytes.Buffer
		if status := helper([]string{"helper", root}, strings.NewReader(request), &out); status != 1 || !strings.Contains(out.String(), want) {
			t.Fatalf("%.20q: exit %d, %s", request, status, out.String())
		}
	}
	var out bytes.Buffer
	if helper([]string{"helper", "relative"}, strings.NewReader(`{"op":"status"}`), &out) != 1 || !strings.Contains(out.String(), "root required") {
		t.Fatal("relative root accepted")
	}
}

func loopback(string, string) (net.Listener, error) { return net.Listen("tcp4", "127.0.0.1:0") }
func toLoopback(ctx context.Context, _, address string) (net.Conn, error) {
	_, port, _ := net.SplitHostPort(address)
	return (&net.Dialer{}).DialContext(ctx, "tcp4", "127.0.0.1:"+port)
}

type session struct {
	t      *testing.T
	stdin  *io.PipeWriter
	events chan string
	status chan int
}

func open(t *testing.T, root, first string) *session {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := &session{t: t, stdin: inW, events: make(chan string, 64), status: make(chan int, 1)}
	// Read stdout as the desktop does: continuously.
	go func() {
		scanner := bufio.NewScanner(outR)
		scanner.Buffer(nil, 1<<20)
		for scanner.Scan() {
			s.events <- scanner.Text()
		}
		close(s.events)
	}()
	go func() {
		status := helper([]string{"helper", root}, inR, outW)
		outW.Close()
		s.status <- status
	}()
	t.Cleanup(func() { inW.Close() })
	s.write(first)
	return s
}

func (s *session) write(line string) {
	if _, e := io.WriteString(s.stdin, line+"\n"); e != nil {
		s.t.Fatal(e)
	}
}

func (s *session) next(kind string) map[string]any {
	s.t.Helper()
	var line string
	select {
	case l, ok := <-s.events:
		if !ok {
			s.t.Fatalf("no %s event", kind)
		}
		line = l
	case <-time.After(5 * time.Second):
		s.t.Fatalf("no %s event", kind)
	}
	var event map[string]any
	if e := json.Unmarshal([]byte(line), &event); e != nil || event["event"] != kind {
		s.t.Fatalf("got %s, want %s", line, kind)
	}
	return event
}

func serveLine(t *testing.T, edit func(map[string]any)) (string, string) {
	dir := t.TempDir()
	certificate, key := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	made, e := tlsutil.NewCertificate(certificate, key, "syncthing", 2, false)
	if e != nil {
		t.Fatal(e)
	}
	secret := sha256.Sum256([]byte("invitation"))
	now := time.Now().Unix()
	line := map[string]any{"op": "commission-serve", "invitation": base64.RawURLEncoding.EncodeToString(secret[:]),
		"organizationID": "test-organisation", "address": "192.168.77.10", "issuedAt": now, "expiresAt": now + 900,
		"certificate": certificate, "key": key}
	if edit != nil {
		edit(line)
	}
	b, _ := json.Marshal(line)
	return string(b), protocol.NewDeviceID(made.Certificate[0]).String()
}

func TestCommissionServeRunsOneInvitation(t *testing.T) {
	listen = loopback
	t.Cleanup(func() { listen = nil })
	root := t.TempDir()
	first, transport := serveLine(t, nil)
	s := open(t, root, first)
	invitation := s.next("invitation")
	office, e := p.OpenOffice(root)
	if e != nil {
		t.Fatal(e)
	}
	if invitation["officeTransportID"] != transport || invitation["officeID"] != office.ManagedOfficeID() {
		t.Fatal("invitation is not this office's", invitation)
	}
	envelope, e := commission.ParseQRText(invitation["qr"].(string))
	if e != nil {
		t.Fatal(e)
	}
	i, _ := commission.ReadInvitation(envelope, time.Now().Unix())
	phoneSeed := sha256.Sum256([]byte("phone"))
	phone := ed25519.NewKeyFromSeed(phoneSeed[:])
	red, e := commission.SignRedemption(commission.Redemption{Version: 1, Kind: commission.RedemptionKind,
		InvitationSHA256: commission.Digest(envelope), Invitation: i.Invitation, EnrolmentID: "enrolment-1",
		PhoneTransportID:    protocol.NewDeviceID([]byte("phone")).String(),
		PhoneApplicationKey: base64.StdEncoding.EncodeToString(phone.Public().(ed25519.PublicKey)),
		AppVersion:          "2.4.0", AppBuild: "412", CreatedAt: time.Now().Unix()}, phone)
	if e != nil {
		t.Fatal(e)
	}
	if a, e := bootstrap.Exchange(context.Background(), toLoopback, envelope, red); e != nil || !a.Awaiting {
		t.Fatal("not awaiting", e)
	}
	if s.next("redemption")["enrolmentID"] != "enrolment-1" {
		t.Fatal("redemption event is for another enrolment")
	}
	// A real office issues the binding only for a profile signed by a production vendor key
	// that names this computer's administrator key.
	s.write(`{"op":"approve","profileDocument":"e30=.AAAA","licenceCode":"l.s","officeAddress":"192.168.77.10:22000"}`)
	if message := s.next("error")["message"].(string); !strings.HasPrefix(message, "peer binding: ") {
		t.Fatal(message)
	}
	s.write(`{"op":"refuse","reason":"refused_by_person"}`)
	s.next("refusal-ready")
	a, e := bootstrap.Exchange(context.Background(), toLoopback, envelope, red)
	if e != nil || a.Decision.Refusal == nil || a.Decision.Refusal.Reason != "refused_by_person" {
		t.Fatal("phone did not get the refusal", e)
	}
	s.next("delivered")
	s.stdin.Close()
	if s.next("closed")["reason"] != "cancelled" || <-s.status != 0 {
		t.Fatal("conversation did not end cleanly")
	}
}

func TestCommissionServeRefusesABadStart(t *testing.T) {
	listen = loopback
	t.Cleanup(func() { listen = nil })
	for name, edit := range map[string]func(map[string]any){
		"public address":    func(l map[string]any) { l["address"] = "8.8.8.8" },
		"wildcard address":  func(l map[string]any) { l["address"] = "0.0.0.0" },
		"relative cert":     func(l map[string]any) { l["certificate"] = "cert.pem" },
		"missing key":       func(l map[string]any) { l["key"] = "/nonexistent/key.pem" },
		"unknown field":     func(l map[string]any) { l["port"] = 1 },
		"short invitation":  func(l map[string]any) { l["invitation"] = "abc" },
		"too long":          func(l map[string]any) { l["expiresAt"] = l["issuedAt"].(int64) + 901 },
		"bad organisation":  func(l map[string]any) { l["organizationID"] = "a b" },
		"not yet live":      func(l map[string]any) { l["issuedAt"] = l["issuedAt"].(int64) + 60 },
		"certificate & key": func(l map[string]any) { l["key"] = l["certificate"] },
	} {
		first, _ := serveLine(t, edit)
		s := open(t, t.TempDir(), first)
		s.next("error")
		if s.next("closed")["reason"] != "failed" || <-s.status != 1 {
			t.Fatal(name, "did not fail")
		}
	}
}

func TestSignManagedJobLendsTheApplicationKeyToItsOwnOfficeOnly(t *testing.T) {
	root := t.TempDir()
	office, err := p.OpenOffice(root)
	if err != nil {
		t.Fatal(err)
	}
	device := func(label string) string {
		digest := sha256.Sum256([]byte(label))
		return protocol.DeviceID(digest).String()
	}
	now := p.Now()
	payload := func(officeID string) string {
		// The members in the contract's order, as the desktop writes them.
		ordered := `{"version":1,"kind":"avenkin.managed-job","messageID":"` + strings.Repeat("ab", 16) +
			`","organizationID":"test-organisation","enrolmentID":"phone-1","officeID":"` + officeID +
			`","generation":1,"officeTransportID":"` + device("office") + `","phoneTransportID":"` + device("phone") +
			`","sequence":1,"issuedAt":` + strings.TrimSpace(string(mustJSON(now))) + `,"expiresAt":` + strings.TrimSpace(string(mustJSON(now+3600))) +
			`,"jobSHA256":"` + strings.Repeat("cd", 32) + `","jobBytes":120}`
		return base64.StdEncoding.EncodeToString([]byte(ordered))
	}
	ask := func(body string) (int, map[string]string) {
		var out bytes.Buffer
		status := helper([]string{"helper", root}, strings.NewReader(body), &out)
		var reply map[string]string
		_ = json.Unmarshal(out.Bytes(), &reply)
		return status, reply
	}

	sent := payload(office.ManagedOfficeID())
	status, reply := ask(`{"op":"sign-managed-job","payload":"` + sent + `"}`)
	if status != 0 || reply["envelope"] == "" {
		t.Fatalf("exit %d: %v", status, reply)
	}
	var envelope struct{ Payload, Signature string }
	if json.Unmarshal([]byte(reply["envelope"]), &envelope) != nil || envelope.Payload != sent {
		t.Fatalf("the payload was not signed as sent: %s", reply["envelope"])
	}
	raw, _ := base64.StdEncoding.DecodeString(envelope.Payload)
	signature, _ := base64.StdEncoding.DecodeString(envelope.Signature)
	if !ed25519.Verify(office.Key.Public().(ed25519.PublicKey), append([]byte("Avenkin.ManagedJob.v1\x00"), raw...), signature) {
		t.Fatal("signature does not verify under the office application key")
	}
	// The reply carries nothing but the envelope: no key.
	if len(reply) != 1 {
		t.Fatalf("unexpected members: %v", reply)
	}

	for name, body := range map[string]string{
		"another office": `{"op":"sign-managed-job","payload":"` + payload("another-office") + `"}`,
		"not base64":     `{"op":"sign-managed-job","payload":"***"}`,
		"no payload":     `{"op":"sign-managed-job"}`,
		"not a job":      `{"op":"sign-managed-job","payload":"` + base64.StdEncoding.EncodeToString([]byte(`{"version":1}`)) + `"}`,
	} {
		if status, reply := ask(body); status != 1 || reply["error"] == "" || reply["envelope"] != "" {
			t.Fatalf("%s: exit %d, %v", name, status, reply)
		}
	}
}

func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }

func TestSignCheckInChallengeLendsTheApplicationKeyToItsOwnOfficeOnly(t *testing.T) {
	root := t.TempDir()
	office, err := p.OpenOffice(root)
	if err != nil {
		t.Fatal(err)
	}
	officePublic := office.Key.Public().(ed25519.PublicKey)
	digest := sha256.Sum256([]byte("phone"))
	now := p.Now()
	payload := func(officeID string, issuedAt, expiresAt int64) string {
		raw, _ := json.Marshal(checkin.Challenge{Version: 1, Kind: checkin.ChallengeKind, ChallengeID: strings.Repeat("ab", 16),
			Nonce: base64.RawURLEncoding.EncodeToString(digest[:]), OrganizationID: "test-organisation", EnrolmentID: "phone-1",
			OfficeID: officeID, PhoneTransportID: protocol.DeviceID(digest).String(), Generation: 1,
			BindingSHA256: strings.Repeat("cd", 32), IssuedAt: issuedAt, ExpiresAt: expiresAt})
		return base64.StdEncoding.EncodeToString(raw)
	}
	ask := func(body string) (int, map[string]string) {
		var out bytes.Buffer
		status := helper([]string{"helper", root}, strings.NewReader(body), &out)
		var reply map[string]string
		_ = json.Unmarshal(out.Bytes(), &reply)
		return status, reply
	}
	sent := payload(checkin.OfficeID(officePublic), now, now+3600)
	status, reply := ask(`{"op":"sign-check-in-challenge","payload":"` + sent + `"}`)
	if status != 0 || len(reply) != 1 {
		t.Fatalf("exit %d: %v", status, reply)
	}
	var envelope struct{ Payload, Signature string }
	if json.Unmarshal([]byte(reply["envelope"]), &envelope) != nil || envelope.Payload != sent {
		t.Fatalf("the payload was not signed as sent: %s", reply["envelope"])
	}
	if _, e := checkin.ReadChallenge(reply["envelope"], officePublic); e != nil {
		t.Fatal(e)
	}
	for name, body := range map[string]string{
		"another office": `{"op":"sign-check-in-challenge","payload":"` + payload("office-000000000000000000000000", now, now+3600) + `"}`,
		"expired":        `{"op":"sign-check-in-challenge","payload":"` + payload(checkin.OfficeID(officePublic), now-7200, now-3600) + `"}`,
		"too long":       `{"op":"sign-check-in-challenge","payload":"` + payload(checkin.OfficeID(officePublic), now, now+8*86400) + `"}`,
		"not base64":     `{"op":"sign-check-in-challenge","payload":"***"}`,
		"a managed job":  `{"op":"sign-check-in-challenge","payload":"` + base64.StdEncoding.EncodeToString([]byte(`{"version":1,"kind":"avenkin.managed-job"}`)) + `"}`,
		// The administrator key signs nothing without a vendor-signed profile and a verified exchange.
		"renewal on request":      `{"op":"renew-peer-binding","profileDocument":"x.y","challenge":"{}","checkIn":"{}","binding":"{}"}`,
		"renewal with nothing":    `{"op":"renew-peer-binding"}`,
		"removal without profile": `{"op":"sign-office-removal","payload":"` + base64.StdEncoding.EncodeToString([]byte(`{}`)) + `"}`,
	} {
		if status, reply := ask(body); status != 1 || reply["error"] == "" || len(reply) != 1 {
			t.Fatalf("%s: exit %d, %v", name, status, reply)
		}
	}
}

// The four messages the office application key signs for the managed folders beyond a job and
// a check-in challenge: each is signed as sent, verifies as the phone verifies it, and is
// refused for another office, out of form, under another message's operation, or out of time.
func TestTheApplicationKeySignsEachFolderMessageForItsOwnOfficeOnly(t *testing.T) {
	root := t.TempDir()
	office, err := p.OpenOffice(root)
	if err != nil {
		t.Fatal(err)
	}
	officePublic := office.Key.Public().(ed25519.PublicKey)
	own, other := office.ManagedOfficeID(), "office-000000000000000000000000"
	device := func(label string) string {
		digest := sha256.Sum256([]byte(label))
		return protocol.DeviceID(digest).String()
	}
	now := p.Now()
	encode := func(v any) string { return base64.StdEncoding.EncodeToString(mustJSON(v)) }
	ask := func(op, payload string) (int, map[string]string) {
		var out bytes.Buffer
		status := helper([]string{"helper", root}, strings.NewReader(`{"op":"`+op+`","payload":"`+payload+`"}`), &out)
		var reply map[string]string
		_ = json.Unmarshal(out.Bytes(), &reply)
		return status, reply
	}
	// signed asks for a signature and checks the reply is one envelope over exactly what was sent.
	signed := func(op, payload string) string {
		t.Helper()
		status, reply := ask(op, payload)
		if status != 0 || len(reply) != 1 {
			t.Fatalf("%s: exit %d: %v", op, status, reply)
		}
		var envelope struct{ Payload, Signature string }
		if json.Unmarshal([]byte(reply["envelope"]), &envelope) != nil || envelope.Payload != payload {
			t.Fatalf("%s: the payload was not signed as sent: %s", op, reply["envelope"])
		}
		return reply["envelope"]
	}
	refused := func(op string, cases map[string]string) {
		t.Helper()
		for name, payload := range cases {
			if status, reply := ask(op, payload); status != 1 || reply["error"] == "" || len(reply) != 1 {
				t.Fatalf("%s, %s: exit %d, %v", op, name, status, reply)
			}
		}
	}

	update := func(officeID string, issuedAt, expiresAt int64) jobupdate.Update {
		return jobupdate.Update{Version: 1, Kind: jobupdate.Kind, UpdateID: strings.Repeat("ab", 16),
			OrganizationID: "test-organisation", EnrolmentID: "phone-1", OfficeID: officeID, Generation: 1,
			OfficeTransportID: device("office"), PhoneTransportID: device("phone"), JobID: "job-1", Sequence: 1,
			IssuedAt: issuedAt, ExpiresAt: expiresAt, UpdateKind: jobupdate.KindNote, Body: "Gate code is 4412."}
	}
	message := signed("sign-job-update", encode(update(own, now, now+3600)))
	if _, e := jobupdate.Read(message, jobupdate.Trust{OrganizationID: "test-organisation", EnrolmentID: "phone-1", OfficeID: own,
		OfficeTransportID: device("office"), PhoneTransportID: device("phone"), Generation: 1, OfficeApplicationKey: officePublic}, now); e != nil {
		t.Fatal(e)
	}
	note := update(own, now, now+3600)
	note.Part = "A part on a note"
	refused("sign-job-update", map[string]string{
		"another office":  encode(update(other, now, now+3600)),
		"expired":         encode(update(own, now-7200, now-3600)),
		"from the future": encode(update(own, now+3600, now+7200)),
		"out of form":     encode(note),
		"not base64":      "***",
		"no payload":      "",
	})

	receipt := func(officeID string, receivedAt int64) officereport.Receipt {
		return officereport.Receipt{Version: 1, Kind: officereport.ReceiptKind, ReportID: strings.Repeat("ab", 32),
			ReportSHA256: strings.Repeat("cd", 32), RecordSHA256: strings.Repeat("ef", 32), ManifestSHA256: strings.Repeat("01", 32),
			OrganizationID: "test-organisation", EnrolmentID: "phone-1", OfficeID: officeID, PhoneTransportID: device("phone"),
			Outcome: officereport.OutcomeRecordAccepted, AttachmentsCommitted: 2, AttachmentsOutstanding: 1, ReceivedAt: receivedAt}
	}
	message = signed("sign-report-receipt", encode(receipt(own, now)))
	var sealed struct{ Payload, Signature string }
	_ = json.Unmarshal([]byte(message), &sealed)
	raw, _ := base64.StdEncoding.DecodeString(sealed.Payload)
	signature, _ := base64.StdEncoding.DecodeString(sealed.Signature)
	if !ed25519.Verify(officePublic, officereport.SigningInput(officereport.ReceiptDomain, raw), signature) {
		t.Fatal("the report receipt does not verify under the office application key")
	}
	impossible := receipt(own, now)
	impossible.Outcome = officereport.OutcomeFullyAccepted
	refused("sign-report-receipt", map[string]string{
		"another office":  encode(receipt(other, now)),
		"from the future": encode(receipt(own, now+3600)),
		"counts and outcome that cannot both hold": encode(impossible),
		"a job update": encode(update(own, now, now+3600)),
		"not base64":   "***",
	})

	status := func(officeID string, at int64) recordingbundle.Receipt {
		return recordingbundle.Receipt{Version: 1, Kind: recordingbundle.ReceiptKind, BundleID: strings.Repeat("ab", 16),
			ManifestSHA256: strings.Repeat("cd", 32), OrganizationID: "test-organisation", EnrolmentID: "phone-1",
			OfficeID: officeID, Generation: 1, PhoneTransportID: device("phone"), Status: recordingbundle.StatusReceived, At: at}
	}
	message = signed("sign-recording-receipt", encode(status(own, now)))
	if _, e := recordingbundle.ReadReceipt(message, recordingbundle.Trust{OrganizationID: "test-organisation", EnrolmentID: "phone-1",
		OfficeID: own, PhoneTransportID: device("phone"), Generation: 1, Key: officePublic},
		recordingbundle.Sent{BundleID: strings.Repeat("ab", 16), ManifestSHA256: strings.Repeat("cd", 32), Generation: 1}); e != nil {
		t.Fatal(e)
	}
	reasoned := status(own, now)
	reasoned.Reason = "tooLarge"
	refused("sign-recording-receipt", map[string]string{
		"another office":            encode(status(other, now)),
		"from the future":           encode(status(own, now+3600)),
		"a reason on an acceptance": encode(reasoned),
		"a report receipt":          encode(receipt(own, now)),
		"not base64":                "***",
	})

	assignment := func(officeID string, issuedAt, expiresAt int64) manualassignment.Payload {
		return manualassignment.Payload{Version: 1, Kind: "avenkin.manual-assignment", AssignmentID: strings.Repeat("ab", 16),
			OrganizationID: "test-organisation", EnrolmentID: "phone-1", OfficeID: officeID, Generation: 1, SetID: "service-manuals",
			Sequence: 1, IssuedAt: issuedAt, ExpiresAt: expiresAt, VaultID: "org-vault", VaultVersion: "2027.1",
			PublisherID: "org.test-organisation", ArchiveSHA256: strings.Repeat("cd", 32), ArchiveBytes: 2048}
	}
	message = signed("sign-manual-assignment", encode(assignment(own, now, now+3600)))
	if _, e := manualassignment.Verify([]byte(message), manualassignment.Trust{OrganizationID: "test-organisation", EnrolmentID: "phone-1",
		OfficeID: own, SetID: "service-manuals", Generation: 1, MaximumArchiveBytes: 1 << 20, PublicKey: officePublic}, now, nil); e != nil {
		t.Fatal(e)
	}
	path := assignment(own, now, now+3600)
	path.VaultID = ".."
	refused("sign-manual-assignment", map[string]string{
		"another office":          encode(assignment(other, now, now+3600)),
		"expired":                 encode(assignment(own, now-7200, now-3600)),
		"from the future":         encode(assignment(own, now+3600, now+7200)),
		"a vault named as a path": encode(path),
		"a job update":            encode(update(own, now, now+3600)),
		"not base64":              "***",
	})

	// Each operation signs under its own domain: one message's envelope is not another's.
	if _, e := jobupdate.Read(signed("sign-report-receipt", encode(receipt(own, now))), jobupdate.Trust{OfficeApplicationKey: officePublic}, now); e == nil {
		t.Fatal("a report receipt read as a job update")
	}

	// The administrator key grants a publisher only under a vendor-signed profile that names it.
	grant := encode(officebulk.Grant{Version: 1, Kind: officebulk.GrantKind, GrantID: strings.Repeat("ab", 16),
		OrganizationID: "test-organisation", ProfileID: "profile-1", PublisherID: "org.test-organisation", PublisherName: "Test Organisation",
		PublisherKey: base64.StdEncoding.EncodeToString(officePublic), Sequence: 1, Status: officebulk.StatusActive, IssuedAt: now, ExpiresAt: now + 86400})
	for name, body := range map[string]string{
		"no profile":          `{"op":"sign-publisher-grant","payload":"` + grant + `"}`,
		"an unsigned profile": `{"op":"sign-publisher-grant","profileDocument":"x.y","payload":"` + grant + `"}`,
		"not base64":          `{"op":"sign-publisher-grant","profileDocument":"x.y","payload":"***"}`,
	} {
		var out bytes.Buffer
		status := helper([]string{"helper", root}, strings.NewReader(body), &out)
		var reply map[string]string
		_ = json.Unmarshal(out.Bytes(), &reply)
		if status != 1 || reply["error"] == "" || len(reply) != 1 {
			t.Fatalf("grant, %s: exit %d, %v", name, status, reply)
		}
	}
}
