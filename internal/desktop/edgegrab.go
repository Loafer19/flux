package desktop

import (
	"errors"
	"fmt"
	"sync"
	"time"
)

// EdgeButton is one mouse button press or release observed while the local
// cursor is leased to a peer.
type EdgeButton struct {
	Button  uint32
	Pressed bool
}

// EdgeScroll is one axis event observed while the local cursor is leased.
type EdgeScroll struct {
	DX, DY float64
}

// EdgeGrab is a fullscreen transparent overlay that sits above windows while
// the peer holds the pointer. Apps under it should not see hover. Button and
// scroll events on the overlay are forwarded through Buttons and Scrolls.
type EdgeGrab struct {
	mu      sync.Mutex
	conn    *wlConn
	buttons chan EdgeButton
	scrolls chan EdgeScroll
	stop    chan struct{}
	done    chan struct{}
}

const (
	ifaceCompositor  = "wl_compositor"
	ifaceSeat        = "wl_seat"
	ifaceLayerShell  = "zwlr_layer_shell_v1"
	ifaceSinglePixel = "wp_single_pixel_buffer_manager_v1"

	compositorCreateSurface = 0
	compositorCreateRegion  = 1

	surfaceAttach          = 1
	surfaceSetOpaqueRegion = 4
	surfaceSetInputRegion  = 5
	surfaceCommit          = 6
	surfaceDamageBuffer    = 9
	surfaceDestroy         = 0

	regionAdd = 1

	seatGetPointer = 0

	pointerSetCursor = 0
	pointerEnter     = 0
	pointerButton    = 3
	pointerAxis      = 4

	layerShellGetSurface = 0
	layerOverlay         = 3
	layerAnchorAll       = 1 | 2 | 4 | 8

	layerSurfaceSetSize                  = 0
	layerSurfaceSetAnchor                = 1
	layerSurfaceSetExclusiveZone         = 2
	layerSurfaceSetKeyboardInteractivity = 4
	layerSurfaceAckConfigure             = 6
	layerSurfaceDestroy                  = 7
	layerSurfaceConfigure                = 0
	layerSurfaceClosed                   = 1

	spbCreateU32RGBABuffer = 1

	seatCapPointer = 2
)

