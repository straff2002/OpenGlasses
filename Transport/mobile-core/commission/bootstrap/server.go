// Package bootstrap is the bootstrap connection of the office commissioning contract
// (Contracts/commissioning.md §3): the office's one-purpose listener on its private-LAN
// address, and the phone's exchange, pinned to the office transport identity the invitation
// names. The messages themselves are package commission's.
//
// The wire protocol is one request, repeated:
//
//	POST /commission/v1/redemption        body: the redemption envelope, exactly as sealed
//	202 {"status":"awaiting"}             until a person decides
//	200 <approval or refusal envelope>    once decided
//
// The phone repeats the identical POST, about every two seconds, until it has a decision or the
// invitation expires. TLS 1.3 only, with the office presenting its transport certificate; the
// phone refuses any certificate whose device identity is not the invitation's officeTransportID.
// Every other path is 404 and every other method on this path 405. A body over the redemption
// cap is 413, a body that is not a redemption of this invitation 400, and requests past the
// listener's total are 429.
package bootstrap

import (
	"crypto/ed25519"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"avenkin.dev/mobilecore/commission"

	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	// Path is the listener's one path.
	Path = "/commission/v1/redemption"
	// PollInterval is how often the phone repeats its request while the office decides.
	PollInterval = 2 * time.Second

	// MaximumConnections is how many connections the listener holds at once; more wait in the
	// kernel's queue.
	MaximumConnections = 8
	// MaximumRequests is how many requests one listener answers in its life. Polling every two
	// seconds for fifteen minutes is 450.
	MaximumRequests = 1024

	serverHeaderTimeout = 5 * time.Second
	serverReadTimeout   = 10 * time.Second
	serverWriteTimeout  = 10 * time.Second
	serverIdleTimeout   = 2 * time.Second
	maximumHeader       = 8192
)

// Config is one invitation's listener.
type Config struct {
	// Invitation is the single-use value issued by the office's invitation ledger: 256 random
	// bits as 43 characters of URL-safe base64 without padding.
	Invitation     string
	OrganizationID string
	// Address is the office's private-LAN IPv4 address, `a.b.c.d` or `a.b.c.d:port`. No port,
	// or port 0, takes a free one. Loopback, wildcard, link-local and public addresses are
	// refused: the listener exists only on the private network.
	Address             string
	IssuedAt, ExpiresAt int64
	// Certificate is the office transport certificate (the sync engine's cert.pem and key.pem).
	// The invitation's officeTransportID is its device identity.
	Certificate tls.Certificate
	// OfficeKey is the office application key. It signs the invitation and the decision.
	OfficeKey ed25519.PrivateKey
	// Notify receives the exchange's events, one at a time and in order: "redemption",
	// "unexpected-use", "approval-ready", "refusal-ready" and "delivered", with the fields
	// documented in converse.go. It is called from one goroutine of its own, never while the
	// exchange is locked, so a slow Notify delays only later events, never a request or Close.
	// Events still queued when the server closes are delivered; none follow. Nil discards them.
	Notify func(map[string]any)
	// Now is the clock in Unix seconds. Nil is the system clock.
	Now func() int64
	// Listen opens the socket. Nil listens on Address after its check. Tests in this module
	// supply a loopback socket; Address must still pass the same check, and the invitation
	// names Address's host with the port the socket got.
	Listen func(network, address string) (net.Listener, error)
}

// Server is one invitation's listener and the state of its one exchange.
type Server struct {
	cfg               Config
	invitation        string
	invitationSHA256  string
	address           string
	officeTransportID string
	http              *http.Server
	served            chan struct{}
	requests          atomic.Int64
	closed            atomic.Bool
	events            *queue

	mu         sync.Mutex
	redemption string
	redeemed   commission.Redemption
	decision   string
	// expired is the `expired` refusal once one has been served for the exchange's own
	// redemption: from then on that is the exchange's answer, and nobody can decide.
	expired    string
	delivered  bool
	unexpected map[string]bool
}

// privateHost checks that `host` is a private-network IPv4 address in canonical dotted form.
func privateHost(host string) bool {
	ip := net.ParseIP(host)
	return ip != nil && ip.To4() != nil && ip.To4().String() == host && ip.IsPrivate()
}

func splitAddress(address string) (host, port string, err error) {
	host, port = address, "0"
	if h, p, e := net.SplitHostPort(address); e == nil {
		host, port = h, p
	}
	n, e := strconv.Atoi(port)
	if e != nil || n < 0 || n > 65535 || strconv.Itoa(n) != port {
		return "", "", errors.New("invalid listener port")
	}
	if !privateHost(host) {
		return "", "", errors.New("the listener must be on this computer's private-network IPv4 address")
	}
	return host, port, nil
}

