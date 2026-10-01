package core

import (
	"context"
	"math"
	"strings"
	"time"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// edgeKeyWatcher records local key activity while a peer drives this pointer.
type edgeKeyWatcher interface {
	ActiveSince(t time.Time) bool
	Stop()
}

const (
	edgeMargin = 6.0
	edgeReturn = 48.0
	edgeTick   = 20 * time.Millisecond
	// edgeLocalGrace ignores compositor lag after a remote enter/move before
	// comparing the live cursor to the expected remote position.
	edgeLocalGrace = 50 * time.Millisecond
	// edgeLocalThresh is how far the live cursor may drift from the expected
	// remote position before local mouse takes the pointer back (logical px).
	edgeLocalThresh = 10.0
)

// edgeLoop watches the cursor. When it crosses the configured edge onto a
// paired computer, later motion goes there until the pointer comes back.
//
// While the peer holds the pointer, this desk parks the local cursor on the
// status-bar corner, hides it, disables focus-follows-mouse, and maps a
// transparent overlay so tiled windows under the park point do not catch
// hover (Barrier-style). Absolute warps avoid the compositor clamping motion
// past the physical edge. Button presses on the overlay are forwarded.
func (d *Daemon) edgeLoop(ctx context.Context) {
	var (
		lease    bool
		skip     bool
		seen     bool
		wasHit   bool
		anchor   desktop.HyprCursor
		along    desktop.HyprCursor
		depth    float64
		held     *lan.Link
		sideHeld string
		logged   string
		// needRecover is set after any Begin so a later edge-off path still
		// runs End even if the Go lease bit was already cleared by a race.
		needRecover bool
	)
	var grab *desktop.EdgeGrab
	stopGrab := func() {
		if grab != nil {
			grab.Stop()
			grab = nil
		}
	}
	// warpBack puts the pointer on-screen after a lease. Prefer the seam
	// inset; fall back to the screen center so "edge off" never leaves the
	// cursor parked at the status-bar corner (often 2,2) invisible.
	warpBack := func(screens []desktop.Monitor, at desktop.HyprCursor) {
		if len(screens) == 0 {
			if _, s, err := desktop.HyprLayout(); err == nil {
				screens = s
			}
		}
		if x, y, ok := desktop.EdgeInside(sideHeld, at, screens, edgeReturn); ok {
			_ = desktop.HyprMoveCursor(x, y)
			return
		}
		if x, y, ok := desktop.ScreenCenter(screens); ok {
			_ = desktop.HyprMoveCursor(x, y)
		}
	}
	release := func(link *lan.Link, screens []desktop.Monitor, at desktop.HyprCursor) {
		if link != nil {
			d.sendEdge(link, "leave", 0, 0)
		}
		stopGrab()
		_ = desktop.HyprEndPointerLease()
		warpBack(screens, at)
		lease = false
		needRecover = false
		depth = 0
		wasHit = true // stay armed until the cursor leaves the margin
		held = nil
		sideHeld = ""
	}
	forceReset := func() {
		_, screens, _ := desktop.HyprLayout()
		if lease {
			release(held, screens, along)
			return
		}
		// No active lease, but a prior crash or race may still have left
		// the cursor hidden / follow-mouse off, an input-capture held, or
		// an overlay mapped. Idempotent recover restores visibility.
		stopGrab()
		_ = desktop.HyprEndPointerLease()
		d.setEdgeActive(false)
		needRecover = false
		if x, y, ok := desktop.EdgeInside(sideHeld, along, screens, edgeReturn); ok {
			_ = desktop.HyprMoveCursor(x, y)
		} else if x, y, ok := desktop.ScreenCenter(screens); ok {
			_ = desktop.HyprMoveCursor(x, y)
		} else {
			_ = desktop.HyprRecoverPointer()
		}
	}
	// A previous run may have left the cursor hidden / follow-mouse off.
	_ = desktop.HyprEndPointerLease()
	tick := time.NewTicker(edgeTick)
	defer tick.Stop()
	defer func() {
		// Always restore on shutdown, even if we think lease is false.
		if lease && held != nil {
			d.sendEdge(held, "leave", 0, 0)
		}
		stopGrab()
		_ = desktop.HyprEndPointerLease()
		if lease {
			_, screens, _ := desktop.HyprLayout()
			warpBack(screens, along)
		}
		d.setEdgeActive(false)
	}()
	for {
		select {
		case <-ctx.Done():
			return
		case <-d.edgeKick:
			forceReset()
			seen = false
			wasHit = false
			continue
		case <-tick.C:
		}
		if d.edgeReceiving() {
			// Peer drives this pointer. Local mouse/keyboard takes it back
			// immediately without warping control to the peer; return to the
			// peer still needs the configured screen edge.
			if d.edgeLocalInput() {
				d.yieldEdgeToLocal()
			}
			continue
		}
		side, dev, link := d.edgeAim()
		if side == "" || dev == nil || link == nil {
			if lease {
				_, screens, _ := desktop.HyprLayout()
				release(held, screens, along)
			} else if needRecover {
				// Edge off / peer gone after a lease: drop overlay and
				// restore visibility even when the Go lease bit is false.
				stopGrab()
				_ = desktop.HyprEndPointerLease()
				d.setEdgeActive(false)
				needRecover = false
				if side == "" {
					if _, screens, err := desktop.HyprLayout(); err == nil {
						if x, y, ok := desktop.ScreenCenter(screens); ok {
							_ = desktop.HyprMoveCursor(x, y)
						}
					}
				}
			}
			continue
		}
		// Edge config or peer changed while leased: drop cleanly first.
		if lease && (side != sideHeld || link != held) {
			_, screens, _ := desktop.HyprLayout()
			release(held, screens, along)
			seen = false
			wasHit = false
			continue
		}
		held = link
		cur, screens, err := desktop.HyprLayout()
		if err != nil {
			if err.Error() != logged {
				d.logf("screen edge off: %v", err)
				logged = err.Error()
			}
			continue
		}
		logged = ""
		hit := desktop.EdgeHit(side, cur.X, cur.Y, screens, edgeMargin)
		if !lease {
			// The first sample records where the pointer already is, so a
			// cursor that is sitting on the edge does not cross by itself.
			if !seen {
				seen = true
				wasHit = hit
				continue
			}
			if hit && !wasHit {
				cx, cy, ok := desktop.ScreenPark(screens)
				if !ok {
					wasHit = hit
					continue
				}
				along = cur
				anchor = desktop.HyprCursor{X: cx, Y: cy}
				_ = desktop.HyprMoveCursor(cx, cy)
				if err := desktop.HyprBeginPointerLease(); err != nil {
					d.logf("screen edge lease: %v", err)
					_ = desktop.HyprEndPointerLease()
					_ = desktop.HyprMoveCursor(cur.X, cur.Y)
					wasHit = hit
					continue
				}
				g, err := desktop.StartEdgeGrab()
				if err != nil {
					// Without the overlay, tiled windows under the park
					// point catch ghost hover. Roll the lease back.
					d.logf("screen edge grab: %v", err)
					_ = desktop.HyprEndPointerLease()
					_ = desktop.HyprMoveCursor(cur.X, cur.Y)
					wasHit = hit
					continue
				}
				grab = g
				lease = true
				needRecover = true
				skip = true
				depth = edgeReturn
				sideHeld = side
				fx, fy := edgeEnterFrac(side, cur, screens)
				d.sendEdge(link, "enter", fx, fy)
			}
			wasHit = hit
			continue
		}
		if grab != nil {
		drainButtons:
			for {
				select {
				case btn := <-grab.Buttons():
					d.sendEdgeButton(link, btn.Button, btn.Pressed)
				default:
					break drainButtons
				}
			}
		}
		if skip {
			skip = false
			// Re-park after the enter warp so the next delta is clean.
			_ = desktop.HyprMoveCursor(anchor.X, anchor.Y)
			continue
		}
		dx, dy := cur.X-anchor.X, cur.Y-anchor.Y
		if math.Abs(dx) < 1 && math.Abs(dy) < 1 {
			continue
		}
		depth += desktop.EdgeOutward(sideHeld, dx, dy)
		along.X += dx
		along.Y += dy
		if depth <= 0 {
			release(link, screens, along)
			continue
		}
		d.sendEdge(link, "move", dx, dy)
		_ = desktop.HyprMoveCursor(anchor.X, anchor.Y)
		skip = true
	}
}

// resetEdgePointer ends any pointer lease right away: show the cursor,
// restore follow_mouse, release input capture, clear receiving state, and
// kick edgeLoop so it destroys the overlay, sends leave, and warps
// on-screen. Call this when the edge config is cleared or changed
// ("edge off" / no edges). Idempotent if the lease is already gone.
func (d *Daemon) resetEdgePointer() {
	d.setEdgeActive(false)
	_ = desktop.HyprEndPointerLease()
	if d.edgeKick == nil {
		// No loop yet (tests): still center the pointer so edge off never
		// leaves it parked invisible at the status-bar corner.
		_ = desktop.HyprRecoverPointer()
		return
	}
	select {
	case d.edgeKick <- struct{}{}:
	default:
	}
}

// edgeEnterFrac is the 0..1 position along the seam for an enter packet.
func edgeEnterFrac(side string, cur desktop.HyprCursor, screens []desktop.Monitor) (fx, fy float64) {
	fx, fy = desktop.EdgePoint(side)
	minX, minY, maxX, maxY, ok := desktop.ScreenBounds(screens)
	if !ok {
		return fx, fy
	}
	clamp01 := func(v float64) float64 {
		if v < 0 {
			return 0
		}
		if v > 1 {
			return 1
		}
		return v
	}
	switch side {
	case "left", "right":
		if maxY > minY {
			fy = clamp01((cur.Y - minY) / (maxY - minY))
		}
	case "top", "bottom":
		if maxX > minX {
			fx = clamp01((cur.X - minX) / (maxX - minX))
		}
	}
	return fx, fy
}

// edgeAim is the configured edge and the connected peer it names.
func (d *Daemon) edgeAim() (side string, dev *Device, link *lan.Link) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.cfg == nil {
		return "", nil, nil
	}
	side = strings.ToLower(strings.TrimSpace(d.cfg.EdgeSide))
	name := strings.TrimSpace(d.cfg.EdgeDevice)
	if !desktop.ValidEdge(side) || name == "" {
		return "", nil, nil
	}
	var found *Device
	for _, item := range d.devices {
		if item.ID != name && !strings.EqualFold(item.Name, name) {
			continue
		}
		if found != nil {
			return "", nil, nil
		}
		found = item
	}
	if found == nil || !found.Paired || found.link == nil || !found.peer() {
		return side, nil, nil
	}
	return side, found, found.link
}

