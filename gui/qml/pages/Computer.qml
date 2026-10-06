import QtQuick
import QtQuick.Layouts
import ".."
import "../components"

// This computer's switches. Network stays a map of devices and a pair door.
// Modules stay collapsed until the user asks.
Item {
  id: root
  property var view
  property bool fillHeight: false

  readonly property var settings: view && view.backend ? (view.backend.settings || {}) : {}
  readonly property var desktop: view && view.backend && view.backend.state ? (view.backend.state.desktop || null) : null
  readonly property bool desktopShown: !!desktop && !desktop.error
  readonly property bool desktopLive: desktopShown && !!desktop.active
  readonly property var moduleRows: {
    var b = root.view && root.view.backend
    var probe = b && b.moduleProbeText ? String(b.moduleProbeText) : ""
    var want = ["v4l2loopback", "wtype", "wl-copy", "wl-paste", "pw-record"]
    var got = ({})
    var lines = probe.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].trim().split(/\s+/)
      if (parts.length >= 2) got[parts[0]] = parts[1]
    }
    var rows = []
    var allowed = { loaded: true, missing: true, found: true, unknown: true }
    for (var j = 0; j < want.length; j++) {
      var name = want[j]
      var status = got[name] || "unknown"
      if (!allowed[status]) status = "unknown"
      rows.push({ name: name, status: status })
    }
    return rows
  }
  readonly property int modulesMissing: {
    var n = 0
    for (var i = 0; i < moduleRows.length; i++) {
      if (moduleRows[i].status === "missing") n++
    }
    return n
  }
  readonly property bool modulesUnknown: {
    for (var i = 0; i < moduleRows.length; i++) {
      if (moduleRows[i].status !== "unknown") return false
    }
    return moduleRows.length > 0
  }
  property bool modulesOpen: false

  implicitHeight: col.implicitHeight

  component CompactToggle: Column {
    id: ct
    property string label: ""
    property string hint: ""
    property bool checked: false
    signal toggled(bool on)
    width: parent ? parent.width : implicitWidth
    spacing: 1
    Toggle {
      text: ct.label
      checked: ct.checked
      onToggled: function (on) { ct.toggled(on) }
    }
    Txt {
      x: 44
      width: Math.max(0, ct.width - x)
      text: ct.hint
      color: Theme.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
    }
  }

  function setSetting(key, value, onText, offText) {
    if (!root.view || !root.view.call) return
    root.view.call("settings.set", { key: key, value: value })
    if (onText) root.view.toast(value ? onText : offText)
  }

  Column {
    id: col
    width: parent.width
    spacing: 18

    Card {
      width: parent.width
      implicitHeight: shareCol.implicitHeight + 32
      Column {
        id: shareCol
        x: 16
        y: 14
        width: parent.width - 32
        spacing: 8
        SectionLabel { text: "SHARING" }
        CompactToggle {
          objectName: "clipboardToggle"
          label: "Clipboard"
          hint: "Copy text between this computer and paired devices."
          checked: root.settings.autoClipboard !== false
          onToggled: function (on) { root.setSetting("autoClipboard", on, "Clipboard on", "Clipboard off") }
        }
        CompactToggle {
          objectName: "dndToggle"
          label: "DND sync"
          hint: "Phones follow this computer. Two desks do not change each other's Do Not Disturb."
          checked: root.settings.syncDnd !== false
          onToggled: function (on) { root.setSetting("syncDnd", on, "DND sync on", "DND sync off") }
        }
        CompactToggle {
          objectName: "homeShareToggle"
          label: "Home share"
          hint: "This computer shares its home with paired devices."
          checked: root.settings.shareHome !== false
          onToggled: function (on) { root.setSetting("shareHome", on, "Home share on", "Home share off") }
        }
      }
    }

    Card {
      id: remoteCard
      objectName: "remoteCard"
      function set(key, on) {
        if (root.view) root.view.call("settings.set", { key: key, value: on })
      }
      width: parent.width
      implicitHeight: remoteCol.implicitHeight + 32
      Column {
        id: remoteCol
        x: 16
        y: 14
        width: parent.width - 32
        spacing: 8
        SectionLabel { text: root.desktopLive ? "REMOTE ACCESS · LIVE" : "REMOTE ACCESS" }
        CompactToggle {
          objectName: "remoteDesktopToggle"
          label: "Remote desktop"
          hint: "A paired device can show this screen."
          checked: !!root.settings.remoteDesktop
          onToggled: function (on) { remoteCard.set("remoteDesktop", on) }
        }
        CompactToggle {
          objectName: "remoteInputToggle"
          label: "Remote input"
          hint: "A paired device can move the pointer and type."
          checked: !!root.settings.remoteInput
          onToggled: function (on) { remoteCard.set("remoteInput", on) }
        }
        RowLayout {
          visible: root.desktopShown
          width: parent.width
          spacing: 8
          Txt {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            readonly property var d: root.desktop || ({})
            text: root.desktopLive
              ? ((d.toName || "A device") + " shows " + (d.monitor || "this screen"))
              : ((d.toName || "A device") + " is starting…")
            font.pixelSize: 12
            color: root.desktopLive ? Theme.fg : Theme.dim
            elide: Text.ElideRight
          }
          OutlineButton {
            icon: "stop"
            text: "Stop"
            onClicked: root.view.call("desktop.stop", {})
          }
        }
      }
    }

    Card {
      id: agentsCard
      objectName: "agentsCard"
      function set(key, on) {
        if (root.view) root.view.call("settings.set", { key: key, value: on })
      }
      width: parent.width
      implicitHeight: agentsCol.implicitHeight + 32
      Column {
        id: agentsCol
        x: 16
        y: 14
        width: parent.width - 32
        spacing: 8
        SectionLabel { text: "AGENTS" }
        CompactToggle {
          objectName: "herdrToggle"
          label: "Agent output"
          hint: "Show herdr agents of this computer on paired devices."
          checked: root.settings.herdr !== false
          onToggled: function (on) { agentsCard.set("herdr", on) }
        }
        CompactToggle {
          objectName: "herdrControlToggle"
          label: "Agent control"
          hint: "Paired devices can send prompts and control agents."
          checked: !!root.settings.herdrControl
          onToggled: function (on) { agentsCard.set("herdrControl", on) }
        }
        CompactToggle {
          objectName: "herdrTerminalsToggle"
          label: "Agent terminals"
          hint: "Paired devices can open and type in herdr terminals."
          checked: !!root.settings.herdrTerminals
          onToggled: function (on) { agentsCard.set("herdrTerminals", on) }
        }
      }
    }

    Card {
      objectName: "modulesCard"
      width: parent.width
      implicitHeight: modCol.implicitHeight + 28
      Column {
        id: modCol
        x: 16
        y: 12
        width: parent.width - 32
        spacing: 8
        RowLayout {
          width: parent.width
          spacing: 10
          Txt {
            text: "Modules"
            font.weight: Font.DemiBold
          }
          Item { Layout.fillWidth: true }
          Txt {
            text: root.modulesMissing > 0 ? (root.modulesMissing + " missing")
                  : (root.modulesUnknown ? "Unknown" : "Ready")
            font.pixelSize: 12
            color: root.modulesMissing > 0 ? Theme.err : (root.modulesUnknown ? Theme.dim : Theme.ok)
          }
          OutlineButton {
            text: root.modulesOpen ? "Hide" : "Show"
            onClicked: root.modulesOpen = !root.modulesOpen
          }
        }
        Column {
          visible: root.modulesOpen
          width: parent.width
          spacing: 2
          Repeater {
            model: root.moduleRows
            delegate: RowLayout {
              required property var modelData
              width: modCol.width
              spacing: 10
              Txt {
                text: modelData.name
                font.weight: Font.DemiBold
                font.pixelSize: 13
              }
              Item { Layout.fillWidth: true }
              Txt {
                text: modelData.status
                font.pixelSize: 12
                color: (modelData.status === "loaded" || modelData.status === "found") ? Theme.ok
                     : (modelData.status === "missing" ? Theme.err : Theme.dim)
              }
            }
          }
        }
      }
    }
  }
}
