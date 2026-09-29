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

const (
	edgeMargin = 6.0
	edgeReturn = 48.0
	edgeTick   = 20 * time.Millisecond
)

// edgeLoop watches the cursor. When it crosses the configured edge onto a
// paired computer, later motion goes there until the pointer comes back.
func (d *Daemon) edgeLoop(ctx context.Context) {
	var (
		lease  bool
		skip   bool
		seen   bool
		wasHit bool
		anchor desktop.HyprCursor
		held   *lan.Link
		logged string
	)
	tick := time.NewTicker(edgeTick)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		if d.edgeReceiving() {
			// The other desk drives this pointer. Do not capture the edge
			// back until it sends leave.
			continue
		}
		side, dev, link := d.edgeAim()
		if side == "" || dev == nil || link == nil {
			if lease {
				d.sendEdge(held, "leave", 0, 0)
				lease = false
			}
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
				anchor = cur
				lease = true
				skip = true
				d.sendEdge(link, "enter", 0, 0)
			}
			wasHit = hit
			continue
		}
		if skip {
			skip = false
			anchor = cur
			continue
		}
		dx, dy := cur.X-anchor.X, cur.Y-anchor.Y
		if desktop.EdgeInward(side, dx, dy, edgeReturn) {
			d.sendEdge(link, "leave", 0, 0)
			lease = false
			wasHit = false
			continue
		}
		if math.Abs(dx) < 1 && math.Abs(dy) < 1 {
			continue
		}
		d.sendEdge(link, "move", dx, dy)
		if d.input != nil {
			_ = d.input.Move(-dx, -dy)
		}
		skip = true
	}
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

// handleEdge applies a pointer seam from another fluxd. The peer must be
// the computer named by edge_device. Keyboard packets stay ignored.
func (d *Daemon) handleEdge(dev *Device, p *proto.Packet) {
	if d.input == nil || !d.edgeFrom(dev) {
		return
	}
	var body struct {
		Op string  `json:"op"`
		DX float64 `json:"dx"`
		DY float64 `json:"dy"`
	}
	if p.Decode(&body) != nil {
		return
	}
	switch body.Op {
	case "leave":
		d.setEdgeActive(false)
	case "enter":
		d.mu.Lock()
		side := strings.ToLower(strings.TrimSpace(d.cfg.EdgeSide))
		d.edgeActive = true
		d.mu.Unlock()
		x, y := desktop.EdgePoint(side)
		_ = d.input.MoveTo("", x, y)
	case "move":
		if !d.edgeReceiving() {
			return
		}
		dx := max(-maxInputDelta, min(maxInputDelta, body.DX))
		dy := max(-maxInputDelta, min(maxInputDelta, body.DY))
		_ = d.input.Move(dx, dy)
	}
}

// edgeReceiving reports whether the named peer currently drives this pointer.
func (d *Daemon) edgeReceiving() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.edgeActive {
		return false
	}
	// A cleared edge config drops a stale lease so this desk can capture again.
	if d.cfg == nil || !desktop.ValidEdge(d.cfg.EdgeSide) || strings.TrimSpace(d.cfg.EdgeDevice) == "" {
		d.edgeActive = false
		return false
	}
	return true
}

func (d *Daemon) setEdgeActive(on bool) {
	d.mu.Lock()
	d.edgeActive = on
	d.mu.Unlock()
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
