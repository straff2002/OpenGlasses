// Package mobilecore embeds the pinned Syncthing engine for the FX0 lab and a managed,
// certificate-pinned handshake. It exposes no management server, private keys or arbitrary
// folder sharing.
package mobilecore

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"avenkin.dev/mobilecore/commission"
	"avenkin.dev/mobilecore/officepreview"

	"github.com/syncthing/syncthing/lib/build"
	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/svcutil"
	"github.com/syncthing/syncthing/lib/syncthing"
)

const controlFolder = "avenkin-fx0-phone-control"
const reportFolder = "avenkin-fx0-phone-reports"

var engineActive atomic.Bool // Syncthing locations are process-wide.

type Client struct {
	workers   sync.WaitGroup
	guard     *requestGuard
	manualLab bool
	managed   bool
	preview   *officepreview.Phone
	inbox     *managedInbox
	mu        sync.Mutex
	home      string
	id        string
	peer      protocol.DeviceID
	app       *syncthing.App
	cancel    context.CancelFunc
	mode      string
	route     string
	routeMu   sync.Mutex
}

type binding struct {
	ManualLab       bool   `json:"manualLab"`
	DeviceID        string `json:"deviceID"`
	Address         string `json:"address"`
	Mode            string `json:"mode"`
	RequiredNetwork string `json:"requiredNetwork"`
}

func parseBinding(raw string) (binding, protocol.DeviceID, error) {
	var b binding
	if err := json.Unmarshal([]byte(raw), &b); err != nil {
		return b, protocol.EmptyDeviceID, err
	}
	id, err := protocol.DeviceIDFromString(b.DeviceID)
	if err != nil || id == protocol.EmptyDeviceID {
		return b, id, errors.New("invalid office device ID")
	}
	if b.Mode == "" {
		b.Mode = "lan"
	}
	if b.RequiredNetwork != "" && b.RequiredNetwork != "any" && b.RequiredNetwork != "cellular" {
		return b, id, errors.New("invalid required network")
	}
	if b.Mode == "automatic" {
		if b.Address != "dynamic" {
			return b, id, errors.New("automatic mode requires discovery, not a fixed endpoint")
		}
		return b, id, nil
	}
	u, err := url.Parse(b.Address)
	if b.Mode == "forced-relay" {
		if err != nil || u.Scheme != "relay" || u.User != nil || (u.Path != "" && u.Path != "/") || u.Fragment != "" || u.Hostname() == "" || u.Port() == "" {
			return b, id, errors.New("expected selected community relay URI")
		}
		query, err := url.ParseQuery(u.RawQuery)
		if err != nil || len(query["id"]) != 1 || query.Has("token") {
			return b, id, errors.New("expected public relay with pinned identity and no token")
		}
		if relayID, err := protocol.DeviceIDFromString(query.Get("id")); err != nil || relayID == protocol.EmptyDeviceID {
			return b, id, errors.New("invalid relay identity")
		}
		port, err := strconv.Atoi(u.Port())
		if err != nil || port < 1 || port > 65535 {
			return b, id, errors.New("invalid relay port")
		}
		return b, id, nil
	}
	if b.Mode != "lan" || b.RequiredNetwork == "cellular" {
		return b, id, errors.New("invalid LAN mode")
	}
	if err != nil || u.Scheme != "tcp" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		return b, id, errors.New("expected a direct LAN tcp address")
	}
	ip := net.ParseIP(u.Hostname())
	if ip == nil || !ip.IsPrivate() || u.Port() == "" {
		return b, id, errors.New("office address must be a private LAN IP and port")
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port < 1 || port > 65535 {
		return b, id, errors.New("invalid office port")
	}
	if _, err := net.ResolveTCPAddr("tcp", u.Host); err != nil {
		return b, id, err
	}
	return b, id, nil
}

