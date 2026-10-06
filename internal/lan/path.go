package lan

import (
	"net"
	"strings"
)

// socketPath names the live TCP socket. via "relay" is a connection that
// the relay helper spliced. A direct socket is "tailscale" when its local
// address belongs to an interface whose name contains "tailscale". Every
// other direct socket is "lan". The address text is not a path.
func socketPath(local net.Addr, via string) string {
	if via == "relay" {
		return "relay"
	}
	if addrOnTailscale(addrIP(local)) {
		return "tailscale"
	}
	return "lan"
}

func addrIP(addr net.Addr) net.IP {
	if addr == nil {
		return nil
	}
	switch a := addr.(type) {
	case *net.TCPAddr:
		return a.IP
	case *net.UDPAddr:
		return a.IP
	case *net.IPAddr:
		return a.IP
	}
	host, _, err := net.SplitHostPort(addr.String())
	if err != nil {
		return net.ParseIP(addr.String())
	}
	return net.ParseIP(host)
}

type ifaceIP struct {
	name string
	ip   net.IP
}

// readIfaceIPs lists each address with the name of its interface. Tests
// replace it.
var readIfaceIPs = func() []ifaceIP {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []ifaceIP
	for _, ifc := range ifaces {
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ip := ipFromAddr(a)
			if ip == nil {
				continue
			}
			out = append(out, ifaceIP{name: ifc.Name, ip: ip})
		}
	}
	return out
}

func ipFromAddr(a net.Addr) net.IP {
	switch v := a.(type) {
	case *net.IPNet:
		return v.IP
	case *net.IPAddr:
		return v.IP
	default:
		return nil
	}
}

// addrOnTailscale reports whether ip is assigned to an interface whose
// name contains "tailscale". An address that only looks like 100.x is not
// enough.
func addrOnTailscale(ip net.IP) bool {
	if ip == nil || ip.IsUnspecified() {
		return false
	}
	for _, row := range readIfaceIPs() {
		if row.ip == nil || !row.ip.Equal(ip) {
			continue
		}
		if strings.Contains(strings.ToLower(row.name), "tailscale") {
			return true
		}
	}
	return false
}
