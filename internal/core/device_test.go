package core

import (
	"context"
	"slices"
	"testing"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

func fluxIdentity() (in, out []string) {
	return append([]string{}, proto.Incoming...), append([]string{}, proto.Outgoing...)
}

func TestLookupAmbiguousName(t *testing.T) {
	a := newDevice("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	a.Name = "omarchy"
	a.Paired = true
	b := newDevice("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
	b.Name = "Omarchy"
	b.Paired = true
	one := newDevice("cccccccccccccccccccccccccccccccc")
	one.Name = "Pixel 8"
	one.Paired = true
	d := &Daemon{devices: map[string]*Device{a.ID: a, b.ID: b, one.ID: one}}
	if _, err := d.find("omarchy", nil); err == nil {
		t.Fatal("two devices with one name were accepted")
	}
	dev, err := d.find(a.ID, nil)
	if err != nil || dev != a {
		t.Fatalf("id lookup %v %v", dev, err)
	}
	dev, err = d.find("pixel 8", nil)
	if err != nil || dev != one {
		t.Fatalf("name lookup %v %v", dev, err)
	}
	dev, err = d.find("missing", nil)
	if err == nil || dev != nil {
		t.Fatalf("missing lookup %v %v", dev, err)
	}
}

func TestPeerRole(t *testing.T) {
	in, out := fluxIdentity()
	peer := &Device{Type: "desktop", Incoming: in, Outgoing: out}
	if peer.role() != "peer" || peer.fluxApp() {
		t.Fatalf("fluxd role %s fluxApp %v", peer.role(), peer.fluxApp())
	}
	if got, want := peer.plugins(), []string{"clipboard", "share", "battery", "desktop"}; !slices.Equal(got, want) {
		t.Fatalf("peer plugins %v", got)
	}
	view := peer.view()
	if view.Role != "peer" || view.Type != "desktop" {
		t.Fatalf("view %+v", view)
	}

	macOut := append(append([]string{}, out...), proto.TypeFluxTunnel)
	mac := &Device{Type: "laptop", Incoming: in, Outgoing: macOut}
	if mac.role() != "remote" || !mac.fluxApp() {
		t.Fatalf("mac role %s fluxApp %v", mac.role(), mac.fluxApp())
	}

	phone := &Device{
		Type:     "phone",
		Incoming: []string{proto.TypeShare, proto.TypeClipboard},
		Outgoing: []string{proto.TypeFluxTunnel, proto.TypeSmsMessages, proto.TypeSftp, proto.TypeFindMyPhone},
	}
	if phone.role() != "remote" || !phone.fluxApp() {
		t.Fatalf("phone role %s", phone.role())
	}
	if !slices.Contains(phone.plugins(), "sms") || !slices.Contains(phone.plugins(), "share") {
		t.Fatalf("phone plugins %v", phone.plugins())
	}

	other := &Device{Type: "desktop", Incoming: []string{proto.TypePing}, Outgoing: []string{proto.TypePing}}
	if other.role() != "remote" {
		t.Fatalf("other desktop role %s", other.role())
	}

	unknown := &Device{}
	if got := unknown.view(); got.Role != "remote" || got.Type != "phone" {
		t.Fatalf("empty device view %+v", got)
	}
}

// Two mDNS reports for one id stay one device. Avahi can emit an IPv4
// record twice, or the browse can repeat. The window keys the list by id.
func TestMDNSReportsStayOneDevice(t *testing.T) {
	self := "fedcba9876543210fedcba9876543210"
	id := "0123456789abcdef0123456789abcdef"
	d := &Daemon{
		selfID:  self,
		devices: map[string]*Device{},
		ctx:     context.Background(),
		lan: lan.New(lan.Config{Identity: func() proto.Identity {
			return proto.Identity{DeviceID: self}
		}}),
	}
	d.onMDNS(lan.MDNSPeer{DeviceID: id, Name: "other-desk", Type: "laptop", Protocol: 8, IP: "192.0.2.10", Port: 0})
	dev := d.devices[id]
	if dev == nil {
		t.Fatal("mDNS did not record the computer")
	}
	dev.Paired = true
	d.onMDNS(lan.MDNSPeer{DeviceID: id, Name: "second-name", Type: "desktop", Protocol: 8, IP: "192.0.2.11", Port: 0})
	if len(d.devices) != 1 {
		t.Fatalf("%d devices, want 1", len(d.devices))
	}
	// A paired device keeps its address. mDNS only records a dial candidate.
	if dev.Name != "other-desk" || dev.IP != "192.0.2.10" || dev.seenIP != "192.0.2.11" {
		t.Fatalf("device name %q ip %s seen %s", dev.Name, dev.IP, dev.seenIP)
	}
	shown := 0
	for _, item := range d.devices {
		if item.Paired || item.link != nil {
			shown++
		}
	}
	if shown != 1 {
		t.Fatalf("list would show %d computers", shown)
	}
}

func TestPeerDropsPhonePackets(t *testing.T) {
	d, _ := clipDaemon(t, true)
	in, out := fluxIdentity()
	dev := &Device{
		ID: "peerdesktop00000000000000000001", Name: "other-desk", Type: "laptop",
		Paired: true, Incoming: in, Outgoing: out,
	}
	d.devices[dev.ID] = dev
	dev.link = &lan.Link{}
	d.cfg.RemoteInput = true
	d.cfg.SyncDnd = true
	d.input = &countingInput{}
	d.inputQ = make(chan inputAction, 8)
	d.dnd = &fakeDND{}

	if err := d.approvals.add(&approval{
		id: "req1", kind: "request", device: dev.ID, deadline: time.Now().Add(time.Minute),
	}); err != nil {
		t.Fatal(err)
	}

	packets := []*proto.Packet{
		proto.New(proto.TypeFluxApprove, map[string]any{"kind": "response", "id": "req1", "denied": true}),
		proto.New(proto.TypeFluxDnd, map[string]any{"on": true}),
		proto.New(proto.TypeSftpRequest, map[string]any{"startBrowsing": true}),
		proto.New(proto.TypeFluxHerdr, map[string]any{"kind": "request"}),
		proto.New(proto.TypeRunCommandRequest, map[string]any{"key": "lock"}),
	}
	for _, p := range packets {
		d.handlePacket(dev, dev.link, p)
	}

	// Mousepad from a peer is allowed when remote_input is on (desk↔desk RD control).
	d.handlePacket(dev, dev.link, proto.New(proto.TypeMousepadRequest, map[string]any{"dx": 10, "dy": 4}))
	if n := len(d.inputQ); n != 1 {
		t.Fatalf("peer mousepad queued %d input actions, want 1", n)
	}
	d.approvals.mu.Lock()
	answered := d.approvals.byID["req1"].result != nil
	d.approvals.mu.Unlock()
	if answered {
		t.Fatal("peer approval changed the waiting request")
	}
	if d.dndGuard.valid {
		t.Fatal("peer changed Do Not Disturb")
	}

	d.handlePacket(dev, dev.link, proto.New(proto.TypeClipboard, map[string]any{"content": "from the other desk"}))
	if len(d.clipboard) != 1 || d.clipboard[0].Text != "from the other desk" || d.clipboard[0].Dir != "in" {
		t.Fatalf("clipboard %+v", d.clipboard)
	}
}

type countingInput struct{ n int }

func (c *countingInput) Move(float64, float64) error                  { c.n++; return nil }
func (c *countingInput) Button(uint32, bool) error                    { c.n++; return nil }
func (c *countingInput) Scroll(float64, float64) error                { c.n++; return nil }
func (c *countingInput) Type(context.Context, string, []string) error { c.n++; return nil }
func (c *countingInput) Key(context.Context, string, []string) error  { c.n++; return nil }
func (c *countingInput) MoveTo(string, float64, float64) error        { c.n++; return nil }

type fakeDND struct{ sets int }

func (f *fakeDND) Get() (bool, bool) { return false, true }
func (f *fakeDND) Set(bool) error    { f.sets++; return nil }
