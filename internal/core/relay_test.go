package core

import (
	"testing"
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
