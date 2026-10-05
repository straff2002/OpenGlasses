package mobilecore

import (
	"errors"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
	"strings"
	"testing"
)

type requestSpy struct {
	model.Model
	calls int
}

func (s *requestSpy) Request(_ protocol.Connection, _ *protocol.Request) (protocol.RequestResponse, error) {
	s.calls++
	return nil, errors.New("underlying request reached")
}

func TestDeniedRequestsNeverReachModelIncludingTemporaryAndUnknownFolders(t *testing.T) {
	spy := &requestSpy{}
	g := &requestGuard{Model: spy}
	for _, request := range []*protocol.Request{
		nil,
		{Folder: manualFolder, Name: "manual-fixture.bin"},
		{Folder: manualFolder, Name: "manual-fixture.bin", FromTemporary: true},
		{Folder: controlFolder, Name: "job.json"},
		{Folder: "future-manual-folder", Name: "reference.pdf"},
		{Folder: reportFolder, Name: "../manual/reference.pdf"},
		{Folder: reportFolder, Name: "receipt.json", FromTemporary: true},
	} {
		response, err := g.Request(nil, request)
		if response != nil || !errors.Is(err, protocol.ErrNoSuchFile) {
			t.Fatal("denied request returned data or wrong refusal")
		}
	}
	if spy.calls != 0 || g.denied.Load() != 7 || g.temporaryDenied.Load() != 2 || g.manualDenied.Load() != 2 {
		t.Fatal("request bypassed guard")
	}
	_, _ = g.Request(nil, &protocol.Request{Folder: reportFolder, Name: "receipt.json"})
	if spy.calls != 1 {
		t.Fatal("valid completed receipt was not delegated")
	}
}

func TestPreviewGuardDelegatesOnlyItsCommittedReceipt(t *testing.T) {
	spy := &requestSpy{}
	folder := "avenkin-preview-0123456789abcdef0123456789abcdef-out"
	g := &requestGuard{Model: spy, allowedFolder: folder}
	for _, r := range []*protocol.Request{
		{Folder: reportFolder, Name: "receipt.json"},
		{Folder: folder, Name: "receipt.json", FromTemporary: true},
		{Folder: folder, Name: "manual.pdf"},
		{Folder: folder + "/../in", Name: "delivery.json"},
	} {
		if _, e := g.Request(nil, r); !errors.Is(e, protocol.ErrNoSuchFile) {
			t.Fatal("preview request escaped allowlist")
		}
	}
	if spy.calls != 0 {
		t.Fatal("forbidden preview request reached model")
	}
	_, _ = g.Request(nil, &protocol.Request{Folder: folder, Name: "receipt.json"})
	if spy.calls != 1 {
		t.Fatal("preview receipt blocked")
	}
}

func TestManagedGuardServesOnlyTheSealedOutboundListInRecords(t *testing.T) {
	spy := &requestSpy{}
	records := managedFolderID("org-harbour", "phone-a", "office-1", roleRecords)
	control := managedFolderID("org-harbour", "phone-a", "office-1", roleControl)
	published := "receipts/0123456789abcdef0123456789abcdef.envelope.json"
	g := &requestGuard{Model: spy, allowedFolder: records, allowedName: func(name string) bool { return name == published }}
	for _, r := range []*protocol.Request{
		{Folder: control, Name: "jobs/0123456789abcdef0123456789abcdef.envelope.json"},
		{Folder: control, Name: published},
		{Folder: records, Name: "receipts/ffffffffffffffffffffffffffffffff.envelope.json"},
		{Folder: records, Name: "receipt.json"},
		{Folder: records, Name: published, FromTemporary: true},
		{Folder: reportFolder, Name: "receipt.json"},
	} {
		if response, err := g.Request(nil, r); response != nil || !errors.Is(err, protocol.ErrNoSuchFile) {
			t.Fatalf("%s/%s was served", r.Folder, r.Name)
		}
	}
	if spy.calls != 0 || g.denied.Load() != 6 {
		t.Fatal("a request bypassed the managed guard")
	}
	if _, _ = g.Request(nil, &protocol.Request{Folder: records, Name: published}); spy.calls != 1 {
		t.Fatal("the published receipt was not served")
	}
	// A managed connection with no folders serves nothing at all.
	none := &requestGuard{Model: spy, allowedName: func(string) bool { return false }}
	if _, err := none.Request(nil, &protocol.Request{Folder: reportFolder, Name: "receipt.json"}); !errors.Is(err, protocol.ErrNoSuchFile) || spy.calls != 1 {
		t.Fatal("a handshake-only connection served a file")
	}
}

