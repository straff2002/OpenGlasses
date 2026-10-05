package mobilecore

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/protocol"
)

func TestManagedOfficeConfigurationHasNoListenerOrSharedFolders(t *testing.T) {
	client, err := NewClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Stop)
	peer := protocol.NewDeviceID([]byte("managed office"))
	if err := client.StartManagedOffice(peer.String(), "tcp://192.168.1.2:22000"); err != nil {
		t.Fatal(err)
	}
	if client.guard == nil || client.guard.allowedFolder != "" {
		t.Fatal("managed connection has no-export guard missing")
	}
	var status map[string]any
	raw, err := client.Snapshot()
	if err != nil || json.Unmarshal([]byte(raw), &status) != nil || status["managedOffice"] != true || status["sharedFolders"] != float64(0) {
		t.Fatal("managed connection did not report zero shared folders", err, raw)
	}
	conf, err := os.ReadFile(filepath.Join(client.home, "config.xml"))
	if err != nil {
		t.Fatal(err)
	}
	var configuration struct {
		Folders []struct{} `xml:"folder"`
		Options struct {
			Listen []string `xml:"listenAddress"`
		} `xml:"options"`
	}
	if err := xml.Unmarshal(conf, &configuration); err != nil || len(configuration.Folders) != 0 || len(configuration.Options.Listen) != 0 {
		t.Fatal("managed engine created a listener or shared folder", err)
	}
}

func managedPeer(t *testing.T, conf config.Configuration, office protocol.DeviceID) config.DeviceConfiguration {
	t.Helper()
	var found []config.DeviceConfiguration
	for _, d := range conf.Devices {
		if d.DeviceID == office {
			found = append(found, d)
		}
	}
	if len(found) != 1 {
		t.Fatal("expected exactly one office peer", conf.Devices)
	}
	return found[0]
}

func TestManagedOfficeAutomaticConfigurationOnlyDials(t *testing.T) {
	self, office := protocol.NewDeviceID([]byte("phone")), protocol.NewDeviceID([]byte("office"))
	for hint, addresses := range map[string][]string{
		"tcp://192.168.1.2:22000": {"tcp://192.168.1.2:22000", "dynamic"},
		"":                        {"dynamic"},
	} {
		conf, err := managedOfficeConfig(self, office, "automatic", hint)
		if err != nil {
			t.Fatal(err)
		}
		opt := conf.Options
		if len(opt.RawListenAddresses) != 0 || len(conf.Folders) != 0 {
			t.Fatal("automatic managed connection listens or shares", opt.RawListenAddresses, conf.Folders)
		}
		if !opt.GlobalAnnEnabled || !reflect.DeepEqual(opt.RawGlobalAnnServers, managedDiscoveryServers) {
			t.Fatal("automatic managed connection cannot look the office up", opt.RawGlobalAnnServers)
		}
		if !opt.RelaysEnabled || opt.RelayReconnectIntervalM != 1 {
			t.Fatal("automatic managed connection cannot dial the office's relay")
		}
		if opt.LocalAnnEnabled || opt.NATEnabled || len(opt.RawStunServers) != 0 || opt.StunKeepaliveStartS != 0 {
			t.Fatal("automatic managed connection broadcasts or maps a port")
		}
		if conf.GUI.Enabled || opt.CREnabled || opt.URAccepted != -1 || opt.AutoUpgradeIntervalH != 0 || opt.UpgradeToPreReleases || opt.StartBrowser {
			t.Fatal("automatic managed connection has management or telemetry on")
		}
		peers := 0
		for _, d := range conf.Devices {
			if d.DeviceID != self {
				peers++
			}
		}
		peer := managedPeer(t, conf, office)
		if peers != 1 || !reflect.DeepEqual(peer.Addresses, addresses) || peer.Introducer || peer.AutoAcceptFolders || peer.Name != "Avenkin approved office" {
			t.Fatal("automatic managed connection has an unexpected peer", conf.Devices)
		}
	}
}

