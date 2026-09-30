package core

import (
	"bufio"
	"context"
	_ "embed"
	"encoding/json"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

//go:embed peerinput.lua
var peerInputLua []byte

// peerInputEvent is one line from the mpv peer-input script.
type peerInputEvent struct {
	Op    string  `json:"op"` // pos, btn, scroll, key, special
	Btn   string  `json:"btn"`
	Down  bool    `json:"down"`
	X     float64 `json:"x"`
	Y     float64 `json:"y"`
	SX    float64 `json:"sx"` // window pixel, for drag slop
	SY    float64 `json:"sy"`
	DX    float64 `json:"dx"`
	DY    float64 `json:"dy"`
	Text  string  `json:"text"`
	Code  int     `json:"code"`
	Ctrl  bool    `json:"ctrl"`
	Alt   bool    `json:"alt"`
	Shift bool    `json:"shift"`
	Super bool    `json:"super"`
}

// peerPointer turns left-button press / move / release into mousepad
// bodies the same way the Mac remote-desktop viewer does: a short press
// is a click; a press that moves becomes a drag (hold + moves + release).
type peerPointer struct {
	pressX, pressY   float64
	pressSX, pressSY float64
	dragging         bool
	pressed          bool
	lastClickSX      float64
	lastClickSY      float64
	lastClickVX      float64
	lastClickVY      float64
	lastClickAt      time.Time
	hasLastClick     bool
}

const (
	peerDragSlop     = 3.0 // window pixels
	peerDoubleDist   = 6.0
	peerDoubleWindow = 400 * time.Millisecond
	peerMotionHz     = 60
)

func (p *peerPointer) down(x, y, sx, sy float64) {
	p.pressed = true
	p.dragging = false
	p.pressX, p.pressY = x, y
	p.pressSX, p.pressSY = sx, sy
}

func (p *peerPointer) drag(x, y, sx, sy float64) []map[string]any {
	if !p.pressed {
		return nil
	}
	if !p.dragging {
		if math.Hypot(sx-p.pressSX, sy-p.pressSY) < peerDragSlop {
			return nil
		}
		p.dragging = true
		return []map[string]any{
			posBody(p.pressX, p.pressY, map[string]any{"singlehold": true}),
			posBody(x, y, nil),
		}
	}
	return []map[string]any{posBody(x, y, nil)}
}

func (p *peerPointer) up(x, y float64, now time.Time) []map[string]any {
	if !p.pressed {
		return nil
	}
	defer func() {
		p.pressed = false
		p.dragging = false
	}()
	if p.dragging {
		p.hasLastClick = false
		return []map[string]any{posBody(x, y, map[string]any{"singlerelease": true})}
	}
	targetX, targetY := p.pressX, p.pressY
	if p.hasLastClick && now.Sub(p.lastClickAt) <= peerDoubleWindow &&
		math.Hypot(p.pressSX-p.lastClickSX, p.pressSY-p.lastClickSY) < peerDoubleDist {
		targetX, targetY = p.lastClickVX, p.lastClickVY
	}
	p.lastClickSX, p.lastClickSY = p.pressSX, p.pressSY
	p.lastClickVX, p.lastClickVY = targetX, targetY
	p.lastClickAt = now
	p.hasLastClick = true
	return []map[string]any{posBody(targetX, targetY, map[string]any{"singleclick": true})}
}

func clamp01(v float64) float64 {
	if !finite(v) {
		return 0
	}
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return math.Round(v*10_000) / 10_000
}

func posBody(x, y float64, extra map[string]any) map[string]any {
	body := map[string]any{"x": clamp01(x), "y": clamp01(y)}
	for k, v := range extra {
		body[k] = v
	}
	return body
}

// peerMotionThrottle sends at most one move packet per interval.
type peerMotionThrottle struct {
	interval time.Duration
	sentAt   time.Time
	sentX    float64
	sentY    float64
	hasSent  bool
	pendX    float64
	pendY    float64
	hasPend  bool
}

func (t *peerMotionThrottle) move(x, y float64, now time.Time) (float64, float64, bool) {
	if t.hasSent && math.Abs(x-t.sentX) < 1e-4 && math.Abs(y-t.sentY) < 1e-4 {
		t.hasPend = false
		return 0, 0, false
	}
	if t.hasSent && now.Sub(t.sentAt) < t.interval {
		t.pendX, t.pendY, t.hasPend = x, y, true
		return 0, 0, false
	}
	t.hasPend = false
	t.sentX, t.sentY, t.hasSent, t.sentAt = x, y, true, now
	return x, y, true
}

func (t *peerMotionThrottle) flush(now time.Time) (float64, float64, bool) {
	if !t.hasPend || now.Sub(t.sentAt) < t.interval {
		return 0, 0, false
	}
	return t.move(t.pendX, t.pendY, now)
}

func (t *peerMotionThrottle) reset(x, y float64, now time.Time) {
	t.hasPend = false
	t.sentX, t.sentY, t.hasSent, t.sentAt = x, y, true, now
}

// peerInput maps mpv events to flux.mousepad.request bodies.
type peerInput struct {
	mu       sync.Mutex
	pointer  peerPointer
	throttle peerMotionThrottle
}

func newPeerInput() *peerInput {
	return &peerInput{throttle: peerMotionThrottle{interval: time.Second / peerMotionHz}}
}

func (p *peerInput) bodies(ev peerInputEvent, now time.Time) []map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	switch ev.Op {
	case "pos":
		if p.pointer.pressed {
			return p.pointer.drag(ev.X, ev.Y, ev.SX, ev.SY)
		}
		if x, y, ok := p.throttle.move(ev.X, ev.Y, now); ok {
			return []map[string]any{posBody(x, y, nil)}
		}
		return nil
	case "btn":
		switch ev.Btn {
		case "left":
			if ev.Down {
				p.pointer.down(ev.X, ev.Y, ev.SX, ev.SY)
				p.throttle.reset(ev.X, ev.Y, now)
				return nil
			}
			out := p.pointer.up(ev.X, ev.Y, now)
			p.throttle.reset(ev.X, ev.Y, now)
			return out
		case "right":
			if ev.Down {
				return nil
			}
			return []map[string]any{posBody(ev.X, ev.Y, map[string]any{"rightclick": true})}
		case "middle":
			if ev.Down {
				return nil
			}
			return []map[string]any{posBody(ev.X, ev.Y, map[string]any{"middleclick": true})}
		}
	case "scroll":
		return []map[string]any{posBody(ev.X, ev.Y, map[string]any{
			"scroll": true, "dx": ev.DX, "dy": ev.DY,
		})}
	case "key":
		if ev.Text == "" {
			return nil
		}
		body := map[string]any{"key": ev.Text}
		addMods(body, ev)
		return []map[string]any{body}
	case "special":
		if ev.Code == 0 {
			return nil
		}
		body := map[string]any{"specialKey": ev.Code}
		addMods(body, ev)
		return []map[string]any{body}
	}
	return nil
}