// Listen checks the configuration, binds the listener, signs the invitation with the address
// it got, and starts answering. Close it when the invitation is cancelled or expires.
func Listen(cfg Config) (*Server, error) {
	if cfg.Now == nil {
		cfg.Now = func() int64 { return time.Now().Unix() }
	}
	if cfg.Notify == nil {
		cfg.Notify = func(map[string]any) {}
	}
	if len(cfg.OfficeKey) != ed25519.PrivateKeySize {
		return nil, errors.New("missing office application key")
	}
	if len(cfg.Certificate.Certificate) == 0 || cfg.Certificate.PrivateKey == nil {
		return nil, errors.New("missing office transport certificate")
	}
	host, port, e := splitAddress(cfg.Address)
	if e != nil {
		return nil, e
	}
	if now := cfg.Now(); now < cfg.IssuedAt || now >= cfg.ExpiresAt {
		return nil, errors.New("the invitation is not live")
	}
	listen := cfg.Listen
	if listen == nil {
		listen = net.Listen
	}
	socket, e := listen("tcp4", net.JoinHostPort(host, port))
	if e != nil {
		return nil, e
	}
	tcp, ok := socket.Addr().(*net.TCPAddr)
	if !ok {
		socket.Close()
		return nil, errors.New("the listener has no TCP port")
	}
	s := &Server{cfg: cfg, served: make(chan struct{}), unexpected: map[string]bool{},
		address:           net.JoinHostPort(host, strconv.Itoa(tcp.Port)),
		officeTransportID: protocol.NewDeviceID(cfg.Certificate.Certificate[0]).String()}
	officePublic := cfg.OfficeKey.Public().(ed25519.PublicKey)
	s.invitation, e = commission.SignInvitation(commission.Invitation{Version: 1, Kind: commission.InvitationKind,
		Invitation: cfg.Invitation, OrganizationID: cfg.OrganizationID, OfficeID: commission.OfficeID(officePublic),
		OfficeApplicationKey: base64.StdEncoding.EncodeToString(officePublic), OfficeTransportID: s.officeTransportID,
		Address: s.address, IssuedAt: cfg.IssuedAt, ExpiresAt: cfg.ExpiresAt}, cfg.OfficeKey)
	if e == nil {
		_, e = commission.ReadInvitation(s.invitation, cfg.Now())
	}
	if e != nil {
		socket.Close()
		return nil, e
	}
	s.invitationSHA256 = commission.Digest(s.invitation)
	s.http = &http.Server{
		Handler:           http.HandlerFunc(s.serveHTTP),
		ReadHeaderTimeout: serverHeaderTimeout,
		ReadTimeout:       serverReadTimeout,
		WriteTimeout:      serverWriteTimeout,
		IdleTimeout:       serverIdleTimeout,
		MaxHeaderBytes:    maximumHeader,
		TLSNextProto:      map[string]func(*http.Server, *tls.Conn, http.Handler){},
		ErrorLog:          log.New(io.Discard, "", 0),
	}
	s.events = newQueue(cfg.Notify)
	listener := tls.NewListener(&limitListener{Listener: socket, slots: make(chan struct{}, MaximumConnections), done: make(chan struct{})},
		&tls.Config{Certificates: []tls.Certificate{cfg.Certificate}, MinVersion: tls.VersionTLS13,
			MaxVersion: tls.VersionTLS13, NextProtos: []string{"http/1.1"}, ClientAuth: tls.NoClientCert})
	go func() {
		defer close(s.served)
		_ = s.http.Serve(listener)
	}()
	return s, nil
}

// Invitation is the signed invitation envelope.
func (s *Server) Invitation() string { return s.invitation }

// InvitationSHA256 is the invitation's digest.
func (s *Server) InvitationSHA256() string { return s.invitationSHA256 }

// QRText is the text of the invitation's QR code.
func (s *Server) QRText() string { return commission.QRText(s.invitation) }

// Address is the `a.b.c.d:port` the listener is on, as the invitation names it.
func (s *Server) Address() string { return s.address }

// OfficeTransportID is the device identity of the certificate the listener presents.
func (s *Server) OfficeTransportID() string { return s.officeTransportID }

// Redeemed returns the first valid redemption, if a phone has sent one.
func (s *Server) Redeemed() (commission.Redemption, string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.redeemed, s.redemption, s.redemption != ""
}

// Decided says whether the office has approved or refused.
func (s *Server) Decided() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.decision != ""
}

