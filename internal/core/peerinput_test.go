package core

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"
)

func TestPeerPointerClickAndDrag(t *testing.T) {
	in := newPeerInput()
	now := time.Unix(100, 0)

	if bodies := in.bodies(peerInputEvent{Op: "btn", Btn: "left", Down: true, X: 0.2, Y: 0.3, SX: 10, SY: 20}, now); bodies != nil {
		t.Fatalf("down: %v", bodies)
	}
	// Small move: still a click.
	if bodies := in.bodies(peerInputEvent{Op: "pos", X: 0.21, Y: 0.31, SX: 11, SY: 21}, now); bodies != nil {
		t.Fatalf("slop move: %v", bodies)
	}
	bodies := in.bodies(peerInputEvent{Op: "btn", Btn: "left", Down: false, X: 0.21, Y: 0.31, SX: 11, SY: 21}, now)
	if len(bodies) != 1 || bodies[0]["singleclick"] != true {
		t.Fatalf("click: %v", bodies)
	}
	if bodies[0]["x"] != 0.2 || bodies[0]["y"] != 0.3 {
		t.Fatalf("click pos: %v", bodies[0])
	}

	in = newPeerInput()
	in.bodies(peerInputEvent{Op: "btn", Btn: "left", Down: true, X: 0.1, Y: 0.1, SX: 0, SY: 0}, now)
	bodies = in.bodies(peerInputEvent{Op: "pos", X: 0.4, Y: 0.5, SX: 40, SY: 50}, now)
	if len(bodies) != 2 || bodies[0]["singlehold"] != true || bodies[1]["x"] != 0.4 {
		t.Fatalf("drag start: %v", bodies)
	}
	bodies = in.bodies(peerInputEvent{Op: "btn", Btn: "left", Down: false, X: 0.5, Y: 0.6, SX: 50, SY: 60}, now)
	if len(bodies) != 1 || bodies[0]["singlerelease"] != true {
		t.Fatalf("drag end: %v", bodies)
	}
}

func TestPeerPointerRightMiddleScrollKey(t *testing.T) {
	in := newPeerInput()
	now := time.Unix(1, 0)
	bodies := in.bodies(peerInputEvent{Op: "btn", Btn: "right", Down: false, X: 0.5, Y: 0.5}, now)
	if len(bodies) != 1 || bodies[0]["rightclick"] != true {
		t.Fatalf("right: %v", bodies)
	}
	bodies = in.bodies(peerInputEvent{Op: "btn", Btn: "middle", Down: false, X: 0.1, Y: 0.2}, now)
	if len(bodies) != 1 || bodies[0]["middleclick"] != true {
		t.Fatalf("middle: %v", bodies)
	}
	bodies = in.bodies(peerInputEvent{Op: "scroll", X: 0.3, Y: 0.4, DX: 0, DY: 3}, now)
	if bodies[0]["scroll"] != true || bodies[0]["dy"] != 3.0 {
		t.Fatalf("scroll: %v", bodies)
	}
	bodies = in.bodies(peerInputEvent{Op: "key", Text: "a", Ctrl: true}, now)
	if bodies[0]["key"] != "a" || bodies[0]["ctrl"] != true {
		t.Fatalf("key: %v", bodies)
	}
	bodies = in.bodies(peerInputEvent{Op: "special", Code: 12, Shift: true}, now)
	if bodies[0]["specialKey"] != 12 || bodies[0]["shift"] != true {
		t.Fatalf("special: %v", bodies)
	}
}

func TestPeerMotionThrottle(t *testing.T) {
	in := newPeerInput()
	t0 := time.Unix(10, 0)
	b1 := in.bodies(peerInputEvent{Op: "pos", X: 0.1, Y: 0.1}, t0)
	if len(b1) != 1 {
		t.Fatalf("first: %v", b1)
	}
	b2 := in.bodies(peerInputEvent{Op: "pos", X: 0.2, Y: 0.2}, t0.Add(time.Millisecond))
	if b2 != nil {
		t.Fatalf("throttled: %v", b2)
	}
	flushed := in.flushMotion(t0.Add(time.Second / peerMotionHz))
	if len(flushed) != 1 || flushed[0]["x"] != 0.2 {
		t.Fatalf("flush: %v", flushed)
	}
}

func TestReadPeerInput(t *testing.T) {
	var got []map[string]any
	src := strings.Join([]string{
		`{"op":"pos","x":0.25,"y":0.75}`,
		`{"op":"btn","btn":"left","down":true,"x":0.25,"y":0.75,"sx":1,"sy":1}`,
		`{"op":"btn","btn":"left","down":false,"x":0.25,"y":0.75,"sx":1,"sy":1}`,
		`{"op":"key","text":"z"}`,
	}, "\n") + "\n"
	err := readPeerInput(context.Background(), bytes.NewBufferString(src), func(body map[string]any) error {
		got = append(got, body)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) < 3 {
		t.Fatalf("got %d packets: %v", len(got), got)
	}
	click := false
	key := false
	for _, b := range got {
		if b["singleclick"] == true {
			click = true
		}
		if b["key"] == "z" {
			key = true
		}
	}
	if !click || !key {
		t.Fatalf("packets: %v", got)
	}
}

func TestWritePeerInputScript(t *testing.T) {
	dir := t.TempDir()
	path, err := writePeerInputScript(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(path, "flux-peer-input.lua") {
		t.Fatalf("path %s", path)
	}
	if len(peerInputLua) < 100 || !bytes.Contains(peerInputLua, []byte("flux_peer_input")) {
		t.Fatalf("embed missing")
	}
}

func TestEdgeButtonPathStillPresent(t *testing.T) {
	// Screen-edge clicks stay separate from peer-desktop mousepad: while the
	// lease is active, EdgeGrab button events call sendEdgeButton → flux.edge.
	// Referencing the helpers keeps a compile break if they disappear.
	var d *Daemon
	_ = d.sendEdgeButton
	_ = d.handleEdge
	_ = edgeMargin
}
