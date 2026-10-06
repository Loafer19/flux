import QtQuick
import ".."

// A surface on the window. Fill is bg2. The border is 1 px bg3.
// A card that needs a person uses an accent or warn border instead.
// Corners stay square, like the switches and the buttons.
Rectangle {
  color: Theme.bg2
  border.width: 1
  border.color: Theme.bg3
  radius: 0
}
