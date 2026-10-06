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
  // The camera card takes a whole row while its settings are open.
  property bool cameraWide: false
  // Page load does not fade the certificate. A later Show does.
  property bool motionReady: false
  Component.onCompleted: motionReady = true

  // Seam, View, the card grid, and the pause before a second Start.
  OverviewRules {
    id: rules
    view: root.view
    cameraWide: root.cameraWide
  }

  property alias dev: rules.dev
  property alias online: rules.online
  property alias peer: rules.peer
  property alias settings: rules.settings
  property alias edgeSide: rules.edgeSide
  property alias notifs: rules.notifs
  property alias waitingAgents: rules.waitingAgents
  property alias webcam: rules.webcam
  property alias mic: rules.mic
  property alias screen: rules.screen
  property alias viewingPeer: rules.viewingPeer
  property alias showBattery: rules.showBattery
  property alias seamNote: rules.seamNote
  property alias viewAllowed: rules.viewAllowed
  property alias viewNote: rules.viewNote
  property alias ringLabel: rules.ringLabel
  property alias accessNeedsGlobal: rules.accessNeedsGlobal
  property alias browse: rules.browse
  property alias canAsk: rules.canAsk
  property alias webcamAsked: rules.webcamAsked
  property alias micAsked: rules.micAsked
  property alias webcamSent: rules.webcamSent
  property alias micSent: rules.micSent

  function agentWaitText(agent) { return rules.agentWaitText(agent) }
  function startPeerView() { rules.startPeerView() }
  function stopPeerView() { rules.stopPeerView() }
  function accessGlobalOn(key) { return rules.accessGlobalOn(key) }
  function accessGroupGated(rows) { return rules.accessGroupGated(rows) }
  function setEdgeSide(side) { rules.setEdgeSide(side) }
  function nowShow(key) { return rules.nowShow(key) }
  function browsePeerHome() { rules.browsePeerHome() }
  function askStream(kind) { rules.askStream(kind) }
  function canSend(sent) { return rules.canSend(sent) }
  function confirmNote(asked) { return rules.confirmNote(asked) }
  function idleTitle(asked, what) { return rules.idleTitle(asked, what) }

  // Width of one Now card. A span of 2, or an unknown key, takes the row.
  function nowWidth(key) {
    var spot = rules.nowLayout[key]
    var full = !spot || spot.span !== 1
    if (full || nowFlow.width <= 0) return nowFlow.width
    return Math.floor((nowFlow.width - 12) / 2)
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
