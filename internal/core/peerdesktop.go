package core

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

// Peer desktop remote desktop: this computer shows another fluxd screen.
// The viewer opens a TLS listener (like a phone), sends flux.desktop start,
// the peer runs the existing recorder path (runDesktop), and this side
// strips the framed stream into Annex-B H.264 for mpv or ffplay.
// With mpv, a small Lua script reports mouse and keys over a pipe; this
// side sends flux.mousepad.request like the phone. The watched desk runs
// them only while remote_input is on (handleMousepad).

const peerDesktopAppID = "flux-peer-desktop"

// PeerDesktopView is the state while this computer shows a peer screen.
type PeerDesktopView struct {
	Active   bool   `json:"active"`
	From     string `json:"from"`
	FromName string `json:"fromName"`
	Monitor  string `json:"monitor"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	Player   string `json:"player"`
	Error    string `json:"error,omitempty"`
}

type peerDesktopSession struct {
	dev    *Device
	link   *lan.Link
	cancel context.CancelFunc
	view   PeerDesktopView
}

func peerDesktopTitle(name string) string { return "Flux · " + name + " desktop" }

// StartPeerDesktop asks a paired peer to stream its screen here.
func (d *Daemon) StartPeerDesktop(deviceKey string) error {
	dev, err := d.pick(deviceKey)
	if err != nil {
		return err
	}
	d.mu.Lock()
	l := dev.link
	peer := dev.peer()
	name := dev.Name
	d.mu.Unlock()
	if l == nil {
		return apiErr("offline", "%s is offline", name)
	}
	if !peer {
		return apiErr("not_peer", "%s is not a desktop peer. Use Flux on the phone or Mac for that device.", name)
	}
	if d.opts.Headless {
		return apiErr("headless", "peer remote desktop is off in headless mode")
	}
	go d.runPeerDesktop(dev, l)
	return nil
}

// StopPeerDesktop stops showing a peer screen from this computer.
func (d *Daemon) StopPeerDesktop() error {
	d.mu.Lock()
	s := d.peerDesktop
	d.mu.Unlock()
	if s == nil {
		return apiErr("not_active", "No peer desktop is shown")
	}
	_ = s.link.Send(proto.New(proto.TypeFluxDesktop, map[string]any{"state": "stop"}))
	s.cancel()
	return nil
}

func (d *Daemon) endPeerDesktop(deviceID string) {
	d.mu.Lock()
	s := d.peerDesktop
	d.mu.Unlock()
	if s != nil && (deviceID == "" || s.dev.ID == deviceID) {
		s.cancel()
	}
}

func (d *Daemon) peerDesktopViewLocked() *PeerDesktopView {
	if d.peerDesktop != nil {
		v := d.peerDesktop.view
		return &v
	}
	if d.peerDesktopErr != "" {
		return &PeerDesktopView{Error: d.peerDesktopErr}
	}
	return nil
}

// onPeerDesktopReply handles live/error/stop while this computer views a peer.
func (d *Daemon) onPeerDesktopReply(dev *Device, b desktopStart) {
	d.mu.Lock()
	s := d.peerDesktop
	d.mu.Unlock()
	if s == nil || s.dev.ID != dev.ID {
		return
	}
	switch b.State {
	case "live":
		d.mu.Lock()
		if d.peerDesktop == s {
			s.view.Active = true
			if b.Monitor != "" {
				s.view.Monitor = b.Monitor
			}
		}
		d.mu.Unlock()
		d.markDirty()
	case "error":
		d.logf("%s: peer desktop: %s", dev.Name, b.Message)
		d.mu.Lock()
		d.peerDesktopErr = b.Message
		d.mu.Unlock()
		s.cancel()
		d.markDirty()
	case "stop":
		s.cancel()
	}
}

func (d *Daemon) runPeerDesktop(dev *Device, l *lan.Link) {
	fail := func(err error) {
		d.logf("%s: peer desktop: %v", dev.Name, err)
		d.mu.Lock()
		d.peerDesktopErr = err.Error()
		d.mu.Unlock()
		d.markDirty()
	}
	player, err := findScreenPlayer(exec.LookPath, peerDesktopTitle(dev.Name))
	if err != nil {
		fail(err)
		return
	}
	for i, a := range player.Args {
		if strings.HasPrefix(a, "--wayland-app-id=") {
			player.Args[i] = "--wayland-app-id=" + peerDesktopAppID
		}
	}
	for i, e := range player.Env {
		if strings.HasPrefix(e, "SDL_VIDEO_WAYLAND_WMCLASS=") || strings.HasPrefix(e, "SDL_APP_ID=") {
			k, _, _ := strings.Cut(e, "=")
			player.Env[i] = k + "=" + peerDesktopAppID
		}
	}

	d.endPeerDesktop("")
	ctx, cancel := context.WithCancel(d.ctx)
	defer cancel()

	pl, err := l.ListenPeer(ctx)
	if err != nil {
		fail(fmt.Errorf("listen for the peer stream: %w", err))
		return
	}
	defer pl.Close()

	s := &peerDesktopSession{dev: dev, link: l, cancel: cancel, view: PeerDesktopView{
		From: dev.ID, FromName: dev.Name, Player: player.Name,
	}}
	d.mu.Lock()
	d.peerDesktop, d.peerDesktopErr = s, ""
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		if d.peerDesktop == s {
			d.peerDesktop = nil
		}
		d.mu.Unlock()
		d.markDirty()
	}()
	cancelOnLinkDown(ctx, l, cancel)

	if err := l.Send(proto.New(proto.TypeFluxDesktop, map[string]any{
		"state": "start", "port": pl.Port(), "maxSize": desktopSize,
	})); err != nil {
		fail(fmt.Errorf("ask the peer to stream: %w", err))
		return
	}

	tc, err := pl.Accept(ctx)
	if err != nil {
		if ctx.Err() != nil {
			d.logf("%s: peer desktop stopped", dev.Name)
			return
		}
		fail(fmt.Errorf("accept the peer stream: %w", err))
		return
	}
	defer tc.Close()
	defer context.AfterFunc(ctx, func() { tc.Close() })()

	var inputPipe *peerInputPipe
	if player.Name == "mpv" {
		dir, err := os.MkdirTemp("", "flux-peer-desktop-*")
		if err != nil {
			fail(fmt.Errorf("peer input temp: %w", err))
			return
		}
		defer os.RemoveAll(dir)
		script, err := writePeerInputScript(dir)
		if err != nil {
			fail(fmt.Errorf("peer input script: %w", err))
			return
		}
		inputPipe, err = openPeerInputPipe(script)
		if err != nil {
			fail(fmt.Errorf("peer input pipe: %w", err))
			return
		}
		defer inputPipe.Close()
		// Insert script args before the trailing "-" stdin marker.
		args := append([]string{}, player.Args...)
		if n := len(args); n > 0 && args[n-1] == "-" {
			args = append(append(args[:n-1], inputPipe.args...), "-")
		} else {
			args = append(args, inputPipe.args...)
		}
		player.Args = args
	}

	cmd := childCommand(ctx, player.Path, player.Args...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		fail(err)
		return
	}
	cmd.Env = append(os.Environ(), player.Env...)
	if inputPipe != nil {
		cmd.ExtraFiles = inputPipe.Extra()
	}
	var stderr lockedBuffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		fail(fmt.Errorf("start %s: %w", player.Name, err))
		return
	}
	if inputPipe != nil {
		inputPipe.CloseWrite()
		inputPipe.start(ctx, l, d.logf)
	}

	go func() {
		select {
		case <-time.After(time.Second):
		case <-ctx.Done():
			return
		}
		d.mu.Lock()
		if d.peerDesktop == s {
			s.view.Active = true
		}
		d.mu.Unlock()
		d.markDirty()
	}()

	err = copyPeerDesktop(tc, stdin, func(w, h int) {
		d.mu.Lock()
		if d.peerDesktop == s {
			if w > 0 {
				s.view.Width = w
			}
			if h > 0 {
				s.view.Height = h
			}
			s.view.Active = true
		}
		d.mu.Unlock()
		d.markDirty()
	})
	_ = stdin.Close()
	started := time.Now()
	waitErr := cmd.Wait()
	if ctx.Err() != nil {
		d.logf("%s: peer desktop stopped", dev.Name)
		return
	}
	if err != nil && !errors.Is(err, io.EOF) {
		fail(fmt.Errorf("the peer stream failed: %w", err))
		return
	}
	if waitErr != nil && time.Since(started) < 3*time.Second {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = waitErr.Error()
		}
		fail(fmt.Errorf("%s stopped: %s", player.Name, lastLine(msg)))
		return
	}
	_ = l.Send(proto.New(proto.TypeFluxDesktop, map[string]any{"state": "stop"}))
	d.logf("%s: peer desktop window closed", dev.Name)
}

// copyPeerDesktop reads framed remote-desktop frames and writes Annex-B
// H.264 to w for mpv or ffplay. onFormat receives the stream size once.
func copyPeerDesktop(r io.Reader, w io.Writer, onFormat func(width, height int)) error {
	fr := newFrameReader(r)
	for {
		flags, data, err := fr.next()
		if err != nil {
			return err
		}
		if flags&frameFormat != 0 {
			if width, height, ok := formatSize(data); ok && onFormat != nil {
				onFormat(width, height)
			}
			continue
		}
		if len(data) == 0 {
			continue
		}
		if _, err := w.Write(data); err != nil {
			return err
		}
	}
}