// NewClient creates an identity in the app's private Application Support directory.
func NewClient(home string) (*Client, error) {
	if !filepath.IsAbs(home) {
		return nil, errors.New("expected an absolute app-private path")
	}
	if err := os.MkdirAll(home, 0700); err != nil {
		return nil, err
	}
	cert, err := syncthing.LoadOrGenerateCertificate(filepath.Join(home, "cert.pem"), filepath.Join(home, "key.pem"))
	if err != nil {
		return nil, err
	}
	return &Client{home: home, id: protocol.NewDeviceID(cert.Certificate[0]).String()}, nil
}

func (c *Client) DeviceID() string { return c.id }

// Start accepts one explicit desktop fingerprint and an explicit network mode.
func (c *Client) Start(bindingJSON string) error { return c.start(bindingJSON, nil) }

// The managed office connection's transport policies: the vendor-signed profile's
// officeAuthority.transportPolicy.
const (
	managedPrivateLan = "privateLan"
	managedAutomatic  = "automatic"
)

// managedDiscoveryServers are where a managed phone looks its office up under the automatic
// policy. "default" is Syncthing's public global discovery. Tests point it at a closed port.
var managedDiscoveryServers = []string{"default"}

// StartManagedOffice opens only a certificate-pinned private-LAN connection. It creates no
// folders and cannot receive a job or manual. The native phone caller must reverify its saved
// vendor/administrator binding and live entitlement before invoking this method. It is
// StartManagedOfficeRoute(officeTransportID, "privateLan", address), keeping this method's
// original address check.
func (c *Client) StartManagedOffice(officeTransportID, address string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.startManagedLocked(officeTransportID, managedPrivateLan, address)
}

// StartManagedOfficeRoute opens the certificate-pinned managed connection under the
// vendor-signed transport policy ("privateLan" | "automatic"). lanHint is "" or
// "tcp://a.b.c.d:port" on a private IPv4 network; privateLan requires it. No folder,
// no listener; the caller must re-verify the saved binding and live entitlement first.
//
// Under privateLan the phone dials only lanHint. Under automatic it dials lanHint first when
// there is one, then the addresses global discovery returns for the office, direct or through
// a community relay; it announces nothing and has no NAT mapping or local discovery.
func (c *Client) StartManagedOfficeRoute(officeTransportID, policy, lanHint string) error {
	if err := checkManagedRoute(policy, lanHint); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.startManagedLocked(officeTransportID, policy, lanHint)
}

func (c *Client) startManagedLocked(officeTransportID, policy, lanHint string) error {
	b := binding{DeviceID: officeTransportID, Address: lanHint, Mode: "lan", RequiredNetwork: "any"}
	if policy == managedAutomatic {
		b = binding{DeviceID: officeTransportID, Address: "dynamic", Mode: "automatic"}
	}
	raw, err := json.Marshal(b)
	if err != nil {
		return err
	}
	return c.startLocked(string(raw), nil, &managedRoute{policy: policy, lanHint: lanHint})
}

// managedRoute is a managed start's checked policy and LAN hint, and, when the caller handed
// over a verified binding, the inbox whose two folders the connection carries.
type managedRoute struct {
	policy, lanHint string
	inbox           *managedInbox
}

// StartManagedOfficeFolders opens the managed connection as StartManagedOfficeRoute does, and
// with it the two managed folders the binding calls for (Contracts/office-folders.md): control,
// which this phone only receives, and records, which it only sends. Managed jobs that arrive in
// control are verified against the binding and committed to private storage; nothing is served
// to the office except receipts this phone has published.
//
// bindingJSON is a closed object with organizationID, enrolmentID, officeID, generation,
// officeTransportID, officeApplicationKey and phoneApplicationKey (the keys base64). The native
// caller must have re-verified the saved vendor and administrator binding and the live
// entitlement first: nothing here verifies that chain, and a folder grants nothing by itself.
func (c *Client) StartManagedOfficeFolders(bindingJSON, policy, lanHint string) error {
	if err := checkManagedRoute(policy, lanHint); err != nil {
		return err
	}
	trust, phoneKey, err := parseManagedBinding(bindingJSON, c.id)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.app != nil {
		return errors.New("engine already running")
	}
	inbox, err := openManagedInbox(c.home, trust, phoneKey)
	if err != nil {
		return err
	}
	b := binding{DeviceID: trust.OfficeTransportID, Address: lanHint, Mode: "lan", RequiredNetwork: "any"}
	if policy == managedAutomatic {
		b = binding{DeviceID: trust.OfficeTransportID, Address: "dynamic", Mode: "automatic"}
	}
	raw, err := json.Marshal(b)
	if err != nil {
		return err
	}
	return c.startLocked(string(raw), nil, &managedRoute{policy: policy, lanHint: lanHint, inbox: inbox})
}

