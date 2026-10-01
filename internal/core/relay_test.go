package core

import (
	"testing"

	"flux/internal/relay"
)

func TestConnectShouldRelayMatchesURL(t *testing.T) {
	d, _ := clipDaemon(t, true)
	d.cfg.Relay = true
	d.cfg.RelayURL = "127.0.0.1:17777"
	if !d.useRelay() {
		t.Fatal("useRelay false")
	}
	if !d.connectShouldRelay("127.0.0.1", 17777) {
		t.Fatal("expected relay match")
	}
	if d.connectShouldRelay("192.168.1.10", 1716) {
		t.Fatal("direct host must not match relay")
	}
	d.cfg.Relay = false
	if d.connectShouldRelay("127.0.0.1", 17777) {
		t.Fatal("relay off must not match")
	}
}

func TestUseRelayNeedsURL(t *testing.T) {
	d, _ := clipDaemon(t, true)
	d.cfg.Relay = true
	d.cfg.RelayURL = ""
	if d.useRelay() {
		t.Fatal("relay on without URL must be false")
	}
	d.cfg.RelayURL = "100.64.0.1:17777"
	if !d.useRelay() {
		t.Fatal("relay on with URL must be true")
	}
}

func TestSetRelayRequiresURL(t *testing.T) {
	d, _ := clipDaemon(t, true)
	d.cfg.RelayURL = ""
	if err := d.setSetting("relay", true); err == nil {
		t.Fatal("relay on without URL should fail")
	}
	if err := d.setSetting("relayURL", "127.0.0.1:17777"); err != nil {
		t.Fatal(err)
	}
	if err := d.setSetting("relay", true); err != nil {
		t.Fatal(err)
	}
	if !d.cfg.Relay {
		t.Fatal("relay should be on")
	}
}

func TestSameEndpoint(t *testing.T) {
	if !relay.SameEndpoint("127.0.0.1", 17777, "127.0.0.1", 17777) {
		t.Fatal("same IP")
	}
	if relay.SameEndpoint("127.0.0.1", 17777, "127.0.0.1", 9) {
		t.Fatal("port mismatch")
	}
	if !relay.SameEndpoint("Relay.Example", 1, "relay.example", 1) {
		t.Fatal("case fold")
	}
}
