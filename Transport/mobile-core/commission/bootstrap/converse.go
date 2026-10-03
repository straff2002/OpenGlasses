package bootstrap

// The office helper's commissioning conversation: one invitation (one named slot) per helper
// process, as line-delimited JSON on stdin and stdout. The desktop owns the invitation ledger
// and decides; the helper owns the listener, the TLS certificate and every signature.
//
// The desktop starts the helper with the absolute office-connection root as its one argument
// and writes one line:
//
//	{"op":"commission-serve","invitation":"<43-character token from the ledger>",
//	 "organizationID":"…","address":"a.b.c.d" or "a.b.c.d:port" (private IPv4; no port or 0 = any),
//	 "issuedAt":<unix s>,"expiresAt":<unix s, at most 900 after issuedAt>,
//	 "certificate":"<absolute path to the transport cert.pem>","key":"<absolute path to key.pem>"}
//
// The helper answers with events, one JSON object per line:
//
//	{"event":"invitation","qr":"avenkin-commission:…","invitationSHA256":"…","address":"a.b.c.d:port",
//	 "expiresAt":…,"officeID":"office-…","officeTransportID":"…"}
//	{"event":"redemption","envelope":"…","redemptionSHA256":"…","comparison":"XXXX-XXXX-XXXX",
//	 "enrolmentID":"…","phoneTransportID":"…","phoneApplicationKey":"…","appVersion":"…",
//	 "appBuild":"…","existingEnrolment":"…"}                    the first valid redemption only
//	{"event":"unexpected-use","redemptionSHA256":"…","phoneTransportID":"…","phoneApplicationKey":"…"}
//	                                    another valid redemption of this invitation; that caller
//	                                    is refused with already_used. Once per distinct redemption.
//	{"event":"approval-ready","peerBinding":"…","decisionSHA256":"…"}
//	{"event":"refusal-ready","reason":"…","decisionSHA256":"…"}
//	{"event":"delivered"}               the phone has been sent the decision (once)
//	{"event":"error","message":"…"}     an operation failed; the invitation stays live
//	{"event":"closed","reason":"cancelled"|"expired"|"delivered"|"failed"}   always last
//
// After the redemption event the desktop writes one decision line:
//
//	{"op":"approve","profileDocument":"<vendor-signed schema-2 profile>","licenceCode":"…"}
//	{"op":"refuse","reason":"refused_by_person"|"wrong_organisation"|"policy"}
//
// "approve" issues the administrator-signed peer binding for the redemption's enrolment and the
// phone's identities and this office's transport identity, then signs the approval. If either
// fails the helper writes an error event and the invitation stays live for another decision.
//
// The helper closes the listener and exits when stdin closes or cannot be read (the desktop
// cancelled the slot or quit: "cancelled"), at expiresAt ("expired"), or Linger (10 s) after
// the decision was delivered ("delivered"). The desktop must keep stdin open until it reads
// "closed". A start-up failure is an error event followed by closed "failed", and the process
// exits 1; otherwise it exits 0.

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"time"
)

// Linger is how long the listener stays after its decision was delivered, for a phone whose
// copy of the answer was lost on the way and that asks once more.
var Linger = 10 * time.Second

// maximumLine bounds one decision line: a profile, a licence and JSON around them.
const maximumLine = 64 * 1024

// Issuer issues the administrator-signed peer binding for an approved phone. In the helper it
// is officepreview's (*Office).IssuePeerBinding.
type Issuer func(profileDocument, enrolmentID, officeTransportID, phoneTransportID, phoneApplicationKey string, now int64) (string, error)

// Decision is a line the desktop writes after the redemption event.
type Decision struct {
	Op              string `json:"op"`
	ProfileDocument string `json:"profileDocument"`
	LicenceCode     string `json:"licenceCode"`
	Reason          string `json:"reason"`
}

// Converse runs one invitation as the helper's line conversation: it listens with `cfg`, writes
// events to `out`, reads decisions from `in`, and returns when the listener has closed. The
// returned error is the start-up failure, if any.
func Converse(cfg Config, issue Issuer, in io.Reader, out io.Writer) error {
	var writing sync.Mutex
	encoder := json.NewEncoder(out)
	encoder.SetEscapeHTML(false)
	emit := func(event map[string]any) {
		writing.Lock()
		defer writing.Unlock()
		_ = encoder.Encode(event)
	}
	delivered := make(chan struct{}, 1)
	cfg.Notify = func(event map[string]any) {
		emit(event)
		if event["event"] == "delivered" {
			select {
			case delivered <- struct{}{}:
			default:
			}
		}
	}
	if cfg.Now == nil {
		cfg.Now = func() int64 { return time.Now().Unix() }
	}
	server, e := Listen(cfg)
	if e != nil {
		emit(map[string]any{"event": "error", "message": e.Error()})
		emit(map[string]any{"event": "closed", "reason": "failed"})
		return e
	}
	invitation, _ := Invitation(server.Invitation())
	emit(map[string]any{"event": "invitation", "qr": server.QRText(), "invitationSHA256": server.InvitationSHA256(),
		"address": server.Address(), "expiresAt": cfg.ExpiresAt, "officeID": invitation.OfficeID,
		"officeTransportID": server.OfficeTransportID()})

	lines := make(chan []byte)
	quit := make(chan struct{})
	defer close(quit)
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(in)
		scanner.Buffer(make([]byte, 4096), maximumLine)
		for scanner.Scan() {
			select {
			case lines <- append([]byte(nil), scanner.Bytes()...):
			case <-quit:
				return
			}
		}
		if scanner.Err() != nil {
			emit(map[string]any{"event": "error", "message": "unreadable input: " + scanner.Err().Error()})
		}
	}()
	expiry := time.NewTimer(time.Duration(cfg.ExpiresAt-cfg.Now()) * time.Second)
	defer expiry.Stop()
	var linger <-chan time.Time
	reason := ""
	for reason == "" {
		select {
		case line, open := <-lines:
			if !open {
				reason = "cancelled"
				continue
			}
			if e := decide(server, issue, cfg.Now, line); e != nil {
				emit(map[string]any{"event": "error", "message": e.Error()})
			}
		case <-expiry.C:
			reason = "expired"
		case <-delivered:
			linger = time.After(Linger)
		case <-linger:
			reason = "delivered"
		}
	}
	_ = server.Close()
	emit(map[string]any{"event": "closed", "reason": reason})
	return nil
}

func decide(server *Server, issue Issuer, now func() int64, line []byte) error {
	var d Decision
	if json.Unmarshal(line, &d) != nil {
		return errors.New("invalid decision line")
	}
	switch d.Op {
	case "approve":
		redeemed, _, ok := server.Redeemed()
		if !ok {
			return errors.New("no phone has redeemed this invitation")
		}
		if server.Decided() {
			return errors.New("this invitation is already decided")
		}
		if len(d.ProfileDocument) == 0 || len(d.LicenceCode) == 0 {
			return errors.New("an approval needs the profile document and the licence code")
		}
		if issue == nil {
			return errors.New("this office cannot issue peer bindings")
		}
		binding, e := issue(d.ProfileDocument, redeemed.EnrolmentID, server.OfficeTransportID(),
			redeemed.PhoneTransportID, redeemed.PhoneApplicationKey, now())
		if e != nil {
			return errors.New("peer binding: " + e.Error())
		}
		_, e = server.Approve(d.ProfileDocument, d.LicenceCode, binding)
		return e
	case "refuse":
		_, e := server.Refuse(d.Reason)
		return e
	default:
		return errors.New("unknown commissioning operation")
	}
}
