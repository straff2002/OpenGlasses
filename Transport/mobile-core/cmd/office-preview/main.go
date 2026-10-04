// Native-owned stdin helper. Signing keys never enter the desktop renderer.
//
// Every operation but one is one JSON request on stdin and one JSON reply on stdout
// ("sign-managed-job" among them: it lends the office application key's signature to a managed-job
// payload the desktop built, after checking it; "sign-check-in-challenge", "renew-peer-binding"
// and "sign-office-removal" are the check-in contract's, each checked here before a key signs). The
// exception is "commission-serve": a long-running, line-delimited conversation for one
// commissioning invitation, whose protocol is documented at the top of
// commission/bootstrap/converse.go.
package main

import (
	"avenkin.dev/mobilecore/checkin"
	"avenkin.dev/mobilecore/commission/bootstrap"
	"avenkin.dev/mobilecore/manageddelivery"
	p "avenkin.dev/mobilecore/officepreview"
	"bufio"
	"bytes"
	"crypto/ed25519"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
)

type Request struct {
	Op                  string     `json:"op"`
	OfficeID            string     `json:"officeID"`
	Address             string     `json:"address"`
	DeviceRecordID      string     `json:"deviceRecordID"`
	Response            string     `json:"response"`
	Comparison          string     `json:"comparison"`
	JobJSON             string     `json:"jobJSON"`
	Manuals             []p.Manual `json:"manuals"`
	Receipt             string     `json:"receipt"`
	ProfileDocument     string     `json:"profileDocument"`
	EnrolmentID         string     `json:"enrolmentID"`
	PhoneTransportID    string     `json:"phoneTransportID"`
	PhoneApplicationKey string     `json:"phoneApplicationKey"`
	// Payload is the exact payload bytes to sign, base64 ("sign-managed-job",
	// "sign-check-in-challenge", "sign-office-removal").
	Payload string `json:"payload"`
	// The exact envelopes of one check-in exchange ("renew-peer-binding").
	Challenge string `json:"challenge"`
	CheckIn   string `json:"checkIn"`
	Binding   string `json:"binding"`
}

// ServeRequest is the first line of a commissioning conversation.
type ServeRequest struct {
	Op             string `json:"op"`
	Invitation     string `json:"invitation"`
	OrganizationID string `json:"organizationID"`
	Address        string `json:"address"`
	IssuedAt       int64  `json:"issuedAt"`
	ExpiresAt      int64  `json:"expiresAt"`
	Certificate    string `json:"certificate"`
	Key            string `json:"key"`
}

// listen is nil in the helper, which listens on the requested private address. Tests bind
// loopback through it.
var listen func(network, address string) (net.Listener, error)

func run(root string, b []byte) (any, error) {
	var r Request
	if e := json.Unmarshal(b, &r); e != nil {
		return nil, e
	}
	o, e := p.OpenOffice(root)
	if e != nil {
		return nil, e
	}
	switch r.Op {
	case "status":
		return o.Public(), nil
	case "administrator-public":
		key, e := p.AdministratorPublicKey(o.Root, false)
		return map[string]string{"administratorPublicKey": key}, e
	case "administrator-create":
		key, e := p.AdministratorPublicKey(o.Root, true)
		return map[string]string{"administratorPublicKey": key}, e
	case "issue-peer-binding":
		s, e := o.IssuePeerBinding(r.ProfileDocument, r.EnrolmentID,
			r.Address, r.PhoneTransportID, r.PhoneApplicationKey, p.Now())
		return map[string]string{"binding": s}, e
	case "invite":
		s, e := o.Invite(r.OfficeID, r.Address, r.DeviceRecordID, p.Now())
		return map[string]string{"invite": s}, e
	case "review":
		res, comparison, e := o.Review(r.Response, p.Now())
		return map[string]string{"phoneID": res.PhoneID, "comparison": comparison}, e
	case "approve":
		s, e := o.Approve(r.Response, r.Comparison, p.Now())
		return map[string]string{"confirmation": s}, e
	case "dispatch":
		id, e := o.Dispatch(r.JobJSON, r.Manuals, filepath.Join(filepath.Dir(o.Root), "content"), p.Now())
		return map[string]string{"messageID": id}, e
	case "publish":
		return o.Public(), o.Publish()
	case "sign-managed-job":
		// The office application key stays here. The desktop sends the payload it built and
		// recorded; it is checked as a phone would check it, and must name this office.
		raw, e := base64.StdEncoding.Strict().DecodeString(r.Payload)
		if e != nil {
			return nil, errors.New("malformed managed job payload")
		}
		envelope, e := manageddelivery.SignPayload(raw, o.Key, o.ManagedOfficeID(), p.Now())
		return map[string]string{"envelope": string(envelope)}, e
	case "sign-check-in-challenge":
		// The office application key signs a check-in challenge the desktop built and recorded,
		// after checking it is one, for this office, and live (Contracts/office-check-in.md §4.1).
		raw, e := base64.StdEncoding.Strict().DecodeString(r.Payload)
		if e != nil {
			return nil, errors.New("malformed check-in challenge payload")
		}
		envelope, e := checkin.SignChallengePayload(raw, o.Key, p.Now())
		return map[string]string{"envelope": envelope}, e
	case "renew-peer-binding":
		// The administrator key stays here, and does not sign a renewed binding on request
		// alone: the challenge, the phone's check-in and the current binding are verified
		// first, and the generation record refuses a binding that is not the latest or an
		// enrolment that was removed (§5).
		binding, result, e := checkin.Renew(o.Authority(), o.Key, r.ProfileDocument, r.Challenge, r.CheckIn, r.Binding, p.Now())
		return map[string]string{"binding": binding, "result": result}, e
	case "sign-office-removal":
		// The administrator key signs a removal the desktop built, for this organisation,
		// profile and office, and marks the enrolment removed before it signs (§8).
		raw, e := base64.StdEncoding.Strict().DecodeString(r.Payload)
		if e != nil {
			return nil, errors.New("malformed removal payload")
		}
		envelope, e := checkin.Remove(o.Authority(), o.Key.Public().(ed25519.PublicKey), r.ProfileDocument, raw, p.Now())
		return map[string]string{"envelope": envelope}, e
	case "receipt":
		if e := o.VerifyReceipt(r.Receipt); e != nil {
			return nil, e
		}
		return o.Public(), nil
	default:
		return nil, errors.New("unknown native operation")
	}
}

