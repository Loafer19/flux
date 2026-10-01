package core

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"flux/internal/proto"
)

func TestPeerURLAndEdge(t *testing.T) {
	dir := t.TempDir()
	opened := filepath.Join(dir, "opened")
	script := filepath.Join(dir, "xdg-open")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s' \"$1\" > '"+opened+"'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	d, _ := clipDaemon(t, true)
	in, out := fluxIdentity()
	peer := &Device{
		ID: "0123456789abcdef0123456789abcdef", Name: "other-desk", Type: "laptop",
		Paired: true, Incoming: in, Outgoing: out,
	}
	phone := &Device{ID: "fedcba9876543210fedcba9876543210", Name: "phone", Type: "phone", Paired: true}
	d.devices[peer.ID] = peer
	d.devices[phone.ID] = phone
	d.cfg.EdgeSide = "left"
	d.cfg.EdgeDevice = "other-desk"
	rec := &countingInput{}
	d.input = rec

	if err := d.ShareText(peer, "url", "file:///etc/passwd"); err == nil {
		t.Fatal("a computer accepted a file URL")
	}
	d.handleShare(peer, nil, proto.New(proto.TypeShare, map[string]any{"url": "file:///etc/passwd"}))
	if _, err := os.Stat(opened); err == nil {
		t.Fatal("a computer opened a file URL")
	}
	d.handleShare(peer, nil, proto.New(proto.TypeShare, map[string]any{"url": "https://example.com/notes"}))
	var got []byte
	var err error
	for range 50 {
		got, err = os.ReadFile(opened)
		if err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err != nil || string(got) != "https://example.com/notes" {
		t.Fatalf("opened %q %v", got, err)
	}

	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "move", "dx": 12, "dy": 3}))
	if rec.n != 0 {
		t.Fatal("motion before the pointer entered")
	}
	d.handleEdge(phone, proto.New(proto.TypeFluxEdge, map[string]any{"op": "enter"}))
	if rec.n != 0 {
		t.Fatal("a phone moved the pointer")
	}
	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "enter"}))
	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "move", "dx": 12, "dy": 3}))
	if rec.n != 2 {
		t.Fatalf("pointer calls %d, want enter and one move", rec.n)
	}
	d.cfg.EdgeDevice = "someone-else"
	before := rec.n
	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "move", "dx": 4, "dy": 4}))
	if rec.n != before {
		t.Fatal("a computer that is not the seam moved the pointer")
	}
}

func TestEdgeIdleLeaseStaysOpen(t *testing.T) {
	d, _ := clipDaemon(t, true)
	in, out := fluxIdentity()
	peer := &Device{
		ID: "0123456789abcdef0123456789abcdef", Name: "other-desk", Type: "laptop",
		Paired: true, Incoming: in, Outgoing: out,
	}
	d.devices[peer.ID] = peer
	d.cfg.EdgeSide = "left"
	d.cfg.EdgeDevice = "other-desk"
	rec := &countingInput{}
	d.input = rec

	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "enter"}))
	time.Sleep(500 * time.Millisecond)
	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "move", "dx": 8, "dy": 0}))
	if rec.n != 2 {
		t.Fatalf("after idle, pointer calls %d, want enter and one move", rec.n)
	}
	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "leave"}))
	before := rec.n
	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "move", "dx": 3, "dy": 0}))
	if rec.n != before {
		t.Fatal("move after leave still applied")
	}
}

func TestSetEdgeSettings(t *testing.T) {
	d, _ := clipDaemon(t, true)
	if err := d.setSetting("edgeSide", "up"); err == nil {
		t.Fatal("accepted a bad edge")
	}
	if err := d.setSetting("edgeSide", "left"); err != nil {
		t.Fatal(err)
	}
	if err := d.setSetting("edgeDevice", "vivobook"); err != nil {
		t.Fatal(err)
	}
	if d.cfg.EdgeSide != "left" || d.cfg.EdgeDevice != "vivobook" {
		t.Fatalf("cfg %q %q", d.cfg.EdgeSide, d.cfg.EdgeDevice)
	}
	if err := d.setSetting("edgeSide", ""); err != nil {
		t.Fatal(err)
	}
	if d.cfg.EdgeSide != "" || d.cfg.EdgeDevice != "" {
		t.Fatalf("clearing edgeSide left device %q %q", d.cfg.EdgeSide, d.cfg.EdgeDevice)
	}
}

func TestEdgeRemoteExpectTracksMoves(t *testing.T) {
	d, _ := clipDaemon(t, true)
	d.setEdgeRemoteExpect(100, 200)
	d.bumpEdgeRemoteExpect(12, -4)
	d.mu.Lock()
	x, y := d.edgeRemoteX, d.edgeRemoteY
	has := d.edgeRemoteHasExpect
	d.mu.Unlock()
	if !has || x != 112 || y != 196 {
		t.Fatalf("expect %v @ %g,%g want 112,196", has, x, y)
	}
	d.clearEdgeRemoteMark()
	d.mu.Lock()
	set, has := d.edgeRemoteSet, d.edgeRemoteHasExpect
	d.mu.Unlock()
	if set || has {
		t.Fatal("clear left remote mark set")
	}
}

