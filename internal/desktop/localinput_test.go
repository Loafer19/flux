package desktop

import (
	"testing"
	"time"
)

func TestLocalInputNoDevicesStillStops(t *testing.T) {
	w := &LocalInput{
		stop: make(chan struct{}),
		done: make(chan struct{}),
	}
	close(w.done) // simulate StartLocalInput with nothing to watch
	w.Stop()
	w.Stop() // idempotent
	if w.ActiveSince(time.Now().Add(-time.Second)) {
		t.Fatal("empty watcher reported activity")
	}
}

func TestLocalInputNodesFiltersVirtual(t *testing.T) {
	// Just ensure the helper does not panic when /dev/input is present.
	_ = localInputNodes()
}
