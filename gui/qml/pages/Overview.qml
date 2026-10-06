import QtQuick
import QtQuick.Layouts
import ".."
import "../components"

// Per-device overview: facts, quick actions, this peer's edge and access,
// and phone streams. Global sharing and remote toggles live on
// Network → This computer. One Browse (the tile) opens the peer's home.
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
  // Agent globals are under Network → This computer → Agents.
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

  // The only Browse for this peer. Opens their shared home in Files.
  // Home share is the global toggle on Network → This computer, with no button here.
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
  // The Browse PC sessions of the devices on this computer. An earlier
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

  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    width: parent.width
    columns: Math.max(1, Math.floor((width + 18) / (320 + 18)))
    columnSpacing: 18
    rowSpacing: 18
    uniformCellWidths: true

    // Device facts (and battery when the device reports a real charge)
    Card {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      implicitHeight: Math.max(root.showBattery ? batteryCol.implicitHeight : 0, facts.implicitHeight) + 46

      Column {
        id: batteryCol
        visible: root.showBattery
        x: 23
        anchors.verticalCenter: parent.verticalCenter
        width: 110
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
          fill: Theme.ok
          value: root.dev && root.dev.battery ? (root.dev.battery.charge || 0) / 100 : 0
        }
        Row {
          spacing: 4
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
        // When battery is hidden, start at the left padding (invisible
        // batteryCol still has geometry, so do not anchor to it).
        x: root.showBattery ? batteryCol.x + batteryCol.width + 22 : 23
        width: parent.width - x - 23
        anchors.verticalCenter: parent.verticalCenter
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
        Txt {
          width: parent.width
          readonly property var b: root.dev ? root.dev.battery : null
          text: "● " + (root.online ? "connected" : "offline") + (root.online && root.showBattery && b ? " · " + (b.charging ? "charging" : "discharging") : "")
          color: root.online ? Theme.ok : Theme.dim
          elide: Text.ElideRight
        }
        // The fingerprint of the certificate of the device, as the pair mode
        // and flux-cli unpair show it. The groups go to the next line as 1
        // part, so that no group is cut.
        Flow {
          objectName: "fingerprint"
          width: parent.width
          visible: fingerprintText.text !== ""
          topPadding: 2
          spacing: 6
          Txt { text: "certificate"; color: Theme.dim; font.pixelSize: 11 }
          Txt {
            id: fingerprintText
            text: Fmt.hexGroups(root.dev ? root.dev.fingerprint : "")
            color: Theme.dim
            font.pixelSize: 11
          }
        }
      }
    }

    // Quick actions — phone: Ring + Send file; desk peer: Send file + Browse home
    GridLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      columns: 2
      columnSpacing: 10
      rowSpacing: 10
      uniformCellWidths: true

      // The tiles fill the height of the row, so they line up with the
      // battery card. Flux rings only phones. A computer does not list
      // findmyphone.
      Tile {
        id: ringTile
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: root.view ? root.view.has("findmyphone") : true
        icon: "bell-ring"
        label: "Ring " + Fmt.noun(root.dev ? root.dev.type : "")
        active: root.online
        onClicked: root.view.ring()
      }
      Tile {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.columnSpan: (ringTile.visible || root.peer) ? 1 : 2
        icon: "upload"
        label: "Send file"
        onClicked: root.view.go("files")
      }
      Tile {
        objectName: "browseHomeTile"
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.columnSpan: ringTile.visible ? 2 : 1
        visible: root.peer
        icon: "browse"
        label: "Browse home"
        active: root.online
        onClicked: root.browsePeerHome()
      }
    }

    // Desk peer: one row to show or stop the peer screen. Not a tall card.
    Card {
      objectName: "viewDesktopRow"
      visible: root.peer
      Layout.fillWidth: true
      Layout.preferredWidth: 320
      Layout.alignment: Qt.AlignTop
      implicitHeight: viewDeskRow.implicitHeight + 24

      RowLayout {
        id: viewDeskRow
        x: 16
        y: 12
        width: parent.width - 32
        spacing: 10
        Icon {
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: 14
          Layout.preferredHeight: 14
          name: "screen-share"
          size: 14
          color: root.viewingPeer ? Theme.err : Theme.dim
        }
        Txt {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          text: root.viewingPeer ? "View desktop · live" : "View desktop"
          font.weight: Font.DemiBold
          elide: Text.ElideRight
        }
        OutlineButton {
          visible: !root.viewingPeer
          icon: "screen-share"
          text: "View"
          active: root.online
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

    // Screen edge stays on this peer. Off / Left / Right / Top / Bottom.
    Card {
      objectName: "screenEdgeRow"
      visible: root.peer
      Layout.fillWidth: true
      Layout.preferredWidth: 320
      Layout.alignment: Qt.AlignTop
      implicitHeight: edgeCol.implicitHeight + 28

      Column {
        id: edgeCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 14
        spacing: 8
        Txt {
          text: "Screen edge"
          font.weight: Font.DemiBold
        }
        Flow {
          width: parent.width
          spacing: 6
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
      }
    }

    // Latest notifications — phones only. Desk peers have no useful feed here.
    Card {
      visible: !root.peer
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      implicitHeight: notifCol.implicitHeight + 38

      Column {
        id: notifCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 19
        spacing: 12
        SectionLabel { text: "LATEST NOTIFICATIONS" }
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

    Card {
      Layout.fillWidth: true
      Layout.preferredWidth: 320
      implicitHeight: access.implicitHeight + 28
      Column {
        id: access
        x: 14; y: 12
        width: parent.width - 28
        spacing: 8
        Txt { text: "Device access"; font.weight: Font.DemiBold }
        Repeater {
          model: [
            {
              title: "Sharing",
              rows: [
                { key: "clipboard", label: "Clipboard sync" },
                { key: "notifications", label: "Notifications" },
                { key: "shareHome", label: "Shared folders" }
              ]
            },
            {
              title: "Remote",
              rows: [
                { key: "remoteInput", label: "Remote input" },
                { key: "remoteDesktop", label: "Remote desktop" }
              ]
            },
            {
              title: "Agents",
              rows: [
                { key: "herdr", label: "Agent output" },
                { key: "herdrControl", label: "Agent control" },
                { key: "herdrTerminals", label: "Agent terminals" }
              ]
            }
          ]
          delegate: Column {
            id: groupCol
            required property var modelData
            readonly property var group: modelData
            readonly property bool gated: root.accessGroupGated(group.rows)
            width: access.width
            spacing: 1
            Txt {
              width: parent.width
              text: groupCol.group.title
              color: Theme.dim
              font.pixelSize: 11
              font.weight: Font.DemiBold
            }
            Repeater {
              model: groupCol.group.rows
              delegate: Toggle {
                required property var modelData
                readonly property var row: modelData
                readonly property var settings: root.settings || ({})
                readonly property var rules: root.dev && settings.deviceRules ? (settings.deviceRules[root.dev.id] || {}) : ({})
                readonly property bool globalOn: root.accessGlobalOn(row.key)
                width: access.width
                text: row.label
                active: !!root.dev
                checked: rules[row.key] !== false
                opacity: globalOn ? 1 : 0.4
                onToggled: function (value) {
                  root.view.call("device.settings.set", { device: root.dev.id, key: row.key, value: value })
                }
              }
            }
            Txt {
              visible: groupCol.gated
              width: parent.width
              text: "Turn on under Network → This computer"
              color: Theme.dim
              font.pixelSize: 11
              elide: Text.ElideRight
            }
          }
        }
      }
    }

    // Phone camera only. A desk peer never shows this card.
    CameraCard {
      objectName: "cameraCard"
      visible: !root.peer && (!!root.webcam || root.canAsk)
      view: root.view
      webcam: root.webcam
      canStart: root.canAsk
      note: root.confirmNote(root.webcamAsked)
      idleTitle: root.idleTitle(root.webcamAsked, "the webcam")
      startActive: root.canSend(root.webcamSent)
      onStart: root.askStream("webcam")
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      Layout.columnSpan: settingsOpen ? grid.columns : 1
    }

    // Phone microphone
    StreamCard {
      objectName: "micCard"
      visible: !root.peer && (!!root.mic || root.canAsk)
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
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
      visible: root.browse.length > 0
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      icon: "folder"
      heading: "BROWSE PC"
      stream: ({ active: true })
      title: root.browse.map(function (b) { return b.name || "A device" }).join(", ") + (root.browse.length > 1 ? " browse" : " browses") + " this computer"
      detail: root.browse.length > 0 ? "Since " + Qt.formatTime(new Date(root.browse[0].since * 1000), "hh:mm") + " · read-only" : ""
      onStop: root.view.call("browse.stop", {})
    }

    // Phone screen mirror
    StreamCard {
      objectName: "screenCard"
      visible: !root.peer && !!root.screen
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      icon: "screen-share"
      heading: "PHONE SCREEN"
      stream: root.screen || ({})
      title: root.screen ? (root.screen.fromName || "The phone") + " shows its screen in " + (root.screen.player || "a window") : ""
      detail: root.screen && root.screen.width ? root.screen.width + "×" + root.screen.height + " · close the window to stop" : ""
      onStop: root.view.call("screen.stop", {})
    }
  }
}
