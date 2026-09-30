import QtQuick
import QtQuick.Layouts
import ".."
import "../components"

// This computer and the paired devices. A peer shows clipboard and files,
// Do Not Disturb between desks off, and the configured screen edge.
// Tap the edge chip on a peer to set or clear that seam.
// View opens desk↔desk remote desktop (desktop.view); Stop ends it.
// Pair without discovery: generate a flux1 invite or paste one from another desk.
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
  // state.peerDesktop while this computer shows another desk (desktop.view).
  readonly property var peerDesktop: {
    if (!view || !view.backend || !view.backend.state) return null
    return view.backend.state.peerDesktop || null
  }
  readonly property bool phoneDnd: settings.syncDnd !== false && paired.some(d => d.role !== "peer")

  // Invite / join state for discovery-less first pairing (same as flux-cli pair invite|join).
  property string inviteCode: ""
  property string inviteHost: ""
  property int invitePort: 0
  property string inviteName: ""
  property string hostDraft: ""
  property string joinDraft: ""
  property string joinStatus: ""
  property string pendingJoinId: ""
  property bool inviting: false
  property bool joining: false

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

  function copyText(t) {
    clipHelper.text = t
    clipHelper.selectAll()
    clipHelper.copy()
    if (root.view) root.view.toast("Invite copied")
  }

  function generateInvite() {
    if (!root.view || !root.view.call || root.inviting) return
    root.inviting = true
    root.inviteCode = ""
    root.joinStatus = ""
    var host = String(hostField.text || root.hostDraft || "").trim()
    root.hostDraft = host
    root.view.call("pair.invite", { host: host }, function (result) {
      root.inviting = false
      if (!result || !result.invite) {
        if (root.view) root.view.toast("Could not build invite")
        return
      }
      root.inviteCode = result.invite
      root.inviteHost = result.host || ""
      root.invitePort = result.port || 0
      root.inviteName = result.name || ""
      if (hostField.text === "" && root.inviteHost !== "")
        hostField.text = root.inviteHost
      if (root.view) root.view.toast("Invite ready")
    })
    // view.call toasts errors and skips cb; clear inviting on a short timer
    // when the request fails (no cb). Success clears it in the cb above.
    inviteBusyTimer.restart()
  }

  function clearInvite() {
    root.inviteCode = ""
    root.inviteHost = ""
    root.invitePort = 0
    root.inviteName = ""
  }

  function joinInvite() {
    if (!root.view || !root.view.call || root.joining) return
    var raw = String(joinField.text || root.joinDraft || "").trim()
    root.joinDraft = raw
    if (raw === "") {
      root.view.toast("Paste a flux1 invite")
      return
    }
    root.joining = true
    root.pendingJoinId = ""
    root.joinStatus = "Dialing…"
    root.view.call("pair.connect", { invite: raw }, function (result) {
      if (!result || !result.id) {
        root.joining = false
        root.joinStatus = ""
        root.view.toast("Could not dial invite")
        return
      }
      root.pendingJoinId = result.id
      root.joinStatus = "Dialing " + (result.host || "") + (result.port ? (":" + result.port) : "") + "…"
      joinWatch.restart()
      tryPairPending()
    })
    joinBusyTimer.restart()
  }

  function findPendingDevice() {
    if (!root.pendingJoinId || !root.view) return null
    var all = root.view.allDevices || []
    for (var i = 0; i < all.length; i++) {
      if (all[i].id === root.pendingJoinId) return all[i]
    }
    return null
  }

  function tryPairPending() {
    if (!root.pendingJoinId || !root.view || !root.view.call) return
    var d = findPendingDevice()
    if (!d) return
    if (d.paired) {
      root.joinStatus = (d.name || "Peer") + " paired"
      root.joining = false
      root.pendingJoinId = ""
      joinWatch.stop()
      root.view.toast(root.joinStatus)
      return
    }
    if (!d.online) return
    if (d.pairState === "requested" || d.pairState === "incoming") {
      root.joinStatus = d.pairKey
                   ? ("Confirm " + d.pairKey + " on both screens")
                   : ("Waiting for " + (d.name || "peer") + "…")
      return
    }
    root.joinStatus = "Linked to " + (d.name || "peer") + ". Asking to pair…"
    root.view.call("pair.request", { device: d.id }, function () {
      root.joinStatus = "Confirm the key on both screens"
    })
  }

  function viewingPeer(d) {
    var pd = root.peerDesktop
    if (!pd || !d) return false
    var from = String(pd.from || "")
    var name = String(pd.fromName || "").toLowerCase()
    return from === String(d.id || "") || name === String(d.name || "").toLowerCase()
  }

  function startPeerView(d) {
    if (!root.view || !root.view.call || !d) return
    if (!d.online) {
      root.view.toast((d.name || "Peer") + " is offline")
      return
    }
    var key = d.name || d.id
    root.view.call("desktop.view", { device: key }, function () {
      if (root.view) root.view.toast("Showing " + (d.name || "peer") + " desktop")
    })
  }

  function stopPeerView() {
    if (!root.view || !root.view.call) return
    root.view.call("desktop.viewStop", {}, function () {
      if (root.view) root.view.toast("Stopped peer desktop")
    })
  }

  // view.call does not invoke cb on error; these clear busy flags after a beat.
  Timer {
    id: inviteBusyTimer
    interval: 400
    onTriggered: {
      if (root.inviting && root.inviteCode === "") root.inviting = false
    }
  }
  Timer {
    id: joinBusyTimer
    interval: 400
    onTriggered: {
      if (root.joining && root.pendingJoinId === "" && root.joinStatus === "Dialing…") {
        root.joining = false
        root.joinStatus = ""
      }
    }
  }
  Timer {
    id: joinWatch
    interval: 500
    repeat: true
    property int runs: 0
    onRunningChanged: if (running) runs = 0
    onTriggered: {
      runs++
      root.tryPairPending()
      // Stop after ~30s with no link row yet.
      if (root.pendingJoinId && !root.findPendingDevice() && runs > 60) {
        root.joinStatus = "No answer yet. Check Tailscale or the host in the invite."
        root.joining = false
        stop()
      }
    }
  }

  // When fluxd pushes state, retry pair for an in-flight join.
  Connections {
    target: root.view
    ignoreUnknownSignals: true
    function onAllDevicesChanged() { root.tryPairPending() }
  }

  // Hidden field used only to put text on the system clipboard.
  TextEdit {
    id: clipHelper
    visible: false
    width: 1
    height: 1
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

    SectionLabel { text: "PAIR WITH INVITE" }

    Card {
      width: parent.width
      implicitHeight: inviteCol.implicitHeight + 36
      Column {
        id: inviteCol
        x: 18
        y: 18
        width: parent.width - 36
        spacing: 10

        Txt {
          width: parent.width
          text: "When the other computer does not appear on the network, share a flux1 invite. Same path as flux-cli pair invite and pair join. The invite is not a secret; you still confirm the 8-character key."
          color: Theme.dim
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }

        Txt {
          text: "Share this computer"
          font.weight: Font.DemiBold
        }
        Txt {
          width: parent.width
          text: "Host the other side can reach (Tailscale name or IP). Leave empty when fluxd can pick the only Tailscale address."
          color: Theme.dim
          font.pixelSize: 11
          wrapMode: Text.Wrap
        }
        RowLayout {
          width: parent.width
          spacing: 8
          Field {
            id: hostField
            Layout.fillWidth: true
            placeholder: "e.g. dragon or 100.99.87.88"
            onAccepted: root.generateInvite()
          }
          AccentButton {
            text: root.inviting ? "…" : "Create invite"
            icon: "link"
            active: !root.inviting
            onClicked: root.generateInvite()
          }
        }

        Column {
          visible: root.inviteCode !== ""
          width: parent.width
          spacing: 10
          Txt {
            width: parent.width
            text: root.inviteName !== ""
                  ? ("Invite for " + root.inviteName + (root.inviteHost ? (" @ " + root.inviteHost + (root.invitePort ? (":" + root.invitePort) : "")) : ""))
                  : "Invite"
            color: Theme.dim
            font.pixelSize: 11
            wrapMode: Text.Wrap
          }
          RowLayout {
            width: parent.width
            spacing: 8
            Field {
              Layout.fillWidth: true
              text: root.inviteCode
              input.readOnly: true
            }
            OutlineButton {
              icon: "copy"
              text: "Copy"
              onClicked: root.copyText(root.inviteCode)
            }
            OutlineButton {
              icon: "close"
              text: "Clear"
              onClicked: root.clearInvite()
            }
          }
          QrImage {
            id: inviteQr
            anchors.horizontalCenter: parent.horizontalCenter
            width: 168
            height: 168
            text: root.inviteCode
            // Fixed black-on-white so phone cameras can scan in any theme.
            dark: "#111111"
            light: "#ffffff"
          }
          Txt {
            width: parent.width
            text: inviteQr.ready
                  ? "Scan or paste on the other computer: Network → Join, then accept the matching key."
                  : "On the other computer: Network → paste invite → Join, then accept the matching key."
            color: Theme.dim
            font.pixelSize: 11
            wrapMode: Text.Wrap
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Theme.bg3
        }

        Txt {
          text: "Join another computer"
          font.weight: Font.DemiBold
        }
        Txt {
          width: parent.width
          text: "Paste a flux1:… invite from the other desk, then Join. Flux dials that host and asks to pair."
          color: Theme.dim
          font.pixelSize: 11
          wrapMode: Text.Wrap
        }
        RowLayout {
          width: parent.width
          spacing: 8
          Field {
            id: joinField
            Layout.fillWidth: true
            placeholder: "flux1:…@host:port"
            onAccepted: root.joinInvite()
          }
          AccentButton {
            text: root.joining ? "…" : "Join"
            icon: "link"
            active: !root.joining
            onClicked: root.joinInvite()
          }
        }
        Txt {
          visible: root.joinStatus !== ""
          width: parent.width
          text: root.joinStatus
          color: Theme.accent
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }
      }
    }

    SectionLabel { text: "DEVICES" }

    Txt {
      visible: root.paired.length === 0
      width: parent.width
      wrapMode: Text.Wrap
      text: "No paired devices. Pair a phone on the LAN, or pair another computer with an invite above."
      color: Theme.dim
    }

    Repeater {
      model: root.ordered
      delegate: Card {
        id: card
        required property var modelData
        readonly property bool peer: modelData.role === "peer"
        readonly property bool viewing: root.viewingPeer(modelData)
        readonly property string edgeLabel: {
          var side = String(root.settings.edgeSide || "")
          var who = String(root.settings.edgeDevice || "").toLowerCase()
          var name = String(modelData.name || "").toLowerCase()
          var id = String(modelData.id || "")
          if (!side || !who || (id !== root.settings.edgeDevice && name !== who)) return "No edges"
          return side.charAt(0).toUpperCase() + side.slice(1) + " edge"
        }
        function cycleEdge() {
          var order = ["", "left", "right", "top", "bottom"]
          var cur = ""
          var who = String(root.settings.edgeDevice || "").toLowerCase()
          var name = String(modelData.name || "").toLowerCase()
          var id = String(modelData.id || "")
          if (root.settings.edgeSide && who && (id === root.settings.edgeDevice || name === who))
            cur = String(root.settings.edgeSide || "").toLowerCase()
          var i = order.indexOf(cur)
          var next = order[(i + 1) % order.length]
          var device = modelData.name || modelData.id
          if (!root.view || !root.view.call) return
          if (!next) {
            root.view.call("settings.set", { key: "edgeSide", value: "" })
            root.view.call("settings.set", { key: "edgeDevice", value: "" })
            root.view.toast("Screen edge off")
            return
          }
          root.view.call("settings.set", { key: "edgeSide", value: next })
          root.view.call("settings.set", { key: "edgeDevice", value: device })
          root.view.toast(next.charAt(0).toUpperCase() + next.slice(1) + " edge → " + device)
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
              Item {
                Layout.preferredWidth: edgeChip.implicitWidth
                Layout.preferredHeight: edgeChip.implicitHeight
                Status {
                  id: edgeChip
                  icon: "monitor"
                  label: card.edgeLabel
                  on: card.edgeLabel !== "No edges"
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: card.cycleEdge()
                }
              }
            }
            RowLayout {
              width: parent.width
              spacing: 8
              Txt {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: {
                  if (card.viewing) {
                    var pd = root.peerDesktop || ({})
                    var bits = ["Viewing"]
                    if (pd.monitor) bits.push(pd.monitor)
                    if (pd.width && pd.height) bits.push(pd.width + "×" + pd.height)
                    if (pd.player) bits.push(pd.player)
                    return bits.join(" · ")
                  }
                  return modelData.online
                    ? "Remote desktop (same as flux-cli desktop view)"
                    : "Remote desktop when online"
                }
                color: card.viewing ? Theme.fg : Theme.dim
                font.pixelSize: 12
                wrapMode: Text.Wrap
              }
              AccentButton {
                visible: !card.viewing
                text: "View"
                icon: "monitor"
                active: !!modelData.online
                onClicked: root.startPeerView(modelData)
              }
              OutlineButton {
                visible: card.viewing
                text: "Stop"
                icon: "stop"
                onClicked: root.stopPeerView()
              }
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
          z: -1
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
