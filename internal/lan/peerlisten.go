package lan

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"time"
)

// PeerListener is a TLS payload listener on a port from 1739 to 1764.
// A paired peer dials it the same way fluxd dials a phone remote-desktop
// listener: this side is the TLS server and checks the pinned certificate.
type PeerListener struct {
	ln   net.Listener
	port int
	link *Link
}

// ListenPeer opens a free payload port for a peer to dial.
func (l *Link) ListenPeer(ctx context.Context) (*PeerListener, error) {
	ln, port, err := listenPayload(ctx)
	if err != nil {
		return nil, err
	}
	return &PeerListener{ln: ln, port: port, link: l}, nil
}

// Port is the TCP port the peer must dial.
func (p *PeerListener) Port() int { return p.port }

// Close stops accepting connections.
func (p *PeerListener) Close() error {
	if p == nil || p.ln == nil {
		return nil
	}
	return p.ln.Close()
}

// Accept waits for the peer, completes the TLS handshake as the server,
// and checks that the certificate matches the link.
func (p *PeerListener) Accept(ctx context.Context) (*tls.Conn, error) {
	if p == nil || p.ln == nil {
		return nil, errors.New("no peer listener")
	}
	type result struct {
		c   net.Conn
		err error
	}
	ch := make(chan result, 1)
	go func() {
		c, err := p.ln.Accept()
		ch <- result{c, err}
	}()
	var conn net.Conn
	select {
	case r := <-ch:
		if r.err != nil {
			return nil, r.err
		}
		conn = r.c
		setUserTimeout(conn)
	case <-ctx.Done():
		_ = p.ln.Close()
		return nil, ctx.Err()
	case <-p.link.done:
		_ = p.ln.Close()
		return nil, net.ErrClosed
	case <-time.After(20 * time.Second):
		_ = p.ln.Close()
		return nil, errors.New("the peer did not connect to the stream listener")
	}
	tc := tls.Server(conn, serverConfig(p.link.provider.cfg.Cert))
	_ = tc.SetDeadline(time.Now().Add(15 * time.Second))
	if err := tc.HandshakeContext(ctx); err != nil {
		tc.Close()
		return nil, fmt.Errorf("peer stream TLS: %w", err)
	}
	if err := p.link.checkPeer(tc); err != nil {
		tc.Close()
		return nil, err
	}
	_ = tc.SetDeadline(time.Time{})
	return tc, nil
}
