package core

import (
	"context"
	"net"
	"strings"
	"time"

	"flux/internal/proto"
	"flux/internal/relay"
)

// useRelay reports whether pairing and desk-peer dials should go through
// the configured rendezvous host.
func (d *Daemon) useRelay() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.cfg != nil && d.cfg.Relay && strings.TrimSpace(d.cfg.RelayURL) != ""
}

func (d *Daemon) relayAddr() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.cfg == nil {
		return ""
	}
	return strings.TrimSpace(d.cfg.RelayURL)
}

// wakeRelay asks relayLoop to re-read the setting (on/off or URL change).
func (d *Daemon) wakeRelay() {
	select {
	case d.relayWake <- struct{}{}:
	default:
	}
}

// relayLoop keeps one REGISTER on the rendezvous host while relay is on,
// so a joiner (or a reconnecting peer) can splice into this computer.
func (d *Daemon) relayLoop(ctx context.Context) {
	var cancel context.CancelFunc
	stop := func() {
		if cancel != nil {
			cancel()
			cancel = nil
		}
	}
	defer stop()
	for {
		if !d.useRelay() {
			stop()
			select {
			case <-ctx.Done():
				return
			case <-d.relayWake:
				continue
			}
		}
		stop()
		rctx, c := context.WithCancel(ctx)
		cancel = c
		go d.registerOnce(rctx)
		select {
		case <-ctx.Done():
			return
		case <-d.relayWake:
		}
	}
}

func (d *Daemon) registerOnce(ctx context.Context) {
	addr := d.relayAddr()
	if addr == "" || d.lan == nil {
		return
	}
	backoff := time.Second
	for {
		if ctx.Err() != nil {
			return
		}
		conn, err := relay.DialRegister(ctx, addr, d.selfID)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			d.logf("relay register: %v", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			if backoff < 30*time.Second {
				backoff *= 2
			}
			continue
		}
		backoff = time.Second
		d.logf("relay: peer joined through %s", addr)
		d.lan.AcceptConn(conn)
		// AcceptConn returns when the handshake finishes or fails. Register
		// again so the next joiner can connect while relay stays on.
	}
}

// dialViaRelay JOINs the peer device ID on the rendezvous host, then runs
// the outgoing Flux handshake on the spliced connection. Retries briefly
// so a peer that just woke its REGISTER can finish dialing first.
func (d *Daemon) dialViaRelay(id, name string) {
	if d.lan == nil || !proto.ValidDeviceID(id) || id == d.selfID {
		return
	}
	addr := d.relayAddr()
	if addr == "" {
		return
	}
	ctx, cancel := context.WithTimeout(d.ctx, 25*time.Second)
	defer cancel()
	var (
		conn net.Conn
		err  error
	)
	for attempt := 0; attempt < 8; attempt++ {
		if ctx.Err() != nil {
			return
		}
		conn, err = relay.DialJoin(ctx, addr, id)
		if err == nil {
			break
		}
		// "no register for that device" is the usual race after invite.
		select {
		case <-ctx.Done():
			d.logf("relay join %s: %v", nameOrID(name, id), err)
			return
		case <-time.After(time.Duration(attempt+1) * 250 * time.Millisecond):
		}
	}
	if err != nil {
		d.logf("relay join %s: %v", nameOrID(name, id), err)
		return
	}
	ok := d.lan.OpenConn(conn, proto.Identity{
		DeviceID: id, DeviceName: name, ProtocolVersion: proto.ProtocolVersion,
	})
	if !ok {
		d.logf("relay: Flux handshake with %s failed", nameOrID(name, id))
	}
}

// connectShouldRelay is true when the invite endpoint is this computer's
// configured rendezvous host. A Tailscale or LAN invite still dials direct
// even if relay is on.
func (d *Daemon) connectShouldRelay(host string, port int) bool {
	if !d.useRelay() {
		return false
	}
	rHost, rPort, err := relay.HostPort(d.relayAddr())
	if err != nil {
		return false
	}
	return strings.EqualFold(host, rHost) && port == rPort
}

func nameOrID(name, id string) string {
	if name != "" {
		return name
	}
	return id
}

// dialTarget dials one offline target. LAN/Tailscale hosts stay preferred
// when known. Desk peers also JOIN the rendezvous host when relay is on so
// invite/reconnect still works with no direct path. Phones stay direct-only.
func (d *Daemon) dialTarget(hosts []string, port int, id proto.Identity, deskPeer bool) {
	if port > 0 && len(hosts) > 0 {
		d.lan.DialAny(d.ctx, hosts, port, id)
	}
	if d.useRelay() && deskPeer {
		go d.dialViaRelay(id.DeviceID, id.DeviceName)
	}
}

func isDeskType(t string) bool {
	switch strings.ToLower(strings.TrimSpace(t)) {
	case "desktop", "laptop", "computer":
		return true
	default:
		return false
	}
}

// normalizeRelayURL validates and canonicalizes a relay host:port value for
// config.toml and settings.set.
func normalizeRelayURL(raw string) (string, error) {
	return relay.NormalizeAddr(raw)
}
