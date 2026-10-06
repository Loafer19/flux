package lan

import (
	"net"
	"testing"
)

func TestSocketPath(t *testing.T) {
	old := readIfaceIPs
	t.Cleanup(func() { readIfaceIPs = old })
	readIfaceIPs = func() []ifaceIP {
		return []ifaceIP{
			{name: "tailscale0", ip: net.ParseIP("100.64.0.8")},
			{name: "eth0", ip: net.ParseIP("100.1.2.3")},
			{name: "eth0", ip: net.ParseIP("192.168.1.20")},
		}
	}
	lanAddr := &net.TCPAddr{IP: net.ParseIP("192.168.1.20")}
	fakeCGNAT := &net.TCPAddr{IP: net.ParseIP("100.1.2.3")}
	tailAddr := &net.TCPAddr{IP: net.ParseIP("100.64.0.8")}

	if got := socketPath(tailAddr, "relay"); got != "relay" {
		t.Fatalf("relay socket %q", got)
	}
	if got := socketPath(fakeCGNAT, "relay"); got != "relay" {
		t.Fatalf("relay over a 100. address %q", got)
	}
	if got := socketPath(tailAddr, ""); got != "tailscale" {
		t.Fatalf("tailscale interface %q", got)
	}
	if got := socketPath(fakeCGNAT, ""); got != "lan" {
		t.Fatalf("100. address on eth0 %q", got)
	}
	if got := socketPath(lanAddr, ""); got != "lan" {
		t.Fatalf("lan socket %q", got)
	}
	if got := socketPath(nil, ""); got != "lan" {
		t.Fatalf("missing address %q", got)
	}
}