// Approve signs the approval for the redeemed phone and serves it from now on. The three
// artefacts are carried unchanged; the peer binding must name the redemption's enrolment and
// identities, which the phone checks. officeAddress is the office sync engine's listener,
// `a.b.c.d:port` on a private IPv4 network: where the phone connects once it is enrolled.
func (s *Server) Approve(profileDocument, licenceCode, peerBinding, officeAddress string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.decidable(); e != nil {
		return "", e
	}
	r := s.redeemed
	approval, e := commission.SignApproval(commission.Approval{Version: 1, Kind: commission.ApprovalKind,
		InvitationSHA256: s.invitationSHA256, RedemptionSHA256: commission.Digest(s.redemption),
		EnrolmentID: r.EnrolmentID, PhoneTransportID: r.PhoneTransportID, PhoneApplicationKey: r.PhoneApplicationKey,
		ProfileDocument: profileDocument, LicenceCode: licenceCode, PeerBinding: peerBinding, OfficeAddress: officeAddress, IssuedAt: s.cfg.Now()}, s.cfg.OfficeKey)
	if e != nil {
		return "", e
	}
	s.decision = approval
	s.events.push(map[string]any{"event": "approval-ready", "peerBinding": peerBinding, "decisionSHA256": commission.Digest(approval)})
	return approval, nil
}

// PersonReasons are the refusals a person or the office's policy may give. `expired` and
// `already_used` are the listener's own.
var PersonReasons = []string{"refused_by_person", "wrong_organisation", "policy"}

// Refuse signs a refusal for the redeemed phone and serves it from now on.
func (s *Server) Refuse(reason string) (string, error) {
	known := false
	for _, r := range PersonReasons {
		known = known || r == reason
	}
	if !known {
		return "", errors.New("unknown refusal reason")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.decidable(); e != nil {
		return "", e
	}
	refusal, e := s.refusal(s.redemption, reason)
	if e != nil {
		return "", e
	}
	s.decision = refusal
	s.events.push(map[string]any{"event": "refusal-ready", "reason": reason, "decisionSHA256": commission.Digest(refusal)})
	return refusal, nil
}

// Decidable says why the office cannot approve or refuse now, or nil if it can. Check it before
// issuing anything for an approval.
func (s *Server) Decidable() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.decidable()
}

func (s *Server) decidable() error {
	if s.expired != "" || s.cfg.Now() >= s.cfg.ExpiresAt {
		return errors.New("the invitation has expired")
	}
	if s.redemption == "" {
		return errors.New("no phone has redeemed this invitation")
	}
	if s.decision != "" {
		return errors.New("this invitation is already decided")
	}
	return nil
}

func (s *Server) refusal(redemption, reason string) (string, error) {
	return commission.SignRefusal(commission.Refusal{Version: 1, Kind: commission.RefusalKind,
		InvitationSHA256: s.invitationSHA256, RedemptionSHA256: commission.Digest(redemption),
		Reason: reason, IssuedAt: s.cfg.Now()}, s.cfg.OfficeKey)
}

// Close stops the listener and every open connection, and waits for the listener (not for
// Notify: events already queued are still delivered, and Flushed says when they have been).
func (s *Server) Close() error {
	s.closed.Store(true)
	e := s.http.Close()
	<-s.served
	s.events.stop()
	return e
}

// Flushed is closed once the server has closed and every queued event has been delivered.
func (s *Server) Flushed() <-chan struct{} { return s.events.done }

func reply(w http.ResponseWriter, status int, body []byte) error {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	if len(body) > 0 {
		h.Set("Content-Type", "application/json")
	}
	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	_, e := w.Write(body)
	return e
}

var awaiting = []byte(`{"status":"awaiting"}`)

func (s *Server) serveHTTP(w http.ResponseWriter, r *http.Request) {
	if s.requests.Add(1) > MaximumRequests {
		_ = reply(w, http.StatusTooManyRequests, nil)
		return
	}
	if r.URL.Path != Path || r.URL.RawQuery != "" {
		_ = reply(w, http.StatusNotFound, nil)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		_ = reply(w, http.StatusMethodNotAllowed, nil)
		return
	}
	body, e := io.ReadAll(http.MaxBytesReader(w, r.Body, commission.MaximumRedemption))
	if e != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(e, &tooLarge) {
			_ = reply(w, http.StatusRequestEntityTooLarge, nil)
		} else {
			_ = reply(w, http.StatusBadRequest, nil)
		}
		return
	}
	redemption := string(body)
	redeemed, e := commission.ReadRedemption(redemption, s.invitation)
	if e != nil {
		_ = reply(w, http.StatusBadRequest, nil)
		return
	}
	status, answer, legitimate := s.answer(redemption, redeemed)
	if e = reply(w, status, answer); e == nil && legitimate {
		s.mu.Lock()
		if !s.delivered && !s.closed.Load() {
			s.delivered = true
			s.events.push(map[string]any{"event": "delivered"})
		}
		s.mu.Unlock()
	}
}

