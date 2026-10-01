package desktop

import (
	"os"
	"os/exec"
	"testing"
	"time"
)

// Live check: exclusive grab should see a virtual key from wtype when available.
func TestEdgeKeyGrabSeesWtype(t *testing.T) {
	if os.Getenv("HYPRLAND_INSTANCE_SIGNATURE") == "" {
		t.Skip("not Hyprland")
	}
	if _, err := exec.LookPath("wtype"); err != nil {
		t.Skip("wtype not installed")
	}
	g, err := StartEdgeKeyGrab()
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer g.Stop()
	time.Sleep(100 * time.Millisecond)
	t0 := time.Now()
	cmd := exec.Command("wtype", "a")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("wtype: %v (%s)", err, out)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if g.ActiveSince(t0) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("grab did not see wtype key — exclusive keyboard may not be focused")
}