func (d *Daemon) sendEdge(link *lan.Link, op string, dx, dy float64) {
	if link == nil {
		return
	}
	_ = link.Send(proto.New(proto.TypeFluxEdge, map[string]any{"op": op, "dx": dx, "dy": dy}))
}

func (d *Daemon) sendEdgeButton(link *lan.Link, button uint32, pressed bool) {
	if link == nil {
		return
	}
	_ = link.Send(proto.New(proto.TypeFluxEdge, map[string]any{
		"op": "button", "button": button, "pressed": pressed,
	}))
}

// handleEdge applies a pointer seam from another fluxd. The peer must be
// the computer named by edge_device. Keyboard packets stay ignored; mouse
// buttons are applied when the sender forwards them.
func (d *Daemon) handleEdge(dev *Device, p *proto.Packet) {
	if d.input == nil || !d.edgeFrom(dev) {
		return
	}
	var body struct {
		Op      string  `json:"op"`
		DX      float64 `json:"dx"`
		DY      float64 `json:"dy"`
		Button  uint32  `json:"button"`
		Pressed bool    `json:"pressed"`
	}
	if p.Decode(&body) != nil {
		return
	}
	switch body.Op {
	case "leave":
		d.setEdgeActive(false)
		d.clearEdgeRemoteMark()
	case "kick":
		// Peer took local control on their desk. Drop our outbound lease
		// (overlay + Hypr lease) and leave their cursor where they moved it.
		d.setEdgeActive(false)
		d.clearEdgeRemoteMark()
		d.resetEdgePointer()
	case "enter":
		d.mu.Lock()
		side := strings.ToLower(strings.TrimSpace(d.cfg.EdgeSide))
		d.edgeActive = true
		d.mu.Unlock()
		x, y := desktop.EdgePoint(side)
		switch side {
		case "left", "right":
			if body.DY >= 0 && body.DY <= 1 {
				y = body.DY
			}
		case "top", "bottom":
			if body.DX >= 0 && body.DX <= 1 {
				x = body.DX
			}
		}
		// Keep the enter point slightly inside the screen. Placing exactly on
		// x=0/y=0 (or 1) lets the compositor clamp the first relative moves
		// through that edge, so left/up feel dead right after a seam cross.
		const enterPad = 0.02
		pad := func(v float64) float64 {
			if v < enterPad {
				return enterPad
			}
			if v > 1-enterPad {
				return 1 - enterPad
			}
			return v
		}
		fx, fy := pad(x), pad(y)
		_ = d.input.MoveTo("", fx, fy)
		// Remember where we placed the pointer so local mouse reclaim does
		// not need /dev/input (often unreadable without the input group).
		if _, screens, err := desktop.HyprLayout(); err == nil {
			if ax, ay, ok := desktop.FracToAbs(fx, fy, screens); ok {
				d.setEdgeRemoteExpect(ax, ay)
			} else {
				d.touchEdgeRemote()
			}
		} else {
			d.touchEdgeRemote()
		}
		// Local keys reclaim without /dev/input via a Wayland keyboard grab.
		d.startEdgeKeys()
	case "move":
		if !d.edgeReceiving() {
			return
		}
		dx := max(-maxInputDelta, min(maxInputDelta, body.DX))
		dy := max(-maxInputDelta, min(maxInputDelta, body.DY))
		d.bumpEdgeRemoteExpect(dx, dy)
		_ = d.input.Move(dx, dy)
	case "button":
		if !d.edgeReceiving() {
			return
		}
		_ = d.input.Button(body.Button, body.Pressed)
		// Buttons do not move the cursor; only refresh the quiet timer so
		// compositor lag after a click is not mistaken for local motion.
		d.touchEdgeRemote()
	}
}

