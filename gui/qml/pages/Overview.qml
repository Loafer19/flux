import QtQuick
import QtQuick.Layouts
import ".."
import "../components"

// Per-device overview. A desk peer is one column: seam, view, and the
// switches that role can honor. A phone is one column: identity, a short
// action row, the cards that need a person, then device access.
// Global switches live on This computer. One Browse opens the peer's home.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online
  readonly property bool peer: !!dev && dev.role === "peer"
  readonly property var settings: view && view.backend ? (view.backend.settings || ({})) : ({})
  readonly property string edgeSide: root.edgeSideFor(root.dev)
  readonly property var notifs: dev && dev.notifications ? dev.notifications.slice(0, 3) : []
  // Agents on this computer. A blocked agent waits for a person. A done
  // agent has finished. Working and idle agents stay off this page.
  readonly property var herdr: view && view.backend && view.backend.state ? (view.backend.state.herdr || null) : null
  readonly property var waitingAgents: {
    var list = root.herdr && root.herdr.agents ? root.herdr.agents : []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      var status = String(item && item.status || "")
      if (status === "blocked" || status === "done") out.push(item)
    }
    return out
  }

  function agentWaitText(agent) {
    var name = (agent && agent.agent) ? agent.agent : "Agent"
    var title = agent ? (agent.title || agent.project || "") : ""
    var state = agent && agent.status === "blocked" ? "needs input" : "finished"
    return title !== "" ? name + " · " + title + " · " + state : name + " · " + state
  }
  // The phone camera as a webcam on this computer. Null when it is not used.
  readonly property var webcam: view && view.backend && view.backend.state ? (view.backend.state.webcam || null) : null
  // The phone microphone and the phone screen mirror. Null when not used.
  readonly property var mic: view && view.backend && view.backend.state ? (view.backend.state.mic || null) : null
  readonly property var screen: view && view.backend && view.backend.state ? (view.backend.state.screen || null) : null
  // The remote desktop of this computer on a device. Null when not used.
  readonly property var desktop: view && view.backend && view.backend.state ? (view.backend.state.desktop || null) : null
  // Desk↔desk view of the selected peer (desktop.view). Null when idle.
  readonly property var peerDesktop: view && view.backend && view.backend.state ? (view.backend.state.peerDesktop || null) : null
  readonly property bool viewingPeer: {
    var pd = root.peerDesktop
    if (!pd || !root.dev) return false
    var from = String(pd.from || "")
    var name = String(pd.fromName || "").toLowerCase()
    return from === String(root.dev.id || "") || name === String(root.dev.name || "").toLowerCase()
  }
  // Hide battery for desktops and when there is no real charge (no "?" / "—").
  readonly property bool showBattery: {
    if (!root.dev || root.dev.type === "desktop") return false
    var b = root.dev.battery
    return !!b && b.charge !== undefined && b.charge !== null && b.charge >= 0
  }

  function startPeerView() {
    if (!root.view || !root.view.call || !root.dev) return
    if (!root.online) {
      root.view.toast((root.dev.name || "Peer") + " is offline")
      return
    }
    var key = root.dev.name || root.dev.id
    root.view.call("desktop.view", { device: key }, function () {
      if (root.view) root.view.toast("Showing " + (root.dev.name || "peer") + " desktop")
    })
  }

  function stopPeerView() {
    if (!root.view || !root.view.call) return
    root.view.call("desktop.viewStop", {}, function () {
      if (root.view) root.view.toast("Stopped peer desktop")
    })
  }

  // True when this computer's global for the device-access key is on.
  // Agent control also needs herdr. Agent terminals also need herdr control.
  // Agent globals are on This computer.
  function accessGlobalOn(key) {
    var settings = root.settings || ({})
    var globalKey = key === "clipboard" ? "autoClipboard" : key
    var on = settings[globalKey] === true
    if (key === "herdrControl" || key === "herdrTerminals")
      on = on && settings.herdr === true
    if (key === "herdrTerminals")
      on = on && settings.herdrControl === true
    return on
  }

  function accessGroupGated(rows) {
    for (var i = 0; i < rows.length; i++) {
      if (!root.accessGlobalOn(rows[i].key)) return true
    }
    return false
  }

  function edgeSideFor(d) {
    if (!d) return ""
    var side = String(root.settings.edgeSide || "")
    var who = String(root.settings.edgeDevice || "").toLowerCase()
    var name = String(d.name || "").toLowerCase()
    var id = String(d.id || "")
    if (!side || !who || (id !== root.settings.edgeDevice && name !== who)) return ""
    return side.toLowerCase()
  }

  // Wire to settings.edgeSide / edgeDevice (same as flux-cli edge SIDE DEVICE).
  function setEdgeSide(side) {
    if (!root.view || !root.view.call || !root.dev) return
    side = String(side || "").toLowerCase()
    if (!side) {
      root.view.call("settings.set", { key: "edgeSide", value: "" })
      root.view.call("settings.set", { key: "edgeDevice", value: "" })
      root.view.toast("Screen edge off")
      return
    }
    var device = root.dev.name || root.dev.id
    root.view.call("settings.set", { key: "edgeSide", value: side })
    root.view.call("settings.set", { key: "edgeDevice", value: device })
    root.view.toast(side.charAt(0).toUpperCase() + side.slice(1) + " edge → " + device)
  }

  function oppositeEdge(side) {
    if (side === "left") return "right"
    if (side === "right") return "left"
    if (side === "top") return "bottom"
    if (side === "bottom") return "top"
    return ""
  }

  // True when the other computer named this one on the opposite edge.
  function namesThisComputer(who) {
    who = String(who || "")
    if (!who || !root.view) return false
    var self = root.view.selfDevice || ({})
    if (who === String(self.id || "")) return true
    return who.toLowerCase() === String(self.name || "").toLowerCase()
  }

  readonly property bool seamAnswers: {
    if (!root.edgeSide || !root.dev || !root.dev.seamKnown) return false
    return String(root.dev.edgeSide || "").toLowerCase() === root.oppositeEdge(root.edgeSide)
        && root.namesThisComputer(root.dev.edgeDevice)
  }

  readonly property string seamNote: {
    var name = (root.dev && root.dev.name) || "The other computer"
    if (!root.edgeSide) return "Pick the edge that leaves this screen."
    var opp = root.oppositeEdge(root.edgeSide)
    if (!root.dev || !root.dev.seamKnown) return name + " has not reported an edge."
    if (root.seamAnswers) return name + " answers on the " + opp + "."
    var theirs = String(root.dev.edgeSide || "").toLowerCase()
    if (!theirs || !root.namesThisComputer(root.dev.edgeDevice))
      return name + " has not set the " + opp + " edge."
    return name + " set " + theirs + ", not the " + opp + " edge."
  }

  // View stays off when that computer has said remote desktop is off.
  // An older peer that has not reported a seam can still be asked.
  readonly property bool viewAllowed: root.online && !(root.dev && root.dev.seamKnown && !root.dev.remoteDesktop)

  readonly property string viewNote: {
    if (!root.dev) return "View desktop"
    var name = root.dev.name || "The other computer"
    if (!root.online) return name + " is offline"
    if (root.dev.seamKnown && !root.dev.remoteDesktop) return name + " has remote desktop off"
    if (root.viewingPeer) return "View desktop · live"
    return "View desktop"
  }

  // "Ring PC" would name a computer wrong. Phones and tablets keep their noun.
  readonly property string ringLabel: {
    var noun = Fmt.noun(root.dev ? root.dev.type : "")
    return "Ring " + (noun === "PC" ? "computer" : noun)
  }
  // The camera card takes a whole row while its settings are open.
  property bool cameraWide: false
  // Page load does not fade. Later opens and appearing cards do.
  property bool motionReady: false
  Component.onCompleted: motionReady = true
  readonly property bool accessNeedsGlobal: root.accessGroupGated([
    { key: "clipboard" }, { key: "notifications" }, { key: "shareHome" },
    { key: "remoteInput" }, { key: "remoteDesktop" },
    { key: "herdr" }, { key: "herdrControl" }, { key: "herdrTerminals" }
  ])

  // Now cards, in order. A hidden card is not a cell.
  function nowShow(key) {
    if (root.peer) return false
    if (key === "notif") return true
    if (key === "camera") return !!root.webcam || root.canAsk
    if (key === "mic") return !!root.mic || root.canAsk
    if (key === "agent") return !!root.waitingAgents && root.waitingAgents.length > 0
    if (key === "browse") return !!root.browse && root.browse.length > 0
    if (key === "screen") return !!root.screen
    return false
  }

  // Packs visible Now cards into rows of two. A wide card, or the last
  // card of an odd count, spans so the row has no empty cell.
  readonly property var nowLayout: {
    var slots = [
      { key: "notif", show: root.nowShow("notif"), wide: false },
      { key: "camera", show: root.nowShow("camera"), wide: root.cameraWide },
      { key: "mic", show: root.nowShow("mic"), wide: false },
      { key: "agent", show: root.nowShow("agent"), wide: false },
      { key: "browse", show: root.nowShow("browse"), wide: false },
      { key: "screen", show: root.nowShow("screen"), wide: false }
    ]
    var rows = []
    var current = []
    for (var i = 0; i < slots.length; i++) {
      var slot = slots[i]
      if (!slot.show) continue
      if (slot.wide) {
        if (current.length > 0) {
          rows.push(current)
          current = []
        }
        rows.push([slot])
        continue
      }
      current.push(slot)
      if (current.length === 2) {
        rows.push(current)
        current = []
      }
    }
    if (current.length > 0) rows.push(current)
    var map = ({})
    for (var r = 0; r < rows.length; r++) {
      var row = rows[r]
      var span = row.length === 1 ? 2 : 1
      for (var c = 0; c < row.length; c++)
        map[row[c].key] = { span: span }
    }
    return map
  }

  function nowWidth(key) {
    var spot = root.nowLayout[key]
    var full = !spot || spot.span !== 1
    if (full || nowFlow.width <= 0) return nowFlow.width
    // Floor keeps a pair on one row: two rounded halves can exceed the row.
    return Math.floor((nowFlow.width - 12) / 2)
  }

  // The only Browse for this peer. Opens their shared home in Files.
  // Home share is the global toggle on This computer, with no button here.
  function browsePeerHome() {
    if (!root.view || !root.dev) return
    if (!root.online) {
      root.view.toast((root.dev.name || "Peer") + " is offline")
      return
    }
    var name = root.dev.name || "peer"
    var id = root.dev.id
    root.view.call("browse.open", { device: id }, function () {
      if (root.view) {
        root.view.toast("Opening " + name + " home…")
        root.view.go("files")
      }
    }, function (err) {
      if (root.view) root.view.toast((err && (err.message || err.code)) || ("Cannot browse " + name))
    })
  }
  // The browse sessions of the devices on this computer. An earlier
  // fluxd sends no list.
  readonly property var browse: view && view.backend && view.backend.state ? (view.backend.state.browse || []) : []
  // The device can start its camera and its microphone when this computer
  // asks. The device asks its user first. An earlier fluxd or app does not
  // list streamrequest.
  readonly property bool canAsk: online && !!dev.paired && Array.isArray(dev.plugins) && dev.plugins.indexOf("streamrequest") >= 0
  // The ID of the device that got the last request of this window for the
  // webcam and for the mic, or "". The card then tells the user to confirm
  // on the device. The device removes its notification after 60 seconds,
  // and the card then removes its note too. The next change of the stream
  // state of the kind also removes the note, for example a stream that
  // starts or a start that fails at once.
  property string webcamAsked: ""
  property string micAsked: ""
  // The stream state of the kind at the time of the request, as JSON. fluxd
  // sends at most 1 state every 100 ms, so a start that fails at once can
  // come only as an error. A comparison with this value finds that change.
  property string webcamSeen: ""
  property string micSeen: ""
  // The ID of the device that got a request of this window for the kind in
  // the last 3 seconds, or "". fluxd refuses a second request in that time,
  // so Start is inactive for that device. An error of the request makes
  // Start active again at once.
  property string webcamSent: ""
  property string micSent: ""
  // streamRequestGap in internal/core/streamrequest.go, in milliseconds.
  readonly property int requestGap: 3000

  onWebcamChanged: if (webcamAsked !== "" && JSON.stringify(webcam) !== webcamSeen) webcamAsked = ""
  onMicChanged: if (micAsked !== "" && JSON.stringify(mic) !== micSeen) micAsked = ""

  Timer { id: webcamWait; interval: 60000; onTriggered: root.webcamAsked = "" }
  Timer { id: micWait; interval: 60000; onTriggered: root.micAsked = "" }
  Timer { id: webcamGap; interval: root.requestGap; onTriggered: root.webcamSent = "" }
  Timer { id: micGap; interval: root.requestGap; onTriggered: root.micSent = "" }

  // Asks the device to start its camera or its mic. kind is "webcam" or
  // "mic". The toast and the card tell the user to confirm on the device.
  // A second request of the kind to the device in requestGap does nothing.
  function askStream(kind) {
    if (!view || !dev) return
    // The view outlives this page, so the replies use it.
    var v = view
    var mic = kind === "mic"
    var id = dev.id
    var name = dev.name || "the device"
    var gap = mic ? micGap : webcamGap
    if ((mic ? micSent : webcamSent) === id) return
    if (mic) micSent = id
    else webcamSent = id
    gap.restart()
    v.call(kind + ".start", { device: id }, function () {
      // The gap of fluxd starts before this reply. A restart here keeps
      // Start inactive until that gap ends.
      gap.restart()
      if (mic) {
        root.micAsked = id
        root.micSeen = JSON.stringify(root.mic)
        micWait.restart()
      } else {
        root.webcamAsked = id
        root.webcamSeen = JSON.stringify(root.webcam)
        webcamWait.restart()
      }
      v.toast("Asked " + name + " to start " + (mic ? "the mic" : "the webcam") + ". Confirm on " + name + ".")
    }, function (err) {
      if (mic && root.micSent === id) root.micSent = ""
      if (!mic && root.webcamSent === id) root.webcamSent = ""
      v.toast(err.message || err.code || "Error")
    })
  }

  // True when Start can send a request to the device. sent is webcamSent
  // or micSent.
  function canSend(sent) {
    return !dev || sent !== dev.id
  }

  // The line under an idle card: the device to confirm on, or "".
  function confirmNote(asked) {
    return asked !== "" && !!dev && asked === dev.id ? "Confirm on " + (dev.name || "the device") + "." : ""
  }

  // The title of an idle card: the request that waits, or that no stream
  // of the kind runs. what is "the webcam" or "the mic".
  function idleTitle(asked, what) {
    if (confirmNote(asked) !== "") return "Asked " + (dev.name || "the device") + " to start " + what
    return what.charAt(0).toUpperCase() + what.slice(1) + " is off"
  }

  // Certificate fingerprint. Closed until the user selects Show.
  // The pair page shows the same value without this step.
  component CertLine: Column {
    id: line
    property string value: ""
    property bool open: false
    width: parent ? parent.width : implicitWidth
    spacing: 8
    visible: value !== ""

    function toggle() { line.open = !line.open }

    Row {
      spacing: 8
      Txt {
        text: "Certificate"
        color: Theme.dim
        font.pixelSize: 11
      }
      Txt {
        text: line.open ? "Hide" : "Show"
        color: Theme.accent
        font.pixelSize: 11
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: line.toggle()
        }
      }
    }
    // The value stays out of the layout until Show. Opacity fades in.
    Txt {
      id: certValue
      objectName: "certificateValue"
      visible: line.open
      opacity: line.open ? 1 : 0
      width: line.width
      text: Fmt.hexGroups(line.value)
      color: Theme.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
      Behavior on opacity {
        enabled: root.motionReady
        NumberAnimation { duration: 80; easing.type: Easing.OutQuad }
      }
    }
  }

  // A short action. Icon and label, fixed height, not stretched.
  component ActionTile: Card {
    id: tile
    property string icon: ""
    property string label: ""
    property bool active: true
    signal clicked()

    implicitHeight: 72
    height: 72
    opacity: active ? 1 : 0.4
    border.color: hover.containsMouse && active ? Theme.accent : Theme.bg3

    Row {
      anchors.fill: parent
      anchors.margins: 16
      spacing: 12
      Icon {
        anchors.verticalCenter: parent.verticalCenter
        name: tile.icon
        size: 16
        color: Theme.accent
      }
      Txt {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width - 32)
        text: tile.label
        font.weight: Font.DemiBold
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: tile.active ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (tile.active) tile.clicked()
    }
  }

  // One device-access switch. A global that is off keeps it off and inactive.
  component AccessSwitch: Toggle {
    id: sw
    property string key: ""
    width: parent ? parent.width : implicitWidth
    readonly property var rules: {
      if (!root.dev || !root.settings || !root.settings.deviceRules) return ({})
      return root.settings.deviceRules[root.dev.id] || ({})
    }
    readonly property bool globalOn: root.accessGlobalOn(sw.key)
    active: !!root.dev && globalOn
    checked: globalOn && rules[sw.key] !== false
    onToggled: function (value) {
      root.view.call("device.settings.set", { device: root.dev.id, key: sw.key, value: value })
    }
  }

  implicitHeight: root.peer ? peerCol.implicitHeight : phoneCol.implicitHeight

  // A desk is one column. The phone column below stays hidden.
  Column {
    id: peerCol
    visible: root.peer
    width: parent.width
    spacing: 12

    Card {
      width: parent.width
      implicitHeight: peerHead.implicitHeight + 32
      Column {
        id: peerHead
        x: 16
        y: 16
        width: parent.width - 32
        spacing: 4
        Txt {
          width: parent.width
          text: root.dev ? root.dev.name : ""
          font.pixelSize: 22
          font.weight: Font.Bold
          elide: Text.ElideRight
        }
        // Type and address stay dim. Only the link word takes the status color.
        Row {
          width: parent.width
          spacing: 0
          clip: true
          Txt {
            id: peerFacts
            width: Math.min(implicitWidth, Math.max(0, parent.width - peerLink.implicitWidth))
            text: {
              var bits = []
              if (root.dev) bits.push(Fmt.typeName(root.dev.type))
              if (root.dev && root.dev.ip) bits.push(root.dev.ip)
              return bits.join(" · ")
            }
            color: Theme.dim
            elide: Text.ElideRight
          }
          Txt {
            id: peerLink
            text: (peerFacts.text !== "" ? " · " : "") + (root.online ? "connected" : "offline")
            color: root.online ? Theme.ok : Theme.dim
          }
        }
        CertLine {
          objectName: "peerCertificate"
          value: root.dev && root.dev.fingerprint ? root.dev.fingerprint : ""
        }
      }
    }

    Row {
      width: parent.width
      spacing: 12
      ActionTile {
        width: (parent.width - 12) / 2
        icon: "upload"
        label: "Files"
        onClicked: root.view.go("files")
      }
      ActionTile {
        objectName: "browseHomeTile"
        width: (parent.width - 12) / 2
        icon: "browse"
        label: "Browse home"
        active: root.online
        onClicked: root.browsePeerHome()
      }
    }

    Card {
      objectName: "screenEdgeRow"
      width: parent.width
      implicitHeight: edgeCol.implicitHeight + 32
      Column {
        id: edgeCol
        x: 16
        y: 16
        width: parent.width - 32
        spacing: 8
        Txt {
          text: "Screen edge"
          font.weight: Font.DemiBold
        }
        Flow {
          width: parent.width
          spacing: 8
          Repeater {
            model: ["", "left", "right", "top", "bottom"]
            delegate: Chip {
              required property var modelData
              text: modelData === "" ? "Off" : (modelData.charAt(0).toUpperCase() + modelData.slice(1))
              selected: root.edgeSide === modelData
              onClicked: root.setEdgeSide(modelData)
            }
          }
        }
        Txt {
          objectName: "seamNote"
          width: parent.width
          text: root.seamNote
          color: Theme.dim
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }
      }
    }

    Card {
      objectName: "viewDesktopRow"
      width: parent.width
      implicitHeight: viewDeskRow.implicitHeight + 32
      RowLayout {
        id: viewDeskRow
        x: 16
        y: 16
        width: parent.width - 32
        spacing: 12
        Icon {
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: 14
          Layout.preferredHeight: 14
          name: "screen-share"
          size: 14
          color: Theme.dim
        }
        Txt {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          text: root.viewNote
          font.weight: Font.DemiBold
          wrapMode: Text.Wrap
        }
        OutlineButton {
          visible: !root.viewingPeer
          icon: "screen-share"
          text: "View"
          active: root.viewAllowed
          onClicked: root.startPeerView()
        }
        OutlineButton {
          visible: root.viewingPeer
          icon: "stop"
          text: "Stop"
          onClicked: root.stopPeerView()
        }
      }
    }

    Card {
      width: parent.width
      implicitHeight: peerAccess.implicitHeight + 32
      Column {
        id: peerAccess
        x: 16
        y: 16
        width: parent.width - 32
        spacing: 8
        Txt { text: "Device access"; font.weight: Font.DemiBold }
        AccessSwitch { key: "clipboard"; text: "Clipboard sync" }
        AccessSwitch { key: "shareHome"; text: "Shared folders" }
        AccessSwitch { key: "remoteInput"; text: "Remote input" }
        AccessSwitch { key: "remoteDesktop"; text: "Remote desktop" }
        Txt {
          visible: root.accessGroupGated([
            { key: "clipboard" }, { key: "shareHome" },
            { key: "remoteInput" }, { key: "remoteDesktop" }
          ])
          width: parent.width
          text: "Turn on under This computer"
          color: Theme.dim
          font.pixelSize: 11
          wrapMode: Text.Wrap
        }
      }
    }
  }

  Column {
    id: phoneCol
    visible: !root.peer
    width: parent.width
    spacing: 12

    // Identity. Battery sits in the card, not in its own column of the page.
    Card {
      width: parent.width
      implicitHeight: idBody.implicitHeight + 32
      height: implicitHeight

      Row {
        id: idBody
        x: 16
        y: 16
        width: parent.width - 32
        spacing: 16

        Column {
          id: batteryCol
          visible: root.showBattery
          width: 96
          spacing: 8
          Txt {
            text: Fmt.battery(root.dev ? root.dev.battery : null)
            font.pixelSize: 30
            font.weight: Font.Bold
            lineHeightMode: Text.FixedHeight
            lineHeight: 30
          }
          Bar {
            width: parent.width
            height: 8
            fill: {
              var b = root.dev && root.dev.battery
              return b && b.charge <= 15 && !b.charging ? Theme.err : Theme.ok
            }
            value: root.dev && root.dev.battery ? (root.dev.battery.charge || 0) / 100 : 0
          }
          Row {
            spacing: 8
            Icon {
              anchors.verticalCenter: parent.verticalCenter
              name: Fmt.batteryIcon(root.dev ? root.dev.battery : null)
              size: 13
              color: Theme.dim
            }
            Txt { anchors.verticalCenter: parent.verticalCenter; text: "battery"; color: Theme.dim; font.pixelSize: 11 }
          }
        }

        Column {
          id: facts
          // A hidden battery column is not in the row, so the facts use the full width.
          width: idBody.width - (batteryCol.visible ? batteryCol.width + idBody.spacing : 0)
          spacing: 4
          Txt {
            width: parent.width
            text: root.dev ? root.dev.name : ""
            font.pixelSize: 22
            font.weight: Font.Bold
            elide: Text.ElideRight
          }
          Txt {
            width: parent.width
            text: root.dev ? Fmt.typeName(root.dev.type) + (root.dev.pairedAt ? " · paired " + root.dev.pairedAt : "") : ""
            color: Theme.dim
            elide: Text.ElideRight
          }
          // The Flux app of the device and its version. An earlier app sends
          // no version.
          Txt {
            width: parent.width
            visible: text !== ""
            text: root.dev && root.dev.appVersion ? "Flux " + root.dev.appVersion + (root.dev.appUpdate ? " · " + root.dev.appUpdate + " is available" : "") : ""
            color: root.dev && root.dev.appUpdate ? Theme.warn : Theme.dim
            elide: Text.ElideRight
          }
          Row {
            width: parent.width
            spacing: 0
            clip: true
            Txt {
              text: "● " + (root.online ? "connected" : "offline")
              color: root.online ? Theme.ok : Theme.dim
              font.pixelSize: 13
            }
            Txt {
              readonly property var b: root.dev ? root.dev.battery : null
              visible: root.online && root.showBattery && !!b
              text: " · " + (b && b.charging ? "charging" : "discharging")
              color: Theme.dim
              font.pixelSize: 13
              elide: Text.ElideRight
            }
          }
          // The certificate fingerprint stays behind Show. It is not the pair key.
          // Network → Pair still shows the certificate on the row.
          CertLine {
            objectName: "fingerprint"
            value: root.dev && root.dev.fingerprint ? root.dev.fingerprint : ""
          }
        }
      }
    }

    // Ring and Send file are not the whole page. They stay short.
    // Flux rings only phones. A computer does not list findmyphone.
    Row {
      id: phoneActions
      width: parent.width
      spacing: 12
      ActionTile {
        id: ringAction
        visible: root.view ? root.view.has("findmyphone") : true
        width: ringAction.visible ? (phoneActions.width - phoneActions.spacing) / 2 : phoneActions.width
        icon: "bell-ring"
        label: root.ringLabel
        active: root.online
        onClicked: root.view.ring()
      }
      ActionTile {
        width: ringAction.visible ? (phoneActions.width - phoneActions.spacing) / 2 : phoneActions.width
        icon: "upload"
        label: "Send file"
        onClicked: root.view.go("files")
      }
    }

    // Notifications, streams, and waiting agents. Switches sit under this group.
    Flow {
        id: nowFlow
        width: parent.width
        spacing: 12

    Card {
      objectName: "notifCard"
      visible: root.nowShow("notif")
      width: root.nowWidth("notif")
      implicitHeight: notifCol.implicitHeight + 32
      height: implicitHeight

      Column {
        id: notifCol
        x: 16
        y: 16
        width: parent.width - 32
        spacing: 8
        Row {
          spacing: 8
          Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: "bell"
            size: 14
            color: Theme.dim
          }
          SectionLabel { anchors.verticalCenter: parent.verticalCenter; text: "LATEST NOTIFICATIONS" }
        }
        Txt {
          visible: root.notifs.length === 0
          text: "No notifications"
          color: Theme.dim
        }
        Repeater {
          model: root.notifs
          delegate: Item {
            required property var modelData
            width: notifCol.width
            height: nCol.implicitHeight
            Icon {
              y: 1
              name: Fmt.appIcon(modelData.app)
              size: 15
              color: Theme[Fmt.appToken(modelData.app)]
            }
            Column {
              id: nCol
              x: 26
              width: parent.width - 26
              Txt {
                width: parent.width
                text: (modelData.app || "") + " · " + (modelData.title || "")
                font.weight: Font.DemiBold
                elide: Text.ElideRight
              }
              Txt {
                width: parent.width
                text: (modelData.text || "").replace(/\n/g, " ")
                color: Theme.dim
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }

    // Agents that wait for a person. A working agent stays off this card.
    Card {
      id: agentCard
      objectName: "agentCard"
      visible: root.nowShow("agent")
      width: root.nowWidth("agent")
      implicitHeight: agentCol.implicitHeight + 32
      height: implicitHeight

      Column {
        id: agentCol
        x: 16
        y: 16
        width: parent.width - 32
        spacing: 8
        Row {
          spacing: 8
          Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: "console"
            size: 14
            color: Theme.dim
          }
          SectionLabel { anchors.verticalCenter: parent.verticalCenter; text: "AGENTS" }
        }
        Repeater {
          model: root.waitingAgents.slice(0, 3)
          delegate: Txt {
            required property var modelData
            width: agentCol.width
            text: root.agentWaitText(modelData)
            font.weight: Font.DemiBold
            elide: Text.ElideRight
          }
        }
        Txt {
          visible: root.waitingAgents.length > 3
          text: (root.waitingAgents.length - 3) + " more"
          color: Theme.dim
        }
      }
    }

    // Phone camera only. A desk peer never shows this card.
    CameraCard {
      id: cameraCard
      objectName: "cameraCard"
      visible: root.nowShow("camera")
      width: root.nowWidth("camera")
      height: implicitHeight
      view: root.view
      webcam: root.webcam
      canStart: root.canAsk
      note: root.confirmNote(root.webcamAsked)
      idleTitle: root.idleTitle(root.webcamAsked, "the webcam")
      startActive: root.canSend(root.webcamSent)
      onStart: root.askStream("webcam")
      onSettingsOpenChanged: root.cameraWide = settingsOpen
      Component.onCompleted: root.cameraWide = settingsOpen
    }

    // Phone microphone
    StreamCard {
      objectName: "micCard"
      visible: root.nowShow("mic")
      width: root.nowWidth("mic")
      height: implicitHeight
      icon: "mic"
      heading: "PHONE MICROPHONE"
      stream: root.mic || ({})
      title: root.mic ? (root.mic.fromName || "The phone") + " is live as " + (root.mic.source || "Flux Microphone") : ""
      detail: root.mic ? Math.round((root.mic.rate || 48000) / 1000) + " kHz · " + (root.mic.channels === 2 ? "stereo" : "mono") : ""
      onStop: root.view.call("mic.stop", {})
      idle: !root.mic
      canStart: root.canAsk
      note: root.confirmNote(root.micAsked)
      idleTitle: root.idleTitle(root.micAsked, "the mic")
      startActive: root.canSend(root.micSent)
      onStart: root.askStream("mic")
    }

    // The devices that browse the files of this computer
    StreamCard {
      objectName: "browseCard"
      visible: root.nowShow("browse")
      width: root.nowWidth("browse")
      height: implicitHeight
      icon: "folder"
      heading: "BROWSE COMPUTER"
      stream: ({ active: true })
      title: root.browse.map(function (b) { return b.name || "A device" }).join(", ") + (root.browse.length > 1 ? " browse" : " browses") + " this computer"
      detail: root.browse.length > 0 ? "Since " + Qt.formatTime(new Date(root.browse[0].since * 1000), "hh:mm") + " · read-only" : ""
      onStop: root.view.call("browse.stop", {})
    }

    // Phone screen mirror
    StreamCard {
      objectName: "screenCard"
      visible: root.nowShow("screen")
      width: root.nowWidth("screen")
      height: implicitHeight
      icon: "screen-share"
      heading: "PHONE SCREEN"
      stream: root.screen || ({})
      title: root.screen ? (root.screen.fromName || "The phone") + " shows its screen in " + (root.screen.player || "a window") : ""
      detail: root.screen && root.screen.width ? root.screen.width + "×" + root.screen.height + " · close the window to stop" : ""
      onStop: root.view.call("screen.stop", {})
    }
    }

    // One card. The global line is once, not once per group.
    Card {
      objectName: "phoneAccess"
      width: parent.width
      implicitHeight: access.implicitHeight + 32
      height: implicitHeight
      Column {
        id: access
        x: 16
        y: 16
        width: parent.width - 32
        spacing: 8
        Txt { text: "Device access"; font.weight: Font.DemiBold }
        Column {
          width: parent.width
          spacing: 8
          Txt {
            width: parent.width
            text: "Sharing"
            color: Theme.dim
            font.pixelSize: 11
            font.weight: Font.DemiBold
          }
          AccessSwitch { key: "clipboard"; text: "Clipboard sync" }
          AccessSwitch { key: "notifications"; text: "Notifications" }
          AccessSwitch { key: "shareHome"; text: "Shared folders" }
        }
        Column {
          width: parent.width
          spacing: 8
          Txt {
            width: parent.width
            text: "Remote"
            color: Theme.dim
            font.pixelSize: 11
            font.weight: Font.DemiBold
          }
          AccessSwitch { key: "remoteInput"; text: "Remote input" }
          AccessSwitch { key: "remoteDesktop"; text: "Remote desktop" }
        }
        Column {
          width: parent.width
          spacing: 8
          Txt {
            width: parent.width
            text: "Agents"
            color: Theme.dim
            font.pixelSize: 11
            font.weight: Font.DemiBold
          }
          AccessSwitch { key: "herdr"; text: "Agent output" }
          AccessSwitch { key: "herdrControl"; text: "Agent control" }
          AccessSwitch { key: "herdrTerminals"; text: "Agent terminals" }
        }
        Txt {
          visible: root.accessNeedsGlobal
          width: parent.width
          text: "Turn on under This computer"
          color: Theme.dim
          font.pixelSize: 11
          wrapMode: Text.Wrap
        }
      }
    }
  }
}
