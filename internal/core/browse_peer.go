package core

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"

	"flux/internal/lan"
	"flux/internal/proto"
)

// peerBrowseWait is how long browse.open waits for flux.sftp from the peer.
const peerBrowseWait = 12 * time.Second

// PeerBrowseEntry is one remote file or folder in the Files browse UI.
type PeerBrowseEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Dir  bool   `json:"dir"`
	Size int64  `json:"size"`
}

// PeerBrowseRoot is one shared root from the peer's Browse PC offer.
type PeerBrowseRoot struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

// PeerBrowseView is the desk↔desk Browse session for the window.
type PeerBrowseView struct {
	Device  string            `json:"device"`
	Name    string            `json:"name"`
	Path    string            `json:"path"`
	Roots   []PeerBrowseRoot  `json:"roots"`
	Entries []PeerBrowseEntry `json:"entries"`
	Loading bool              `json:"loading"`
	Error   string            `json:"error,omitempty"`
}

type peerBrowseOffer struct {
	errMsg   string
	port     int
	user     string
	password string
	path     string
	roots    []PeerBrowseRoot
}

type peerBrowseSession struct {
	dev    *Device
	link   *lan.Link
	cancel context.CancelFunc
	gen    uint64

	mu   sync.Mutex
	ssh  *ssh.Client
	sftp *sftp.Client
	view PeerBrowseView

	offer chan peerBrowseOffer
}

// OpenPeerBrowse starts a read-only SFTP browse of a paired desktop peer.
// The peer must have share_home on. The Files page shows peerBrowse state.
func (d *Daemon) OpenPeerBrowse(deviceKey string) error {
	dev, err := d.pick(deviceKey)
	if err != nil {
		return err
	}
	d.mu.Lock()
	l := dev.link
	peer := dev.peer()
	name := dev.Name
	id := dev.ID
	d.mu.Unlock()
	if l == nil {
		return offline(dev)
	}
	if !peer {
		return apiErr("not_peer", "%s is not a desktop peer. Use Get files on the phone or Mac.", name)
	}
	d.ClosePeerBrowse()

	ctx, cancel := context.WithCancel(d.ctx)
	s := &peerBrowseSession{
		dev:  dev,
		link: l,
		cancel: cancel,
		offer:  make(chan peerBrowseOffer, 1),
		view: PeerBrowseView{
			Device:  id,
			Name:    name,
			Loading: true,
		},
	}
	d.mu.Lock()
	d.peerBrowseGen++
	s.gen = d.peerBrowseGen
	d.peerBrowse = s
	d.mu.Unlock()
	d.markDirty()

	d.watchSession(ctx, cancel, dev, l, nil)

	if err := l.Send(proto.New(proto.TypeSftpRequest, map[string]any{"startBrowsing": true})); err != nil {
		d.failPeerBrowse(s, fmt.Sprintf("Cannot ask %s: %v", name, err))
		return nil
	}
	go d.runPeerBrowse(ctx, s, name)
	return nil
}

