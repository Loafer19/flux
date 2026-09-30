import QtQuick
import ".."
import "../QrCode.js" as QrCode

// Renders text as a QR code. Hidden when the encoder fails or text is empty.
Item {
  id: root
  property string text: ""
  property color dark: "#111111"
  property color light: "#ffffff"
  property int modules: 0
  property bool ready: modules > 0

  implicitWidth: 168
  implicitHeight: 168
  visible: ready

  property var grid: null

  onTextChanged: rebuild()
  Component.onCompleted: rebuild()

  function rebuild() {
    var t = String(root.text || "").trim()
    if (t === "") {
      root.grid = null
      root.modules = 0
      canvas.requestPaint()
      return
    }
    var m = QrCode.matrix(t)
    root.grid = m
    root.modules = m ? m.length : 0
    canvas.requestPaint()
  }

  Rectangle {
    anchors.fill: parent
    color: root.light
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    anchors.margins: 8
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var m = root.grid
      if (!m || m.length === 0) return
      var n = m.length
      var cell = Math.floor(Math.min(width, height) / n)
      if (cell < 1) return
      var side = cell * n
      var ox = Math.floor((width - side) / 2)
      var oy = Math.floor((height - side) / 2)
      ctx.fillStyle = root.light
      ctx.fillRect(0, 0, width, height)
      ctx.fillStyle = root.dark
      for (var r = 0; r < n; r++) {
        for (var c = 0; c < n; c++) {
          if (m[r][c]) ctx.fillRect(ox + c * cell, oy + r * cell, cell, cell)
        }
      }
    }
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
  }
}
