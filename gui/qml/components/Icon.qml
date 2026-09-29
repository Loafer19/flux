import QtQuick
import QtQuick.Controls.impl
import ".."

// A square icon tile. Material Design Icons SVGs share a 24×24 viewBox, so
// phone, laptop, and every other kind share the same cell geometry. ColorImage
// tints the paths; no per-glyph optical nudge.
ColorImage {
  id: root
  property string name: ""
  property int size: 16

  width: size
  height: size
  source: name !== "" ? Qt.resolvedUrl("../icons/" + name + ".svg") : ""
  sourceSize.width: size
  sourceSize.height: size
  fillMode: Image.PreserveAspectFit
  smooth: true
  color: Theme.fg
}
