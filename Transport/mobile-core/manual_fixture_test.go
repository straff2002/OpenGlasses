package mobilecore

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/syncthing/syncthing/lib/fs"
	"os"
	"path/filepath"
	"testing"
)

func TestManualFixtureInstallsOnlyVerifiedBytesOutsideShares(t *testing.T) {
	c := &Client{home: t.TempDir()}
	folder := filepath.Join(c.home, manualFolder)
	if err := os.Mkdir(folder, 0700); err != nil {
		t.Fatal(err)
	}
	data := make([]byte, fixtureBlockSize*2)
	for n := range data {
		data[n] = byte(n % 251)
	}
	all := sha256.Sum256(data)
	first := sha256.Sum256(data[:fixtureBlockSize])
	digest := hex.EncodeToString(all[:])
	job, _ := json.Marshal(map[string]string{"manualSHA256": digest, "manualFirstBlockSHA256": hex.EncodeToString(first[:])})
	if err := os.WriteFile(filepath.Join(folder, fs.TempName(manualName)), data[:fixtureBlockSize], 0600); err != nil {
		t.Fatal(err)
	}
	got, partial, err := c.inspectManualFixture(job)
	if err != nil || got != "" || !partial {
		t.Fatal("partial download was not verified without being installed")
	}
	if err := os.WriteFile(filepath.Join(folder, manualName), data, 0600); err != nil {
		t.Fatal(err)
	}
	got, _, err = c.inspectManualFixture(job)
	if err != nil || got != digest {
		t.Fatal("valid fixture did not install")
	}
	installed, err := os.ReadFile(filepath.Join(c.home, "installed-manual-fixtures", manualName))
	if err != nil || string(installed) != string(data) {
		t.Fatal("installed fixture changed bytes")
	}
	data[0] ^= 1
	if err = os.WriteFile(filepath.Join(folder, manualName), data, 0600); err != nil {
		t.Fatal(err)
	}
	got, _, err = c.inspectManualFixture(job)
	if err != nil || got != "" {
		t.Fatal("tampered fixture was accepted")
	}
}
func TestManualFixtureRefusesSymlinkAndOversize(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "outside")
	if err := os.WriteFile(target, []byte("outside"), 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := boundedFixture(link); err == nil {
		t.Fatal("symlink read was accepted")
	}
	file, err := os.Create(filepath.Join(root, "too-large"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err = file.Truncate(maxManualFixture + 1); err != nil {
		t.Fatal(err)
	}
	if _, err = boundedFixture(file.Name()); err == nil {
		t.Fatal("oversized fixture read was accepted")
	}
}

func TestManualReadToleratesConcurrentCompletionRename(t *testing.T) {
	root := t.TempDir()
	temporary := filepath.Join(root, "partial")
	complete := filepath.Join(root, "complete")
	if err := os.WriteFile(temporary, []byte("fixture bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case <-stop:
				return
			default:
			}
			_ = os.Rename(temporary, complete)
			_ = os.Rename(complete, temporary)
		}
	}()
	defer func() { close(stop); <-done }()
	for n := 0; n < 1000; n++ {
		if _, err := boundedFixture(temporary); err != nil {
			t.Fatalf("ordinary completion rename interrupted polling: %v", err)
		}
	}
}

func TestDesktopAcknowledgementRequiresCurrentNonceAndExactDigest(t *testing.T) {
	home := t.TempDir()
	folder := filepath.Join(home, controlFolder)
	if err := os.Mkdir(folder, 0700); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(map[string]string{"kind": "avenkin-fx0-desktop-verified", "nonce": "fresh", "jobSHA256": "exact"})
	if err := os.WriteFile(filepath.Join(folder, "lab-ack.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if verifiedDesktopNonce(home, "fresh", "exact") != "fresh" {
		t.Fatal("current acknowledgement was not matched")
	}
	if verifiedDesktopNonce(home, "stale", "exact") != "" || verifiedDesktopNonce(home, "fresh", "wrong") != "" {
		t.Fatal("stale acknowledgement advanced the UI")
	}
}