// ManagedJobsPending lists the managed jobs this phone has verified and committed and not yet
// given a receipt for, as a JSON array of {messageID, sequence, jobSHA256, receiptPayload}.
// receiptPayload is the exact bytes (base64) the phone application key must sign, after the
// receipt signature domain.
func (c *Client) ManagedJobsPending() (string, error) {
	c.mu.Lock()
	inbox := c.inbox
	c.mu.Unlock()
	if inbox == nil {
		return "[]", nil
	}
	pending, err := inbox.pending()
	if err != nil {
		return "", err
	}
	return stringJSON(pending)
}

// ManagedJobFile returns the committed job-file bytes of one managed job, base64, for the app's
// own job-file review. Committing a job is not accepting it.
func (c *Client) ManagedJobFile(messageID string) (string, error) {
	c.mu.Lock()
	inbox := c.inbox
	c.mu.Unlock()
	if inbox == nil {
		return "", errors.New("no managed office folders are open")
	}
	job, err := inbox.jobFile(messageID)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(job), nil
}

// PublishManagedJobReceipt publishes the receipt for one committed job. signatureBase64 is the
// phone application key's signature over the receipt signature domain followed by the
// receiptPayload ManagedJobsPending gave. A signature that is not this phone's publishes nothing.
func (c *Client) PublishManagedJobReceipt(messageID, signatureBase64 string) error {
	signature, err := base64.StdEncoding.Strict().DecodeString(signatureBase64)
	if err != nil {
		return errors.New("malformed receipt signature")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.inbox == nil || c.app == nil {
		return errors.New("no managed office folders are open")
	}
	if err = c.inbox.publishReceipt(messageID, signature); err != nil {
		return err
	}
	t := c.inbox.trust
	return c.app.Internals.ScanFolderSubdirs(managedFolderID(t.OrganizationID, t.EnrolmentID, t.OfficeID, roleRecords), nil)
}

// checkManagedRoute accepts exactly the policies and hints StartManagedOfficeRoute documents.
func checkManagedRoute(policy, lanHint string) error {
	switch policy {
	case managedPrivateLan:
		if lanHint == "" {
			return errors.New("an office network only connection needs the office's LAN address")
		}
	case managedAutomatic:
		if lanHint == "" {
			return nil
		}
	default:
		return errors.New("unknown office transport policy")
	}
	if address, ok := strings.CutPrefix(lanHint, "tcp://"); !ok || !commission.PrivateAddress(address) {
		return errors.New("office LAN address must be tcp://a.b.c.d:port on a private IPv4 network")
	}
	return nil
}

// managedOfficeConfig is the managed phone's whole engine configuration for one office under
// one transport policy: no listener, no folder, one pinned peer.
func managedOfficeConfig(self, office protocol.DeviceID, policy, lanHint string) (config.Configuration, error) {
	if err := checkManagedRoute(policy, lanHint); err != nil {
		return config.Configuration{}, err
	}
	return buildManagedOfficeConfig(self, office, policy, lanHint), nil
}

// buildManagedOfficeConfig assumes a checked route. StartManagedOffice reaches it with its own
// original address check.
func buildManagedOfficeConfig(self, office protocol.DeviceID, policy, lanHint string) config.Configuration {
	conf := directConfig(self)
	opt := &conf.Options
	// The phone only dials: nothing to announce and no port for an office to dial back.
	opt.RawListenAddresses = []string{}
	addresses := []string{lanHint}
	if policy == managedAutomatic {
		// Look the office up and, if it is reachable only through its community relay, dial
		// that relay as a client. No announcement (no listener), local discovery, NAT or STUN.
		opt.GlobalAnnEnabled = true
		opt.RawGlobalAnnServers = append([]string{}, managedDiscoveryServers...)
		opt.RelaysEnabled, opt.RelayReconnectIntervalM = true, 1
		opt.LocalAnnEnabled, opt.NATEnabled = false, false
		opt.RawStunServers, opt.StunKeepaliveStartS = []string{}, 0
		addresses = []string{"dynamic"}
		if lanHint != "" {
			addresses = []string{lanHint, "dynamic"}
		}
	}
	device := conf.Defaults.Device.Copy()
	device.DeviceID, device.Name, device.Addresses = office, "Avenkin approved office", addresses
	device.Introducer, device.AutoAcceptFolders = false, false
	conf.SetDevice(device)
	return conf
}

func (c *Client) start(bindingJSON string, preview *officepreview.Phone) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.startLocked(bindingJSON, preview, nil)
}