func TestEdgeLocalInputNeedsExpectOrLocalInput(t *testing.T) {
	d, _ := clipDaemon(t, true)
	// No mark: never local.
	if d.edgeLocalInput() {
		t.Fatal("unmarked session reported local input")
	}
	// Touch without expect: only /dev/input could reclaim; none here.
	d.touchEdgeRemote()
	if d.edgeLocalInput() {
		t.Fatal("touch-only mark should not reclaim without expect or LocalInput")
	}
}

func TestEdgeButtonForward(t *testing.T) {
	d, _ := clipDaemon(t, true)
	in, out := fluxIdentity()
	peer := &Device{
		ID: "0123456789abcdef0123456789abcdef", Name: "other-desk", Type: "laptop",
		Paired: true, Incoming: in, Outgoing: out,
	}
	d.devices[peer.ID] = peer
	d.cfg.EdgeSide = "left"
	d.cfg.EdgeDevice = "other-desk"
	rec := &countingInput{}
	d.input = rec

	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "enter"}))
	before := rec.n
	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "button", "button": 0x110, "pressed": true}))
	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "button", "button": 0x110, "pressed": false}))
	if rec.n != before+2 {
		t.Fatalf("button calls %d, want %d", rec.n-before, 2)
	}
	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "leave"}))
	before = rec.n
	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "button", "button": 0x110, "pressed": true}))
	if rec.n != before {
		t.Fatal("button after leave still applied")
	}
}

func TestEdgeKickClearsReceiveAndSignalsLease(t *testing.T) {
	d, _ := clipDaemon(t, true)
	in, out := fluxIdentity()
	peer := &Device{
		ID: "0123456789abcdef0123456789abcdef", Name: "other-desk", Type: "laptop",
		Paired: true, Incoming: in, Outgoing: out,
	}
	d.devices[peer.ID] = peer
	d.cfg.EdgeSide = "left"
	d.cfg.EdgeDevice = "other-desk"
	d.input = &countingInput{}
	d.edgeKick = make(chan struct{}, 1)

	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "enter"}))
	if !d.edgeReceiving() {
		t.Fatal("expected receiving after enter")
	}
	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "kick"}))
	if d.edgeReceiving() {
		t.Fatal("kick left receiving on")
	}
	select {
	case <-d.edgeKick:
	default:
		t.Fatal("kick did not signal edgeKick")
	}
}

func TestYieldEdgeToLocalClearsWithoutWarp(t *testing.T) {
	d, _ := clipDaemon(t, true)
	in, out := fluxIdentity()
	peer := &Device{
		ID: "0123456789abcdef0123456789abcdef", Name: "other-desk", Type: "laptop",
		Paired: true, Incoming: in, Outgoing: out,
	}
	d.devices[peer.ID] = peer
	d.cfg.EdgeSide = "left"
	d.cfg.EdgeDevice = "other-desk"
	rec := &countingInput{}
	d.input = rec

	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "enter"}))
	before := rec.n
	d.yieldEdgeToLocal()
	if d.edgeReceiving() {
		t.Fatal("yield left receiving on")
	}
	// No further input applied by yield itself.
	if rec.n != before {
		t.Fatalf("yield applied input: %d -> %d", before, rec.n)
	}
	// Later peer moves must not apply.
	d.handleEdge(peer, proto.New(proto.TypeFluxEdge, map[string]any{"op": "move", "dx": 9, "dy": 0}))
	if rec.n != before {
		t.Fatal("move after yield still applied")
	}
}

func TestEdgeCursorDiverged(t *testing.T) {
	if edgeCursorDiverged(100, 100, 105, 100, 10) {
		t.Fatal("5px should stay under 10px threshold")
	}
	if !edgeCursorDiverged(100, 100, 120, 100, 10) {
		t.Fatal("20px should exceed 10px threshold")
	}
}

type stubKeyWatcher struct {
	at      time.Time
	stopped bool
}

func (s *stubKeyWatcher) ActiveSince(t time.Time) bool {
	return !s.at.IsZero() && !s.at.Before(t)
}

func (s *stubKeyWatcher) Stop() { s.stopped = true }

func TestEdgeLocalInputUsesKeyWatcher(t *testing.T) {
	d, _ := clipDaemon(t, true)
	d.touchEdgeRemote()
	// Without expect or keys: false
	if d.edgeLocalInput() {
		t.Fatal("expected no local input")
	}
	w := &stubKeyWatcher{at: time.Now()}
	d.edgeKeys = w
	if !d.edgeLocalInput() {
		t.Fatal("key watcher should reclaim")
	}
	d.setEdgeActive(true)
	d.setEdgeActive(false)
	if !w.stopped {
		t.Fatal("setEdgeActive(false) should stop key watcher")
	}
}