// edgeReceiving reports whether the named peer currently drives this pointer.
func (d *Daemon) edgeReceiving() bool {
	d.mu.Lock()
	if !d.edgeActive {
		d.mu.Unlock()
		return false
	}
	// A cleared edge config drops a stale lease so this desk can capture again.
	if d.cfg == nil || !desktop.ValidEdge(d.cfg.EdgeSide) || strings.TrimSpace(d.cfg.EdgeDevice) == "" {
		d.edgeActive = false
		d.mu.Unlock()
		d.stopEdgeKeys()
		return false
	}
	d.mu.Unlock()
	return true
}

func (d *Daemon) setEdgeActive(on bool) {
	d.mu.Lock()
	was := d.edgeActive
	d.edgeActive = on
	d.mu.Unlock()
	if !on && was {
		d.stopEdgeKeys()
	}
}

// setEdgeRemoteExpect records the absolute pointer position the peer just
// commanded. Divergence from this expectation means local mouse took over.
func (d *Daemon) setEdgeRemoteExpect(x, y float64) {
	d.mu.Lock()
	d.edgeRemoteX, d.edgeRemoteY = x, y
	d.edgeRemoteAt = time.Now()
	d.edgeRemoteSet = true
	d.edgeRemoteHasExpect = true
	d.mu.Unlock()
}