func TestManagedOfficePrivateLanConfigurationIsUnchanged(t *testing.T) {
	self, office := protocol.NewDeviceID([]byte("phone")), protocol.NewDeviceID([]byte("office"))
	hint := "tcp://192.168.1.2:22000"
	// The configuration StartManagedOffice built before transport policies.
	legacy := networkConfig(self, "lan")
	legacy.Options.RawListenAddresses = []string{}
	device := legacy.Defaults.Device.Copy()
	device.DeviceID, device.Name, device.Addresses = office, "Avenkin approved office", []string{hint}
	device.Introducer, device.AutoAcceptFolders = false, false
	legacy.SetDevice(device)
	conf, err := managedOfficeConfig(self, office, "privateLan", hint)
	// config.New draws a random API key for the GUI, which stays disabled.
	conf.GUI.APIKey = legacy.GUI.APIKey
	if err != nil || !reflect.DeepEqual(conf, legacy) {
		t.Fatal("office network only configuration changed", err)
	}
}

func TestManagedOfficeRouteRefusesUnsignedWidening(t *testing.T) {
	self, office := protocol.NewDeviceID([]byte("phone")), protocol.NewDeviceID([]byte("office"))
	malformed := []string{"dynamic", "tcp://8.8.8.8:22000", "tcp://100.64.0.1:22000", "tcp://127.0.0.1:22000",
		"192.168.1.2:22000", "quic://192.168.1.2:22000", "relay://192.168.1.2:22067", "tcp://192.168.1.2",
		"tcp://192.168.1.2:0", "tcp://192.168.1.2:65536", "tcp://192.168.1.2:022000", "tcp://192.168.1.2:22000/",
		"tcp://user@192.168.1.2:22000", "tcp://[fd00::1]:22000", "tcp://localhost:22000", " tcp://192.168.1.2:22000",
		"TCP://192.168.1.2:22000", "tcp://192.168.1.2:22000?x=1"}
	for _, hint := range append([]string{""}, malformed...) {
		if _, err := managedOfficeConfig(self, office, "privateLan", hint); err == nil {
			t.Errorf("office network only accepted %q", hint)
		}
	}
	for _, hint := range malformed {
		if _, err := managedOfficeConfig(self, office, "automatic", hint); err == nil {
			t.Errorf("automatic accepted %q", hint)
		}
	}
	for _, policy := range []string{"", "lan", "PrivateLan", "private-lan", "Automatic", "forced-relay", "relay"} {
		if _, err := managedOfficeConfig(self, office, policy, "tcp://192.168.1.2:22000"); err == nil {
			t.Errorf("accepted policy %q", policy)
		}
	}
	for _, ok := range []string{"tcp://10.0.0.1:1", "tcp://172.16.5.4:65535", "tcp://192.168.1.2:22000"} {
		for _, policy := range []string{"privateLan", "automatic"} {
			if _, err := managedOfficeConfig(self, office, policy, ok); err != nil {
				t.Errorf("%s refused %q: %v", policy, ok, err)
			}
		}
	}
	client, err := NewClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Stop)
	if err := client.StartManagedOfficeRoute(office.String(), "privateLan", ""); err == nil || client.app != nil || engineActive.Load() {
		t.Fatal("started an office network only connection without its address", err)
	}
}