func (d *Daemon) runPeerBrowse(ctx context.Context, s *peerBrowseSession, name string) {
	defer d.dropPeerBrowse(s)

	var offer peerBrowseOffer
	select {
	case offer = <-s.offer:
	case <-time.After(peerBrowseWait):
		d.failPeerBrowse(s, name+" did not answer. Turn on Home share on that computer.")
		return
	case <-ctx.Done():
		return
	}
	if offer.errMsg != "" {
		d.failPeerBrowse(s, offer.errMsg)
		return
	}
	if offer.port <= 0 {
		d.failPeerBrowse(s, name+" sent no way to connect")
		return
	}

	tc, err := s.link.DialPeer(ctx, offer.port)
	if err != nil {
		d.failPeerBrowse(s, fmt.Sprintf("Cannot reach %s: %v", name, err))
		return
	}
	if !d.peerBrowseAlive(s) {
		tc.Close()
		return
	}

	sc, chans, reqs, err := ssh.NewClientConn(tc, "flux", &ssh.ClientConfig{
		User:            offer.user,
		Auth:            []ssh.AuthMethod{ssh.Password(offer.password)},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         8 * time.Second,
	})
	if err != nil {
		tc.Close()
		d.failPeerBrowse(s, fmt.Sprintf("Cannot open files on %s: %v", name, err))
		return
	}
	client := ssh.NewClient(sc, chans, reqs)
	sftpClient, err := sftp.NewClient(client)
	if err != nil {
		client.Close()
		d.failPeerBrowse(s, fmt.Sprintf("Cannot open files on %s: %v", name, err))
		return
	}
	if !d.peerBrowseAlive(s) {
		sftpClient.Close()
		client.Close()
		return
	}

	s.mu.Lock()
	s.ssh = client
	s.sftp = sftpClient
	s.view.Roots = offer.roots
	s.view.Loading = false
	s.view.Error = ""
	s.mu.Unlock()
	d.markDirty()

	open := offer.path
	if open == "" && len(offer.roots) > 0 {
		open = offer.roots[0].Path
	}
	_ = d.listPeerBrowse(s, open)

	<-ctx.Done()
	s.mu.Lock()
	scftp, sshc := s.sftp, s.ssh
	s.sftp, s.ssh = nil, nil
	s.mu.Unlock()
	if scftp != nil {
		_ = scftp.Close()
	}
	if sshc != nil {
		_ = sshc.Close()
	}
}

// handleSftpOffer receives flux.sftp while this computer browses a peer.
func (d *Daemon) handleSftpOffer(dev *Device, _ *lan.Link, p *proto.Packet) {
	d.mu.Lock()
	s := d.peerBrowse
	d.mu.Unlock()
	if s == nil || s.dev.ID != dev.ID {
		return
	}
	var b struct {
		ErrorMessage string   `json:"errorMessage"`
		Port         int      `json:"port"`
		User         string   `json:"user"`
		Password     string   `json:"password"`
		Path         string   `json:"path"`
		MultiPaths   []string `json:"multiPaths"`
		PathNames    []string `json:"pathNames"`
	}
	if p.Decode(&b) != nil {
		return
	}
	offer := peerBrowseOffer{
		errMsg:   b.ErrorMessage,
		port:     b.Port,
		user:     b.User,
		password: b.Password,
		path:     b.Path,
	}
	n := len(b.MultiPaths)
	if len(b.PathNames) < n {
		n = len(b.PathNames)
	}
	for i := 0; i < n; i++ {
		offer.roots = append(offer.roots, PeerBrowseRoot{Name: b.PathNames[i], Path: b.MultiPaths[i]})
	}
	select {
	case s.offer <- offer:
	default:
	}
}

// ListPeerBrowse lists path on the open peer Browse session.
func (d *Daemon) ListPeerBrowse(path string) error {
	d.mu.Lock()
	s := d.peerBrowse
	d.mu.Unlock()
	if s == nil {
		return apiErr("not_active", "No peer Browse session")
	}
	path = strings.TrimSpace(path)
	if path == "" {
		return apiErr("bad_params", "path is empty")
	}
	return d.listPeerBrowse(s, path)
}