// startLocked starts the lab or office preview engine, or, given a route, the managed office
// connection with buildManagedOfficeConfig.
func (c *Client) startLocked(bindingJSON string, preview *officepreview.Phone, route *managedRoute) (err error) {
	managed := route != nil
	if c.app != nil {
		return errors.New("engine already running")
	}
	b, peer, err := parseBinding(bindingJSON)
	if err != nil {
		return err
	}
	if b.DeviceID == c.id {
		return errors.New("office and phone identities must differ")
	}
	if !engineActive.CompareAndSwap(false, true) {
		return errors.New("another embedded engine is active")
	}
	defer func() {
		if err != nil {
			engineActive.Store(false)
		}
	}()
	build.Version = "v2.1.5"
	if managed {
		build.User = "avenkin-managed-office"
	} else {
		build.User = "avenkin-device-lab"
	}
	locations.SetBaseDir(locations.DataBaseDir, c.home)
	locations.SetBaseDir(locations.ConfigBaseDir, c.home)
	locations.SetBaseDir(locations.UserHomeBaseDir, c.home)
	ctx, cancel := context.WithCancel(context.Background())
	defer func() {
		if err != nil {
			cancel()
			c.workers.Wait()
		}
	}()
	logger := events.NewLogger()
	c.workers.Add(1)
	go func() { defer c.workers.Done(); _ = logger.Serve(ctx) }()
	self, _ := protocol.DeviceIDFromString(c.id)
	var conf config.Configuration
	if managed {
		conf = buildManagedOfficeConfig(self, peer, route.policy, route.lanHint)
	} else {
		conf = networkConfig(self, b.Mode)
		device := conf.Defaults.Device.Copy()
		device.DeviceID, device.Name, device.Addresses = peer, "Avenkin synthetic office", []string{b.Address}
		device.Introducer, device.AutoAcceptFolders = false, false
		conf.SetDevice(device)
	}
	// The managed folders: control is received, records is sent, and each has its own path.
	type managedFolder struct {
		id, label, path string
		mode            config.FolderType
	}
	var managedFolders []managedFolder
	if managed && route.inbox != nil {
		t := route.inbox.trust
		managedFolders = []managedFolder{
			{managedFolderID(t.OrganizationID, t.EnrolmentID, t.OfficeID, roleControl), roleControl, route.inbox.control, config.FolderTypeReceiveOnly},
			{managedFolderID(t.OrganizationID, t.EnrolmentID, t.OfficeID, roleRecords), roleRecords, route.inbox.records, config.FolderTypeSendOnly},
		}
	}
	for _, spec := range managedFolders {
		folder := conf.Defaults.Folder.Copy()
		folder.ID, folder.Label, folder.Path, folder.Type = spec.id, spec.label, spec.path, spec.mode
		folder.FSWatcherEnabled, folder.IgnorePerms, folder.RescanIntervalS = false, true, 60
		folder.Devices = []config.FolderDeviceConfiguration{{DeviceID: self}, {DeviceID: peer}}
		if err = os.MkdirAll(filepath.Join(folder.Path, ".stfolder"), 0700); err != nil {
			return err
		}
		conf.SetFolder(folder)
	}
	folders := []struct {
		id   string
		mode config.FolderType
	}{}
	if !managed {
		folders = append(folders, struct {
			id   string
			mode config.FolderType
		}{controlFolder, config.FolderTypeReceiveOnly}, struct {
			id   string
			mode config.FolderType
		}{reportFolder, config.FolderTypeSendOnly})
	}
	if b.ManualLab {
		folders = append(folders, struct {
			id   string
			mode config.FolderType
		}{manualFolder, config.FolderTypeReceiveOnly})
	}
	if preview != nil {
		i, e := preview.Binding()
		if e != nil {
			return e
		}
		in, out, manuals := officepreview.Folders(i.PairID)
		folders = []struct {
			id   string
			mode config.FolderType
		}{{in, config.FolderTypeReceiveOnly}, {out, config.FolderTypeSendOnly}, {manuals, config.FolderTypeReceiveOnly}}
	}
	for _, spec := range folders {
		folder := conf.Defaults.Folder.Copy()
		folder.ID, folder.Label, folder.Path, folder.Type = spec.id, "Synthetic fixtures only", filepath.Join(c.home, spec.id), spec.mode
		folder.FSWatcherEnabled, folder.IgnorePerms, folder.RescanIntervalS = false, true, 1
		folder.Devices = []config.FolderDeviceConfiguration{{DeviceID: self}, {DeviceID: peer}}
		if err = os.MkdirAll(filepath.Join(folder.Path, ".stfolder"), 0700); err != nil {
			return err
		}
		conf.SetFolder(folder)
	}
	wrapper := config.Wrap(filepath.Join(c.home, "config.xml"), conf, self, logger)
	c.workers.Add(1)
	go func() { defer c.workers.Done(); _ = wrapper.Serve(ctx) }()
	if err = wrapper.Save(); err != nil {
		return err
	}
	cert, err := syncthing.LoadOrGenerateCertificate(filepath.Join(c.home, "cert.pem"), filepath.Join(c.home, "key.pem"))
	if err != nil {
		return err
	}
	database, err := syncthing.OpenDatabase(locations.Get(locations.Database), 4320*time.Hour)
	if err != nil {
		return err
	}
	app, err := syncthing.New(wrapper, database, logger, cert, syncthing.Options{NoUpgrade: true, ModelWrapper: func(m model.Model) model.Model {
		c.guard = &requestGuard{Model: m}
		if managed && route.inbox != nil {
			// Only what this phone published in records may be served; nothing it received.
			t := route.inbox.trust
			c.guard.allowedFolder = managedFolderID(t.OrganizationID, t.EnrolmentID, t.OfficeID, roleRecords)
			c.guard.allowedName = route.inbox.outbound
		} else if managed {
			// The handshake-only connection has no folder and serves nothing.
			c.guard.allowedName = func(string) bool { return false }
		}
		if preview != nil {
			i, _ := preview.Binding()
			_, out, _ := officepreview.Folders(i.PairID)
			c.guard.allowedFolder = out
		}
		return c.guard
	}})
	if err != nil {
		database.Close()
		return err
	}
	subscription := logger.Subscribe(events.DeviceConnected | events.DeviceDisconnected)
	c.workers.Add(1)
	go func() {
		defer c.workers.Done()
		defer subscription.Unsubscribe()
		for ctx.Err() == nil {
			if event, err := subscription.Poll(time.Second); err == nil {
				c.noteRoute(event, b.DeviceID)
			}
		}
	}()
	if err = app.Start(); err != nil {
		app.Stop(svcutil.ExitError)
		return err
	}
	c.app, c.cancel, c.peer, c.mode, c.manualLab, c.preview, c.managed = app, cancel, peer, b.Mode, b.ManualLab, preview, managed
	if managed && route.inbox != nil {
		c.inbox = route.inbox
		inbox := route.inbox
		// Take in what has arrived. Arrival order means nothing; the inbox applies sequence.
		c.workers.Add(1)
		go func() {
			defer c.workers.Done()
			ticker := time.NewTicker(time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					_, _ = inbox.sweep(time.Now().Unix())
				}
			}
		}()
	}
	return nil
}