func TestManagedOfficeRouteAutomaticStartsWithoutListener(t *testing.T) {
	closed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := "https://" + closed.Addr().String() + "/v2/?noannounce"
	closed.Close()
	previous := managedDiscoveryServers
	managedDiscoveryServers = []string{server}
	t.Cleanup(func() { managedDiscoveryServers = previous })

	client, err := NewClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Stop)
	office := protocol.NewDeviceID([]byte("managed office"))
	if err := client.StartManagedOfficeRoute(office.String(), "automatic", ""); err != nil {
		t.Fatal(err)
	}
	if client.guard == nil || client.guard.allowedFolder != "" {
		t.Fatal("managed connection has no-export guard missing")
	}
	var status map[string]any
	raw, err := client.Snapshot()
	if err != nil || json.Unmarshal([]byte(raw), &status) != nil || status["managedOffice"] != true ||
		status["sharedFolders"] != float64(0) || status["networkMode"] != "automatic" || status["running"] != true {
		t.Fatal("automatic managed connection reported unexpected state", err, raw)
	}
	saved, err := os.ReadFile(filepath.Join(client.home, "config.xml"))
	if err != nil {
		t.Fatal(err)
	}
	var configuration struct {
		Folders []struct{} `xml:"folder"`
		Devices []struct {
			ID        string   `xml:"id,attr"`
			Addresses []string `xml:"address"`
		} `xml:"device"`
		Options struct {
			Listen   []string `xml:"listenAddress"`
			Announce []string `xml:"globalAnnounceServer"`
			Global   bool     `xml:"globalAnnounceEnabled"`
			Local    bool     `xml:"localAnnounceEnabled"`
			Relays   bool     `xml:"relaysEnabled"`
			NAT      bool     `xml:"natEnabled"`
		} `xml:"options"`
	}
	if err := xml.Unmarshal(saved, &configuration); err != nil || len(configuration.Folders) != 0 || len(configuration.Options.Listen) != 0 {
		t.Fatal("automatic managed engine created a listener or shared folder", err)
	}
	opt := configuration.Options
	if !reflect.DeepEqual(opt.Announce, []string{server}) || !opt.Global || opt.Local || !opt.Relays || opt.NAT {
		t.Fatal("automatic managed engine saved unexpected discovery options", opt)
	}
	found := false
	for _, d := range configuration.Devices {
		if d.ID == office.String() {
			found = reflect.DeepEqual(d.Addresses, []string{"dynamic"})
		}
	}
	if !found {
		t.Fatal("office is not found through discovery", configuration.Devices)
	}
	client.noteRoute(events.Event{Type: events.DeviceConnected, Data: map[string]string{"id": office.String(), "type": "relay-client"}}, office.String())
	client.Stop()
	raw, err = client.Snapshot()
	if err != nil || json.Unmarshal([]byte(raw), &status) != nil || status["observedConnectionType"] != "" || status["networkMode"] != "" || status["running"] != false {
		t.Fatal("stopped connection still reports a route", err, raw)
	}
}

func TestManagedOfficeRouteClearsOnDisconnect(t *testing.T) {
	client := &Client{}
	office := protocol.NewDeviceID([]byte("office")).String()
	other := protocol.NewDeviceID([]byte("other")).String()
	route := func() string { client.routeMu.Lock(); defer client.routeMu.Unlock(); return client.route }
	client.noteRoute(events.Event{Type: events.DeviceConnected, Data: map[string]string{"id": office, "type": "relay-client"}}, office)
	if route() != "relay-client" {
		t.Fatal("connection route not kept", route())
	}
	client.noteRoute(events.Event{Type: events.DeviceConnected, Data: map[string]string{"id": office, "type": "tcp-client"}}, office)
	client.noteRoute(events.Event{Type: events.DeviceDisconnected, Data: map[string]string{"id": other, "error": "closed"}}, office)
	if route() != "tcp-client" {
		t.Fatal("another device changed the office route", route())
	}
	client.noteRoute(events.Event{Type: events.DeviceDisconnected, Data: map[string]string{"id": office, "error": "closed"}}, office)
	if route() != "" {
		t.Fatal("route kept after the office disconnected", route())
	}
}

func TestDirectConfigHasNoPublicServicesOrDefaultShare(t *testing.T) {
	cfg := directConfig(protocol.NewDeviceID([]byte("synthetic")))
	opt := cfg.Options
	if cfg.GUI.Enabled || len(cfg.Folders) != 0 || opt.GlobalAnnEnabled || opt.LocalAnnEnabled || opt.RelaysEnabled || opt.NATEnabled || opt.CREnabled || opt.URAccepted != -1 || opt.AutoUpgradeIntervalH != 0 || len(opt.RawGlobalAnnServers) != 0 || len(opt.RawStunServers) != 0 {
		t.Fatal("test engine has unintended network defaults")
	}
}

func TestBindingRejectsPublicAndMalformedAddresses(t *testing.T) {
	id := protocol.NewDeviceID([]byte("office")).String()
	for _, addr := range []string{"tcp://8.8.8.8:22000", "https://192.168.1.2:22000", "tcp://192.168.1.2:22000/path", "tcp://user@192.168.1.2:22000", "tcp://localhost:22000", "tcp://192.168.1.2:0"} {
		raw, _ := json.Marshal(binding{DeviceID: id, Address: addr})
		_, _, err := parseBinding(string(raw))
		if err == nil {
			t.Errorf("accepted %s", addr)
		}
	}
	raw, _ := json.Marshal(binding{DeviceID: id, Address: "tcp://192.168.1.2:22000"})
	if _, _, err := parseBinding(string(raw)); err != nil {
		t.Fatal(err)
	}
}

