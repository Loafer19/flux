package core

import (
	"testing"
	"time"

	"flux/internal/proto"
)

// A paired device that stays offline gets fewer dials, and a device that
// shows again gets the normal interval.
func TestDialBackoff(t *testing.T) {
	phone := newDevice("phone")
	phone.Paired = true
	d := &Daemon{devices: map[string]*Device{"phone": phone}}
	for range fastDials + 5 {
		d.dialKnown()
	}
	if phone.dialTries != fastDials {
		t.Errorf("%d dials, want %d", phone.dialTries, fastDials)
	}
	phone.dialAt = time.Now().Add(-slowDial)
	d.dialKnown()
	if phone.dialTries != fastDials+1 {
		t.Errorf("%d dials after the slow interval, want %d", phone.dialTries, fastDials+1)
	}
	d.onIdentity(proto.Identity{DeviceID: "phone"}, "192.0.2.1")
	if phone.dialTries != 0 {
		t.Errorf("%d dials after an identity, want 0", phone.dialTries)
	}
}

// A paired desk uses the same dial schedule as a phone. peer does not
// remove it from dialKnown.
func TestPeerDialBackoff(t *testing.T) {
	in, out := fluxIdentity()
	id := "0123456789abcdef0123456789abcdef"
	peer := newDevice(id)
	peer.Paired = true
	peer.Type = "laptop"
	peer.Incoming, peer.Outgoing = in, out
	if !peer.peer() {
		t.Fatal("fixture is not a peer")
	}
	d := &Daemon{devices: map[string]*Device{id: peer}}
	for range fastDials {
		d.dialKnown()
	}
	if peer.dialTries != fastDials {
		t.Fatalf("%d dials, want %d", peer.dialTries, fastDials)
	}
	d.dialKnown()
	if peer.dialTries != fastDials {
		t.Fatalf("%d dials on the slow schedule, want %d", peer.dialTries, fastDials)
	}
	peer.dialAt = time.Now().Add(-slowDial)
	d.dialKnown()
	if peer.dialTries != fastDials+1 {
		t.Fatalf("%d dials after the slow interval, want %d", peer.dialTries, fastDials+1)
	}
}

// dialKnown removes a device that is not paired and was not seen for a
// while. It keeps a device with a pairing request.
func TestForgetOldDevices(t *testing.T) {
	old := time.Now().Add(-2 * forgetAfter)
	stale := newDevice("stale")
	stale.LastSeen, stale.mdnsSeen = old, old
	asking := newDevice("asking")
	asking.LastSeen, asking.mdnsSeen = old, old
	asking.pairState = "incoming"
	recent := newDevice("recent")
	recent.LastSeen = time.Now()
	paired := newDevice("paired")
	paired.Paired = true
	d := &Daemon{devices: map[string]*Device{"stale": stale, "asking": asking, "recent": recent, "paired": paired}}
	d.dialKnown()
	if _, ok := d.devices["stale"]; ok {
		t.Error("the stale device is still there")
	}
	for _, id := range []string{"asking", "recent", "paired"} {
		if _, ok := d.devices[id]; !ok {
			t.Errorf("dialKnown removed %s", id)
		}
	}
}
