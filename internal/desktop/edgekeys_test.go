package desktop

import (
	"os"
	"testing"
	"time"
)

func TestStartEdgeKeyGrabNoDisplay(t *testing.T) {
	t.Setenv("WAYLAND_DISPLAY", "flux-missing-display-socket")
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	_, err := StartEdgeKeyGrab()
	if err == nil {
		t.Fatal("expected error without a Wayland display")
	}
}

func TestStartEdgeKeyGrabStartStop(t *testing.T) {
	if os.Getenv("WAYLAND_DISPLAY") == "" && os.Getenv("XDG_RUNTIME_DIR") == "" {
		t.Skip("no Wayland session")
	}
	if os.Getenv("HYPRLAND_INSTANCE_SIGNATURE") == "" {
		t.Skip("not Hyprland")
	}
	g, err := StartEdgeKeyGrab()
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	g.Stop()
	g.Stop() // idempotent
}

func TestEdgeKeyGrabActiveSince(t *testing.T) {
	g := &EdgeKeyGrab{}
	if g.ActiveSince(time.Now().Add(-time.Second)) {
		t.Fatal("empty grab reported activity")
	}
	g.last = time.Now()
	if !g.ActiveSince(time.Now().Add(-time.Second)) {
		t.Fatal("expected activity")
	}
}