// bumpEdgeRemoteExpect advances the expected position by a remote move delta.
func (d *Daemon) bumpEdgeRemoteExpect(dx, dy float64) {
	d.mu.Lock()
	if d.edgeRemoteHasExpect {
		d.edgeRemoteX += dx
		d.edgeRemoteY += dy
	}
	d.edgeRemoteAt = time.Now()
	d.edgeRemoteSet = true
	d.mu.Unlock()
}

// touchEdgeRemote refreshes the quiet timer without changing the expected
// position (buttons, or enter when layout is unavailable).
func (d *Daemon) touchEdgeRemote() {
	d.mu.Lock()
	d.edgeRemoteAt = time.Now()
	d.edgeRemoteSet = true
	d.mu.Unlock()
}

func (d *Daemon) clearEdgeRemoteMark() {
	d.mu.Lock()
	d.edgeRemoteSet = false
	d.edgeRemoteHasExpect = false
	d.mu.Unlock()
}

// edgeCursorDiverged reports whether cur is farther than thresh from baseline.
func edgeCursorDiverged(bx, by, cx, cy, thresh float64) bool {
	return math.Hypot(cx-bx, cy-by) > thresh
}

// edgeLocalInput reports local mouse or key activity while a peer drives this
// pointer. Order: /dev/input when readable, Wayland EdgeKeyGrab (no input
// group), then live cursor vs expected remote position. Do not chase the live
// cursor into the baseline — that absorbed local motion and blocked reclaim.
func (d *Daemon) edgeLocalInput() bool {
	d.mu.Lock()
	set := d.edgeRemoteSet
	has := d.edgeRemoteHasExpect
	at := d.edgeRemoteAt
	bx, by := d.edgeRemoteX, d.edgeRemoteY
	d.mu.Unlock()
	if !set {
		return false
	}
	if d.localInput != nil && d.localInput.ActiveSince(at) {
		return true
	}
	d.mu.Lock()
	keys := d.edgeKeys
	d.mu.Unlock()
	if keys != nil && keys.ActiveSince(at) {
		return true
	}
	if !has {
		return false
	}
	if time.Since(at) < edgeLocalGrace {
		// Remote motion may still be landing in the compositor.
		return false
	}
	cur, _, err := desktop.HyprLayout()
	if err != nil {
		return false
	}
	return edgeCursorDiverged(bx, by, cur.X, cur.Y, edgeLocalThresh)
}

