package desktop

import "testing"

func TestEdgeGeometry(t *testing.T) {
	screens := []Monitor{{X: 0, Y: 0, W: 1800, H: 1125}}
	if !EdgeHit("left", 2, 100, screens, 6) || EdgeHit("left", 40, 100, screens, 6) {
		t.Fatal("left edge")
	}
	if !EdgeHit("right", 1798, 10, screens, 6) || EdgeHit("right", 1700, 10, screens, 6) {
		t.Fatal("right edge")
	}
	if !EdgeInward("left", 48, 0, 48) || EdgeInward("left", 10, 0, 48) {
		t.Fatal("return from the left")
	}
	if !EdgeInward("right", -48, 0, 48) || EdgeInward("bottom", 0, 10, 48) {
		t.Fatal("return direction")
	}
	if EdgeOutward("left", -10, 3) != 10 || EdgeOutward("right", 8, 0) != 8 {
		t.Fatal("outward depth")
	}
	if EdgeOutward("left", 12, 0) != -12 {
		t.Fatal("inward reduces depth")
	}
	cx, cy, ok := ScreenCenter(screens)
	if !ok || cx != 900 || cy != 562.5 {
		t.Fatalf("center %v %v %v", cx, cy, ok)
	}
	x, y, ok := EdgeInside("left", HyprCursor{X: 0, Y: 200}, screens, 48)
	if !ok || x != 48 || y != 200 {
		t.Fatalf("inside %v %v %v", x, y, ok)
	}
	x, y = EdgePoint("right")
	if x != 1 || y != 0.5 {
		t.Fatalf("point %v %v", x, y)
	}
	cur, err := parseCursor("900, 181")
	if err != nil || cur.X != 900 || cur.Y != 181 {
		t.Fatalf("cursor %v %v", cur, err)
	}
	screens, err = parseMonitors([]byte(`[{"x":0,"y":0,"width":2880,"height":1800,"scale":1.6}]`))
	if err != nil || len(screens) != 1 || screens[0].W != 1800 || screens[0].H != 1125 {
		t.Fatalf("monitors %+v %v", screens, err)
	}
}

func TestScreenPark(t *testing.T) {
	screens := []Monitor{{X: 0, Y: 0, W: 100, H: 50}}
	x, y, ok := ScreenPark(screens)
	if !ok || x != 2 || y != 2 {
		t.Fatalf("park %v %v %v", x, y, ok)
	}
}
