package core

import (
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

// invitePrefix marks a discovery-less pair invite. The rest is
// <deviceId>@<host>:<port>. Host may be bracketed for IPv6.
const invitePrefix = "flux1:"

// Invite is a one-shot endpoint a peer can dial when mDNS and UDP discovery
// do not cross the network path. It is not a secret: pairing still needs the
// verification key and Accept on both sides. The device ID in the invite is
// checked against the TLS certificate of the peer.
type Invite struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Host string `json:"host"`
	Port int    `json:"port"`
	Code string `json:"invite"`
}

// FormatInvite builds the pasteable invite string.
func FormatInvite(id, host string, port int) string {
	h := host
	if ip, err := netip.ParseAddr(host); err == nil && ip.Is6() {
		h = "[" + ip.String() + "]"
	}
	return fmt.Sprintf("%s%s@%s:%d", invitePrefix, id, h, port)
}

// ParseInvite reads a flux1 invite. It accepts the code alone, or the code
// with surrounding whitespace.
func ParseInvite(raw string) (Invite, error) {
	s := strings.TrimSpace(raw)
	if !strings.HasPrefix(s, invitePrefix) {
		return Invite{}, apiErr("bad_invite", "Give a flux1 invite from flux-cli pair invite")
	}
	rest := strings.TrimPrefix(s, invitePrefix)
	at := strings.IndexByte(rest, '@')
	if at <= 0 {
		return Invite{}, apiErr("bad_invite", "Invite is missing the device ID")
	}
	id, endpoint := rest[:at], rest[at+1:]
	if !proto.ValidDeviceID(id) {
		return Invite{}, apiErr("bad_invite", "Invite device ID is not valid")
	}
	host, port, err := splitHostPort(endpoint)
	if err != nil {
		return Invite{}, err
	}
	host, err = normalizeAddress(host)
	if err != nil {
		return Invite{}, err
	}
	if port <= 0 || port > 65535 {
		return Invite{}, apiErr("bad_invite", "Invite port is not valid")
	}
	return Invite{ID: id, Host: host, Port: port, Code: FormatInvite(id, host, port)}, nil
}

// splitHostPort splits host:port. An IPv6 host must use brackets.
func splitHostPort(endpoint string) (string, int, error) {
	host, portStr, err := net.SplitHostPort(endpoint)
	if err != nil {
		return "", 0, apiErr("bad_invite", "Invite address must be host:port")
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port <= 0 || port > 65535 {
		return "", 0, apiErr("bad_invite", "Invite port is not valid")
	}
	return host, port, nil
}

// MakeInvite builds an invite for this computer. host is the address the
// other side must be able to reach: a Tailscale name or IP, or a LAN address
// after both sides allow TCP 1716–1764 from each other. An empty host picks
// the only Tailscale IPv4 address when there is one.
func (d *Daemon) MakeInvite(host string) (Invite, error) {
	port := d.lanPort()
	if port == 0 {
		return Invite{}, apiErr("not_ready", "fluxd is not listening yet")
	}
	host = strings.TrimSpace(host)
	if host == "" {
		cands := d.inviteHostCandidates()
		switch len(cands) {
		case 0:
			return Invite{}, apiErr("need_host", "Give --host with a reachable address, for example a Tailscale name. Run: flux-cli pair invite --host HOST")
		case 1:
			host = cands[0]
		default:
			return Invite{}, apiErr("need_host", "Give --host with one of: %s", strings.Join(cands, ", "))
		}
	}
	normalized, err := normalizeAddress(host)
	if err != nil {
		return Invite{}, err
	}
	inv := Invite{
		ID:   d.selfID,
		Name: d.Name(),
		Host: normalized,
		Port: port,
		Code: FormatInvite(d.selfID, normalized, port),
	}
	return inv, nil
}

// ConnectInvite dials the peer named in an invite and remembers the endpoint
// so fluxd can retry while the pair is open. Discovery is not used.
func (d *Daemon) ConnectInvite(raw string) (Invite, error) {
	inv, err := ParseInvite(raw)
	if err != nil {
		return Invite{}, err
	}
	return inv, d.connectEndpoint(inv.ID, "", inv.Host, inv.Port)
}

// ConnectEndpoint dials a peer at an explicit host when the user already
// has a verified reachable address and the peer device ID. Prefer an invite
// from pair invite when both sides can share one.
func (d *Daemon) ConnectEndpoint(id, name, host string, port int) error {
	if !proto.ValidDeviceID(id) {
		return apiErr("bad_params", "Give a valid device ID")
	}
	host, err := normalizeAddress(host)
	if err != nil {
		return err
	}
	if port == 0 {
		port = lan.MinTCPPort
	}
	if port <= 0 || port > 65535 {
		return apiErr("bad_params", "Port is not valid")
	}
	return d.connectEndpoint(id, name, host, port)
}

func (d *Daemon) connectEndpoint(id, name, host string, port int) error {
	if id == d.selfID {
		return apiErr("bad_params", "That invite is this computer")
	}
	if d.lan == nil {
		return apiErr("not_ready", "fluxd is not listening yet")
	}
	d.mu.Lock()
	dev := d.deviceLocked(id)
	if name != "" {
		dev.Name = proto.CleanName(name)
	} else if dev.Name == "" {
		dev.Name = "peer"
	}
	dev.IP = host
	dev.Port = port
	dev.inviteHost = host
	now := time.Now()
	dev.mdnsSeen = now
	dev.LastSeen = now
	dev.dialTries = 0
	online := dev.link != nil
	d.mu.Unlock()
	d.markDirty()
	if online {
		return nil
	}
	d.lan.DialAny(d.ctx, []string{host}, port, proto.Identity{
		DeviceID: id, DeviceName: name, ProtocolVersion: proto.ProtocolVersion,
	})
	return nil
}

// inviteHostCandidates lists addresses that another computer might reach:
// Tailscale IPv4 first, then other global unicast IPv4 addresses. Loopback
// and link-local addresses stay out.
func (d *Daemon) inviteHostCandidates() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var tailscale, other []string
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		isTailscale := strings.Contains(strings.ToLower(ifc.Name), "tailscale")
		for _, a := range addrs {
			var ip net.IP
			switch v := a.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			ip4 := ip.To4()
			if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() || ip4.IsMulticast() || ip4.IsUnspecified() {
				continue
			}
			s := ip4.String()
			if isTailscale || isTailscaleIP(ip4) {
				if !containsString(tailscale, s) {
					tailscale = append(tailscale, s)
				}
				continue
			}
			if !containsString(other, s) && !containsString(tailscale, s) {
				other = append(other, s)
			}
		}
	}
	return append(tailscale, other...)
}

func isTailscaleIP(ip net.IP) bool {
	// Tailscale CGNAT: 100.64.0.0/10
	return ip[0] == 100 && ip[1] >= 64 && ip[1] <= 127
}

func containsString(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
