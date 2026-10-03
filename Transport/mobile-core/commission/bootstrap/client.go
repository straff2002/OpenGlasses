package bootstrap

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"avenkin.dev/mobilecore/commission"

	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	clientTimeout   = 10 * time.Second
	handshakeWithin = 5 * time.Second
)

// Dial opens the TCP connection to the invitation's address.
type Dial func(ctx context.Context, network, address string) (net.Conn, error)

// Answer is what one exchange got back: either the office is still waiting for a person, or
// its verified decision.
type Answer struct {
	Awaiting bool
	Decision commission.Decision
	// Envelope is the decision envelope exactly as received.
	Envelope string
}

// ErrNotTheOffice is returned when the listener's certificate is not the invitation's office
// transport identity.
var ErrNotTheOffice = errors.New("the office's certificate is not the transport identity the invitation names")

// Invitation reads a signed invitation without asking whether it is live: the office enforces
// its own window, and answers an expired one with a signed refusal.
func Invitation(invitationEnvelope string) (commission.Invitation, error) {
	var outer struct {
		Payload string `json:"payload"`
	}
	var inner struct {
		IssuedAt int64 `json:"issuedAt"`
	}
	if len(invitationEnvelope) > commission.MaximumInvitation || json.Unmarshal([]byte(invitationEnvelope), &outer) != nil {
		return commission.Invitation{}, errors.New("invalid invitation")
	}
	payload, e := base64.StdEncoding.Strict().DecodeString(outer.Payload)
	if e != nil || json.Unmarshal(payload, &inner) != nil {
		return commission.Invitation{}, errors.New("invalid invitation")
	}
	return commission.ReadInvitation(invitationEnvelope, inner.IssuedAt)
}

// Exchange sends the redemption once to the office the invitation names and returns its
// answer. It dials only the invitation's address, speaks TLS 1.3 only, and refuses any
// certificate whose device identity is not the invitation's officeTransportID; there is no CA
// validation and no host name. It follows no redirect, uses no proxy and reads at most the
// decision cap. A decision is returned only after commission.ReadDecision has checked it
// against this invitation and this redemption. `dial` nil dials directly.
func Exchange(ctx context.Context, dial Dial, invitationEnvelope, redemptionEnvelope string) (Answer, error) {
	invitation, e := Invitation(invitationEnvelope)
	if e != nil {
		return Answer{}, e
	}
	if _, e = commission.ReadRedemption(redemptionEnvelope, invitationEnvelope); e != nil {
		return Answer{}, e
	}
	office, e := protocol.DeviceIDFromString(invitation.OfficeTransportID)
	if e != nil {
		return Answer{}, e
	}
	if dial == nil {
		dial = (&net.Dialer{Timeout: handshakeWithin}).DialContext
	}
	transport := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			if address != invitation.Address {
				return nil, errors.New("refusing to dial anything but the invitation's address")
			}
			return dial(ctx, "tcp4", invitation.Address)
		},
		TLSClientConfig: &tls.Config{
			// Not CA trust: VerifyConnection pins the leaf certificate to the invitation's
			// office transport identity, as the sync engine does.
			InsecureSkipVerify: true,
			MinVersion:         tls.VersionTLS13,
			MaxVersion:         tls.VersionTLS13,
			NextProtos:         []string{"http/1.1"},
			VerifyConnection: func(state tls.ConnectionState) error {
				if len(state.PeerCertificates) == 0 || protocol.NewDeviceID(state.PeerCertificates[0].Raw) != office {
					return ErrNotTheOffice
				}
				return nil
			},
		},
		TLSNextProto:           map[string]func(string, *tls.Conn) http.RoundTripper{},
		TLSHandshakeTimeout:    handshakeWithin,
		ResponseHeaderTimeout:  handshakeWithin,
		DisableKeepAlives:      true,
		DisableCompression:     true,
		MaxResponseHeaderBytes: maximumHeader,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: clientTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("the office redirected; refused") }}
	request, e := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+invitation.Address+Path, strings.NewReader(redemptionEnvelope))
	if e != nil {
		return Answer{}, e
	}
	request.Header.Set("Content-Type", "application/json")
	response, e := client.Do(request)
	if e != nil {
		if errors.Is(e, ErrNotTheOffice) {
			return Answer{}, ErrNotTheOffice
		}
		return Answer{}, e
	}
	defer response.Body.Close()
	body, e := io.ReadAll(io.LimitReader(response.Body, commission.MaximumDecision+1))
	if e != nil {
		return Answer{}, e
	}
	if len(body) > commission.MaximumDecision {
		return Answer{}, errors.New("the office's answer is too large")
	}
	switch response.StatusCode {
	case http.StatusAccepted:
		var status struct {
			Status string `json:"status"`
		}
		if json.Unmarshal(body, &status) != nil || status.Status != "awaiting" {
			return Answer{}, errors.New("invalid answer from the office")
		}
		return Answer{Awaiting: true}, nil
	case http.StatusOK:
		decision, e := commission.ReadDecision(string(body), invitationEnvelope, redemptionEnvelope)
		if e != nil {
			return Answer{}, e
		}
		return Answer{Decision: decision, Envelope: string(body)}, nil
	default:
		return Answer{}, fmt.Errorf("the office answered %d", response.StatusCode)
	}
}
