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
	x, y := EdgePoint("right")
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
