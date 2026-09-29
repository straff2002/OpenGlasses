// Package labprobe is an adversarial synthetic BEP fixture peer, not an office server.
package labprobe

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
	"github.com/syncthing/syncthing/lib/tlsutil"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const Control = "avenkin-fx0-phone-control"
const Reports = "avenkin-fx0-phone-reports"
const Manual = "avenkin-fx0-phone-manual"
const ManualName = "manual-fixture.bin"
const BlockSize = 128 * 1024

// Run accepts only the explicitly supplied phone fingerprint. Status is public
// evidence copied by the harness; payloads always cross authenticated TLS/BEP.
func Run(ctx context.Context, root, address string, phone protocol.DeviceID) (map[string]any, error) {
	if err := os.Mkdir(root, 0700); err != nil {
		return nil, err
	}
	cert, err := syncthing.LoadOrGenerateCertificate(filepath.Join(root, "cert.pem"), filepath.Join(root, "key.pem"))
	if err != nil {
		return nil, err
	}
	id := protocol.NewDeviceID(cert.Certificate[0])
	cfg := tlsutil.SecureDefaultTLS13()
	cfg.Certificates = []tls.Certificate{cert}
	cfg.ClientAuth = tls.RequireAnyClientCert
	cfg.NextProtos = []string{"bep/1.0"}
	cfg.InsecureSkipVerify = true // fingerprint verified below
	listener, err := tls.Listen("tcp", address, cfg)
	if err != nil {
		return nil, err
	}
	defer listener.Close()
	go func() { <-ctx.Done(); listener.Close() }()
	manual := make([]byte, 4*BlockSize)
	if _, err = rand.Read(manual); err != nil {
		return nil, err
	}
	nonceBytes := make([]byte, 16)
	if _, err = rand.Read(nonceBytes); err != nil {
		return nil, err
	}
	nonce := hex.EncodeToString(nonceBytes)
	digest := sha256.Sum256(manual)
	first := sha256.Sum256(manual[:BlockSize])
	manualDigest := hex.EncodeToString(digest[:])
	job, _ := json.Marshal(map[string]string{"kind": "avenkin-fx0-synthetic-job", "nonce": nonce, "manualSHA256": manualDigest, "manualFirstBlockSHA256": hex.EncodeToString(first[:])})
	jobDigest := sha256.Sum256(job)
	binding, _ := json.Marshal(map[string]any{"deviceID": id.String(), "address": "tcp://" + listener.Addr().String(), "mode": "lan", "requiredNetwork": "any", "manualLab": true})
	if err = os.WriteFile(filepath.Join(root, "office-binding.json"), binding, 0600); err != nil {
		return nil, err
	}
	wire, err := listener.Accept()
	if err != nil {
		return nil, err
	}
	defer wire.Close()
	secure := wire.(*tls.Conn)
	if err = secure.HandshakeContext(ctx); err != nil {
		return nil, err
	}
	state := secure.ConnectionState()
	if len(state.PeerCertificates) != 1 || protocol.NewDeviceID(state.PeerCertificates[0].Raw) != phone {
		return nil, errors.New("unapproved phone identity")
	}
	if _, err = protocol.ExchangeHello(secure, protocol.Hello{DeviceName: "Avenkin synthetic manual probe", ClientName: "avenkin-manual-probe", ClientVersion: "v2.1.5", NumConnections: 1, Timestamp: time.Now().UnixNano()}); err != nil {
		return nil, err
	}
	source := &fixturePeer{files: map[string][]byte{Control: job, Manual: manual}, release: make(chan struct{}), configured: make(chan struct{}), id: id}
	info := connectionInfo{conn: secure, established: time.Now()}
	conn := protocol.NewConnection(phone, secure, secure, secure, source, info, protocol.CompressionNever, protocol.NewKeyGenerator())
	defer conn.Close(errors.New("synthetic experiment complete"))
	conn.Start()
	folders := []protocol.Folder{}
	for _, folder := range []string{Control, Reports, Manual} {
		folders = append(folders, protocol.Folder{ID: folder, Type: protocol.FolderTypeSendReceive, Devices: []protocol.Device{{ID: id, IndexID: 1, MaxSequence: 1}, {ID: phone}}})
	}
	conn.ClusterConfig(&protocol.ClusterConfig{Folders: folders}, nil)
	select {
	case <-source.configured:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	for _, folder := range []string{Control, Reports, Manual} {
		files := []protocol.FileInfo{}
		if data := source.files[folder]; data != nil {
			name := "job.json"
			if folder == Manual {
				name = ManualName
			}
			files = append(files, fileInfo(id, name, data))
		}
		if err = conn.Index(ctx, &protocol.Index{Folder: folder, Files: files}); err != nil {
			return nil, err
		}
	}
	if err = waitStatus(ctx, root, func(s map[string]any) bool {
		return s["manualStagingVerified"] == true && s["outboundGuardActive"] == true
	}); err != nil {
		return nil, fmt.Errorf("partial staging: %w", err)
	}
	if err = deny(ctx, conn, &protocol.Request{Folder: Manual, Name: ManualName, Size: BlockSize, Hash: first[:], FromTemporary: true}); err != nil {
		return nil, err
	}
	if err = deny(ctx, conn, &protocol.Request{Folder: Manual, Name: ManualName, Size: BlockSize, Hash: first[:]}); err != nil {
		return nil, err
	}
	if err = waitStatus(ctx, root, func(s map[string]any) bool {
		return number(s["temporaryRequestsDenied"]) >= 1 && number(s["manualRequestsDenied"]) >= 2
	}); err != nil {
		return nil, err
	}
	close(source.release)
	if err = waitStatus(ctx, root, func(s map[string]any) bool { return s["manualSHA256"] == manualDigest }); err != nil {
		return nil, err
	}
	for _, temporary := range []bool{false, true} {
		if err = deny(ctx, conn, &protocol.Request{Folder: Manual, Name: ManualName, Size: BlockSize, Hash: first[:], FromTemporary: temporary}); err != nil {
			return nil, err
		}
	}
	if err = deny(ctx, conn, &protocol.Request{Folder: "unclassified-future-manual", Name: ManualName, Size: BlockSize, Hash: first[:]}); err != nil {
		return nil, err
	}
	// Receipts still flow on the same connection. Their data is verified from
	// requests using received file metadata, never copied through USB.
	var receipt map[string]string
	for {
		source.mu.Lock()
		file := source.receipt
		source.mu.Unlock()
		if file != nil {
			var data []byte
			valid := true
			for n, block := range file.Blocks {
				bytes, requestErr := conn.Request(ctx, &protocol.Request{Folder: Reports, Name: "receipt.json", BlockNo: n, Offset: block.Offset, Size: block.Size, Hash: block.Hash})
				h := sha256.Sum256(bytes)
				if requestErr != nil || hex.EncodeToString(h[:]) != hex.EncodeToString(block.Hash) {
					valid = false
					break
				}
				data = append(data, bytes...)
			}
			if valid && json.Unmarshal(data, &receipt) == nil && receipt["kind"] == "avenkin-fx0-synthetic-receipt" && receipt["nonce"] == nonce && receipt["jobSHA256"] == hex.EncodeToString(jobDigest[:]) && receipt["manualSHA256"] == manualDigest {
				break
			}
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	if err = waitStatus(ctx, root, func(s map[string]any) bool {
		return number(s["manualRequestsDenied"]) >= 4 && number(s["outboundRequestsDenied"]) >= 5
	}); err != nil {
		return nil, err
	}
	report := map[string]any{"status": "passed", "experiment": "FX0 embedded manual no-export adversarial BEP", "engineVersion": "v2.1.5", "engineExtension": "avenkin-model-hook.1", "sourceFingerprintVerified": true, "phoneFingerprintVerified": true, "observedConnectionType": "tcp-server", "manualBytes": len(manual), "manualSHA256": manualDigest, "partialStagingBytesVerified": true, "partialStagingOutboundRequestsDenied": 2, "completedManualOutboundRequestsDenied": 2, "unknownFolderRequestDenied": true, "installedOutsideSharedFolders": true, "exactReceiptStillRetrievable": true, "requestsReturnedNoContent": 5, "productionManualIntegration": "notImplemented"}
	raw, _ := json.MarshalIndent(report, "", "  ")
	err = os.WriteFile(filepath.Join(root, "result.json"), append(raw, '\n'), 0600)
	return report, err
}

func deny(ctx context.Context, conn protocol.Connection, req *protocol.Request) error {
	data, err := conn.Request(ctx, req)
	if len(data) != 0 || !errors.Is(err, protocol.ErrNoSuchFile) {
		return fmt.Errorf("outbound request was not denied without bytes: folder=%s temporary=%v bytes=%d error=%v", req.Folder, req.FromTemporary, len(data), err)
	}
	return nil
}
func number(value any) float64 { n, _ := value.(float64); return n }
func waitStatus(ctx context.Context, root string, predicate func(map[string]any) bool) error {
	for {
		raw, _ := os.ReadFile(filepath.Join(root, "phone-status.json"))
		var value map[string]any
		_ = json.Unmarshal(raw, &value)
		if predicate(value) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
}
func fileInfo(id protocol.DeviceID, name string, data []byte) protocol.FileInfo {
	info := protocol.FileInfo{Name: name, Size: int64(len(data)), ModifiedS: time.Now().Unix(), ModifiedBy: id.Short(), Permissions: 0600, RawBlockSize: BlockSize, Sequence: 1, Version: protocol.Vector{Counters: []protocol.Counter{{ID: id.Short(), Value: 1}}}}
	for offset := 0; offset < len(data); offset += BlockSize {
		end := min(offset+BlockSize, len(data))
		hash := sha256.Sum256(data[offset:end])
		info.Blocks = append(info.Blocks, protocol.BlockInfo{Offset: int64(offset), Size: end - offset, Hash: hash[:]})
	}
	return info
}

type fixturePeer struct {
	mu         sync.Mutex
	files      map[string][]byte
	receipt    *protocol.FileInfo
	release    chan struct{}
	configured chan struct{}
	once       sync.Once
	id         protocol.DeviceID
}

func (m *fixturePeer) Index(_ protocol.Connection, index *protocol.Index) error {
	m.record(index.Folder, index.Files)
	return nil
}
func (m *fixturePeer) IndexUpdate(_ protocol.Connection, index *protocol.IndexUpdate) error {
	m.record(index.Folder, index.Files)
	return nil
}
func (m *fixturePeer) record(folder string, files []protocol.FileInfo) {
	if folder == Reports {
		m.mu.Lock()
		defer m.mu.Unlock()
		for _, file := range files {
			if file.Name == "receipt.json" && !file.Deleted {
				copy := file
				m.receipt = &copy
			}
		}
	}
}
func (m *fixturePeer) ClusterConfig(_ protocol.Connection, _ *protocol.ClusterConfig) error {
	m.once.Do(func() { close(m.configured) })
	return nil
}
func (m *fixturePeer) Closed(_ protocol.Connection, _ error) {}
func (m *fixturePeer) DownloadProgress(_ protocol.Connection, _ *protocol.DownloadProgress) error {
	return nil
}
func (m *fixturePeer) Request(conn protocol.Connection, req *protocol.Request) (protocol.RequestResponse, error) {
	data := m.files[req.Folder]
	expected := "job.json"
	if req.Folder == Manual {
		expected = ManualName
	}
	if req.Name != expected || req.Offset < 0 || req.Size <= 0 || req.Size > BlockSize || req.Offset+int64(req.Size) > int64(len(data)) {
		return nil, protocol.ErrNoSuchFile
	}
	if req.Folder == Manual && req.Offset > 0 {
		select {
		case <-m.release:
		case <-conn.Closed():
			return nil, protocol.ErrGeneric
		}
	}
	bytes := data[req.Offset : req.Offset+int64(req.Size)]
	hash := sha256.Sum256(bytes)
	if hex.EncodeToString(req.Hash) != hex.EncodeToString(hash[:]) {
		return nil, protocol.ErrInvalid
	}
	return &response{bytes: bytes}, nil
}

type response struct{ bytes []byte }

func (r *response) Data() []byte { return r.bytes }
func (r *response) Close()       {}
func (r *response) Wait()        {}

type connectionInfo struct {
	conn        net.Conn
	established time.Time
}

func (i connectionInfo) Type() string             { return "tcp-server" }
func (i connectionInfo) Transport() string        { return "tcp" }
func (i connectionInfo) IsLocal() bool            { return true }
func (i connectionInfo) RemoteAddr() net.Addr     { return i.conn.RemoteAddr() }
func (i connectionInfo) Priority() int            { return 10 }
func (i connectionInfo) String() string           { return "synthetic manual probe" }
func (i connectionInfo) Crypto() string           { return "TLS1.3" }
func (i connectionInfo) EstablishedAt() time.Time { return i.established }
func (i connectionInfo) ConnectionID() string     { return "avenkin-synthetic-manual-probe" }
