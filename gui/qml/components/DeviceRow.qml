import QtQuick
import QtQuick.Layouts
import ".."

// One device in the sidebar: type icon, name, status, and battery.
Rectangle {
  id: root
  property var device: ({})
  property bool selected: false
  signal clicked()

  readonly property bool online: !!device.online
  readonly property string statusText: !device.paired ? "not paired" : (online ? "connected" : "offline")

  implicitHeight: row.implicitHeight + 22
  color: selected ? Theme.bg : (area.containsMouse ? Theme.alpha(Theme.bg, 0.5) : "transparent")
  border.width: 1
  border.color: selected ? Theme.bg3 : "transparent"

  RowLayout {
    id: row
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: 11
    anchors.rightMargin: 11
    spacing: 10

    Rectangle {
      id: kind
      Layout.preferredWidth: 32
      Layout.preferredHeight: 32
      Layout.alignment: Qt.AlignVCenter
      clip: true
      color: root.online && root.device.paired ? Theme.alpha(Theme.accent, 0.16) : Theme.bg3
      Icon {
        anchors.centerIn: parent
        name: Fmt.kindIcon(root.device.type)
        size: 18
        color: root.online && root.device.paired ? Theme.accent : Theme.dim
      }
    }

    Column {
      id: info
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      Layout.minimumWidth: 0
      Txt {
        width: parent.width
        text: root.device.name || ""
        font.weight: Font.DemiBold
        elide: Text.ElideRight
      }
      Txt {
        width: parent.width
        text: "● " + root.statusText
        color: root.online && root.device.paired ? Theme.ok : Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
    }

    RowLayout {
      id: battery
      Layout.alignment: Qt.AlignVCenter
      spacing: 2
      visible: !!root.device.battery && root.device.battery.charge >= 0
      Icon {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: 14
        Layout.preferredHeight: 14
        name: Fmt.batteryIcon(root.device.battery)
        size: 14
        color: root.device.battery && root.device.battery.charge <= 15 && !root.device.battery.charging ? Theme.err : Theme.dim
      }
      Txt {
        Layout.alignment: Qt.AlignVCenter
        text: Fmt.battery(root.device.battery)
        color: Theme.dim
        font.pixelSize: 11
      }
    }
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
