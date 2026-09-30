// Package relay is a minimal TCP rendezvous for Flux pairing when neither
// side can dial the other on the LAN or through Tailscale.
//
// Both peers dial out to a shared relay host. One REGISTERs with its device
// ID; the other JOINs that ID. The relay splices the two TCP streams and
// steps out of the way. After the splice, Flux runs its normal plain-identity
// plus TLS handshake on the spliced connection.
//
// Direct LAN or Tailscale paths stay preferred. The relay is optional and
// off by default. It is not STUN/TURN and does not encrypt; Flux TLS still
// protects the session end to end.
package relay

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"flux/internal/proto"
)

const (
	// ProtoName is the first token of every relay handshake line.
	ProtoName = "FLUXRELAY1"
	// DefaultPort is used when a relay URL omits the port.
	DefaultPort = 17777
	// handshakeTimeout bounds the text handshake before the splice.
	handshakeTimeout = 15 * time.Second
)

// NormalizeAddr accepts host:port, [ipv6]:port, or tcp://host:port and
// returns host:port for net.Dial. An empty port becomes DefaultPort.
func NormalizeAddr(raw string) (string, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return "", fmt.Errorf("relay address is empty")
	}
	if strings.Contains(s, "://") {
		u, err := url.Parse(s)
		if err != nil {
			return "", fmt.Errorf("relay address: %w", err)
		}
		if u.Host == "" {
			return "", fmt.Errorf("relay address needs a host")
		}
		s = u.Host
	}
	host, port, err := net.SplitHostPort(s)
	if err != nil {
		// Bare host: add the default port.
		if strings.Contains(s, ":") && !strings.HasPrefix(s, "[") {
			return "", fmt.Errorf("relay address must be host:port")
		}
		host, port = s, fmt.Sprintf("%d", DefaultPort)
	}
	if host == "" {
		return "", fmt.Errorf("relay address needs a host")
	}
	if port == "" {
		port = fmt.Sprintf("%d", DefaultPort)
	}
	return net.JoinHostPort(host, port), nil
}

// HostPort splits a normalized address into host and port number.
func HostPort(addr string) (string, int, error) {
	normalized, err := NormalizeAddr(addr)
	if err != nil {
		return "", 0, err
	}
	host, portStr, err := net.SplitHostPort(normalized)
	if err != nil {
		return "", 0, err
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port <= 0 || port > 65535 {
		return "", 0, fmt.Errorf("relay port is not valid")
	}
	return host, port, nil
}

func handshakeLine(role, deviceID string) string {
	return fmt.Sprintf("%s %s %s\n", ProtoName, role, deviceID)
}

func writeLine(c net.Conn, line string) error {
	_, err := io.WriteString(c, line)
	return err
}

func readResponse(r *bufio.Reader) error {
	line, err := r.ReadString('\n')
	if err != nil {
		return err
	}
	line = strings.TrimSpace(line)
	switch {
	case line == "OK":
		return nil
	case strings.HasPrefix(line, "ERR "):
		return fmt.Errorf("%s", strings.TrimPrefix(line, "ERR "))
	default:
		return fmt.Errorf("unexpected relay reply %q", line)
	}
}

// DialRegister opens a connection to the relay and waits until a peer JOINs
// deviceID. The returned connection is ready for Flux accept().
func DialRegister(ctx context.Context, addr, deviceID string) (net.Conn, error) {
	return dialRole(ctx, addr, "REGISTER", deviceID, 10*time.Minute)
}

// DialJoin opens a connection to the relay and pairs with a peer that
// REGISTERed deviceID. The returned connection is ready for Flux open().
func DialJoin(ctx context.Context, addr, deviceID string) (net.Conn, error) {
	return dialRole(ctx, addr, "JOIN", deviceID, handshakeTimeout)
}

func dialRole(ctx context.Context, addr, role, deviceID string, wait time.Duration) (net.Conn, error) {
	if !proto.ValidDeviceID(deviceID) {
		return nil, fmt.Errorf("device ID is not valid")
	}
	normalized, err := NormalizeAddr(addr)
	if err != nil {
		return nil, err
	}
	d := net.Dialer{Timeout: 10 * time.Second}
	c, err := d.DialContext(ctx, "tcp", normalized)
	if err != nil {
		return nil, err
	}
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = c.SetDeadline(time.Now())
		case <-done:
		}
	}()
	_ = c.SetDeadline(time.Now().Add(wait))
	if err := writeLine(c, handshakeLine(role, deviceID)); err != nil {
		c.Close()
		return nil, err
	}
	br := bufio.NewReader(c)
	if err := readResponse(br); err != nil {
		c.Close()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, err
	}
	if br.Buffered() > 0 {
		c.Close()
		return nil, fmt.Errorf("relay sent data before the Flux handshake")
	}
	_ = c.SetDeadline(time.Time{})
	return c, nil
}

