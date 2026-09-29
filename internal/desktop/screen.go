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
	minX, minY, maxX, maxY, ok := screenBounds(screens)
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

// ValidEdge reports whether side names a screen edge.
func ValidEdge(side string) bool {
	switch strings.ToLower(strings.TrimSpace(side)) {
	case "left", "right", "top", "bottom":
		return true
	}
	return false
}

func screenBounds(screens []Monitor) (minX, minY, maxX, maxY float64, ok bool) {
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
