import QtQuick
import QtQuick.Layouts
import ".."
import "../components"

// This computer and the paired devices. A peer shows the link as it is:
// clipboard and files work, Do Not Disturb between desks is off, and screen
// edges are not set. The page does not turn those on.
Item {
  id: root
  property var view
  property bool fillHeight: false

  readonly property var self: view && view.backend ? (view.backend.selfDevice || {}) : {}
  readonly property var paired: view && view.paired ? view.paired : []
  // Desks first, then phones and other remotes.
  readonly property var ordered: {
    var list = paired.slice()
    list.sort(function (a, b) {
      var rank = function (d) { return d.role === "peer" ? 0 : 1 }
      var byRole = rank(a) - rank(b)
      if (byRole !== 0) return byRole
      return String(a.name || "").localeCompare(String(b.name || ""))
    })
    return list
  }
  readonly property var settings: view && view.backend ? (view.backend.settings || {}) : {}
  readonly property bool phoneDnd: settings.syncDnd !== false && paired.some(d => d.role !== "peer")

  implicitHeight: col.implicitHeight

  // Capability / feature chip. On = fg (neutral); green is reserved for
  // the live "connected" indicator on the status line.
  component Status: RowLayout {
    property string icon: ""
    property string label: ""
    property bool on: false
    spacing: 6
    Icon {
      Layout.alignment: Qt.AlignVCenter
      Layout.preferredWidth: 14
      Layout.preferredHeight: 14
      name: icon
      size: 14
      color: on ? Theme.fg : Theme.dim
    }
    Txt {
      Layout.alignment: Qt.AlignVCenter
      text: label
      color: on ? Theme.fg : Theme.dim
      font.pixelSize: 12
    }
  }

  function roleLine(d) {
    if (d.role === "peer") return "Peer · " + Fmt.typeName(d.type || "desktop")
    if (d.type === "phone" || d.type === "tablet") return Fmt.typeName(d.type)
    return "Remote · " + Fmt.typeName(d.type || "device")
  }

  Column {
    id: col
    width: parent.width
    spacing: 18

    SectionLabel { text: "THIS COMPUTER" }

    Card {
      width: parent.width
      implicitHeight: selfCol.implicitHeight + 36
      Column {
        id: selfCol
        x: 18
        y: 18
        width: parent.width - 36
        spacing: 6
        RowLayout {
          spacing: 10
          Icon {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 18
            Layout.preferredHeight: 18
            name: Fmt.kindIcon(root.self.type || "desktop")
            size: 18
            color: Theme.accent
          }
          Txt {
            Layout.alignment: Qt.AlignVCenter
            text: root.self.name || "This computer"
            font.pixelSize: 18
            font.weight: Font.Bold
          }
        }
        Txt {
          text: Fmt.typeName(root.self.type || "desktop") + (root.self.tcpPort ? " · TCP " + root.self.tcpPort : "")
          color: Theme.dim
        }
        Status {
          visible: root.phoneDnd
          icon: "bell"
          label: "Phones follow DND"
          on: true
        }
      }
    }

    SectionLabel { text: "DEVICES" }

    Txt {
      visible: root.paired.length === 0
      width: parent.width
      wrapMode: Text.Wrap
      text: "No paired devices. Pair a phone or another computer."
      color: Theme.dim
    }

    Repeater {
      model: root.ordered
      delegate: Card {
        id: card
        required property var modelData
        readonly property bool peer: modelData.role === "peer"
        readonly property string edgeLabel: {
          var side = String(root.settings.edgeSide || "")
          var who = String(root.settings.edgeDevice || "").toLowerCase()
          var name = String(modelData.name || "").toLowerCase()
          var id = String(modelData.id || "")
          if (!side || !who || (id !== root.settings.edgeDevice && name !== who)) return "No edges"
          return side.charAt(0).toUpperCase() + side.slice(1) + " edge"
        }
        width: col.width
        implicitHeight: devCol.implicitHeight + 36

        Column {
          id: devCol
          x: 18
          y: 18
          width: parent.width - 36
          spacing: 6
          RowLayout {
            width: parent.width
            spacing: 10
            Icon {
              Layout.alignment: Qt.AlignVCenter
              Layout.preferredWidth: 18
              Layout.preferredHeight: 18
                name: Fmt.kindIcon(modelData.type)
              size: 18
              color: Theme.fg
            }
            Txt {
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              text: modelData.name || "Device"
              font.pixelSize: 16
              font.weight: Font.DemiBold
              elide: Text.ElideRight
            }
          }
          // Role and IP stay muted; only the live link word uses Theme.ok.
          RowLayout {
            width: parent.width
            spacing: 0
            Txt {
              Layout.alignment: Qt.AlignVCenter
              text: root.roleLine(modelData) + " · "
              color: Theme.dim
              elide: Text.ElideRight
            }
            Txt {
              Layout.alignment: Qt.AlignVCenter
              text: modelData.online ? "connected" : "offline"
              color: modelData.online ? Theme.ok : Theme.dim
            }
            Txt {
              Layout.alignment: Qt.AlignVCenter
              Layout.fillWidth: true
              visible: !!modelData.ip
              text: " · " + (modelData.ip || "")
              color: Theme.dim
              elide: Text.ElideRight
            }
          }
          Column {
            visible: card.peer
            spacing: 8
            RowLayout {
              spacing: 18
              Status {
                icon: "clipboard"
                label: root.settings.autoClipboard === false ? "Clipboard off" : "Clipboard"
                on: root.settings.autoClipboard !== false
              }
              Status { icon: "file"; label: "Files"; on: true }
            }
            RowLayout {
              spacing: 18
              Status { icon: "bell-off"; label: "DND off"; on: false }
              Status { icon: "monitor"; label: card.edgeLabel; on: card.edgeLabel !== "No edges" }
            }
          }
          Status {
            visible: !card.peer
            icon: "dashboard"
            label: "Overview"
            on: true
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.view.selectedId = modelData.id
            root.view.go("overview")
          }
        }
      }
    }
  }
}
