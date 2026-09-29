package mobilecore

import (
	"avenkin.dev/mobilecore/labprobe"
	"context"
	"encoding/json"
	"github.com/syncthing/syncthing/lib/protocol"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestManualNoExportAcrossRealEmbeddedEngineAndBEP(t *testing.T) {
	ip := os.Getenv("AVENKIN_MANUAL_TEST_IP")
	if ip == "" {
		t.Skip("requires an explicit private interface for the real embedded-engine probe")
	}
	directory := t.TempDir()
	root := filepath.Join(directory, "peer")
	client, err := NewClient(filepath.Join(directory, "phone"))
	if err != nil {
		t.Fatal(err)
	}
	id, err := protocol.DeviceIDFromString(client.DeviceID())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := labprobe.Run(ctx, root, ip+":0", id); done <- err }()
	var binding []byte
	for len(binding) == 0 {
		binding, _ = os.ReadFile(filepath.Join(root, "office-binding.json"))
		select {
		case err := <-done:
			t.Fatal(err)
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		default:
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err = client.Start(string(binding)); err != nil {
		t.Fatal(err)
	}
	defer client.Stop()
	for {
		raw, err := client.Snapshot()
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(root, "phone-status.json"), []byte(raw), 0600); err != nil {
			t.Fatal(err)
		}
		select {
		case err = <-done:
			if err != nil {
				t.Fatal(err)
			}
			var report map[string]any
			data, _ := os.ReadFile(filepath.Join(root, "result.json"))
			_ = json.Unmarshal(data, &report)
			if report["status"] != "passed" {
				t.Fatal("no real-wire proof")
			}
			installed, _ := os.ReadFile(filepath.Join(client.home, "installed-manual-fixtures", manualName))
			if len(installed) != 4*fixtureBlockSize {
				t.Fatal("verified fixture was not installed outside shared folders")
			}
			return
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(50 * time.Millisecond):
		}
	}
}