// serve runs one commissioning invitation until it closes, and returns the exit status.
func serve(root string, first []byte, in io.Reader, out io.Writer) int {
	var r ServeRequest
	decoder := json.NewDecoder(bytes.NewReader(first))
	decoder.DisallowUnknownFields()
	e := decoder.Decode(&r)
	if e == nil && (!filepath.IsAbs(r.Certificate) || !filepath.IsAbs(r.Key)) {
		e = errors.New("the transport certificate and key need absolute paths")
	}
	var o *p.Office
	if e == nil {
		o, e = p.OpenOffice(root)
	}
	var certificate tls.Certificate
	if e == nil {
		certificate, e = tls.LoadX509KeyPair(r.Certificate, r.Key)
	}
	if e != nil {
		// A start-up failure, in the conversation's own terms.
		for _, event := range []map[string]string{{"event": "error", "message": e.Error()}, {"event": "closed", "reason": "failed"}} {
			b, _ := json.Marshal(event)
			fmt.Fprintln(out, string(b))
		}
		return 1
	}
	cfg := bootstrap.Config{Invitation: r.Invitation, OrganizationID: r.OrganizationID, Address: r.Address,
		IssuedAt: r.IssuedAt, ExpiresAt: r.ExpiresAt, Certificate: certificate, OfficeKey: o.Key, Listen: listen}
	if bootstrap.Converse(cfg, o.IssuePeerBinding, in, out) != nil {
		return 1
	}
	return 0
}

// firstLine reads up to the first newline, or to the end, and at most limit+1 bytes.
func firstLine(in *bufio.Reader, limit int) ([]byte, error) {
	var line []byte
	for len(line) <= limit {
		c, e := in.ReadByte()
		if e == io.EOF {
			return line, nil
		}
		if e != nil {
			return nil, e
		}
		line = append(line, c)
		if c == '\n' {
			return line, nil
		}
	}
	return line, nil
}

func fail(out io.Writer, e error) int {
	b, _ := json.Marshal(map[string]string{"error": e.Error()})
	fmt.Fprintln(out, string(b))
	return 1
}

// helper is the program: one request and one reply, or a commissioning conversation when the
// first line asks for one.
func helper(args []string, stdin io.Reader, stdout io.Writer) int {
	if len(args) != 2 || !filepath.IsAbs(args[1]) {
		return fail(stdout, errors.New("native connection root required"))
	}
	in := bufio.NewReader(stdin)
	b, e := firstLine(in, p.MaximumEnvelope)
	if e != nil {
		return fail(stdout, errors.New("request too large"))
	}
	var op struct {
		Op string `json:"op"`
	}
	if json.Unmarshal(b, &op) == nil && op.Op == "commission-serve" {
		return serve(args[1], b, in, stdout)
	}
	rest, e := io.ReadAll(io.LimitReader(in, int64(p.MaximumEnvelope+1-len(b))))
	if b = append(b, rest...); e != nil || len(b) > p.MaximumEnvelope {
		return fail(stdout, errors.New("request too large"))
	}
	v, e := run(args[1], b)
	if e != nil {
		return fail(stdout, e)
	}
	out, e := json.Marshal(v)
	if e != nil {
		return 1
	}
	fmt.Fprintln(stdout, string(out))
	return 0
}

func main() { os.Exit(helper(os.Args, os.Stdin, os.Stdout)) }