// StartEdgeGrab maps a fullscreen overlay and listens for pointer buttons
// and scroll axes.
func StartEdgeGrab() (*EdgeGrab, error) {
	w, err := dialWayland()
	if err != nil {
		return nil, err
	}
	_ = w.c.SetReadDeadline(time.Now().Add(3 * time.Second))

	registry := w.newID()
	globals := map[string]wlGlobal{}
	err = w.roundTrip(w.msg(displayID, displayGetRegistry, registry), func(obj uint32, op uint16, body []byte) {
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
	})
	if err != nil {
		w.close()
		return nil, err
	}
	for _, need := range []string{ifaceCompositor, ifaceSeat, ifaceLayerShell, ifaceSinglePixel} {
		if _, ok := globals[need]; !ok {
			w.close()
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
		w.close()
		return nil, err
	}

	surf := w.newID()
	lsurf := w.newID()
	if err := w.write(
		w.msg(comp, compositorCreateSurface, surf),
		w.msg(layerShell, layerShellGetSurface, lsurf, surf, uint32(0), uint32(layerOverlay), "flux-edge"),
		w.msg(lsurf, layerSurfaceSetSize, uint32(0), uint32(0)),
		w.msg(lsurf, layerSurfaceSetAnchor, uint32(layerAnchorAll)),
		w.msg(lsurf, layerSurfaceSetExclusiveZone, int32(-1)),
		w.msg(lsurf, layerSurfaceSetKeyboardInteractivity, uint32(0)),
		w.msg(surf, surfaceCommit),
	); err != nil {
		w.close()
		return nil, err
	}

	var serial, width, height uint32
	deadline := time.Now().Add(2 * time.Second)
	for serial == 0 && time.Now().Before(deadline) {
		_ = w.c.SetReadDeadline(deadline)
		obj, op, body, err := w.read()
		if err != nil {
			w.close()
			return nil, fmt.Errorf("layer configure: %w", err)
		}
		if obj == displayID && op == 0 {
			w.close()
			return nil, displayError(body)
		}
		if obj == lsurf && op == layerSurfaceConfigure {
			serial, body = wlUint(body)
			width, body = wlUint(body)
			height, _ = wlUint(body)
		}
	}
	if serial == 0 || width == 0 || height == 0 {
		w.close()
		return nil, errors.New("layer surface did not configure")
	}

	buf := w.newID()
	region := w.newID()
	ptr := w.newID()
	// Fully transparent pixel; input region covers the whole surface.
	if err := w.write(
		w.msg(lsurf, layerSurfaceAckConfigure, serial),
		w.msg(spb, spbCreateU32RGBABuffer, buf, uint32(0), uint32(0), uint32(0), uint32(0)),
		w.msg(comp, compositorCreateRegion, region),
		w.msg(region, regionAdd, int32(0), int32(0), int32(width), int32(height)),
		w.msg(surf, surfaceSetInputRegion, region),
		w.msg(surf, surfaceAttach, buf, int32(0), int32(0)),
		w.msg(surf, surfaceDamageBuffer, int32(0), int32(0), int32(width), int32(height)),
		w.msg(surf, surfaceCommit),
		w.msg(seat, seatGetPointer, ptr),
	); err != nil {
		w.close()
		return nil, err
	}
	if err := w.roundTrip(nil, nil); err != nil {
		w.close()
		return nil, err
	}
	_ = w.c.SetReadDeadline(time.Time{})

	g := &EdgeGrab{
		conn:    w,
		buttons: make(chan EdgeButton, 32),
		scrolls: make(chan EdgeScroll, 32),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
	}
	go g.loop(lsurf, surf, ptr)
	return g, nil
}

// Buttons is the stream of presses and releases on the overlay.
func (g *EdgeGrab) Buttons() <-chan EdgeButton { return g.buttons }

// Scrolls is the stream of axis events on the overlay.
func (g *EdgeGrab) Scrolls() <-chan EdgeScroll { return g.scrolls }

// Stop unmaps the overlay and closes the Wayland connection.
func (g *EdgeGrab) Stop() {
	if g == nil {
		return
	}
	g.mu.Lock()
	select {
	case <-g.stop:
		g.mu.Unlock()
		return
	default:
		close(g.stop)
	}
	g.mu.Unlock()
	<-g.done
}

func (g *EdgeGrab) loop(lsurf, surf, ptr uint32) {
	defer close(g.done)
	defer g.conn.close()
	defer close(g.buttons)
	defer close(g.scrolls)

	for {
		select {
		case <-g.stop:
			_ = g.conn.write(
				g.conn.msg(lsurf, layerSurfaceDestroy),
				g.conn.msg(surf, surfaceDestroy),
			)
			return
		default:
		}
		_ = g.conn.c.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
		obj, op, body, err := g.conn.read()
		if err != nil {
			select {
			case <-g.stop:
				return
			default:
				// timeout: keep waiting
				continue
			}
		}
		switch {
		case obj == displayID && op == 0:
			g.conn.mu.Lock()
			g.conn.err = displayError(body)
			g.conn.mu.Unlock()
			return
		case obj == lsurf && op == layerSurfaceClosed:
			return
		case obj == ptr && op == pointerEnter:
			serial, _ := wlUint(body)
			_ = g.conn.write(g.conn.msg(ptr, pointerSetCursor, serial, uint32(0), int32(0), int32(0)))
		case obj == ptr && op == pointerButton:
			_, rest := wlUint(body) // time
			button, rest := wlUint(rest)
			state, _ := wlUint(rest)
			ev := EdgeButton{Button: button, Pressed: state == 1}
			select {
			case g.buttons <- ev:
			default:
			}
		case obj == ptr && op == pointerAxis:
			_, rest := wlUint(body) // time
			axis, rest := wlUint(rest)
			val, _ := wlFixed(rest)
			ev := EdgeScroll{}
			if axis == 0 {
				ev.DY = val
			} else {
				ev.DX = val
			}
			if ev.DX == 0 && ev.DY == 0 {
				continue
			}
			select {
			case g.scrolls <- ev:
			default:
			}
		}
	}
}
