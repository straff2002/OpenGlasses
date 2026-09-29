package mobilecore

import (
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
	"sync/atomic"
)

const manualFolder = "avenkin-fx0-phone-manual"

// Fail closed: this lab can export only its one atomic synthetic receipt.
// The folder allowlist is independent of peers, paths and temporary-file flags.
// No denied request reaches the underlying model or its filesystem reads.
type requestGuard struct {
	model.Model
	allowedFolder   string
	denied          atomic.Uint64
	temporaryDenied atomic.Uint64
	manualDenied    atomic.Uint64
}

func (g *requestGuard) Request(conn protocol.Connection, req *protocol.Request) (protocol.RequestResponse, error) {
	allowed := g.allowedFolder
	if allowed == "" {
		allowed = reportFolder
	}
	if req == nil || req.Folder != allowed || req.Name != "receipt.json" || req.FromTemporary {
		g.denied.Add(1)
		if req != nil && req.FromTemporary {
			g.temporaryDenied.Add(1)
		}
		if req != nil && req.Folder == manualFolder {
			g.manualDenied.Add(1)
		}
		return nil, protocol.ErrNoSuchFile
	}
	return g.Model.Request(conn, req)
}
