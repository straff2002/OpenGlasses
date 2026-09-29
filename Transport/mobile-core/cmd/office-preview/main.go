// Native-owned stdin helper. Signing keys never enter the desktop renderer.
package main

import (
	p "avenkin.dev/mobilecore/officepreview"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
}

func run() (any, error) {
	if len(os.Args) != 2 || !filepath.IsAbs(os.Args[1]) {
		return nil, errors.New("native connection root required")
	}
	b, e := io.ReadAll(io.LimitReader(os.Stdin, p.MaximumEnvelope+1))
	if e != nil || len(b) > p.MaximumEnvelope {
		return nil, errors.New("request too large")
	}
	var r Request
	if e = json.Unmarshal(b, &r); e != nil {
		return nil, e
	}
	o, e := p.OpenOffice(os.Args[1])
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
	case "receipt":
		if e := o.VerifyReceipt(r.Receipt); e != nil {
			return nil, e
		}
		return o.Public(), nil
	default:
		return nil, errors.New("unknown native operation")
	}
}
func main() {
	v, e := run()
	if e != nil {
		b, _ := json.Marshal(map[string]string{"error": e.Error()})
		fmt.Println(string(b))
		os.Exit(1)
	}
	b, e := json.Marshal(v)
	if e != nil {
		os.Exit(1)
	}
	fmt.Println(string(b))
}
