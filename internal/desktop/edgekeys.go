package desktop

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// EdgeKeyGrab maps a fullscreen transparent layer that takes exclusive
// keyboard focus while a peer drives this pointer. Local key presses are
// recorded so fluxd can reclaim without reading /dev/input (no input group).
// The pointer input region is an empty wl_region so pointer events pass
// through to windows below. A NULL region would mean infinite (whole
// surface), which swallows remote clicks and blocks local mouse reclaim.
type EdgeKeyGrab struct {
	mu   sync.Mutex
	last time.Time
	conn *net.UnixConn
	stop chan struct{}
	done chan struct{}
	once sync.Once
}

const (
	seatGetKeyboard = 1

	keyboardKeymap = 0
	keyboardEnter  = 1
	keyboardLeave  = 2
	keyboardKey    = 3

	keyStatePressed = 1

	layerKeyboardExclusive = 1
)

// StartEdgeKeyGrab maps the overlay and watches wl_keyboard key events.
func StartEdgeKeyGrab() (*EdgeKeyGrab, error) {
	c, err := dialUnixWayland()
	if err != nil {
		return nil, err
	}
	w := &wlFDConn{c: c, nextID: displayID + 1}
	_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))

	registry := w.newID()
	globals := map[string]wlGlobal{}
	if err := w.roundTrip(w.msg(displayID, displayGetRegistry, registry), func(obj uint32, op uint16, body []byte) {
		if obj != registry || op != 0 {
			return
		}
		name, rest := wlUint(body)
		iface, rest := wlString(rest)
		version, _ := wlUint(rest)
		switch iface {
		case ifaceCompositor, ifaceSeat, ifaceLayerShell, ifaceSinglePixel:
			globals[iface] = wlGlobal{name, version}
		}
	}); err != nil {
		_ = c.Close()
		return nil, err
	}
	for _, need := range []string{ifaceCompositor, ifaceSeat, ifaceLayerShell, ifaceSinglePixel} {
		if _, ok := globals[need]; !ok {
			_ = c.Close()
			return nil, fmt.Errorf("the compositor does not offer %s", need)
		}
	}

	bind := func(iface string, ver uint32) uint32 {
		g := globals[iface]
		id := w.newID()
		_ = w.write(w.msg(registry, registryBind, g.name, iface, min(g.version, ver), id))
		return id
	}
	comp := bind(ifaceCompositor, 4)
	layerShell := bind(ifaceLayerShell, 4)
	seat := bind(ifaceSeat, 5)
	spb := bind(ifaceSinglePixel, 1)
	if err := w.roundTrip(nil, nil); err != nil {
		_ = c.Close()
		return nil, err
	}
	// Empty region: no rects → surface accepts no pointer/touch (NULL would
	// mean infinite and swallow clicks). Create it before the layer surface
	// so the compositor accepts it on a fresh connection.
	empty := w.newID()
	if err := w.write(w.msg(comp, compositorCreateRegion, empty)); err != nil {
		_ = c.Close()
		return nil, err
	}
	if err := w.roundTrip(nil, nil); err != nil {
		_ = c.Close()
		return nil, err
	}

	surf := w.newID()
	lsurf := w.newID()
	if err := w.write(
		w.msg(comp, compositorCreateSurface, surf),
		w.msg(layerShell, layerShellGetSurface, lsurf, surf, uint32(0), uint32(layerOverlay), "flux-edge-keys"),
		w.msg(lsurf, layerSurfaceSetSize, uint32(0), uint32(0)),
		w.msg(lsurf, layerSurfaceSetAnchor, uint32(layerAnchorAll)),
		w.msg(lsurf, layerSurfaceSetExclusiveZone, int32(-1)),
		w.msg(lsurf, layerSurfaceSetKeyboardInteractivity, uint32(layerKeyboardExclusive)),
		w.msg(surf, surfaceCommit),
	); err != nil {
		_ = c.Close()
		return nil, err
	}

	var serial, width, height uint32
	deadline := time.Now().Add(2 * time.Second)
	for serial == 0 && time.Now().Before(deadline) {
		_ = c.SetReadDeadline(deadline)
		obj, op, body, _, err := w.read()
		if err != nil {
			_ = c.Close()
			return nil, fmt.Errorf("layer configure: %w", err)
		}
		if obj == displayID && op == 0 {
			_ = c.Close()
			return nil, displayError(body)
		}
		if obj == lsurf && op == layerSurfaceConfigure {
			serial, body = wlUint(body)
			width, body = wlUint(body)
			height, _ = wlUint(body)
		}
	}
	if serial == 0 || width == 0 || height == 0 {
		_ = c.Close()
		return nil, errors.New("layer surface did not configure")
	}

	buf := w.newID()
	kbd := w.newID()
	// Transparent pixel; apply the empty input region created above.
	if err := w.write(
		w.msg(lsurf, layerSurfaceAckConfigure, serial),
		w.msg(spb, spbCreateU32RGBABuffer, buf, uint32(0), uint32(0), uint32(0), uint32(0)),
		w.msg(surf, surfaceSetInputRegion, empty),
		w.msg(surf, surfaceAttach, buf, int32(0), int32(0)),
		w.msg(surf, surfaceDamageBuffer, int32(0), int32(0), int32(width), int32(height)),
		w.msg(surf, surfaceCommit),
		w.msg(seat, seatGetKeyboard, kbd),
	); err != nil {
		_ = c.Close()
		return nil, err
	}
	if err := w.roundTrip(nil, nil); err != nil {
		_ = c.Close()
		return nil, err
	}
	_ = c.SetReadDeadline(time.Time{})

	g := &EdgeKeyGrab{
		conn: c,
		stop: make(chan struct{}),
		done: make(chan struct{}),
	}
	go g.loop(w, lsurf, surf, kbd)
	return g, nil
}