func (d *Daemon) listPeerBrowse(s *peerBrowseSession, path string) error {
	s.mu.Lock()
	client := s.sftp
	s.view.Loading = true
	s.view.Path = path
	s.view.Error = ""
	s.mu.Unlock()
	d.markDirty()
	if client == nil {
		d.failPeerBrowse(s, "Browse session is not ready")
		return apiErr("not_active", "Browse session is not ready")
	}
	entries, err := client.ReadDir(path)
	if err != nil {
		msg := fmt.Sprintf("Cannot open %s: %v", path, err)
		s.mu.Lock()
		s.view.Loading = false
		s.view.Error = msg
		s.mu.Unlock()
		d.markDirty()
		return apiErr("browse_failed", "%s", msg)
	}
	out := make([]PeerBrowseEntry, 0, len(entries))
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		out = append(out, PeerBrowseEntry{
			Name: name,
			Path: filepath.Join(path, name),
			Dir:  e.IsDir(),
			Size: e.Size(),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Dir != out[j].Dir {
			return out[i].Dir
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	s.mu.Lock()
	s.view.Loading = false
	s.view.Entries = out
	s.view.Error = ""
	s.mu.Unlock()
	d.markDirty()
	return nil
}

// DownloadPeerBrowse copies a remote file into the local download folder.
func (d *Daemon) DownloadPeerBrowse(path string) (map[string]any, error) {
	d.mu.Lock()
	s := d.peerBrowse
	downloads := d.cfg.DownloadPath()
	d.mu.Unlock()
	if s == nil {
		return nil, apiErr("not_active", "No peer Browse session")
	}
	path = strings.TrimSpace(path)
	if path == "" {
		return nil, apiErr("bad_params", "path is empty")
	}
	s.mu.Lock()
	client := s.sftp
	s.mu.Unlock()
	if client == nil {
		return nil, apiErr("not_active", "Browse session is not ready")
	}
	src, err := client.Open(path)
	if err != nil {
		return nil, apiErr("browse_failed", "Cannot open %s: %v", path, err)
	}
	defer src.Close()
	name := filepath.Base(path)
	if name == "" || name == "." || name == "/" {
		return nil, apiErr("bad_params", "bad remote path")
	}
	if err := os.MkdirAll(downloads, 0o755); err != nil {
		return nil, apiErr("browse_failed", "Cannot write downloads: %v", err)
	}
	dstPath := uniqueDownloadPath(downloads, name)
	dst, err := os.OpenFile(dstPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, apiErr("browse_failed", "Cannot save %s: %v", name, err)
	}
	_, copyErr := io.Copy(dst, src)
	closeErr := dst.Close()
	if copyErr != nil {
		_ = os.Remove(dstPath)
		return nil, apiErr("browse_failed", "Download failed: %v", copyErr)
	}
	if closeErr != nil {
		_ = os.Remove(dstPath)
		return nil, apiErr("browse_failed", "Download failed: %v", closeErr)
	}
	return map[string]any{"path": dstPath, "name": filepath.Base(dstPath)}, nil
}

func uniqueDownloadPath(dir, name string) string {
	base := filepath.Join(dir, name)
	if _, err := os.Stat(base); err != nil {
		return base
	}
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	for i := 1; i < 1000; i++ {
		p := filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, i, ext))
		if _, err := os.Stat(p); err != nil {
			return p
		}
	}
	return filepath.Join(dir, fmt.Sprintf("%s-%d%s", stem, time.Now().Unix(), ext))
}

// ClosePeerBrowse ends the desk↔desk Browse client session.
// It is a no-op when no session is open.
func (d *Daemon) ClosePeerBrowse() error {
	d.mu.Lock()
	s := d.peerBrowse
	d.mu.Unlock()
	if s == nil {
		return nil
	}
	s.cancel()
	return nil
}

func (d *Daemon) peerBrowseAlive(s *peerBrowseSession) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.peerBrowse == s
}

func (d *Daemon) failPeerBrowse(s *peerBrowseSession, msg string) {
	if !d.peerBrowseAlive(s) {
		return
	}
	s.mu.Lock()
	s.view.Loading = false
	s.view.Error = msg
	s.view.Entries = nil
	s.mu.Unlock()
	d.markDirty()
	s.cancel()
}

func (d *Daemon) dropPeerBrowse(s *peerBrowseSession) {
	d.mu.Lock()
	if d.peerBrowse == s {
		d.peerBrowse = nil
	}
	d.mu.Unlock()
	d.markDirty()
}

func (d *Daemon) peerBrowseViewLocked() *PeerBrowseView {
	s := d.peerBrowse
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	v := s.view
	v.Roots = append([]PeerBrowseRoot(nil), v.Roots...)
	v.Entries = append([]PeerBrowseEntry(nil), v.Entries...)
	return &v
}

// endPeerBrowse ends the client session for deviceID, or every session when empty.
func (d *Daemon) endPeerBrowse(deviceID string) {
	d.mu.Lock()
	s := d.peerBrowse
	d.mu.Unlock()
	if s != nil && (deviceID == "" || s.dev.ID == deviceID) {
		s.cancel()
	}
}
