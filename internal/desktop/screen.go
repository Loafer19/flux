package desktop

import "strings"

// Monitor is one screen in logical pixels, the same space as the cursor.
type Monitor struct {
	X, Y float64
	W, H float64
}

// EdgeHit reports whether x, y is within margin of the named edge of the
// screens. side is left, right, top, or bottom.
func EdgeHit(side string, x, y float64, screens []Monitor, margin float64) bool {
	minX, minY, maxX, maxY, ok := ScreenBounds(screens)
	if !ok {
		return false
	}
	switch side {
	case "left":
		return x <= minX+margin
	case "right":
		return x >= maxX-margin
	case "top":
		return y <= minY+margin
	case "bottom":
		return y >= maxY-margin
	}
	return false
}

// EdgeInward reports whether dx, dy moves back inside from side by at
// least slack pixels.
func EdgeInward(side string, dx, dy, slack float64) bool {
	switch side {
	case "left":
		return dx >= slack
	case "right":
		return dx <= -slack
	case "top":
		return dy >= slack
	case "bottom":
		return dy <= -slack
	}
	return false
}

// EdgeOutward is how far dx, dy move through side onto the peer. Positive
// means further onto the other screen.
func EdgeOutward(side string, dx, dy float64) float64 {
	switch side {
	case "left":
		return -dx
	case "right":
		return dx
	case "top":
		return -dy
	case "bottom":
		return dy
	}
	return 0
}

// EdgePoint is the pointer position, from 0 to 1, where a seam on side
// places the cursor: the middle of that edge.
func EdgePoint(side string) (x, y float64) {
	switch side {
	case "left":
		return 0, 0.5
	case "right":
		return 1, 0.5
	case "top":
		return 0.5, 0
	case "bottom":
		return 0.5, 1
	}
	return 0.5, 0.5
}

// ScreenCenter is the middle of the combined screen bounds in logical pixels.
func ScreenCenter(screens []Monitor) (x, y float64, ok bool) {
	minX, minY, maxX, maxY, ok := ScreenBounds(screens)
	if !ok {
		return 0, 0, false
	}
	return (minX + maxX) / 2, (minY + maxY) / 2, true
}

// ScreenPark is where the local cursor sits while the peer holds the pointer.
// Top-left of the combined bounds (typically the status bar) avoids the
// middle of tiled windows that would otherwise catch hover and focus.
func ScreenPark(screens []Monitor) (x, y float64, ok bool) {
	minX, minY, _, _, ok := ScreenBounds(screens)
	if !ok {
		return 0, 0, false
	}
	return minX + 2, minY + 2, true
}

// EdgeInside is a point inset from side, keeping the along-edge coordinate
// from along. Used when the pointer returns from the peer.
func EdgeInside(side string, along HyprCursor, screens []Monitor, inset float64) (x, y float64, ok bool) {
	minX, minY, maxX, maxY, ok := ScreenBounds(screens)
	if !ok {
		return 0, 0, false
	}
	if inset < 1 {
		inset = 1
	}
	clamp := func(v, lo, hi float64) float64 {
		if v < lo {
			return lo
		}
		if v > hi {
			return hi
		}
		return v
	}
	switch side {
	case "left":
		return minX + inset, clamp(along.Y, minY, maxY), true
	case "right":
		return maxX - inset, clamp(along.Y, minY, maxY), true
	case "top":
		return clamp(along.X, minX, maxX), minY + inset, true
	case "bottom":
		return clamp(along.X, minX, maxX), maxY - inset, true
	}
	return (minX + maxX) / 2, (minY + maxY) / 2, true
}

// ValidEdge reports whether side names a screen edge.
func ValidEdge(side string) bool {
	switch strings.ToLower(strings.TrimSpace(side)) {
	case "left", "right", "top", "bottom":
		return true
	}
	return false
}

func ScreenBounds(screens []Monitor) (minX, minY, maxX, maxY float64, ok bool) {
	for _, s := range screens {
		if s.W <= 0 || s.H <= 0 {
			continue
		}
		x2, y2 := s.X+s.W, s.Y+s.H
		if !ok {
			minX, minY, maxX, maxY = s.X, s.Y, x2, y2
			ok = true
			continue
		}
		if s.X < minX {
			minX = s.X
		}
		if s.Y < minY {
			minY = s.Y
		}
		if x2 > maxX {
			maxX = x2
		}
		if y2 > maxY {
			maxY = y2
		}
	}
	return minX, minY, maxX, maxY, ok
}