// startEdgeKeys begins a Wayland exclusive keyboard grab for local reclaim.
// Idempotent: replaces any prior grab.
func (d *Daemon) startEdgeKeys() {
	g, err := desktop.StartEdgeKeyGrab()
	if err != nil {
		d.logf("screen edge keys: %v", err)
		return
	}
	d.mu.Lock()
	old := d.edgeKeys
	d.edgeKeys = g
	d.mu.Unlock()
	if old != nil {
		old.Stop()
	}
}

// stopEdgeKeys drops the receive-side keyboard grab.
func (d *Daemon) stopEdgeKeys() {
	d.mu.Lock()
	g := d.edgeKeys
	d.edgeKeys = nil
	d.mu.Unlock()
	if g != nil {
		g.Stop()
	}
}

// yieldEdgeToLocal drops peer control of this pointer and tells the peer to
// release their outbound lease. The local cursor stays where the user moved
// it — no warp to the peer.
func (d *Daemon) yieldEdgeToLocal() {
	if !d.edgeReceiving() {
		return
	}
	d.setEdgeActive(false)
	d.clearEdgeRemoteMark()
	_, _, link := d.edgeAim()
	if link != nil {
		d.sendEdge(link, "kick", 0, 0)
	}
}

// edgeFrom reports whether dev is the computer this desk named for its seam.
func (d *Daemon) edgeFrom(dev *Device) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.cfg == nil || !dev.peer() || !desktop.ValidEdge(d.cfg.EdgeSide) {
		return false
	}
	name := strings.TrimSpace(d.cfg.EdgeDevice)
	return name != "" && (dev.ID == name || strings.EqualFold(dev.Name, name))
}
