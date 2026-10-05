package mobilecore

import (
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
	"strings"
	"sync/atomic"
)

const manualFolder = "avenkin-fx0-phone-manual"

// Fail closed: this lab can export only its one atomic synthetic receipt.
// The folder allowlist is independent of peers, paths and temporary-file flags.
// No denied request reaches the underlying model or its filesystem reads.
type requestGuard struct {
	model.Model
	allowedFolder string
	// allowedName, when set, decides which names in allowedFolder may be served: the managed
	// office connection's sealed outbound list. Unset, only the lab's one receipt may be.
	allowedName func(string) bool
	// directOnly, when set, names what is served only on a connection straight to the office:
	// never through a relay. It is asked after allowedName, so it can only take away.
	directOnly      func(string) bool
	denied          atomic.Uint64
	relayDenied     atomic.Uint64
	temporaryDenied atomic.Uint64
	manualDenied    atomic.Uint64
}

func (g *requestGuard) Request(conn protocol.Connection, req *protocol.Request) (protocol.RequestResponse, error) {
	allowed := g.allowedFolder
	if allowed == "" {
		allowed = reportFolder
	}
	named := func(name string) bool {
		if g.allowedName != nil {
			return g.allowedName(name)
		}
		return name == "receipt.json"
	}
	if req == nil || req.Folder != allowed || req.FromTemporary || !named(req.Name) {
		g.denied.Add(1)
		if req != nil && req.FromTemporary {
			g.temporaryDenied.Add(1)
		}
		if req != nil && req.Folder == manualFolder {
			g.manualDenied.Add(1)
		}
		return nil, protocol.ErrNoSuchFile
	}
	if g.directOnly != nil && g.directOnly(req.Name) && !directConnection(conn) {
		g.denied.Add(1)
		g.relayDenied.Add(1)
		return nil, protocol.ErrNoSuchFile
	}
	return g.Model.Request(conn, req)
}

// directConnection says whether a request came in on a TCP or QUIC connection straight to the
// peer. A relay, or a connection whose kind cannot be read, is not direct.
func directConnection(conn protocol.Connection) bool {
	if conn == nil {
		return false
	}
	kind := conn.Type()
	return strings.HasPrefix(kind, "tcp-") || strings.HasPrefix(kind, "quic-")
}
