package core

import (
	"context"
	"fmt"
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

func (d *Daemon) markRelayWaiting(on bool) {
	d.mu.Lock()
	d.relayWaiting = on
	ch := d.relayWaitCh
	d.mu.Unlock()
	if on && ch != nil {
		select {
		case <-ch:
		default:
			close(ch)
		}
	}
}

func (d *Daemon) resetRelayWaitCh() {
	d.mu.Lock()
	d.relayWaiting = false
	d.relayWaitCh = make(chan struct{})
	d.mu.Unlock()
}

// waitRelayReady waits until REGISTER is listed on the rendezvous host, or
// until timeout / context cancel. Used before pair.invite so the joiner's
// JOIN finds a waiter.
func (d *Daemon) waitRelayReady(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		d.mu.Lock()
		if d.relayWaiting {
			d.mu.Unlock()
			return nil
		}
		err := d.relayLastErr
		ch := d.relayWaitCh
		d.mu.Unlock()
		remain := time.Until(deadline)
		if remain <= 0 {
			if err != nil {
				return fmt.Errorf("relay host not ready: %w", err)
			}
			return fmt.Errorf("relay host not ready (is flux-cli relay serve running, and is relay_url reachable?)")
		}
		wait := 200 * time.Millisecond
		if wait > remain {
			wait = remain
		}
		timer := time.NewTimer(wait)
		select {
		case <-d.ctx.Done():
			timer.Stop()
			return d.ctx.Err()
		case <-ch:
			timer.Stop()
		case <-timer.C:
		}
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
		d.markRelayWaiting(false)
	}
	defer stop()
	for {
		if !d.useRelay() {
			stop()
			d.mu.Lock()
			d.relayLastErr = nil
			d.mu.Unlock()
			select {
			case <-ctx.Done():
				return
			case <-d.relayWake:
				continue
			}
		}
		stop()
		d.resetRelayWaitCh()
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
			d.markRelayWaiting(false)
			return
		}
		conn, err := relay.DialRegisterReady(ctx, addr, d.selfID, func() {
			d.mu.Lock()
			d.relayLastErr = nil
			d.mu.Unlock()
			d.markRelayWaiting(true)
		})
		d.markRelayWaiting(false)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			d.mu.Lock()
			d.relayLastErr = err
			d.mu.Unlock()
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
		d.mu.Lock()
		d.relayLastErr = nil
		d.mu.Unlock()
		d.logf("relay: peer joined through %s", addr)
		d.lan.AcceptConn(conn)
		// AcceptConn returns when the handshake finishes or fails. Register
		// again so the next joiner can connect while relay stays on.
		d.resetRelayWaitCh()
	}
}

// dialViaRelay JOINs the peer device ID on the configured rendezvous host.
func (d *Daemon) dialViaRelay(id, name string) error {
	return d.dialViaRelayAddr(d.relayAddr(), id, name, 25*time.Second)
}

// dialViaRelayAddr JOINs id on an explicit rendezvous address (invite host).
func (d *Daemon) dialViaRelayAddr(addr, id, name string, timeout time.Duration) error {
	if d.lan == nil || !proto.ValidDeviceID(id) || id == d.selfID {
		return fmt.Errorf("relay join is not available")
	}
	addr = strings.TrimSpace(addr)
	if addr == "" {
		return fmt.Errorf("relay URL is empty")
	}
	ctx, cancel := context.WithTimeout(d.ctx, timeout)
	defer cancel()
	var (
		conn net.Conn
		err  error
	)
	for attempt := 0; attempt < 8; attempt++ {
		if ctx.Err() != nil {
			return fmt.Errorf("relay join %s: %w", nameOrID(name, id), ctx.Err())
		}
		conn, err = relay.DialJoin(ctx, addr, id)
		if err == nil {
			break
		}
		// "no register for that device" is the usual race after invite.
		select {
		case <-ctx.Done():
			d.logf("relay join %s: %v", nameOrID(name, id), err)
			return fmt.Errorf("relay join %s: %w", nameOrID(name, id), err)
		case <-time.After(time.Duration(attempt+1) * 250 * time.Millisecond):
		}
	}
	if err != nil {
		d.logf("relay join %s: %v", nameOrID(name, id), err)
		return fmt.Errorf("relay join %s: %w", nameOrID(name, id), err)
	}
	ok := d.lan.OpenConn(conn, proto.Identity{
		DeviceID: id, DeviceName: name, ProtocolVersion: proto.ProtocolVersion,
	})
	if !ok {
		d.logf("relay: Flux handshake with %s failed", nameOrID(name, id))
		return fmt.Errorf("relay: Flux handshake with %s failed", nameOrID(name, id))
	}
	return nil
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
	return relay.SameEndpoint(host, port, rHost, rPort)
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
func (d *Daemon) dialTarget(addrs []string, id proto.Identity, deskPeer bool) {
	if d.lan != nil && len(addrs) > 0 {
		d.lan.DialAddrs(d.ctx, addrs, id)
	}
	if d.useRelay() && deskPeer {
		go func() { _ = d.dialViaRelay(id.DeviceID, id.DeviceName) }()
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
