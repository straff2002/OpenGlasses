package mobilecore

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"os"
	"path/filepath"
	"testing"

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