func (p *peerInput) flushMotion(now time.Time) []map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	if x, y, ok := p.throttle.flush(now); ok {
		return []map[string]any{posBody(x, y, nil)}
	}
	return nil
}

func addMods(body map[string]any, ev peerInputEvent) {
	if ev.Ctrl {
		body["ctrl"] = true
	}
	if ev.Alt {
		body["alt"] = true
	}
	if ev.Shift {
		body["shift"] = true
	}
	if ev.Super {
		body["super"] = true
	}
}

func writePeerInputScript(dir string) (string, error) {
	path := filepath.Join(dir, "flux-peer-input.lua")
	if err := os.WriteFile(path, peerInputLua, 0o644); err != nil {
		return "", err
	}
	return path, nil
}

// readPeerInput sends mousepad packets for each JSON line from r until EOF or ctx ends.
func readPeerInput(ctx context.Context, r io.Reader, send func(map[string]any) error) error {
	in := newPeerInput()
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 4096), 64*1024)
	ticker := time.NewTicker(in.throttle.interval)
	defer ticker.Stop()

	type line struct {
		raw string
		err error
	}
	lines := make(chan line, 64)
	go func() {
		defer close(lines)
		for sc.Scan() {
			select {
			case <-ctx.Done():
				return
			case lines <- line{raw: sc.Text()}:
			}
		}
		if err := sc.Err(); err != nil {
			select {
			case <-ctx.Done():
			case lines <- line{err: err}:
			}
		}
	}()

	sendAll := func(bodies []map[string]any) error {
		for _, body := range bodies {
			if err := send(body); err != nil {
				return err
			}
		}
		return nil
	}

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			if err := sendAll(in.flushMotion(time.Now())); err != nil {
				return err
			}
		case l, ok := <-lines:
			if !ok {
				return nil
			}
			if l.err != nil {
				return l.err
			}
			var ev peerInputEvent
			if json.Unmarshal([]byte(l.raw), &ev) != nil || ev.Op == "" {
				continue
			}
			if err := sendAll(in.bodies(ev, time.Now())); err != nil {
				return err
			}
		}
	}
}

// peerInputPipe is the parent side of the mpv input pipe (ExtraFiles fd 3).
type peerInputPipe struct {
	pr, pw *os.File
	args   []string
}

// openPeerInputPipe creates the pipe and mpv args. Extra returns the write
// end for cmd.ExtraFiles (child fd 3). CloseWrite after Start so only mpv
// holds the writer. Close releases both ends.
func openPeerInputPipe(scriptPath string) (*peerInputPipe, error) {
	pr, pw, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	const childFD = 3
	return &peerInputPipe{
		pr: pr, pw: pw,
		args: []string{
			"--script=" + scriptPath,
			"--script-opts=flux_peer_input-fd=" + strconv.Itoa(childFD),
			"--no-input-default-bindings",
			"--input-vo-keyboard=yes",
		},
	}, nil
}

func (p *peerInputPipe) Extra() []*os.File { return []*os.File{p.pw} }

func (p *peerInputPipe) CloseWrite() {
	if p.pw != nil {
		_ = p.pw.Close()
		p.pw = nil
	}
}

func (p *peerInputPipe) Close() {
	p.CloseWrite()
	if p.pr != nil {
		_ = p.pr.Close()
		p.pr = nil
	}
}

// start sends flux.mousepad.request for each event until ctx ends or the pipe closes.
func (p *peerInputPipe) start(ctx context.Context, link *lan.Link, logf func(string, ...any)) {
	go func() {
		err := readPeerInput(ctx, p.pr, func(body map[string]any) error {
			if link == nil {
				return nil
			}
			return link.Send(proto.New(proto.TypeMousepadRequest, body))
		})
		if err != nil && ctx.Err() == nil {
			logf("peer desktop input: %v", err)
		}
	}()
}
