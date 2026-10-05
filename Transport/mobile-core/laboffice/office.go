// Package laboffice is a synthetic managed office over BEP, for tests of the phone's embedded
// engine: it holds the three managed folders for one phone, offers files in control and bulk,
// takes what the phone publishes in records, and can ask for things it has no business asking
// for. It is not an office server: it verifies no binding and keeps nothing.
package laboffice

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"errors"
	"net"
	"os"
	"path"
	"sort"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
	"github.com/syncthing/syncthing/lib/tlsutil"
)

// BlockSize is the block size the office announces its files in.
const BlockSize = 128 * 1024

// Folders are the engine identifiers of the three managed folders, as both sides compute them.
type Folders struct {
	Control, Records, Bulk string
}

// Office is one synthetic office for one phone.
type Office struct {
	// ID is the office's transport identity and Address where it listens ("a.b.c.d:port").
	ID      protocol.DeviceID
	Address string

	listener net.Listener
	folders  Folders

	mu        sync.Mutex
	conn      protocol.Connection
	offered   map[string]map[string][]byte            // folder → name → bytes this office offers
	announced map[string]map[string]protocol.FileInfo // folder → name → what this office has announced
	sequence  map[string]int64                        // folder → last sequence announced
	live      map[string]bool                         // folder → the phone has it running
	records   map[string]protocol.FileInfo            // what the phone has announced in records
	closed    error
}

// Listen makes an office with a transport identity of its own, listening on address
// ("a.b.c.d:0" for any port). certDir is where its certificate is kept.
func Listen(certDir, address string) (*Office, error) {
	if err := os.MkdirAll(certDir, 0700); err != nil {
		return nil, err
	}
	cert, err := syncthing.LoadOrGenerateCertificate(path.Join(certDir, "cert.pem"), path.Join(certDir, "key.pem"))
	if err != nil {
		return nil, err
	}
	cfg := tlsutil.SecureDefaultTLS13()
	cfg.Certificates = []tls.Certificate{cert}
	cfg.ClientAuth = tls.RequireAnyClientCert
	cfg.NextProtos = []string{"bep/1.0"}
	cfg.InsecureSkipVerify = true // the phone's fingerprint is checked in Serve
	listener, err := tls.Listen("tcp", address, cfg)
	if err != nil {
		return nil, err
	}
	return &Office{ID: protocol.NewDeviceID(cert.Certificate[0]), Address: listener.Addr().String(), listener: listener,
		offered: map[string]map[string][]byte{}, announced: map[string]map[string]protocol.FileInfo{},
		sequence: map[string]int64{}, live: map[string]bool{}, records: map[string]protocol.FileInfo{}}, nil
}

// Serve accepts the one phone it is told to expect and speaks BEP with it until ctx ends or the
// connection closes. Anything else that connects is refused.
func (o *Office) Serve(ctx context.Context, phone protocol.DeviceID, folders Folders) error {
	o.mu.Lock()
	o.folders = folders
	o.mu.Unlock()
	go func() { <-ctx.Done(); o.listener.Close() }()
	wire, err := o.listener.Accept()
	if err != nil {
		return err
	}
	defer wire.Close()
	secure := wire.(*tls.Conn)
	if err = secure.HandshakeContext(ctx); err != nil {
		return err
	}
	state := secure.ConnectionState()
	if len(state.PeerCertificates) != 1 || protocol.NewDeviceID(state.PeerCertificates[0].Raw) != phone {
		return errors.New("unapproved phone identity")
	}
	if _, err = protocol.ExchangeHello(secure, protocol.Hello{DeviceName: "Avenkin synthetic office", ClientName: "avenkin-lab-office", ClientVersion: "v2.1.5", NumConnections: 1, Timestamp: time.Now().UnixNano()}); err != nil {
		return err
	}
	conn := protocol.NewConnection(phone, secure, secure, secure, &model{o}, connectionInfo{conn: secure, established: time.Now()}, protocol.CompressionNever, protocol.NewKeyGenerator())
	o.mu.Lock()
	o.conn = conn
	o.mu.Unlock()
	conn.Start()
	var list []protocol.Folder
	for _, folder := range []string{folders.Control, folders.Records, folders.Bulk} {
		list = append(list, protocol.Folder{ID: folder, Type: protocol.FolderTypeSendReceive,
			Devices: []protocol.Device{{ID: o.ID, IndexID: 1, MaxSequence: 0}, {ID: phone}}})
	}
	conn.ClusterConfig(&protocol.ClusterConfig{Folders: list}, nil)
	select {
	case <-ctx.Done():
		conn.Close(errors.New("synthetic office finished"))
		return nil
	case <-conn.Closed():
		o.mu.Lock()
		defer o.mu.Unlock()
		return o.closed
	}
}