// noteRoute keeps the office connection's type (tcp-/quic-/relay- with client/server) while it
// is up. Syncthing sends DeviceDisconnected only when the device's last connection closes.
func (c *Client) noteRoute(event events.Event, office string) {
	data, ok := event.Data.(map[string]string)
	if !ok || data["id"] != office {
		return
	}
	route := ""
	if event.Type == events.DeviceConnected {
		route = data["type"]
	}
	c.routeMu.Lock()
	c.route = route
	c.routeMu.Unlock()
}

func networkConfig(id protocol.DeviceID, mode string) config.Configuration {
	conf := directConfig(id)
	opt := &conf.Options
	if mode == "automatic" {
		opt.RawListenAddresses = []string{"tcp://0.0.0.0:0", "quic://0.0.0.0:0", "dynamic+https://relays.syncthing.net/endpoint"}
		opt.RawGlobalAnnServers, opt.RawStunServers = []string{"default"}, []string{"default"}
		opt.GlobalAnnEnabled, opt.LocalAnnEnabled, opt.RelaysEnabled, opt.NATEnabled = true, true, true, true
		opt.StunKeepaliveStartS, opt.RelayReconnectIntervalM = 180, 1
	} else if mode == "forced-relay" {
		// Outbound only to the desktop's selected relay; no direct listener,
		// dynamic peer lookup, NAT, STUN or local discovery can bypass it.
		opt.RawListenAddresses = []string{}
		opt.RelaysEnabled = true
	}
	return conf
}

