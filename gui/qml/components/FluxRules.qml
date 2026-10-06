import QtQuick
import ".."

// Rules for the Flux window. The view draws the sidebar and the page.
// This object chooses the device, the page, and the pair flow.
Item {
  id: rules
  width: 0
  height: 0
  visible: false

  property var backend: null
  // The window. It shows toasts and calls fluxd.
  property var host: null

  signal freshPairRequest()

  readonly property var tabs: [
    { key: "overview", label: "Overview", page: "Overview", icon: "dashboard" },
    { key: "clipboard", label: "Clipboard", page: "Clipboard", icon: "clipboard" },
    { key: "files", label: "Files", page: "Files", icon: "transfers" },
    { key: "notifications", label: "Notifications", page: "Notifications", icon: "bell" },
    { key: "messages", label: "Messages", page: "Messages", icon: "message" },
    { key: "commands", label: "Phone commands", page: "PhoneCommands", icon: "console" }
  ]

  property string tab: "overview"
  onTabChanged: if (tab !== "network") pairPane = false
  property string selectedId: ""
  // Pair is open. Pair new device, the rail plus button, and key p open it.
  property bool pairPane: false
  property string justPaired: ""
  property var prevPairStates: ({})
  property var unpairTarget: null

  readonly property bool daemonUp: !!backend && backend.connected
  readonly property var allDevices: backend ? (backend.devices || []) : []
  readonly property var paired: allDevices.filter(d => d.paired)
  readonly property var discovered: allDevices.filter(d => !d.paired && d.online && d.pairState !== "incoming" && d.pairState !== "confirm")
  // A pair request of a device, and a pairing that this computer started
  // and the device accepted ("confirm").
  readonly property var incoming: allDevices.filter(d => d.pairState === "incoming" || d.pairState === "confirm")
  readonly property var requested: allDevices.find(d => d.pairState === "requested") || null
  // The text changes only when one of these fields changes, so a state
  // event does not build a card again under the pointer.
  readonly property string incomingText: JSON.stringify(incoming.map(d => ({
    id: d.id, name: d.name, ip: d.ip || "", pairKey: d.pairKey || "", pairState: d.pairState
  })))
  readonly property var incomingRows: JSON.parse(incomingText)
  readonly property string discoveredText: JSON.stringify(discovered.map(d => ({
    id: d.id, name: d.name, type: d.type, ip: d.ip || "", fingerprint: d.fingerprint || "",
    pairState: d.pairState, pairKey: d.pairKey || "", twin: twinText(d)
  })))
  readonly property var discoveredRows: JSON.parse(discoveredText)

  // since is when the request first showed. until is when it stopped, or 0
  // while it is open. An entry stays for requestQuiet, so a device that
  // withdraws a request and sends it again does not count as new.
  property var requestShown: ({})
  readonly property int requestQuiet: 5 * 60 * 1000
  // The oldest open pair request. A later request does not replace the card.
  readonly property var pairRequest: {
    var best = null
    var bestAt = 0
    for (var i = 0; i < incomingRows.length; i++) {
      var r = incomingRows[i]
      var e = Fmt.lookup(requestShown, r.id)
      var at = e ? e.since : Number.MAX_VALUE
      if (!best || at < bestAt) {
        best = r
        bestAt = at
      }
    }
    return best
  }

  readonly property string pairedRowsText: JSON.stringify(paired.map(d => ({
    id: d.id, name: d.name, type: d.type, online: !!d.online, paired: !!d.paired,
    battery: d.battery || null, ip: d.ip || "", path: d.path || ""
  })))
  readonly property var pairedRows: JSON.parse(pairedRowsText)
  readonly property var dev: {
    for (var i = 0; i < paired.length; i++)
      if (paired[i].id === selectedId) return paired[i]
    return paired.length > 0 ? paired[0] : null
  }
  readonly property bool devOnline: !!dev && !!dev.online
  readonly property string devName: dev ? (dev.name || "device") : "device"
  readonly property var visibleTabs: tabs.filter(t => rules.tabAllowed(t.key))
  readonly property var currentTab: {
    if (tab === "network" || tab === "computer") return null
    for (var i = 0; i < visibleTabs.length; i++)
      if (visibleTabs[i].key === tab) return visibleTabs[i]
    return visibleTabs.length > 0 ? visibleTabs[0] : null
  }
  readonly property bool networkTab: tab === "network"
  readonly property bool computerTab: tab === "computer"
  readonly property bool deskTab: networkTab || computerTab
  readonly property var selfDevice: backend ? (backend.selfDevice || {}) : {}
  readonly property string viewingId: {
    var desk = backend && backend.state ? backend.state.peerDesktop : null
    return desk && desk.from ? desk.from : ""
  }

  Timer {
    id: pairedTimer
    interval: 3000
    onTriggered: rules.justPaired = ""
  }

  onIncomingRowsChanged: rules.noteIncoming()
  onAllDevicesChanged: rules.notePaired()

  function has(plugin) {
    if (!dev || !dev.plugins || dev.plugins.length === 0) return true
    return dev.plugins.indexOf(plugin) >= 0
  }

  function tabAllowed(key) {
    if (key === "messages") return rules.has("sms")
    if (key === "commands") return !dev || dev.role !== "peer"
    return true
  }

  function go(key) {
    if (rules.tabAllowed(key)) tab = key
  }

  function showPage(key) {
    if (key === "network" || key === "computer") {
      rules.tab = key
      return true
    }
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].key === key) {
        rules.go(key)
        return true
      }
    }
    return false
  }

  function selectOffset(n) {
    if (paired.length === 0) return
    var i = 0
    for (var j = 0; j < paired.length; j++) if (dev && paired[j].id === dev.id) i = j
    i = Math.max(0, Math.min(paired.length - 1, i + n))
    selectedId = paired[i].id
  }

  function ring() {
    if (!dev || !host) return
    if (!dev.online) {
      host.toast(devName + " is offline")
      return
    }
    host.call("ring", { device: dev.id }, function () { host.toast("Ringing " + rules.devName + "…") })
  }

  function sendClipboard() {
    if (!dev || !host) return
    if (!dev.online) {
      host.toast(devName + " is offline")
      return
    }
    host.call("clipboard.send", { device: dev.id }, function () { host.toast("Clipboard sent to " + rules.devName) })
  }

  function unpair() {
    if (!dev) return
    unpairTarget = dev
  }

  function confirmUnpair() {
    var target = unpairTarget
    unpairTarget = null
    if (!target || !host) return
    host.call("pair.unpair", { device: target.id }, function () {
      host.toast((target.name || "Device") + " unpaired")
      if (rules.selectedId === target.id) rules.selectedId = ""
    })
  }

  function twinText(d) {
    var key = Fmt.nameKey(d.name)
    var others = allDevices.filter(o => o.id !== d.id && Fmt.nameKey(o.name) === key)
    if (others.length === 0) return ""
    return others.some(o => o.paired) ? "Same name as a paired device" : "Same name as another device"
  }

  function openPair() {
    pairPane = true
    tab = "network"
    if (host) host.call("discover", {})
  }

  // A selected device opens on Overview. With no device, that tab has
  // nothing to show, so the empty page stays.
  function leavePair() {
    pairPane = false
    if (tab === "network") tab = "overview"
  }

  function notePaired() {
    var next = {}
    for (var i = 0; i < allDevices.length; i++) {
      var d = allDevices[i]
      var before = prevPairStates[d.id]
      if (before !== undefined && before !== "paired" && d.pairState === "paired") {
        justPaired = d.name
        selectedId = d.id
        if (pairPane) tab = "overview"
        pairPane = false
        pairedTimer.restart()
      }
      next[d.id] = d.pairState
    }
    prevPairStates = next
  }

  // A new pair request asks the window to scroll to the card. A device
  // that withdraws its request and sends it again inside requestQuiet
  // does not count as new.
  function noteIncoming() {
    var now = Date.now()
    var open = {}
    incomingRows.forEach(d => { open[d.id] = true })
    var shown = {}
    for (var id in requestShown) {
      var e = requestShown[id]
      var isOpen = !!Fmt.lookup(open, id)
      if (!e.until) shown[id] = isOpen ? e : { since: e.since, until: now }
      else if (now - e.until < requestQuiet) shown[id] = isOpen ? { since: now, until: 0 } : e
    }
    var fresh = false
    for (var rid in open) {
      if (Fmt.lookup(shown, rid)) continue
      shown[rid] = { since: now, until: 0 }
      fresh = true
    }
    requestShown = shown
    if (fresh) freshPairRequest()
  }
}
