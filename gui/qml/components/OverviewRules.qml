import QtQuick
import ".."

// Rules for the device Overview. The page draws the cards. This object
// decides the seam, whether View is allowed, which cards show, and the
// pause before a second camera or mic request. It is an item so the
// pause timers can live here. It takes no space on the page.
Item {
  id: rules
  width: 0
  height: 0
  visible: false

  // The Flux window. It owns the selected device and the fluxd calls.
  property var view: null
  // The camera card takes a whole row while its settings are open.
  property bool cameraWide: false

  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online
  readonly property bool peer: !!dev && dev.role === "peer"
  readonly property var settings: view && view.backend ? (view.backend.settings || ({})) : ({})
  readonly property var state: view && view.backend && view.backend.state ? view.backend.state : ({})

  readonly property string edgeSide: rules.edgeSideFor(rules.dev)
  readonly property var notifs: dev && dev.notifications ? dev.notifications.slice(0, 3) : []
  readonly property var herdr: state.herdr || null
  readonly property var waitingAgents: {
    var list = rules.herdr && rules.herdr.agents ? rules.herdr.agents : []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      var status = String(item && item.status || "")
      if (status === "blocked" || status === "done") out.push(item)
    }
    return out
  }

  readonly property var webcam: state.webcam || null
  readonly property var mic: state.mic || null
  readonly property var screen: state.screen || null
  readonly property var desktop: state.desktop || null
  readonly property var peerDesktop: state.peerDesktop || null
  readonly property var browse: state.browse || []

  readonly property bool viewingPeer: {
    var pd = rules.peerDesktop
    if (!pd || !rules.dev) return false
    var from = String(pd.from || "")
    var name = String(pd.fromName || "").toLowerCase()
    return from === String(rules.dev.id || "") || name === String(rules.dev.name || "").toLowerCase()
  }

  readonly property bool showBattery: {
    if (!rules.dev || rules.dev.type === "desktop") return false
    var b = rules.dev.battery
    return !!b && b.charge !== undefined && b.charge !== null && b.charge >= 0
  }

  readonly property bool seamAnswers: {
    if (!rules.edgeSide || !rules.dev || !rules.dev.seamKnown) return false
    return String(rules.dev.edgeSide || "").toLowerCase() === rules.oppositeEdge(rules.edgeSide)
        && rules.namesThisComputer(rules.dev.edgeDevice)
  }

  readonly property string seamNote: {
    var name = (rules.dev && rules.dev.name) || "The other computer"
    if (!rules.edgeSide) return "Pick the edge that leaves this screen."
    var opp = rules.oppositeEdge(rules.edgeSide)
    if (!rules.dev || !rules.dev.seamKnown) return name + " has not reported an edge."
    if (rules.seamAnswers) return name + " answers on the " + opp + "."
    var theirs = String(rules.dev.edgeSide || "").toLowerCase()
    if (!theirs || !rules.namesThisComputer(rules.dev.edgeDevice))
      return name + " has not set the " + opp + " edge."
    return name + " set " + theirs + ", not the " + opp + " edge."
  }

  // View stays off when that computer has said remote desktop is off.
  // An older peer that has not reported a seam can still be asked.
  readonly property bool viewAllowed: rules.online && !(rules.dev && rules.dev.seamKnown && !rules.dev.remoteDesktop)

  readonly property string viewNote: {
    if (!rules.dev) return "View desktop"
    var name = rules.dev.name || "The other computer"
    if (!rules.online) return name + " is offline"
    if (rules.dev.seamKnown && !rules.dev.remoteDesktop) return name + " has remote desktop off"
    if (rules.viewingPeer) return "View desktop · live"
    return "View desktop"
  }

  readonly property string ringLabel: {
    var noun = Fmt.noun(rules.dev ? rules.dev.type : "")
    return "Ring " + (noun === "PC" ? "computer" : noun)
  }

  readonly property bool accessNeedsGlobal: rules.accessGroupGated([
    { key: "clipboard" }, { key: "notifications" }, { key: "shareHome" },
    { key: "remoteInput" }, { key: "remoteDesktop" },
    { key: "herdr" }, { key: "herdrControl" }, { key: "herdrTerminals" }
  ])

  readonly property var nowLayout: {
    var slots = [
      { key: "notif", show: rules.nowShow("notif"), wide: false },
      { key: "camera", show: rules.nowShow("camera"), wide: rules.cameraWide },
      { key: "mic", show: rules.nowShow("mic"), wide: false },
      { key: "agent", show: rules.nowShow("agent"), wide: false },
      { key: "browse", show: rules.nowShow("browse"), wide: false },
      { key: "screen", show: rules.nowShow("screen"), wide: false }
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

  // The device can start its camera and its microphone when this computer
  // asks. The device asks its user first.
  readonly property bool canAsk: rules.online && !!rules.dev && !!rules.dev.paired && Array.isArray(rules.dev.plugins) && rules.dev.plugins.indexOf("streamrequest") >= 0

  property string webcamAsked: ""
  property string micAsked: ""
  property string webcamSeen: ""
  property string micSeen: ""
  property string webcamSent: ""
  property string micSent: ""
  // streamRequestGap in internal/core/streamrequest.go, in milliseconds.
  readonly property int requestGap: 3000

  onWebcamChanged: if (webcamAsked !== "" && JSON.stringify(webcam) !== webcamSeen) webcamAsked = ""
  onMicChanged: if (micAsked !== "" && JSON.stringify(mic) !== micSeen) micAsked = ""

  Timer { id: webcamWait; interval: 60000; onTriggered: rules.webcamAsked = "" }
  Timer { id: micWait; interval: 60000; onTriggered: rules.micAsked = "" }
  Timer { id: webcamGap; interval: rules.requestGap; onTriggered: rules.webcamSent = "" }
  Timer { id: micGap; interval: rules.requestGap; onTriggered: rules.micSent = "" }

  function agentWaitText(agent) {
    var name = (agent && agent.agent) ? agent.agent : "Agent"
    var title = agent ? (agent.title || agent.project || "") : ""
    var status = agent && agent.status === "blocked" ? "needs input" : "finished"
    return title !== "" ? name + " · " + title + " · " + status : name + " · " + status
  }

  function startPeerView() {
    if (!rules.view || !rules.view.call || !rules.dev) return
    if (!rules.online) {
      rules.view.toast((rules.dev.name || "Peer") + " is offline")
      return
    }
    var key = rules.dev.name || rules.dev.id
    rules.view.call("desktop.view", { device: key }, function () {
      if (rules.view) rules.view.toast("Showing " + (rules.dev.name || "peer") + " desktop")
    })
  }

  function stopPeerView() {
    if (!rules.view || !rules.view.call) return
    rules.view.call("desktop.viewStop", {}, function () {
      if (rules.view) rules.view.toast("Stopped peer desktop")
    })
  }

  function accessGlobalOn(key) {
    var settings = rules.settings || ({})
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
      if (!rules.accessGlobalOn(rows[i].key)) return true
    }
    return false
  }

  function edgeSideFor(d) {
    if (!d) return ""
    var side = String(rules.settings.edgeSide || "")
    var who = String(rules.settings.edgeDevice || "").toLowerCase()
    var name = String(d.name || "").toLowerCase()
    var id = String(d.id || "")
    if (!side || !who || (id !== rules.settings.edgeDevice && name !== who)) return ""
    return side.toLowerCase()
  }

  function setEdgeSide(side) {
    if (!rules.view || !rules.view.call || !rules.dev) return
    side = String(side || "").toLowerCase()
    if (!side) {
      rules.view.call("settings.set", { key: "edgeSide", value: "" })
      rules.view.call("settings.set", { key: "edgeDevice", value: "" })
      rules.view.toast("Screen edge off")
      return
    }
    var device = rules.dev.name || rules.dev.id
    rules.view.call("settings.set", { key: "edgeSide", value: side })
    rules.view.call("settings.set", { key: "edgeDevice", value: device })
    rules.view.toast(side.charAt(0).toUpperCase() + side.slice(1) + " edge → " + device)
  }

  function oppositeEdge(side) {
    if (side === "left") return "right"
    if (side === "right") return "left"
    if (side === "top") return "bottom"
    if (side === "bottom") return "top"
    return ""
  }

  function namesThisComputer(who) {
    who = String(who || "")
    if (!who || !rules.view) return false
    var self = rules.view.selfDevice || ({})
    if (who === String(self.id || "")) return true
    return who.toLowerCase() === String(self.name || "").toLowerCase()
  }

  function nowShow(key) {
    if (rules.peer) return false
    if (key === "notif") return true
    if (key === "camera") return !!rules.webcam || rules.canAsk
    if (key === "mic") return !!rules.mic || rules.canAsk
    if (key === "agent") return !!rules.waitingAgents && rules.waitingAgents.length > 0
    if (key === "browse") return !!rules.browse && rules.browse.length > 0
    if (key === "screen") return !!rules.screen
    return false
  }

  function browsePeerHome() {
    if (!rules.view || !rules.dev) return
    if (!rules.online) {
      rules.view.toast((rules.dev.name || "Peer") + " is offline")
      return
    }
    var name = rules.dev.name || "peer"
    var id = rules.dev.id
    rules.view.call("browse.open", { device: id }, function () {
      if (rules.view) {
        rules.view.toast("Opening " + name + " home…")
        rules.view.go("files")
      }
    }, function (err) {
      if (rules.view) rules.view.toast((err && (err.message || err.code)) || ("Cannot browse " + name))
    })
  }

  function askStream(kind) {
    if (!rules.view || !rules.dev) return
    var v = rules.view
    var micKind = kind === "mic"
    var id = rules.dev.id
    var name = rules.dev.name || "the device"
    var gap = micKind ? micGap : webcamGap
    if ((micKind ? rules.micSent : rules.webcamSent) === id) return
    if (micKind) rules.micSent = id
    else rules.webcamSent = id
    gap.restart()
    v.call(kind + ".start", { device: id }, function () {
      gap.restart()
      if (micKind) {
        rules.micAsked = id
        rules.micSeen = JSON.stringify(rules.mic)
        micWait.restart()
      } else {
        rules.webcamAsked = id
        rules.webcamSeen = JSON.stringify(rules.webcam)
        webcamWait.restart()
      }
      v.toast("Asked " + name + " to start " + (micKind ? "the mic" : "the webcam") + ". Confirm on " + name + ".")
    }, function (err) {
      if (micKind && rules.micSent === id) rules.micSent = ""
      if (!micKind && rules.webcamSent === id) rules.webcamSent = ""
      v.toast(err.message || err.code || "Error")
    })
  }

  function canSend(sent) {
    return !rules.dev || sent !== rules.dev.id
  }

  function confirmNote(asked) {
    return asked !== "" && !!rules.dev && asked === rules.dev.id ? "Confirm on " + (rules.dev.name || "the device") + "." : ""
  }

  function idleTitle(asked, what) {
    if (rules.confirmNote(asked) !== "") return "Asked " + (rules.dev.name || "the device") + " to start " + what
    return what.charAt(0).toUpperCase() + what.slice(1) + " is off"
  }
}