func TestNetworkModesCannotSilentlyBypassRelayOrChangeTrust(t *testing.T) {
	id := protocol.NewDeviceID([]byte("office")).String()
	relayID := protocol.NewDeviceID([]byte("relay")).String()
	for _, b := range []binding{
		{DeviceID: id, Address: "dynamic", Mode: "automatic"},
		{DeviceID: id, Address: "relay://192.0.2.1:22067/?id=" + relayID, Mode: "forced-relay"},
	} {
		raw, _ := json.Marshal(b)
		if _, _, err := parseBinding(string(raw)); err != nil {
			t.Fatal(err)
		}
	}
	for _, b := range []binding{
		{DeviceID: id, Address: "tcp://192.168.1.2:22000", Mode: "automatic"},
		{DeviceID: id, Address: "dynamic", Mode: "forced-relay"},
		{DeviceID: id, Address: "relay://192.0.2.1:22067/?id=" + relayID + "&token=secret", Mode: "forced-relay"},
		{DeviceID: id, Address: "relay://192.0.2.1:22067/?id=invalid", Mode: "forced-relay"},
		{DeviceID: id, Address: "dynamic", Mode: "unknown"},
	} {
		raw, _ := json.Marshal(b)
		if _, _, err := parseBinding(string(raw)); err == nil {
			t.Fatal("accepted invalid route policy")
		}
	}
	cfg := networkConfig(protocol.NewDeviceID([]byte("phone")), "forced-relay")
	opt := cfg.Options
	if len(opt.RawListenAddresses) != 0 || !opt.RelaysEnabled || opt.GlobalAnnEnabled || opt.LocalAnnEnabled || opt.NATEnabled || len(opt.RawStunServers) != 0 {
		t.Fatal("forced relay has a direct route")
	}
	cfg = networkConfig(protocol.NewDeviceID([]byte("phone")), "automatic")
	if !cfg.Options.GlobalAnnEnabled || !cfg.Options.RelaysEnabled || cfg.GUI.Enabled || len(cfg.Folders) != 0 || cfg.Options.CREnabled || cfg.Options.URAccepted != -1 || cfg.Options.AutoUpgradeIntervalH != 0 {
		t.Fatal("automatic mode has unsafe management or telemetry defaults")
	}
}

func TestReceiptBindsExactFixtureBytes(t *testing.T) {
	job := []byte(`{"kind":"avenkin-fx0-synthetic-job","nonce":"0123456789abcdef0123456789abcdef"}`)
	receipt, err := fixtureReceipt(job)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]string
	if err := json.Unmarshal(receipt, &decoded); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(job)
	if decoded["jobSHA256"] != hex.EncodeToString(digest[:]) || decoded["nonce"] != "0123456789abcdef0123456789abcdef" {
		t.Fatal("receipt does not bind the fixture")
	}
	for _, invalid := range [][]byte{[]byte(`{"kind":"real-job"}`), []byte(`{"kind":"avenkin-fx0-synthetic-job","nonce":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"}`), make([]byte, 4097)} {
		if _, err := fixtureReceipt(invalid); err == nil {
			t.Fatal("accepted invalid fixture")
		}
	}
}

// A connection is local only when it is straight to the office and the far end is a private or
// link-local address: never a relay, never a public address, never something that cannot be read.
func TestOnlyADirectConnectionToAPrivateAddressIsLocal(t *testing.T) {
	for _, c := range []struct {
		kind, address string
		local         bool
	}{
		{"tcp-client", "192.168.1.20:22000", true},
		{"tcp-server", "10.0.4.7:51000", true},
		{"quic-client", "172.16.9.1:22000", true},
		{"tcp-client", "[fe80::1%en0]:22000", false}, // a zone is not an address this can read
		{"tcp-client", "[fd12:3456::1]:22000", true},
		{"tcp-client", "169.254.10.2:22000", true},
		{"tcp-client", "203.0.113.9:22000", false},
		{"quic-client", "[2001:db8::1]:22000", false},
		{"tcp-client", "100.64.0.5:22000", false}, // carrier-grade and overlay ranges are not the office's own network
		{"relay-client", "192.168.1.20:22067", false},
		{"relay-server", "10.0.4.7:22067", false},
		{"tcp-client", "192.168.1.20", false},
		{"tcp-client", "", false},
		{"", "192.168.1.20:22000", false},
	} {
		if got := localRoute(c.kind, c.address); got != c.local {
			t.Fatalf("%s to %q: local=%v, want %v", c.kind, c.address, got, c.local)
		}
	}
}
