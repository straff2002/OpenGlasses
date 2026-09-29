package mobilecore

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/syncthing/syncthing/lib/fs"
	"io"
	"os"
	"path/filepath"
)

const manualName = "manual-fixture.bin"
const fixtureBlockSize = 128 * 1024
const maxManualFixture = 1024 * 1024

// Synthetic only. Production uses the signed assignment/manifest and vault
// importer. Both transport staging and installed copies remain non-exportable.
func (c *Client) inspectManualFixture(job []byte) (string, bool, error) {
	var manifest struct {
		SHA   string `json:"manualSHA256"`
		First string `json:"manualFirstBlockSHA256"`
	}
	if err := json.Unmarshal(job, &manifest); err != nil {
		return "", false, err
	}
	if manifest.SHA == "" || manifest.First == "" {
		return "", false, nil
	} // waiting for this run's challenge
	for _, digest := range []string{manifest.SHA, manifest.First} {
		if raw, err := hex.DecodeString(digest); err != nil || len(raw) != sha256.Size {
			return "", false, errors.New("invalid synthetic manual manifest")
		}
	}
	stagingVerified := false
	partial, err := boundedFixture(filepath.Join(c.home, manualFolder, fs.TempName(manualName)))
	if err != nil {
		return "", false, err
	}
	if len(partial) >= fixtureBlockSize {
		h := sha256.Sum256(partial[:fixtureBlockSize])
		stagingVerified = hex.EncodeToString(h[:]) == manifest.First
	}
	complete, err := boundedFixture(filepath.Join(c.home, manualFolder, manualName))
	if err != nil {
		return "", stagingVerified, err
	}
	if len(complete) == 0 {
		return "", stagingVerified, nil
	}
	h := sha256.Sum256(complete)
	if hex.EncodeToString(h[:]) != manifest.SHA {
		return "", stagingVerified, nil
	}
	// Install atomically outside EVERY configured sync folder. Never copy to a
	// report/control share. The request guard also covers retained transport bytes.
	installed := filepath.Join(c.home, "installed-manual-fixtures")
	if err = os.MkdirAll(installed, 0700); err != nil {
		return "", stagingVerified, err
	}
	existing, err := boundedFixture(filepath.Join(installed, manualName))
	if err != nil {
		return "", stagingVerified, err
	}
	previous := sha256.Sum256(existing)
	if previous != h {
		temporary := filepath.Join(installed, "manual.tmp")
		if err = os.WriteFile(temporary, complete, 0600); err != nil {
			return "", stagingVerified, err
		}
		if err = os.Rename(temporary, filepath.Join(installed, manualName)); err != nil {
			return "", stagingVerified, err
		}
	}
	return manifest.SHA, stagingVerified, nil
}

func boundedFixture(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxManualFixture {
		return nil, errors.New("invalid synthetic manual fixture")
	}
	file, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	} // normal completion renamed the temporary file
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !opened.Mode().IsRegular() {
		return nil, errors.New("invalid synthetic manual fixture")
	}
	data, err := io.ReadAll(io.LimitReader(file, maxManualFixture+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxManualFixture {
		return nil, errors.New("invalid synthetic manual fixture")
	}
	return data, nil
}

// This is a lab transport acknowledgement, never a signed business receipt.
func verifiedDesktopNonce(home, nonce, digest string) string {
	data, err := boundedFixture(filepath.Join(home, controlFolder, "lab-ack.json"))
	if err != nil || len(data) > 4096 {
		return ""
	}
	var ack map[string]string
	if json.Unmarshal(data, &ack) != nil || ack["kind"] != "avenkin-fx0-desktop-verified" || ack["nonce"] != nonce || ack["jobSHA256"] != digest {
		return ""
	}
	return nonce
}