func directConfig(id protocol.DeviceID) config.Configuration {
	conf := config.New(id)
	conf.Folders = nil
	conf.GUI.Enabled = false
	opt := &conf.Options
	opt.RawListenAddresses = []string{"tcp://0.0.0.0:0"}
	opt.RawGlobalAnnServers, opt.RawStunServers = []string{}, []string{}
	opt.GlobalAnnEnabled, opt.LocalAnnEnabled, opt.RelaysEnabled, opt.NATEnabled = false, false, false, false
	opt.StartBrowser, opt.CREnabled, opt.UpgradeToPreReleases = false, false, false
	opt.URAccepted, opt.AutoUpgradeIntervalH, opt.StunKeepaliveStartS = -1, 0, 0
	opt.CRURL, opt.URURL, opt.ReleasesURL = "", "", ""
	opt.ReconnectIntervalS = 5
	return conf
}

// Snapshot returns public test evidence only; no keys, paths, or logs.
func (c *Client) Snapshot() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	status := map[string]any{"deviceID": c.id, "engineVersion": "v2.1.5", "running": c.app != nil, "connected": false, "receivedJob": false, "receiptPublished": false}
	status["networkMode"] = c.mode
	status["managedOffice"] = c.managed
	status["engineExtension"] = "avenkin-model-hook.1"
	if c.guard != nil {
		status["outboundGuardActive"] = true
		status["outboundRequestsDenied"] = c.guard.denied.Load()
		status["temporaryRequestsDenied"] = c.guard.temporaryDenied.Load()
		status["manualRequestsDenied"] = c.guard.manualDenied.Load()
	}
	c.routeMu.Lock()
	status["observedConnectionType"] = c.route
	c.routeMu.Unlock()
	if c.app != nil {
		status["connected"] = c.app.Internals.IsConnectedTo(c.peer)
	}
	if c.preview != nil {
		if i, e := c.preview.Binding(); e == nil {
			in, out, manuals := officepreview.Folders(i.PairID)
			path := filepath.Join(c.home, in, "delivery.json")
			if raw, e := officepreview.ReadFile(path, officepreview.MaximumEnvelope); e == nil {
				ready, e := c.preview.Receive(string(raw), filepath.Join(c.home, manuals), officepreview.Now())
				if e != nil {
					status["deliveryError"] = e.Error()
				} else if ready && c.app != nil {
					destination := filepath.Join(c.home, out, "receipt.json")
					previous, _ := officepreview.ReadFile(destination, officepreview.MaximumEnvelope)
					if string(previous) != c.preview.State.Receipt {
						if e = officepreview.Atomic(destination, []byte(c.preview.State.Receipt)); e != nil {
							return "", e
						}
						if e = c.app.Internals.ScanFolderSubdirs(out, nil); e != nil {
							return "", e
						}
					}
				}
			} else if !os.IsNotExist(e) {
				status["deliveryError"] = e.Error()
			}
		}
		status["officePreview"] = c.preview.Public()
		return stringJSON(status)
	}
	if c.managed {
		status["sharedFolders"] = 0
		if c.inbox != nil {
			status["sharedFolders"] = 2
			status["managedJobsCommitted"], status["managedReceiptsPublished"] = c.inbox.counts()
		}
		return stringJSON(status)
	}
	jobPath := filepath.Join(c.home, controlFolder, "job.json")
	info, err := os.Lstat(jobPath)
	if err == nil {
		if !info.Mode().IsRegular() || info.Size() > 4096 {
			return "", errors.New("invalid synthetic fixture file")
		}
		data, err := os.ReadFile(jobPath)
		if err != nil {
			return "", err
		}
		receipt, err := fixtureReceipt(data)
		if err != nil {
			return "", err
		}
		status["receivedJob"] = true
		var parsed map[string]string
		_ = json.Unmarshal(receipt, &parsed)
		if c.manualLab {
			digest, staged, err := c.inspectManualFixture(data)
			if err != nil {
				return "", err
			}
			status["manualSHA256"], status["manualStagingVerified"] = digest, staged
			if digest != "" {
				parsed["manualSHA256"] = digest
				receipt, _ = json.Marshal(parsed)
			}
		}
		status["jobSHA256"], status["nonce"] = parsed["jobSHA256"], parsed["nonce"]
		status["desktopVerifiedNonce"] = verifiedDesktopNonce(c.home, parsed["nonce"], parsed["jobSHA256"])
		dest := filepath.Join(c.home, reportFolder, "receipt.json")
		previous, _ := os.ReadFile(dest)
		if string(previous) != string(receipt) {
			if c.app == nil {
				return stringJSON(status)
			}
			// Stage outside the shared folder, then publish atomically.
			staging := filepath.Join(c.home, "receipt.tmp")
			if err := os.WriteFile(staging, receipt, 0600); err != nil {
				return "", err
			}
			if err := os.Rename(staging, dest); err != nil {
				return "", err
			}
			if err := c.app.Internals.ScanFolderSubdirs(reportFolder, nil); err != nil {
				return "", err
			}
		}
		status["receiptPublished"] = true
	} else if !os.IsNotExist(err) {
		return "", err
	}
	return stringJSON(status)
}

