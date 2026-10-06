import QtQuick
import QtQuick.Layouts
import ".."
import "../components"

// Devices and Pair. This computer's switches live on their own page.
// Pair lists this network, then the invite, the join field, and the relay.
// The row shows the address fluxd connected with. A path word comes from
// the live socket (lan, tailscale, relay). The address and the relay
// switch do not choose it. An offline device has no path word.
// Screen edge, view desktop, and home browse stay on Overview.
// A live desk view is a badge on the row. Stop stays on Overview.
Item {
  id: root
  property var view
  property bool fillHeight: false

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
  // Network segment: "devices" | "pair"
  property string networkPane: "devices"
  // Invite / join state for discovery-less first pairing.
  property string inviteCode: ""
  property string inviteHost: ""
  property string inviteName: ""
  property int invitePort: 0
  property string hostDraft: ""
  property string joinDraft: ""
  property string joinStatus: ""
  property string pendingJoinId: ""
  property bool inviting: false
  property bool joining: false

  // Relay card: collapsed when off until the user expands; auto-open when on.
  property bool relayUserExpanded: false
  readonly property bool relayExpanded: !!settings.relay || relayUserExpanded

  implicitHeight: col.implicitHeight

  Connections {
    target: root.view
    ignoreUnknownSignals: true
    function onPairPaneChanged() {
      if (!root.view) return
      root.networkPane = root.view.pairPane ? "pair" : "devices"
    }
  }
  Component.onCompleted: if (root.view && root.view.pairPane) root.networkPane = "pair"

  // Segment chip for Devices | Pair.
  component PaneChip: Rectangle {
    id: chip
    property string key: ""
    property string label: ""
    readonly property bool on: root.networkPane === key
    signal activated()
    height: chipLabel.implicitHeight + 14
    width: chipLabel.implicitWidth + 24
    color: on ? Theme.alpha(Theme.accent, 0.18) : (chipArea.containsMouse ? Theme.alpha(Theme.fg, 0.06) : "transparent")
    border.width: 1
    border.color: on ? Theme.alpha(Theme.accent, 0.45) : Theme.bg3
    Txt {
      id: chipLabel
      anchors.centerIn: parent
      text: chip.label
      color: chip.on ? Theme.accent : Theme.fg
      font.pixelSize: 13
      font.weight: chip.on ? Font.DemiBold : Font.Normal
    }
    MouseArea {
      id: chipArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.activated()
    }
  }

  // Short type only — no "Peer ·" / "Remote ·" noise.
  function roleLine(d) {
    if (d.role === "peer") return Fmt.typeName(d.type || "desktop")
    if (d.type === "phone" || d.type === "tablet") return Fmt.typeName(d.type)
    return Fmt.typeName(d.type || "device")
  }

  // The word for a socket path from fluxd. An unknown value stays blank.
  function pathWord(path) {
    if (path === "lan") return "LAN"
    if (path === "tailscale") return "Tailscale"
    if (path === "relay") return "Relay"
    return ""
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

  function saveRelayURL() {
    if (!root.view || !root.view.call) return
    var url = String(relayURLField.text || "").trim()
    root.view.call("settings.set", { key: "relayURL", value: url }, function () {
      if (root.view) root.view.toast(url ? ("Relay URL saved") : "Relay URL cleared")
    })
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
      root.networkPane = "devices"
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

    // ── Segment: Devices | Pair ──
    Row {
      spacing: 8
      PaneChip {
        key: "devices"
        label: "Devices"
        onActivated: {
          root.networkPane = "devices"
          if (root.view) root.view.pairPane = false
        }
      }
      PaneChip {
        key: "pair"
        label: "Pair"
        onActivated: {
          root.networkPane = "pair"
          if (root.view) {
            root.view.pairPane = true
            root.view.call("discover", {})
          }
        }
      }
    }

    // ── Devices pane ──
    Column {
      visible: root.networkPane === "devices"
      width: parent.width
      spacing: 18

      SectionLabel { text: "DEVICES" }

      Txt {
        visible: root.paired.length === 0
        width: parent.width
        wrapMode: Text.Wrap
        text: "No paired devices yet. Open Pair to find a phone on this network, or to invite another computer."
        color: Theme.dim
      }

      Txt {
        visible: root.paired.length === 0
        color: Theme.accent
        font.pixelSize: 12
        text: "Go to Pair →"
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.networkPane = "pair"
            if (root.view) {
              root.view.pairPane = true
              root.view.call("discover", {})
            }
          }
        }
      }

      Repeater {
        model: root.ordered
        delegate: Card {
          id: card
          required property var modelData
          readonly property bool peer: modelData.role === "peer"
          readonly property bool viewing: root.viewingPeer(modelData)
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
            // Type · address · path · Online/Offline. The path is the live socket.
            RowLayout {
              width: parent.width
              spacing: 0
              Txt {
                Layout.alignment: Qt.AlignVCenter
                text: root.roleLine(modelData)
                color: Theme.dim
                elide: Text.ElideRight
              }
              Txt {
                Layout.alignment: Qt.AlignVCenter
                visible: !!modelData.ip
                text: " · " + (modelData.ip || "")
                color: Theme.dim
                elide: Text.ElideRight
              }
              Txt {
                objectName: "pathWord"
                Layout.alignment: Qt.AlignVCenter
                visible: !!modelData.online && root.pathWord(modelData.path) !== ""
                text: " · " + root.pathWord(modelData.path)
                color: Theme.dim
              }
              Txt {
                Layout.alignment: Qt.AlignVCenter
                text: " · "
                color: Theme.dim
              }
              Txt {
                Layout.alignment: Qt.AlignVCenter
                text: modelData.online ? "Online" : "Offline"
                color: modelData.online ? Theme.ok : Theme.dim
              }
              Txt {
                Layout.alignment: Qt.AlignVCenter
                visible: card.peer && card.viewing
                text: " · Viewing"
                color: Theme.ok
              }
              Item { Layout.fillWidth: true }
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

    // ── Pair pane (Invite / Join) ──
    Column {
      visible: root.networkPane === "pair"
      width: parent.width
      spacing: 18

      SectionLabel { text: "PAIR" }

      SectionLabel { text: "THIS NETWORK" }

      Txt {
        visible: !root.view || !root.view.discoveredRows || root.view.discoveredRows.length === 0
        width: parent.width
        wrapMode: Text.Wrap
        color: Theme.dim
        text: "Searching this network. Open Flux on the phone. A computer that never appears can use the invite below."
      }

      Repeater {
        model: root.view && root.view.discoveredRows ? root.view.discoveredRows : []
        delegate: Card {
          required property var modelData
          readonly property bool waiting: modelData.pairState === "requested"
          width: parent.width
          implicitHeight: foundCol.implicitHeight + 28
          Column {
            id: foundCol
            x: 16
            y: 14
            width: parent.width - 32
            spacing: 4
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
                text: Fmt.showControls(modelData.name)
                font.pixelSize: 16
                font.weight: Font.DemiBold
                elide: Text.ElideRight
              }
              OutlineButton {
                objectName: "lanPair"
                visible: !waiting
                text: "Pair"
                onClicked: root.view.call("pair.request", { device: modelData.id })
              }
              OutlineButton {
                objectName: "lanCancel"
                visible: waiting
                text: "Cancel"
                onClicked: root.view.call("pair.reject", { device: modelData.id, key: modelData.pairKey || "" })
              }
            }
            Txt {
              width: parent.width
              visible: !!modelData.ip
              text: modelData.ip
              color: Theme.dim
              font.pixelSize: 12
              elide: Text.ElideRight
            }
            Txt {
              width: parent.width
              visible: !!modelData.fingerprint
              text: "Certificate " + Fmt.hexGroups(modelData.fingerprint)
              color: Theme.dim
              font.pixelSize: 11
              elide: Text.ElideRight
            }
            Txt {
              width: parent.width
              visible: modelData.twin !== ""
              text: modelData.twin
              color: Theme.warn
              font.pixelSize: 12
              wrapMode: Text.Wrap
            }
            Txt {
              objectName: "lanKey"
              width: parent.width
              visible: waiting && Fmt.hexGroups(modelData.pairKey || "") !== ""
              text: "Confirm " + Fmt.hexGroups(modelData.pairKey || "") + " on " + Fmt.showControls(modelData.name)
              color: Theme.accent
              font.pixelSize: 12
              wrapMode: Text.Wrap
            }
          }
        }
      }

      OutlineButton {
        objectName: "searchAgain"
        text: "Search again"
        icon: "refresh"
        onClicked: if (root.view) root.view.call("discover", {})
      }

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
            text: "Share a flux1 invite when the other desk is not discovered. Prefer LAN; Tailscale stays as an option. Enable Relay below only if there is no direct path. Confirm the matching key on both sides."
            color: Theme.dim
            font.pixelSize: 12
            wrapMode: Text.Wrap
          }

          Txt {
            text: "Share invite"
            font.weight: Font.DemiBold
          }
          Txt {
            width: parent.width
            text: "Host the other side can reach (LAN IP preferred, or Tailscale name/IP). Leave empty to auto-pick LAN when available."
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
              placeholder: "e.g. 192.168.1.8 or dragon"
              onAccepted: root.generateInvite()
            }
            AccentButton {
              text: root.inviting ? "…" : "Create invite"
              icon: "key"
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
                    ? "Scan or paste on the other computer: Network → Pair → Join, then accept the matching key."
                    : "On the other computer: Network → Pair → paste invite → Join, then accept the matching key."
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
            text: "Join with invite"
            font.weight: Font.DemiBold
          }
          Txt {
            width: parent.width
            text: "Paste a flux1 invite from the other desk, then Join."
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
      // ── RELAY · OPTIONAL (collapsed when off) ──
      SectionLabel { text: "RELAY · OPTIONAL" }

      Card {
        width: parent.width
        implicitHeight: relayCol.implicitHeight + 36
        Column {
          id: relayCol
          x: 18
          y: 18
          width: parent.width - 36
          spacing: 10

          // Collapsed summary: toggle + expand affordance
          RowLayout {
            width: parent.width
            spacing: 12
            Toggle {
              id: relayToggle
              text: "Use relay host"
              checked: !!root.settings.relay
              onToggled: function (checked) {
                if (checked && !String(root.settings.relayURL || "").trim()) {
                  root.relayUserExpanded = true
                  if (root.view) root.view.toast("Save a relay host:port first, then turn relay on")
                  return
                }
                if (root.view) root.view.call("settings.set", { key: "relay", value: checked })
                if (checked) root.relayUserExpanded = true
              }
            }
            Item { Layout.fillWidth: true }
            OutlineButton {
              visible: !root.relayExpanded
              text: "Configure"
              icon: "chevron"
              onClicked: root.relayUserExpanded = true
            }
            OutlineButton {
              visible: root.relayExpanded && !root.settings.relay
              text: "Hide"
              onClicked: root.relayUserExpanded = false
            }
          }

          Column {
            visible: root.relayExpanded
            width: parent.width
            spacing: 10
            Txt {
              width: parent.width
              text: "Both sides need the same host:port. Leave off when peers can reach each other."
              color: Theme.dim
              font.pixelSize: 12
              wrapMode: Text.Wrap
            }
            RowLayout {
              width: parent.width
              spacing: 8
              Field {
                id: relayURLField
                Layout.fillWidth: true
                placeholder: "e.g. 100.64.0.1:17777"
                text: root.settings.relayURL || ""
                onAccepted: root.saveRelayURL()
              }
              OutlineButton {
                text: "Save"
                icon: "check"
                onClicked: root.saveRelayURL()
              }
            }
          }
        }
      }

    }


  }
}
