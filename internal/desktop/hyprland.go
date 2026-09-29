package desktop

import (
	"encoding/json"
	"errors"
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