// Put offers a file in control or bulk. A phone that is connected and has the folder running is
// told at once; otherwise it is told when it has.
func (o *Office) Put(folder, name string, data []byte) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.offered[folder] == nil {
		o.offered[folder] = map[string][]byte{}
	}
	o.offered[folder][name] = append([]byte{}, data...)
	o.announce(folder, o.entries(folder, name, data, false))
}

// Remove takes a file this office offered out of the folder.
func (o *Office) Remove(folder, name string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if _, ok := o.offered[folder][name]; !ok {
		return
	}
	delete(o.offered[folder], name)
	o.announce(folder, o.entries(folder, name, nil, true))
}

// entries are the index entries for one file: its parent directories, then the file itself.
// The caller holds the lock.
func (o *Office) entries(folder, name string, data []byte, deleted bool) []protocol.FileInfo {
	var out []protocol.FileInfo
	if !deleted {
		for dir := path.Dir(name); dir != "." && dir != "/"; dir = path.Dir(dir) {
			if _, known := o.announced[folder][dir]; known {
				continue
			}
			out = append([]protocol.FileInfo{{Name: dir, Type: protocol.FileInfoTypeDirectory, Permissions: 0700,
				ModifiedS: time.Now().Unix(), ModifiedBy: o.ID.Short(),
				Version: protocol.Vector{Counters: []protocol.Counter{{ID: o.ID.Short(), Value: 1}}}}}, out...)
		}
	}
	version := uint64(1)
	if previous, ok := o.announced[folder][name]; ok && len(previous.Version.Counters) == 1 {
		version = previous.Version.Counters[0].Value + 1
	}
	info := protocol.FileInfo{Name: name, Size: int64(len(data)), ModifiedS: time.Now().Unix(), ModifiedBy: o.ID.Short(),
		Permissions: 0600, RawBlockSize: BlockSize, Deleted: deleted,
		Version: protocol.Vector{Counters: []protocol.Counter{{ID: o.ID.Short(), Value: version}}}}
	if deleted {
		info.Size = 0
	}
	for offset := 0; offset < len(data); offset += BlockSize {
		end := min(offset+BlockSize, len(data))
		hash := sha256.Sum256(data[offset:end])
		info.Blocks = append(info.Blocks, protocol.BlockInfo{Offset: int64(offset), Size: end - offset, Hash: hash[:]})
	}
	return append(out, info)
}

// announce records index entries and, when the phone has the folder running, sends them. The
// caller holds the lock.
func (o *Office) announce(folder string, files []protocol.FileInfo) {
	if o.announced[folder] == nil {
		o.announced[folder] = map[string]protocol.FileInfo{}
	}
	for n := range files {
		o.sequence[folder]++
		files[n].Sequence = o.sequence[folder]
		o.announced[folder][files[n].Name] = files[n]
	}
	if o.conn != nil && o.live[folder] {
		_ = o.conn.IndexUpdate(context.Background(), &protocol.IndexUpdate{Folder: folder, Files: files})
	}
}

// sendIndex sends everything announced for a folder, in sequence order. The caller holds the lock.
func (o *Office) sendIndex(folder string) {
	files := make([]protocol.FileInfo, 0, len(o.announced[folder]))
	for _, file := range o.announced[folder] {
		files = append(files, file)
	}
	sort.Slice(files, func(a, b int) bool { return files[a].Sequence < files[b].Sequence })
	_ = o.conn.Index(context.Background(), &protocol.Index{Folder: folder, Files: files})
}