func fixtureReceipt(data []byte) ([]byte, error) {
	var job struct {
		Kind  string `json:"kind"`
		Nonce string `json:"nonce"`
	}
	if len(data) > 4096 || json.Unmarshal(data, &job) != nil || job.Kind != "avenkin-fx0-synthetic-job" || len(job.Nonce) != 32 {
		return nil, errors.New("expected an Avenkin synthetic job")
	}
	if _, err := hex.DecodeString(job.Nonce); err != nil {
		return nil, fmt.Errorf("invalid test nonce: %w", err)
	}
	digest := sha256.Sum256(data)
	return json.Marshal(map[string]string{"kind": "avenkin-fx0-synthetic-receipt", "nonce": job.Nonce, "jobSHA256": hex.EncodeToString(digest[:])})
}

func stringJSON(value any) (string, error) {
	data, err := json.Marshal(value)
	return string(data), err
}

func (c *Client) Stop() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.app != nil {
		c.app.Stop(svcutil.ExitSuccess)
		c.cancel()
		c.workers.Wait()
		c.app, c.cancel = nil, nil
		c.managed, c.mode, c.inbox = false, "", nil
		engineActive.Store(false)
	}
	c.routeMu.Lock()
	c.route = ""
	c.routeMu.Unlock()
}

// BeginOfficePairing proves the companion's application-key possession. Human
// comparison and desktop approval are required before any preview folders start.
func (c *Client) BeginOfficePairing(invite string) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.app != nil {
		return "", errors.New("stop the current connection before pairing")
	}
	p, e := officepreview.OpenPhone(filepath.Join(c.home, "OfficePreview"), c.id)
	if e != nil {
		return "", e
	}
	response, comparison, e := p.Respond(invite, officepreview.Now())
	if e != nil {
		return "", e
	}
	c.preview = p
	return stringJSON(map[string]string{"response": response, "comparison": comparison, "phoneID": c.id})
}
func (c *Client) ConfirmOfficePairing(confirmation string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.app != nil {
		return errors.New("stop the current connection before confirming")
	}
	p, e := officepreview.OpenPhone(filepath.Join(c.home, "OfficePreview"), c.id)
	if e != nil {
		return e
	}
	if e = p.Confirm(confirmation, officepreview.Now()); e != nil {
		return e
	}
	c.preview = p
	return nil
}
func (c *Client) StartOffice() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	p, e := officepreview.OpenPhone(filepath.Join(c.home, "OfficePreview"), c.id)
	if e != nil {
		return e
	}
	i, e := p.Binding()
	if e != nil {
		return e
	}
	raw, e := json.Marshal(binding{DeviceID: i.OfficeID, Address: i.Address, Mode: "lan", RequiredNetwork: "any"})
	if e != nil {
		return e
	}
	return c.startLocked(string(raw), p, nil)
}
func (c *Client) OfficePairingStatus() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	p, e := officepreview.OpenPhone(filepath.Join(c.home, "OfficePreview"), c.id)
	if e != nil {
		return "", e
	}
	if p.State.Confirmation != "" {
		if _, e = p.Binding(); e != nil {
			return "", e
		}
	}
	if c.app == nil && p.State.Invite != "" {
		c.preview = p
	}
	return stringJSON(p.Public())
}
func (c *Client) CancelOfficePairing() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.app != nil {
		return errors.New("stop the current connection first")
	}
	p, e := officepreview.OpenPhone(filepath.Join(c.home, "OfficePreview"), c.id)
	if e != nil {
		return e
	}
	if p.State.Confirmation != "" {
		return errors.New("paired devices require a separate revocation flow")
	}
	p.State.Invite = ""
	p.State.Response = ""
	if e = p.CancelPending(); e != nil {
		return e
	}
	c.preview = nil
	return nil
}