// typedConnection is a connection of a stated kind, for the guard's one question about it.
type typedConnection struct {
	protocol.Connection
	kind string
}

func (c typedConnection) Type() string { return c.kind }

// A recording's video and sound are served only straight to the office: through a relay the
// chunk is refused before the model or the disk is touched, and everything else in records
// still goes.
func TestARecordingsMediaIsNeverServedThroughARelay(t *testing.T) {
	spy := &requestSpy{}
	records := "avenkin-records-0123456789abcdef0123456789abcdef"
	g := &requestGuard{Model: spy, allowedFolder: records, allowedName: func(string) bool { return true }, directOnly: recordingMedia}
	bundle := "recordings/0123456789abcdef0123456789abcdef/"
	chunk := bundle + "media/" + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" + ".chunk"

	for _, kind := range []string{"relay-client", "relay-server", "", "something-new"} {
		response, err := g.Request(typedConnection{kind: kind}, &protocol.Request{Folder: records, Name: chunk})
		if response != nil || !errors.Is(err, protocol.ErrNoSuchFile) {
			t.Fatalf("a chunk was served on %q", kind)
		}
	}
	if response, err := g.Request(nil, &protocol.Request{Folder: records, Name: chunk}); response != nil || !errors.Is(err, protocol.ErrNoSuchFile) {
		t.Fatal("a chunk was served on a connection that cannot be read")
	}
	if spy.calls != 0 || g.relayDenied.Load() != 5 || g.denied.Load() != 5 {
		t.Fatalf("calls=%d relayDenied=%d denied=%d", spy.calls, g.relayDenied.Load(), g.denied.Load())
	}

	// Straight to the office the chunk is served.
	for _, kind := range []string{"tcp-client", "tcp-server", "quic-client", "quic-server"} {
		_, _ = g.Request(typedConnection{kind: kind}, &protocol.Request{Folder: records, Name: chunk})
	}
	if spy.calls != 4 {
		t.Fatalf("a chunk was not served on a direct connection: %d", spy.calls)
	}
	// Through a relay everything else still goes: the bundle's own small files, and the rest of records.
	for _, name := range []string{bundle + "manifest.envelope.json", bundle + "timeline.json", bundle + "transcript.json",
		"reports/0123.envelope.json", "attachments/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "receipts/0123.envelope.json"} {
		_, _ = g.Request(typedConnection{kind: "relay-client"}, &protocol.Request{Folder: records, Name: name})
	}
	if spy.calls != 10 || g.relayDenied.Load() != 5 {
		t.Fatalf("something that is not a recording's media was held back from a relay: calls=%d", spy.calls)
	}
	// Only a chunk in its own place is a chunk.
	for _, name := range []string{"recordings/short/media/" + strings.Repeat("0", 64) + ".chunk", bundle + "media/short.chunk",
		bundle + "media/" + strings.Repeat("0", 64), bundle + strings.Repeat("0", 64) + ".chunk", "media/" + strings.Repeat("0", 64) + ".chunk"} {
		if recordingMedia(name) {
			t.Fatalf("%s was taken for a recording's media", name)
		}
	}
	if !recordingMedia(chunk) {
		t.Fatal("a chunk was not recognised")
	}
}