// Published lists the names the phone has announced in records and not deleted.
func (o *Office) Published() []string {
	o.mu.Lock()
	defer o.mu.Unlock()
	var names []string
	for name, file := range o.records {
		if !file.Deleted && file.Type == protocol.FileInfoTypeFile {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}

// Fetch pulls one file the phone has announced in records, block by block, checking each block
// against the hash the phone announced; then tells the phone it has the file, as an engine that
// had synchronised it would. An error when the phone has announced no such file.
func (o *Office) Fetch(ctx context.Context, name string) ([]byte, error) {
	o.mu.Lock()
	file, ok := o.records[name]
	conn, folder := o.conn, o.folders.Records
	o.mu.Unlock()
	if !ok || file.Deleted || conn == nil {
		return nil, errors.New("the phone has not announced " + name)
	}
	var data []byte
	for n, block := range file.Blocks {
		bytes, err := conn.Request(ctx, &protocol.Request{Folder: folder, Name: name, BlockNo: n, Offset: block.Offset, Size: block.Size, Hash: block.Hash})
		if err != nil {
			return nil, err
		}
		if hash := sha256.Sum256(bytes); string(hash[:]) != string(block.Hash) {
			return nil, errors.New("a block of " + name + " is not what was announced")
		}
		data = append(data, bytes...)
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	have := file
	have.LocalFlags = 0
	o.announce(folder, []protocol.FileInfo{have})
	return data, nil
}

// Ask requests the first block of a name in a folder and returns what came back: an office
// asking for something it should not be given.
func (o *Office) Ask(ctx context.Context, folder, name string, size int, hash []byte) ([]byte, error) {
	o.mu.Lock()
	conn := o.conn
	o.mu.Unlock()
	if conn == nil {
		return nil, errors.New("no phone is connected")
	}
	if len(hash) == 0 {
		// The engine drops a peer that sends a request with no block hash at all, so an
		// office that does not know the bytes still has to name some.
		hash = make([]byte, sha256.Size)
	}
	return conn.Request(ctx, &protocol.Request{Folder: folder, Name: name, Size: size, Hash: hash})
}

// model is the office's side of the connection.
type model struct{ o *Office }

func (m *model) Index(_ protocol.Connection, index *protocol.Index) error {
	m.record(index.Folder, index.Files)
	return nil
}

func (m *model) IndexUpdate(_ protocol.Connection, index *protocol.IndexUpdate) error {
	m.record(index.Folder, index.Files)
	return nil
}

func (m *model) record(folder string, files []protocol.FileInfo) {
	m.o.mu.Lock()
	defer m.o.mu.Unlock()
	if folder != m.o.folders.Records {
		return
	}
	for _, file := range files {
		m.o.records[file.Name] = file
	}
}

// ClusterConfig is the phone saying which folders it has running. A folder that has started
// since the office last heard is sent this office's whole index for it: a paused folder is sent
// nothing, because an index for a folder a peer is not running closes the connection.
func (m *model) ClusterConfig(_ protocol.Connection, config *protocol.ClusterConfig) error {
	m.o.mu.Lock()
	defer m.o.mu.Unlock()
	running := map[string]bool{}
	for _, folder := range config.Folders {
		if folder.IsRunning() {
			running[folder.ID] = true
		}
	}
	for _, folder := range []string{m.o.folders.Control, m.o.folders.Records, m.o.folders.Bulk} {
		started := running[folder] && !m.o.live[folder]
		m.o.live[folder] = running[folder]
		if started {
			m.o.sendIndex(folder)
		}
	}
	return nil
}

func (m *model) Closed(_ protocol.Connection, err error) {
	m.o.mu.Lock()
	defer m.o.mu.Unlock()
	m.o.conn, m.o.closed = nil, err
	m.o.live = map[string]bool{}
}

func (m *model) DownloadProgress(_ protocol.Connection, _ *protocol.DownloadProgress) error {
	return nil
}

// Request serves a block of a file this office offers, and nothing else.
func (m *model) Request(_ protocol.Connection, req *protocol.Request) (protocol.RequestResponse, error) {
	m.o.mu.Lock()
	data, ok := m.o.offered[req.Folder][req.Name]
	m.o.mu.Unlock()
	if !ok || req.Offset < 0 || req.Size <= 0 || req.Offset+int64(req.Size) > int64(len(data)) {
		return nil, protocol.ErrNoSuchFile
	}
	bytes := data[req.Offset : req.Offset+int64(req.Size)]
	if hash := sha256.Sum256(bytes); len(req.Hash) > 0 && string(hash[:]) != string(req.Hash) {
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
func (i connectionInfo) String() string           { return "synthetic managed office" }
func (i connectionInfo) Crypto() string           { return "TLS1.3" }
func (i connectionInfo) EstablishedAt() time.Time { return i.established }
func (i connectionInfo) ConnectionID() string     { return "avenkin-synthetic-managed-office" }