// answer decides what one valid redemption gets. `legitimate` is true when the answer is the
// office's decision for the exchange's own redemption.
func (s *Server) answer(redemption string, redeemed commission.Redemption) (status int, body []byte, legitimate bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed.Load() {
		return http.StatusServiceUnavailable, nil, false
	}
	if s.redemption == redemption && s.decision != "" {
		return http.StatusOK, []byte(s.decision), true
	}
	if s.redemption == redemption && s.expired != "" {
		return http.StatusOK, []byte(s.expired), false
	}
	if s.cfg.Now() >= s.cfg.ExpiresAt {
		status, body, _ := s.refused(redemption, "expired")
		if status == http.StatusOK && s.redemption == redemption {
			s.expired = string(body)
		}
		return status, body, false
	}
	switch {
	case s.redemption == "":
		comparison, e := commission.Comparison(s.invitationSHA256, commission.Digest(redemption))
		if e != nil {
			return http.StatusInternalServerError, nil, false
		}
		s.redemption, s.redeemed = redemption, redeemed
		s.events.push(map[string]any{"event": "redemption", "envelope": redemption,
			"redemptionSHA256": commission.Digest(redemption), "comparison": comparison,
			"enrolmentID": redeemed.EnrolmentID, "phoneTransportID": redeemed.PhoneTransportID,
			"phoneApplicationKey": redeemed.PhoneApplicationKey, "appVersion": redeemed.AppVersion,
			"appBuild": redeemed.AppBuild, "existingEnrolment": redeemed.ExistingEnrolment})
		return http.StatusAccepted, awaiting, false
	case s.redemption == redemption:
		return http.StatusAccepted, awaiting, false
	default:
		// Contract §2.2: a second redemption of the same invitation, by any device, is refused
		// and shown as an unexpected use.
		digest := commission.Digest(redemption)
		if !s.unexpected[digest] {
			s.unexpected[digest] = true
			s.events.push(map[string]any{"event": "unexpected-use", "redemptionSHA256": digest,
				"phoneTransportID": redeemed.PhoneTransportID, "phoneApplicationKey": redeemed.PhoneApplicationKey})
		}
		return s.refused(redemption, "already_used")
	}
}

func (s *Server) refused(redemption, reason string) (int, []byte, bool) {
	refusal, e := s.refusal(redemption, reason)
	if e != nil {
		return http.StatusInternalServerError, nil, false
	}
	return http.StatusOK, []byte(refusal), false
}

// limitListener holds at most cap(slots) connections at once. Close does not wait for a slot.
type limitListener struct {
	net.Listener
	slots     chan struct{}
	done      chan struct{}
	closeOnce sync.Once
}

func (l *limitListener) Accept() (net.Conn, error) {
	select {
	case l.slots <- struct{}{}:
	case <-l.done:
		return nil, net.ErrClosed
	}
	c, e := l.Listener.Accept()
	if e != nil {
		<-l.slots
		return nil, e
	}
	return &limitConn{Conn: c, release: func() { <-l.slots }}, nil
}

func (l *limitListener) Close() error {
	l.closeOnce.Do(func() { close(l.done) })
	return l.Listener.Close()
}

type limitConn struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *limitConn) Close() error {
	e := c.Conn.Close()
	c.once.Do(c.release)
	return e
}

// queue delivers events in the order they were pushed, from one goroutine, so that pushing
// never waits for the receiver.
type queue struct {
	mu      sync.Mutex
	items   []map[string]any
	stopped bool
	wake    chan struct{}
	done    chan struct{}
}

func newQueue(deliver func(map[string]any)) *queue {
	q := &queue{wake: make(chan struct{}, 1), done: make(chan struct{})}
	go func() {
		defer close(q.done)
		for {
			q.mu.Lock()
			items, stopped := q.items, q.stopped
			q.items = nil
			q.mu.Unlock()
			for _, event := range items {
				deliver(event)
			}
			if len(items) > 0 {
				continue
			}
			if stopped {
				return
			}
			<-q.wake
		}
	}()
	return q
}

// push queues an event; after stop it is dropped.
func (q *queue) push(event map[string]any) {
	q.mu.Lock()
	if !q.stopped {
		q.items = append(q.items, event)
	}
	q.mu.Unlock()
	q.signal()
}

// stop accepts no more events; those queued are still delivered, then done closes.
func (q *queue) stop() {
	q.mu.Lock()
	q.stopped = true
	q.mu.Unlock()
	q.signal()
}

func (q *queue) signal() {
	select {
	case q.wake <- struct{}{}:
	default:
	}
}
