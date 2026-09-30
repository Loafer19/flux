package desktop

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// HyprCursor is the pointer position in logical pixels.
type HyprCursor struct {
	X, Y float64
}

// HyprLayout reads the cursor and the screens from the Hyprland socket.
func HyprLayout() (HyprCursor, []Monitor, error) {
	curText, err := hyprCommand("cursorpos")
	if err != nil {
		return HyprCursor{}, nil, err
	}
	cur, err := parseCursor(curText)
	if err != nil {
		return HyprCursor{}, nil, err
	}
	raw, err := hyprCommand("j/monitors")
	if err != nil {
		return HyprCursor{}, nil, err
	}
	screens, err := parseMonitors([]byte(raw))
	if err != nil {
		return HyprCursor{}, nil, err
	}
	return cur, screens, nil
}

// HyprMoveCursor warps the pointer to x, y in global logical pixels.
func HyprMoveCursor(x, y float64) error {
	out, err := hyprCommand(fmt.Sprintf("dispatch hl.dsp.cursor.move({ x = %g, y = %g })", x, y))
	if err != nil {
		return err
	}
	if msg := strings.TrimSpace(out); msg != "" && !strings.EqualFold(msg, "ok") {
		return fmt.Errorf("hyprland move cursor: %s", msg)
	}
	return nil
}

// HyprSetCursorInvisible hides or shows the pointer image.
func HyprSetCursorInvisible(hide bool) error {
	return hyprEval(fmt.Sprintf("hl.config{ cursor = { invisible = %v } }", hide))
}

// HyprBeginPointerLease hides the cursor image and stops focus-follows-mouse
// so a parked pointer does not activate tiled windows under it.
func HyprBeginPointerLease() error {
	var err error
	if e := HyprSetCursorInvisible(true); e != nil {
		err = e
	}
	if e := hyprEval(`hl.config{ input = { follow_mouse = 0, mouse_refocus = false } }`); e != nil && err == nil {
		err = e
	}
	return err
}

// HyprEndPointerLease restores the usual pointer image and focus-follows-mouse.
// It is idempotent: safe when no lease is held. It also releases any Hyprland
// input-capture session left behind by a crashed overlay or an incomplete
// prior restore (Hyprland 0.56+), which otherwise leaves a stuck or invisible
// pointer after edge handoff.
func HyprEndPointerLease() error {
	var err error
	// Best-effort: no active capture still returns ok from Hyprland.
	if _, e := hyprCommand(`dispatch hl.dsp.release_input_capture()`); e != nil && err == nil {
		err = e
	}
	if e := HyprSetCursorInvisible(false); e != nil && err == nil {
		err = e
	}
	// Omarchy default is follow_mouse = 1 and mouse_refocus = true.
	if e := hyprEval(`hl.config{ input = { follow_mouse = 1, mouse_refocus = true } }`); e != nil && err == nil {
		err = e
	}
	return err
}

// HyprRecoverPointer is the stuck-lease recover path: release capture, show
// the cursor, restore follow_mouse, and warp to the screen center so the
// pointer is never left parked at the status-bar corner.
func HyprRecoverPointer() error {
	err := HyprEndPointerLease()
	if _, screens, layoutErr := HyprLayout(); layoutErr == nil {
		if x, y, ok := ScreenCenter(screens); ok {
			if e := HyprMoveCursor(x, y); e != nil && err == nil {
				err = e
			}
		}
	} else if err == nil {
		err = layoutErr
	}
	return err
}

func hyprEval(expr string) error {
	out, err := hyprCommand("eval " + expr)
	if err != nil {
		return err
	}
	if msg := strings.TrimSpace(out); msg != "" && !strings.EqualFold(msg, "ok") {
		return fmt.Errorf("hyprland eval: %s", msg)
	}
	return nil
}

func hyprCommand(cmd string) (string, error) {
	sig := os.Getenv("HYPRLAND_INSTANCE_SIGNATURE")
	runtime := os.Getenv("XDG_RUNTIME_DIR")
	if sig == "" || runtime == "" {
		return "", errors.New("hyprland is not running")
	}
	path := filepath.Join(runtime, "hypr", sig, ".socket.sock")
	c, err := net.DialTimeout("unix", path, 200*time.Millisecond)
	if err != nil {
		return "", err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(200 * time.Millisecond))
	if _, err := c.Write([]byte(cmd)); err != nil {
		return "", err
	}
	if u, ok := c.(*net.UnixConn); ok {
		_ = u.CloseWrite()
	}
	body, err := io.ReadAll(c)
	if err != nil {
		return "", err
	}
	return string(body), nil
}

func parseCursor(s string) (HyprCursor, error) {
	a, b, ok := strings.Cut(strings.TrimSpace(s), ",")
	if !ok {
		return HyprCursor{}, errors.New("cursor position is not two numbers")
	}
	x, errX := strconv.ParseFloat(strings.TrimSpace(a), 64)
	y, errY := strconv.ParseFloat(strings.TrimSpace(b), 64)
	if errX != nil || errY != nil {
		return HyprCursor{}, errors.New("cursor position is not two numbers")
	}
	return HyprCursor{X: x, Y: y}, nil
}

func parseMonitors(raw []byte) ([]Monitor, error) {
	var rows []struct {
		X      float64 `json:"x"`
		Y      float64 `json:"y"`
		Width  float64 `json:"width"`
		Height float64 `json:"height"`
		Scale  float64 `json:"scale"`
	}
	if err := json.Unmarshal(raw, &rows); err != nil {
		return nil, err
	}
	out := make([]Monitor, 0, len(rows))
	for _, row := range rows {
		scale := row.Scale
		if scale <= 0 {
			scale = 1
		}
		// width and height are physical pixels. The cursor is in logical pixels.
		out = append(out, Monitor{X: row.X, Y: row.Y, W: row.Width / scale, H: row.Height / scale})
	}
	return out, nil
}
