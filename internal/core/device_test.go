package core

import (
	"slices"
	"testing"
	"time"

	"flux/internal/proto"
)

func fluxIdentity() (in, out []string) {
	return append([]string{}, proto.Incoming...), append([]string{}, proto.Outgoing...)
}

func TestPeerRole(t *testing.T) {
	in, out := fluxIdentity()
	peer := &Device{Type: "desktop", Incoming: in, Outgoing: out}
	if peer.role() != "peer" || peer.fluxApp() {
		t.Fatalf("fluxd role %s fluxApp %v", peer.role(), peer.fluxApp())
	}
	if got, want := peer.plugins(), []string{"clipboard", "share", "battery"}; !slices.Equal(got, want) {
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

func TestPeerDropsPhonePackets(t *testing.T) {
	d, _ := clipDaemon(t, true)
	in, out := fluxIdentity()
	dev := &Device{
		ID: "peerdesktop00000000000000000001", Name: "other-desk", Type: "laptop",
		Paired: true, Incoming: in, Outgoing: out,
	}
	d.devices[dev.ID] = dev
	d.cfg.RemoteInput = true
	d.cfg.SyncDnd = true
	d.input = &countingInput{}
	d.inputQ = make(chan inputAction, 4)
	d.dnd = &fakeDND{}

	if err := d.approvals.add(&approval{
		id: "req1", kind: "request", device: dev.ID, deadline: time.Now().Add(time.Minute),
	}); err != nil {
		t.Fatal(err)
	}

	packets := []*proto.Packet{
		proto.New(proto.TypeMousepadRequest, map[string]any{"dx": 10, "dy": 4}),
		proto.New(proto.TypeFluxApprove, map[string]any{"kind": "response", "id": "req1", "denied": true}),
		proto.New(proto.TypeFluxDnd, map[string]any{"on": true}),
		proto.New(proto.TypeSftpRequest, map[string]any{"startBrowsing": true}),
		proto.New(proto.TypeFluxHerdr, map[string]any{"kind": "request"}),
		proto.New(proto.TypeRunCommandRequest, map[string]any{"key": "lock"}),
	}
	for _, p := range packets {
		d.handlePacket(dev, nil, p)
	}

	if n := len(d.inputQ); n != 0 {
		t.Fatalf("peer queued %d input actions", n)
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

	d.handlePacket(dev, nil, proto.New(proto.TypeClipboard, map[string]any{"content": "from the other desk"}))
	if len(d.clipboard) != 1 || d.clipboard[0].Text != "from the other desk" || d.clipboard[0].Dir != "in" {
		t.Fatalf("clipboard %+v", d.clipboard)
	}
}

type countingInput struct{ n int }

func (c *countingInput) Move(float64, float64) error           { c.n++; return nil }
func (c *countingInput) Button(uint32, bool) error             { c.n++; return nil }
func (c *countingInput) Scroll(float64, float64) error         { c.n++; return nil }
func (c *countingInput) Type(string, []string) error           { c.n++; return nil }
func (c *countingInput) Key(string, []string) error            { c.n++; return nil }
func (c *countingInput) MoveTo(string, float64, float64) error { c.n++; return nil }

type fakeDND struct{ sets int }

func (f *fakeDND) Get() (bool, bool) { return false, true }
func (f *fakeDND) Set(bool) error    { f.sets++; return nil }
