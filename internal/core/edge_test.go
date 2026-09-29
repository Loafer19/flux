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
