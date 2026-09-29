package mobilecore

import (
	"errors"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
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
