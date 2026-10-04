import QtQuick
import ".."
import "../components"

// Send files to the device, list transfers, and (for desktop peers) browse
// the peer's shared home via browse.open / peerBrowse state.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online
  readonly property bool peer: !!dev && dev.role === "peer"
  readonly property var transfers: {
    var all = view && view.backend ? (view.backend.transfers || []) : []
    if (!dev) return all
    return all.filter(t => !t.device || t.device === dev.id)
  }
  readonly property var peerBrowse: {
    var pb = view && view.backend && view.backend.state ? (view.backend.state.peerBrowse || null) : null
    if (!pb || !dev || pb.device !== dev.id) return null
    return pb
  }
  readonly property bool browsing: !!peerBrowse
  readonly property var pending: transfers.filter(t => ["waiting", "queued", "active"].indexOf(t.state) >= 0)
  readonly property real pendingBytes: pending.reduce((n, t) => n + (t.size || 0), 0)
  readonly property real pendingDone: pending.reduce((n, t) => n + (t.done || 0), 0)

  implicitHeight: col.implicitHeight

  function send(paths, skipped) {
    var note = skipped === 1 ? "1 item is not a file on this computer."
      : (skipped > 1 ? skipped + " items are not files on this computer." : "")
    if (!dev) return
    if (paths.length === 0) {
      if (note !== "") view.toast("Flux sends only files on this computer.")
      return
    }
    view.call("share.files", { device: dev.id, paths: paths }, function () {
      var sending = "Queued " + paths.length + " items for " + root.view.devName
      root.view.toast(note !== "" ? sending + ". " + note : sending)
    })
  }

  property bool picking: false
  readonly property var life: ({ alive: true })
  Component.onDestruction: life.alive = false

  function pick() {
    if (picking || !view || !view.backend || !dev) return
    picking = true
    var life = root.life
    var v = view
    var id = dev.id
    var name = view.devName
    v.backend.pickFiles("Send to " + name, function (paths) {
      if (life.alive) root.picking = false
      if (!paths || paths.length === 0) return
      v.call("share.files", { device: id, paths: paths }, function () {
        v.toast("Queued " + paths.length + " items for " + name)
      })
    })
  }

  function openBrowse() {
    if (!view || !dev) return
    if (!online) {
      view.toast(view.devName + " is offline")
      return
    }
    var name = view.devName
    view.call("browse.open", { device: dev.id }, function () {
      view.toast("Opening " + name + " home…")
    })
  }

  function closeBrowse() {
    if (!view) return
    view.call("browse.close", {}, function () {
      view.toast("Closed remote browse")
    })
  }

  function listPath(path) {
    if (!view || !path) return
    view.call("browse.list", { path: path })
  }

  function parentPath(path) {
    if (!path) return ""
    var trimmed = String(path).replace(/\/+$/, "")
    var i = trimmed.lastIndexOf("/")
    if (i <= 0) return trimmed.length ? "/" : ""
    return trimmed.substring(0, i) || "/"
  }

  function atRoot() {
    var pb = root.peerBrowse
    if (!pb || !pb.path) return true
    if (!pb.roots || pb.roots.length === 0) return false
    for (var i = 0; i < pb.roots.length; i++) {
      if (pb.roots[i].path === pb.path) return true
    }
    return false
  }

  function openEntry(e) {
    if (!e) return
    if (e.dir) {
      listPath(e.path)
      return
    }
    view.call("browse.download", { path: e.path }, function (res) {
      var name = (res && res.name) ? res.name : e.name
      view.toast("Saved " + name + " to Downloads")
    })
  }

  function stateText(t) {
    var pct = t.size > 0 ? Math.floor(100 * (t.done || 0) / t.size) : 0
    if (t.state === "active") return pct + "%" + (t.rate > 0 ? " · " + Fmt.rate(t.rate) : "")
    if (t.state === "done") return t.dir === "out" ? "sent" : "done"
    if (t.state === "waiting") return "waiting"
    return t.state || ""
  }

  function stateColor(t) {
    if (t.state === "active") return Theme.accent
    if (t.state === "done") return Theme.ok
    if (t.state === "failed") return Theme.err
    return Theme.dim
  }

  KeyedModel { id: rows; values: root.transfers }

  Column {
    id: col
    width: parent.width
    spacing: 0

    // Desk peer: remote home listing (browse.open / peerBrowse).
    // Accent border + AccentButton so PEER HOME is impossible to miss.
    Card {
      objectName: "peerHomeCard"
      visible: root.peer
      width: parent.width
      implicitHeight: browseCol.implicitHeight + 38
      border.width: 1
      border.color: Theme.accent

      Column {
        id: browseCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 19
        spacing: 12

        Item {
          width: parent.width
          height: Math.max(peerHomeTitleCol.height, browseBtnRow.height)
          Column {
            id: peerHomeTitleCol
            anchors.left: parent.left
            anchors.right: browseBtnRow.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            SectionLabel {
              id: peerHomeTitle
              text: "PEER HOME"
              color: Theme.accent
            }
            Txt {
              width: parent.width
              text: "Browse shared folders on " + (root.view ? root.view.devName : "this desk peer")
              color: Theme.fg
              font.pixelSize: 13
              font.weight: Font.DemiBold
              wrapMode: Text.Wrap
            }
          }
          Row {
            id: browseBtnRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            AccentButton {
              visible: !root.browsing
              text: "Browse"
              icon: "browse"
              active: root.online
              onClicked: root.openBrowse()
            }
            OutlineButton {
              visible: root.browsing
              text: "Close"
              active: true
              onClicked: root.closeBrowse()
            }
          }
        }

        Txt {
          visible: !root.browsing
          width: parent.width
          text: root.online
            ? "Home share must be on on " + (root.view ? root.view.devName : "the peer") + ". Tap Browse to list folders and download files."
            : (root.view ? root.view.devName : "Peer") + " is offline."
          color: Theme.dim
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }

        Column {
          visible: root.browsing
          width: parent.width
          spacing: 10

          // Root chips
          Flow {
            width: parent.width
            spacing: 8
            visible: root.peerBrowse && root.peerBrowse.roots && root.peerBrowse.roots.length > 0
            Repeater {
              model: root.peerBrowse ? (root.peerBrowse.roots || []) : []
              delegate: Chip {
                required property var modelData
                text: modelData.name || modelData.path
                selected: root.peerBrowse && root.peerBrowse.path === modelData.path
                onClicked: root.listPath(modelData.path)
              }
            }
          }

          Row {
            width: parent.width
            spacing: 10
            OutlineButton {
              visible: root.browsing && !root.atRoot()
              text: "Up"
              onClicked: root.listPath(root.parentPath(root.peerBrowse.path))
            }
            Txt {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(40, parent.width - 80)
              text: root.peerBrowse ? (root.peerBrowse.path || "") : ""
              color: Theme.dim
              font.pixelSize: 12
              elide: Text.ElideMiddle
            }
          }

          Txt {
            visible: !!(root.peerBrowse && root.peerBrowse.error)
            width: parent.width
            text: root.peerBrowse ? (root.peerBrowse.error || "") : ""
            color: Theme.err
            wrapMode: Text.Wrap
            font.pixelSize: 12
          }

          Txt {
            visible: root.peerBrowse && root.peerBrowse.loading && !(root.peerBrowse.entries && root.peerBrowse.entries.length)
            text: "Loading…"
            color: Theme.dim
          }

          Txt {
            visible: root.peerBrowse && !root.peerBrowse.loading && !root.peerBrowse.error && !(root.peerBrowse.entries && root.peerBrowse.entries.length)
            text: "This folder is empty."
            color: Theme.dim
          }

          Column {
            width: parent.width
            spacing: 6
            Repeater {
              model: root.peerBrowse ? (root.peerBrowse.entries || []) : []
              delegate: Rectangle {
                required property var modelData
                width: browseCol.width
                height: 36
                radius: 8
                color: entryArea.containsMouse ? Theme.alpha(Theme.fg, 0.06) : "transparent"
                Row {
                  anchors.fill: parent
                  anchors.leftMargin: 8
                  anchors.rightMargin: 8
                  spacing: 10
                  Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: modelData.dir ? "browse" : "transfers"
                    size: 18
                    color: Theme.dim
                  }
                  Txt {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(40, parent.parent.width - 100)
                    text: modelData.name
                    elide: Text.ElideMiddle
                  }
                  Txt {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !modelData.dir
                    text: Fmt.bytes(modelData.size || 0)
                    color: Theme.dim
                    font.pixelSize: 11
                  }
                }
                MouseArea {
                  id: entryArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openEntry(modelData)
                }
              }
            }
          }
        }
      }
    }

    Item { visible: root.peer; width: 1; height: 18 }

    DashedRect {
      id: zone
      width: parent.width
      height: 170
      lineWidth: 1.5
      color: drop.containsDrag ? Theme.accent : Theme.dim
      fill: drop.containsDrag ? Theme.alpha(Theme.accent, 0.08) : "transparent"

      Column {
        anchors.centerIn: parent
        spacing: 6
        Icon {
          anchors.horizontalCenter: parent.horizontalCenter
          name: "tray-up"
          size: 34
          color: drop.containsDrag ? Theme.accent : Theme.dim
        }
        Txt {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(implicitWidth, zone.width - 32)
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          text: "Drop files or folders for " + (root.view ? root.view.devName : "")
          font.pixelSize: 16
          font.weight: Font.DemiBold
        }
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          Txt { text: "or "; color: Theme.dim }
          Txt {
            text: "browse this computer"
            color: Theme.accent
            font.underline: browseArea.containsMouse
            MouseArea {
              id: browseArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.pick()
            }
          }
        }
      }

      DropArea {
        id: drop
        anchors.fill: parent
        keys: ["text/uri-list"]
        onDropped: function (event) {
          var paths = []
          var skipped = 0
          for (var i = 0; i < event.urls.length; i++) {
            var path = Fmt.urlToPath(event.urls[i])
            if (path !== "") paths.push(path)
            else skipped++
          }
          root.send(paths, skipped)
          event.acceptProposedAction()
        }
      }
    }

    Item { width: 1; height: 22 }

    Txt {
      width: parent.width
      text: "Folders use ZIP archives. Queued files stay in the outbox until the device connects."
      color: Theme.dim
      wrapMode: Text.Wrap
    }

    Item { width: 1; height: 12 }

    Txt {
      visible: root.pending.length > 0
      width: parent.width
      text: root.pending.length + " pending · " + Fmt.bytes(root.pendingDone) + " of " + Fmt.bytes(root.pendingBytes)
      color: Theme.dim
    }

    Item { width: 1; height: root.pending.length > 0 ? 12 : 0 }

    Txt {
      visible: root.transfers.length === 0
      text: "No transfers yet."
      color: Theme.dim
    }

    Column {
      width: parent.width
      spacing: 10
      Repeater {
        model: rows
        delegate: Card {
          id: row
          required property string key
          readonly property var modelData: rows.byId[key] || ({})
          readonly property bool incoming: modelData.dir !== "out"
          readonly property real inner: width - 38
          readonly property bool compact: inner < 460
          readonly property real statusWidth: compact ? 90 : 110
          readonly property real barWidth: compact ? 0 : Math.max(80, Math.min(260, inner - 28 - 110 - 48 - 120))
          readonly property real progress: modelData.size > 0 ? (modelData.done || 0) / modelData.size : (modelData.state === "done" ? 1 : 0)
          width: col.width
          implicitHeight: nameCol.implicitHeight + 26 + (actions.visible ? actions.implicitHeight + 18 : 0)

          Icon {
            x: 19
            y: 13
            name: row.incoming ? "tray-down" : "tray-up"
            size: 20
            color: row.incoming ? Theme.ok : Theme.accent
          }
          Column {
            id: nameCol
            x: 19 + 28 + 16
            width: row.compact ? row.inner - 28 - 16 - 16 - row.statusWidth : row.inner - 28 - 16 - row.barWidth - 16 - 16 - 110
            y: 13
            spacing: row.compact ? 3 : 0
            Txt { width: parent.width; text: Fmt.showControls(modelData.name); elide: Text.ElideMiddle }
            Txt { width: parent.width; text: Fmt.bytes(modelData.size); color: Theme.dim; font.pixelSize: 11 }
            Txt { visible: !!modelData.error; width: parent.width; text: modelData.error || ""; color: Theme.warn; font.pixelSize: 11; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
            Bar {
              visible: row.compact
              width: parent.width
              height: 4
              value: row.progress
            }
          }
          Bar {
            visible: !row.compact
            x: nameCol.x + nameCol.width + 16
            y: nameCol.y + nameCol.implicitHeight / 2 - height / 2
            width: row.barWidth
            height: 5
            value: row.progress
          }
          Txt {
            anchors.right: parent.right
            anchors.rightMargin: 19
            y: nameCol.y + nameCol.implicitHeight / 2 - height / 2
            width: row.statusWidth
            horizontalAlignment: Text.AlignRight
            text: row.compact ? root.stateText(modelData).split(" · ")[0] : root.stateText(modelData)
            color: root.stateColor(modelData)
            font.pixelSize: 12
            elide: Text.ElideLeft
          }
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            enabled: modelData.state === "active" || modelData.state === "queued" || modelData.state === "waiting"
            onClicked: root.view.call("transfer.cancel", { id: modelData.id }, function () { root.view.toast("Canceled " + Fmt.showControls(modelData.name)) })
          }
          Row {
            id: actions
            visible: ["waiting", "queued", "active"].indexOf(modelData.state) >= 0
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 12
            spacing: 8
            OutlineButton {
              visible: modelData.state === "waiting"
              text: "Retry now"
              fontSize: 11
              onClicked: root.view.call("transfer.retry", { id: modelData.id })
            }
            OutlineButton {
              text: "Cancel"
              fontSize: 11
              onClicked: root.view.call("transfer.cancel", { id: modelData.id })
            }
          }
        }
      }
    }
  }
}
