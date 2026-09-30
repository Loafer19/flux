package desktop

import (
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// LocalInput watches physical /dev/input nodes for mouse and key activity.
// Virtual Wayland pointers do not write there, so activity means a real
// local device moved or a key was pressed. When the process cannot open
// any node (common without the input group), Watch is a no-op and OK is
// false — callers still detect local mouse via cursor divergence.
type LocalInput struct {
	mu     sync.Mutex
	last   time.Time
	ok     bool
	stop   chan struct{}
	done   chan struct{}
	once   sync.Once
}

// StartLocalInput opens readable event nodes and records activity.
// It is safe to call once; later calls are ignored.
func StartLocalInput() *LocalInput {
	w := &LocalInput{
		stop: make(chan struct{}),
		done: make(chan struct{}),
	}
	nodes := localInputNodes()
	var files []*os.File
	for _, path := range nodes {
		f, err := os.OpenFile(path, os.O_RDONLY|unix.O_NONBLOCK, 0)
		if err != nil {
			continue
		}
		files = append(files, f)
	}
	if len(files) == 0 {
		close(w.done)
		return w
	}
	w.ok = true
	go w.loop(files)
	return w
}

// OK reports whether at least one input node is being watched.
func (w *LocalInput) OK() bool {
	if w == nil {
		return false
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.ok
}

// ActiveSince reports whether a physical key or relative mouse event
// arrived at or after t.
func (w *LocalInput) ActiveSince(t time.Time) bool {
	if w == nil {
		return false
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	return !w.last.IsZero() && !w.last.Before(t)
}

// Stop closes the watcher.
func (w *LocalInput) Stop() {
	if w == nil {
		return
	}
	w.once.Do(func() {
		select {
		case <-w.done:
			return
		default:
			close(w.stop)
		}
		<-w.done
	})
}

func (w *LocalInput) loop(files []*os.File) {
	defer close(w.done)
	defer func() {
		for _, f := range files {
			_ = f.Close()
		}
	}()
	bufs := make([][]byte, len(files))
	for i := range bufs {
		bufs[i] = make([]byte, 24) // input_event on 64-bit Linux
	}
	for {
		select {
		case <-w.stop:
			return
		default:
		}
		progress := false
		for i, f := range files {
			for {
				n, err := f.Read(bufs[i])
				if n == 24 {
					typ := binary.LittleEndian.Uint16(bufs[i][16:18])
					val := int32(binary.LittleEndian.Uint32(bufs[i][20:24]))
					// EV_KEY (1) press/release, EV_REL (2) mouse motion.
					if (typ == 1 && val != 0) || typ == 2 {
						w.mu.Lock()
						w.last = time.Now()
						w.mu.Unlock()
					}
					progress = true
					continue
				}
				if err == nil {
					break
				}
				if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EWOULDBLOCK) {
					break
				}
				// Device gone: stop reading this fd.
				_ = f.Close()
				files[i] = nil
				break
			}
		}
		alive := files[:0]
		for _, f := range files {
			if f != nil {
				alive = append(alive, f)
			}
		}
		files = alive
		if len(files) == 0 {
			w.mu.Lock()
			w.ok = false
			w.mu.Unlock()
			return
		}
		if !progress {
			select {
			case <-w.stop:
				return
			case <-time.After(20 * time.Millisecond):
			}
		}
	}
}

func localInputNodes() []string {
	matches, _ := filepath.Glob("/dev/input/event*")
	var out []string
	for _, path := range matches {
		name := inputDeviceName(path)
		if name == "" {
			out = append(out, path)
			continue
		}
		lower := strings.ToLower(name)
		if strings.Contains(lower, "virtual") ||
			strings.Contains(lower, "js") ||
			strings.Contains(lower, "consumer control") ||
			strings.Contains(lower, "system control") ||
			strings.Contains(lower, "power button") {
			continue
		}
		out = append(out, path)
	}
	return out
}

func inputDeviceName(eventPath string) string {
	base := filepath.Base(eventPath)
	sys := filepath.Join("/sys/class/input", base, "device", "name")
	b, err := os.ReadFile(sys)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}
