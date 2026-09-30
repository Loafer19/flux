import QtQuick
import QtQuick.Layouts
import ".."
import "../components"

// Battery and device facts, quick actions, the latest notifications, the
// remote access settings of this computer, and the streams from the device.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online
  readonly property bool peer: !!dev && dev.role === "peer"
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
  // The Browse PC sessions of the devices on this computer. An earlier
  // fluxd sends no list.
  readonly property var browse: view && view.backend && view.backend.state ? (view.backend.state.browse || []) : []

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

    // Quick actions — phone: Ring + Send file; desk peer: Send file then View desktop
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
        Layout.columnSpan: ringTile.visible ? 1 : 2
        icon: "upload"
        label: "Send file"
        onClicked: root.view.go("files")
      }
    }

    // Desk peer: open the peer screen (same desktop.view as Network).
    Card {
      visible: root.peer
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      implicitHeight: viewDeskCol.implicitHeight + 38

      Column {
        id: viewDeskCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 19
        spacing: 12

        Row {
          spacing: 8
          Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: "screen-share"
            size: 14
            color: root.viewingPeer ? Theme.err : Theme.dim
          }
          SectionLabel {
            anchors.verticalCenter: parent.verticalCenter
            text: root.viewingPeer ? "VIEW DESKTOP · LIVE" : "VIEW DESKTOP"
          }
        }

        Item {
          width: parent.width
          height: Math.max(viewDeskText.implicitHeight, viewDeskButtons.implicitHeight)

          Column {
            id: viewDeskText
            anchors.left: parent.left
            anchors.right: viewDeskButtons.left
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            Txt {
              width: parent.width
              text: {
                if (root.viewingPeer) {
                  var pd = root.peerDesktop || ({})
                  var bits = [(root.dev && root.dev.name) ? root.dev.name : "Peer"]
                  if (pd.monitor) bits.push(pd.monitor)
                  if (pd.width && pd.height) bits.push(pd.width + "×" + pd.height)
                  return bits.join(" · ") + " is on this screen"
                }
                return root.online
                  ? "Show " + ((root.dev && root.dev.name) ? root.dev.name : "peer") + " on this screen"
                  : ((root.dev && root.dev.name) ? root.dev.name : "Peer") + " is offline"
              }
              font.weight: root.viewingPeer ? Font.Bold : Font.Normal
              color: root.viewingPeer ? Theme.fg : Theme.dim
              wrapMode: Text.Wrap
            }
            Txt {
              width: parent.width
              visible: root.viewingPeer && root.peerDesktop && root.peerDesktop.player
              text: root.peerDesktop ? (root.peerDesktop.player || "") : ""
              color: Theme.dim
              elide: Text.ElideRight
            }
          }

          Row {
            id: viewDeskButtons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
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
      }
    }

    // Latest notifications
    Card {
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

    // The remote desktop and remote input settings of this computer.
    RemoteCard {
      objectName: "remoteCard"
      view: root.view
      settings: root.view && root.view.backend ? (root.view.backend.settings || ({})) : ({})
      desktop: root.desktop
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
    }

    // Phone camera, with its settings. The card spans the grid while the
    // settings are open.
    CameraCard {
      objectName: "cameraCard"
      visible: !!root.webcam
      view: root.view
      webcam: root.webcam
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      Layout.columnSpan: settingsOpen ? grid.columns : 1
    }

    // Phone microphone
    StreamCard {
      objectName: "micCard"
      visible: !!root.mic
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      icon: "mic"
      heading: "PHONE MICROPHONE"
      stream: root.mic || ({})
      title: root.mic ? (root.mic.fromName || "The phone") + " is live as " + (root.mic.source || "Flux Microphone") : ""
      detail: root.mic ? Math.round((root.mic.rate || 48000) / 1000) + " kHz · " + (root.mic.channels === 2 ? "stereo" : "mono") : ""
      onStop: root.view.call("mic.stop", {})
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
      visible: !!root.screen
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
