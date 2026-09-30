package core

import (
	"net"
	"strings"
	"testing"

	"flux/internal/proto"
)

func TestFormatParseInvite(t *testing.T) {
	id := "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b"
	if !proto.ValidDeviceID(id) {
		t.Fatal(id)
	}
	code := FormatInvite(id, "other-desk", 1716)
	if code != "flux1:"+id+"@other-desk:1716" {
		t.Fatalf("code %q", code)
	}
	inv, err := ParseInvite("  " + code + "\n")
	if err != nil {
		t.Fatal(err)
	}
	if inv.ID != id || inv.Host != "other-desk" || inv.Port != 1716 {
		t.Fatalf("%+v", inv)
	}
	v6 := FormatInvite(id, "fd7a:115c:a1e0::1234", 1720)
	got, err := ParseInvite(v6)
	if err != nil {
		t.Fatal(err)
	}
	if got.Host != "fd7a:115c:a1e0::1234" || got.Port != 1720 {
		t.Fatalf("%+v", got)
	}
}

func TestParseInviteRejects(t *testing.T) {
	for _, in := range []string{
		"", "flux1:", "flux1:short@host:1716", "flux1:9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b@host",
		"flux1:9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b@https://host:1716",
	} {
		if _, err := ParseInvite(in); err == nil {
			t.Fatalf("%q accepted", in)
		}
	}
}

func TestIsTailscaleIP(t *testing.T) {
	if !isTailscaleIP(net.IP{100, 64, 0, 1}) || !isTailscaleIP(net.IP{100, 127, 1, 1}) {
		t.Fatal("CGNAT")
	}
	if isTailscaleIP(net.IP{100, 63, 0, 1}) || isTailscaleIP(net.IP{192, 168, 1, 1}) {
		t.Fatal("not CGNAT")
	}
}

func TestFormatInviteStable(t *testing.T) {
	id := strings.Repeat("a", 32)
	a := FormatInvite(id, "desk", 1716)
	b, err := ParseInvite(a)
	if err != nil || b.Code != a {
		t.Fatalf("%v %q", err, b.Code)
	}
}

func TestPickInviteHost(t *testing.T) {
	// Sole Tailscale wins even when LAN/docker addresses are listed too.
	got, err := pickInviteHost([]string{"100.75.127.31", "192.168.1.8", "172.18.0.1", "172.17.0.1"})
	if err != nil || got != "100.75.127.31" {
		t.Fatalf("sole Tailscale: got %q err %v", got, err)
	}
	got, err = pickInviteHost([]string{"192.168.1.8"})
	if err != nil || got != "192.168.1.8" {
		t.Fatalf("sole other: got %q err %v", got, err)
	}
	if _, err := pickInviteHost(nil); err == nil {
		t.Fatal("empty candidates should fail")
	}
	if _, err := pickInviteHost([]string{"192.168.1.8", "10.0.0.2"}); err == nil {
		t.Fatal("ambiguous non-Tailscale should fail")
	}
	if _, err := pickInviteHost([]string{"100.64.0.1", "100.64.0.2"}); err == nil {
		t.Fatal("ambiguous Tailscale should fail")
	}
}