// OpenOfficeManual returns only a byte-verified, native-owned viewer copy from the
// current signed delivery. There is no path or peer-supplied filename parameter.
func (c *Client) OpenOfficeManual(manualID string) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	p, e := officepreview.OpenPhone(filepath.Join(c.home, "OfficePreview"), c.id)
	if e != nil {
		return "", e
	}
	if _, e = p.Binding(); e != nil {
		return "", e
	}
	if e = officepreview.ValidateManuals(p.State.Manuals); e != nil {
		return "", e
	}
	if p.State.Receipt == "" {
		return "", errors.New("manual delivery has not committed")
	}
	for _, m := range p.State.Manuals {
		if m.ID == manualID {
			b, e := officepreview.ReadFile(filepath.Join(p.Root, "library", m.SourceSHA256), m.Bytes)
			if e != nil {
				return "", e
			}
			if int64(len(b)) != m.Bytes || officepreview.Digest(b) != m.SourceSHA256 {
				return "", errors.New("saved manual integrity check failed")
			}
			path := filepath.Join(p.Root, "viewer", m.SourceSHA256+"."+m.Format)
			if e = officepreview.Atomic(path, b); e != nil {
				return "", e
			}
			return path, nil
		}
	}
	return "", errors.New("manual is not in the current delivery")
}