// Server matches REGISTER and JOIN by device ID and splices the two TCP
// streams. It is a test helper and a small self-hosted broker, not a
// production TURN service.
type Server struct {
	Logf func(format string, args ...any)

	mu    sync.Mutex
	wait  map[string]waiting // device ID → REGISTER waiting for JOIN
	conns int
}

type waiting struct {
	conn net.Conn
	ch   chan net.Conn // receives the JOIN conn, or nil on cancel
}

// NewServer returns an empty relay server.
func NewServer() *Server {
	return &Server{wait: map[string]waiting{}, Logf: func(string, ...any) {}}
}

// Serve accepts connections on ln until the listener closes.
func (s *Server) Serve(ln net.Listener) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			return err
		}
		s.mu.Lock()
		s.conns++
		s.mu.Unlock()
		go s.handle(c)
	}
}

func (s *Server) handle(c net.Conn) {
	defer func() {
		s.mu.Lock()
		s.conns--
		s.mu.Unlock()
	}()
	_ = c.SetDeadline(time.Now().Add(handshakeTimeout))
	r := bufio.NewReaderSize(c, 512)
	line, err := r.ReadString('\n')
	if err != nil {
		c.Close()
		return
	}
	role, id, err := parseHello(strings.TrimSpace(line))
	if err != nil {
		_ = writeLine(c, "ERR "+err.Error()+"\n")
		c.Close()
		return
	}
	if r.Buffered() > 0 {
		_ = writeLine(c, "ERR leftover bytes after handshake\n")
		c.Close()
		return
	}
	_ = c.SetDeadline(time.Time{})

	switch role {
	case "REGISTER":
		s.register(c, id)
	case "JOIN":
		s.join(c, id)
	default:
		_ = writeLine(c, "ERR unknown role\n")
		c.Close()
	}
}

func parseHello(line string) (role, id string, err error) {
	parts := strings.Fields(line)
	if len(parts) != 3 || parts[0] != ProtoName {
		return "", "", fmt.Errorf("want %s ROLE DEVICE_ID", ProtoName)
	}
	role, id = parts[1], parts[2]
	if role != "REGISTER" && role != "JOIN" {
		return "", "", fmt.Errorf("role must be REGISTER or JOIN")
	}
	if !proto.ValidDeviceID(id) {
		return "", "", fmt.Errorf("device ID is not valid")
	}
	return role, id, nil
}

func (s *Server) register(c net.Conn, id string) {
	s.mu.Lock()
	if old, ok := s.wait[id]; ok {
		close(old.ch)
		old.conn.Close()
		delete(s.wait, id)
	}
	ch := make(chan net.Conn, 1)
	s.wait[id] = waiting{conn: c, ch: ch}
	s.mu.Unlock()
	s.Logf("register %s waiting", id)

	select {
	case peer, ok := <-ch:
		if !ok || peer == nil {
			c.Close()
			return
		}
		if err := writeLine(c, "OK\n"); err != nil {
			c.Close()
			peer.Close()
			return
		}
		if err := writeLine(peer, "OK\n"); err != nil {
			c.Close()
			peer.Close()
			return
		}
		s.Logf("splice %s", id)
		splice(c, peer)
	case <-time.After(10 * time.Minute):
		s.mu.Lock()
		if w, ok := s.wait[id]; ok && w.conn == c {
			delete(s.wait, id)
		}
		s.mu.Unlock()
		_ = writeLine(c, "ERR register timed out\n")
		c.Close()
	}
}

func (s *Server) join(c net.Conn, id string) {
	s.mu.Lock()
	w, ok := s.wait[id]
	if ok {
		delete(s.wait, id)
	}
	s.mu.Unlock()
	if !ok {
		_ = writeLine(c, "ERR no register for that device\n")
		c.Close()
		return
	}
	select {
	case w.ch <- c:
	default:
		c.Close()
		w.conn.Close()
	}
}

func splice(a, b net.Conn) {
	defer a.Close()
	defer b.Close()
	var wg sync.WaitGroup
	wg.Add(2)
	copy := func(dst, src net.Conn) {
		defer wg.Done()
		_, _ = io.Copy(dst, src)
		// Unblock the other direction.
		type closeWriter interface{ CloseWrite() error }
		if cw, ok := dst.(closeWriter); ok {
			_ = cw.CloseWrite()
		}
	}
	go copy(a, b)
	go copy(b, a)
	wg.Wait()
}