// ActiveSince reports whether a key was pressed at or after t.
func (g *EdgeKeyGrab) ActiveSince(t time.Time) bool {
	if g == nil {
		return false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	return !g.last.IsZero() && !g.last.Before(t)
}

// Stop unmaps the overlay and closes the Wayland connection.
func (g *EdgeKeyGrab) Stop() {
	if g == nil {
		return
	}
	g.once.Do(func() {
		close(g.stop)
		<-g.done
	})
}

func (g *EdgeKeyGrab) loop(w *wlFDConn, lsurf, surf, kbd uint32) {
	defer close(g.done)
	defer g.conn.Close()

	for {
		select {
		case <-g.stop:
			_ = w.write(
				w.msg(lsurf, layerSurfaceDestroy),
				w.msg(surf, surfaceDestroy),
			)
			return
		default:
		}
		_ = g.conn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
		obj, op, body, fds, err := w.read()
		for _, fd := range fds {
			_ = unix.Close(fd)
		}
		if err != nil {
			select {
			case <-g.stop:
				return
			default:
				continue
			}
		}
		switch {
		case obj == displayID && op == 0:
			return
		case obj == lsurf && op == layerSurfaceClosed:
			return
		case obj == kbd && op == keyboardKey:
			_, rest := wlUint(body) // time
			_, rest = wlUint(rest)  // key
			state, _ := wlUint(rest)
			if state == keyStatePressed {
				g.mu.Lock()
				g.last = time.Now()
				g.mu.Unlock()
			}
		}
	}
}

func dialUnixWayland() (*net.UnixConn, error) {
	name := os.Getenv("WAYLAND_DISPLAY")
	if name == "" {
		name = "wayland-0"
	}
	path := name
	if !filepath.IsAbs(path) {
		dir := os.Getenv("XDG_RUNTIME_DIR")
		if dir == "" {
			return nil, errors.New("XDG_RUNTIME_DIR is not set")
		}
		path = filepath.Join(dir, name)
	}
	c, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return nil, fmt.Errorf("connect to the Wayland display: %w", err)
	}
	return c, nil
}

// wlFDConn is a Wayland client connection that drains SCM_RIGHTS file
// descriptors (needed for wl_keyboard.keymap) instead of leaving them open.
type wlFDConn struct {
	c       *net.UnixConn
	nextID  uint32
	pending []byte
	fds     []int
}

func (w *wlFDConn) newID() uint32 {
	id := w.nextID
	w.nextID++
	return id
}

func (w *wlFDConn) msg(obj uint32, op uint16, args ...any) []byte {
	return (&wlConn{}).msg(obj, op, args...)
}

func (w *wlFDConn) write(msgs ...[]byte) error {
	var b []byte
	for _, m := range msgs {
		b = append(b, m...)
	}
	_ = w.c.SetWriteDeadline(time.Now().Add(wlWriteWait))
	_, err := w.c.Write(b)
	return err
}

func (w *wlFDConn) read() (obj uint32, op uint16, body []byte, fds []int, err error) {
	for len(w.pending) < 8 {
		if err = w.fill(); err != nil {
			return
		}
	}
	obj = binary.NativeEndian.Uint32(w.pending[0:])
	so := binary.NativeEndian.Uint32(w.pending[4:])
	size, op := so>>16, uint16(so&0xffff)
	if size < 8 {
		err = fmt.Errorf("wayland: event of %d bytes", size)
		return
	}
	for uint32(len(w.pending)) < size {
		if err = w.fill(); err != nil {
			return
		}
	}
	body = append([]byte(nil), w.pending[8:size]...)
	w.pending = w.pending[size:]
	fds = w.fds
	w.fds = nil
	return
}

func (w *wlFDConn) fill() error {
	buf := make([]byte, 4096)
	oob := make([]byte, unix.CmsgSpace(4*8)) // up to 8 fds
	n, oobn, _, _, err := w.c.ReadMsgUnix(buf, oob)
	if err != nil {
		return err
	}
	if n > 0 {
		w.pending = append(w.pending, buf[:n]...)
	}
	if oobn > 0 {
		scms, err := unix.ParseSocketControlMessage(oob[:oobn])
		if err != nil {
			return err
		}
		for _, scm := range scms {
			rights, err := unix.ParseUnixRights(&scm)
			if err != nil {
				continue
			}
			w.fds = append(w.fds, rights...)
		}
	}
	return nil
}

func (w *wlFDConn) roundTrip(req []byte, handle func(obj uint32, op uint16, body []byte)) error {
	done := w.newID()
	msgs := [][]byte{w.msg(displayID, displaySync, done)}
	if req != nil {
		msgs = append([][]byte{req}, msgs...)
	}
	if err := w.write(msgs...); err != nil {
		return err
	}
	for {
		obj, op, body, fds, err := w.read()
		for _, fd := range fds {
			_ = unix.Close(fd)
		}
		if err != nil {
			return fmt.Errorf("wayland: %w", err)
		}
		switch {
		case obj == displayID && op == 0:
			return displayError(body)
		case obj == done:
			return nil
		case handle != nil:
			handle(obj, op, body)
		}
	}
}
