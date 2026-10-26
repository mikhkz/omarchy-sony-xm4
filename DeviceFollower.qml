import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// One device, followed for as long as it is connected.
//
// Everything here belongs to a single set of earbuds: its mode bridge, its
// levels, its errors, its warning state. The address is handed in when the
// service builds this and never changes afterwards — that is the whole point of
// the split. The old single-device service pointed one reader at whichever
// device it had picked, and a pick that moved while a line was in flight put
// one headset's name over another's left, right and case. A follower cannot mix
// two devices because it only ever knew about one; when its device goes, the
// follower goes with it and Quickshell kills the bridges below.
//
// The Fast Pair reader is the one helper a follower does not own. BlueZ hands
// out a single Message Stream registration for the whole system, so one process
// serves every device and the service holds it; each line it writes names the
// device it is about, and the service calls applyReaderLine() on the follower
// that address belongs to. What a line means is still decided here.
//
// Not a service entry point. The plugin's one service (Service.qml) creates
// these, holds what they share — the settings, the reader, the mode-support
// cache, the parked and backoff maps, the notification process — and hands
// itself in as `service` so a follower can reach them.
Item {
  id: follower

  // The service that made this follower, for the shared state above. Never null
  // in practice; the guards are for the moment of construction and for anyone
  // who builds one of these by hand.
  property var service: null

  // The device this follower is about, fixed for its lifetime. Everything else
  // in this file hangs off it.
  property string address: ""

  // Looked up again rather than remembered, so a BlueZ device object that is
  // replaced (an adapter reset, a re-pair) is followed through. The lookup is by
  // address, so it can never land on a different set of earbuds.
  readonly property var device: Model.deviceByAddress(service ? service.devices : [], address)

  readonly property bool hasDevice: !!device
  readonly property bool connected: hasDevice && device.connected === true
  readonly property string name: hasDevice ? Model.deviceLabel(device) : ""

  // ---- Bluetooth audio codec. This is host-side state, separate from the
  //      vendor control channel below: changing it asks PipeWire to select one
  //      of the A2DP profiles this exact card advertised and cannot alter ANC.
  property var codecState: ({ options: [], active: "", activeLabel: "" })
  property string codecError: ""
  property real codecStamp: 0
  readonly property var codecOptions: codecState.options || []
  readonly property string codecProfile: String(codecState.active || "")
  readonly property string codecActiveLabel: String(codecState.activeLabel || "")
  readonly property bool codecChanging: codecSetProcess.running

  // ---- The settings live on the service, where the panel pushes them. They are
  //      the same for every device — a threshold is about you, not about a
  //      headset — and they are read through here so the bindings below need not
  //      say `service ?` twice a line.
  readonly property bool useFastPair: service ? service.useFastPair : true
  readonly property bool useModeControl: service ? service.useModeControl : true
  readonly property int lowThreshold: service ? service.lowThreshold : 20
  readonly property bool notifyLow: service ? service.notifyLow : true

  // ---- What this device's lines from the service's Fast Pair reader said.
  property var reading: ({})
  // Set while this device's channel is being cycled on purpose, so the rows do
  // not blank while the reader drops it and opens it again.
  property bool refreshing: false
  property real readingStamp: 0
  // What this device's own lines complained about. The reader failing as a
  // whole is the service's to report, and it arrives through readerError below.
  property string readerErrorRaw: ""
  readonly property bool readerRunning: service ? service.readerRunning : false
  readonly property string serviceReaderError: service ? service.readerError : ""
  // With Fast Pair off the reader never runs, and a message left over from when
  // it did would be read as a live fault. A reader that could not start at all
  // is shown by every device it was meant to serve, because it is every one of
  // their reasons for having no per-earbud levels.
  readonly property string readerError: !useFastPair
    ? ""
    : (readerErrorRaw !== "" ? readerErrorRaw : serviceReaderError)

  // No live reader means no stream, whatever the last line said: a reader that was
  // killed rather than closed leaves its last reading behind, and showing stale
  // per-earbud levels as current is worse than falling back to BlueZ. A refresh is
  // the exception — the channel is being dropped on purpose, and blanking the rows
  // for that second would flash BlueZ's single "Battery" row in their place.
  readonly property bool streaming: reading.stream === true
    && (readerRunning || refreshing)

  // ---- What the mode bridge said about the battery, on a device whose control
  //      channel carries it (the Nothing one does). Second to the Fast Pair
  //      stream, which announces a change the moment it happens where the
  //      bridge polls: it fills in when there is no stream — a set with no
  //      Message Stream, or Fast Pair switched off — and only while the bridge
  //      is up and answering, for the reason the stream's levels go with the
  //      reader: a figure nobody is updating must not read as current.
  readonly property bool bridgeBattery: ancLive && !streaming
    && (Model.bridgeLevel(ancState, "left") >= 0 || Model.bridgeLevel(ancState, "right") >= 0
        || Model.bridgeLevel(ancState, "case") >= 0 || Model.bridgeLevel(ancState, "headset") >= 0)

  readonly property int leftLevel: streaming ? Model.readerLevel(reading, "left")
    : (bridgeBattery ? Model.bridgeLevel(ancState, "left") : -1)
  readonly property int rightLevel: streaming ? Model.readerLevel(reading, "right")
    : (bridgeBattery ? Model.bridgeLevel(ancState, "right") : -1)
  readonly property int caseLevel: streaming ? Model.readerLevel(reading, "case")
    : (bridgeBattery ? Model.bridgeLevel(ancState, "case") : -1)
  readonly property bool leftCharging: streaming ? reading.leftCharging === true
    : (bridgeBattery && Model.bridgeCharging(ancState, "left"))
  readonly property bool rightCharging: streaming ? reading.rightCharging === true
    : (bridgeBattery && Model.bridgeCharging(ancState, "right"))
  readonly property bool caseCharging: streaming ? reading.caseCharging === true
    : (bridgeBattery && Model.bridgeCharging(ancState, "case"))
  readonly property bool perBud: leftLevel >= 0 || rightLevel >= 0
  // The case only reports while it is open; the panel dims that row rather than
  // dropping it.
  readonly property bool caseStale: bridgeBattery && Model.bridgeCaseStale(ancState)

  // A set with one battery for the whole thing — an over-ear headset, mostly.
  // It is its own shape, not a pair with one bud missing: there is no side to
  // name and no case to report, so the panel draws one row and the bar fills
  // both halves of the mark with the same figure. `perBud` deliberately stays
  // false here, because there are no buds to compare.
  readonly property bool single: streaming ? reading.single === true
    : (bridgeBattery && Model.bridgeLevel(ancState, "headset") >= 0)
  readonly property int singleLevel: !single ? -1
    : (streaming ? Model.readerLevel(reading, "battery") : Model.bridgeLevel(ancState, "headset"))
  readonly property bool singleCharging: single && (streaming ? reading.batteryCharging === true
    : Model.bridgeCharging(ancState, "headset"))

  readonly property string modelId: String(reading.modelId || "")
  readonly property string bleAddress: String(reading.bleAddress || "")

  // ---- Listening mode. The panel shows a mode and writes a mode; the helper
  //      that carries it is sony-v1-bridge, Sony's MDR v1 protocol over an
  //      RFCOMM channel the headset itself serves. A device that advertises the
  //      UUID in its SDP record speaks the protocol, so this path needs no Fast
  //      Pair and no cache of which models answered.
  //
  //      Exactly one process owns the link, because writes and the device's own
  //      notifications (a mode changed from the headset) must share one
  //      connection; this follower talks to it through its stdin.
  readonly property string sonyV1BridgePath: service ? service.sonyV1BridgePath : ""
  readonly property string classicBridgePath: controlBackend === "sony-v1" ? sonyV1BridgePath : ""
  property var ancState: ({})
  property bool ancEnabled: true
  property bool ancAnswered: false
  // One request per connection: WH-1000XM4 should start with every listening
  // effect disabled. It stays pending until the Sony v1 bridge has read the
  // device and can accept a write, then clears before sending so the resulting
  // notification cannot trigger a loop.
  property bool defaultOffPending: false
  property string ancRunError: ""
  property string ancErrorRaw: ""
  property bool classicEnabled: true
  // Armed one turn of the event loop late: `command` and `running` both depend
  // on the SDP probe, and QML does not promise which binding settles first.
  // Otherwise the Process could start as QList("", address) before the UUIDs
  // arrived and never run the bridge.
  readonly property bool classicWanted: useModeControl && classicEnabled && connected
    && classicBridgePath !== ""
    && !addressParked
  property bool classicArmed: false
  onClassicWantedChanged: {
    if (!classicWanted) { classicArmed = false; return }
    Qt.callLater(function () { classicArmed = follower.classicWanted })
  }

  // What this device serves, read once per connection with `bluetoothctl info`.
  // Empty while it is not connected, or while the probe is still out.
  property var deviceUuids: []
  readonly property string controlBackend: Model.controlBackend(deviceUuids, bleAddress)
  readonly property bool classicBackend: Model.isClassicBackend(controlBackend)

  readonly property bool ancSupported: ancState.modes === true
  readonly property string ancMode: String(ancState.mode || "")
  // Which modes this device offers, in the order the panel draws them: what
  // the headset lists, which for an over-ear WH is Off / NC / Ambient.
  readonly property var modesAvailable: Model.modesAvailable(ancState)
  // Ambient detail: how much of the room comes through (0-20) and
  // whether voices are lifted out of it. -1 and false mean "not said".
  readonly property int ambientLevel: typeof ancState.level === "number" ? ancState.level : -1
  readonly property bool ambientVoice: ancState.voice === true
  // Whether this device has the two Ambient extras at all, which is decided by
  // the bridge that answered rather than by a name. The panel draws the dial
  // and the voice switch on this, and nothing before the bridge has spoken.
  readonly property bool ambientControls: ancLive && ambientLevel >= 0
  // Optional Sony v1 system settings discovered by the bridge. They are absent
  // on other headsets, so the panel gets no misleading generic controls.
  readonly property bool multipointKnown: typeof ancState.multipoint === "boolean"
  readonly property bool multipointEnabled: multipointKnown && ancState.multipoint === true
  readonly property bool multipointChanging: multipointKnown
    && ancState.multipointChanging === true
  readonly property string multipointError: String(ancState.multipointError || "")
  readonly property var autoPowerOptions: Array.isArray(ancState.autoPowerOptions)
    ? ancState.autoPowerOptions : []
  readonly property string autoPower: String(ancState.autoPower || "")
  readonly property bool autoPowerKnown: autoPower !== "" && autoPowerOptions.length > 0

  readonly property bool bridgeRunning: classicBridge.running
  // The bridge is up and the device has answered on it, which is the only state
  // in which a write has somewhere to land.
  readonly property bool ancLive: bridgeRunning && ancAnswered
  // Why the listening-mode row is not there. Blank while the row is simply
  // switched off, because that needs no explaining.
  readonly property string ancError: {
    if (!useModeControl) return ""
    return ancErrorRaw
  }

  readonly property bool addressParked: service ? service.sonyParked[address] === true : false
  // How long to wait before the next attempt, keyed by the Classic address.
  readonly property string ancBackoffKey: address

  readonly property int bluezLevel: Model.batteryLevel(device)
  // The bar carries one number: the headset's own figure where there is only
  // one, otherwise the earbud that dies first, or BlueZ's rounded single figure
  // when the Message Stream has said nothing.
  readonly property int level: singleLevel >= 0
    ? singleLevel
    : (perBud ? Model.lowestBud(leftLevel, rightLevel) : bluezLevel)
  readonly property bool charging: leftCharging || rightCharging || singleCharging
  readonly property bool low: connected && level >= 0 && level <= lowThreshold && !charging

  readonly property var summary: ({
    hasDevice: follower.hasDevice, connected: follower.connected, name: follower.name,
    level: follower.level, left: follower.leftLevel, right: follower.rightLevel,
    caseLevel: follower.caseLevel,
    single: follower.single, singleLevel: follower.singleLevel
  })

  // The earbuds announce on connect and when a level changes, and docking an
  // earbud is neither: park one in the case and its last level stands until
  // something asks again. Opening the panel is when someone wants the truth, so a
  // reading older than half a minute is refreshed then — which keeps the promise
  // that nothing is polled while nobody is looking.
  readonly property int stalerThanMs: 30000

  // ---- Warning state. The last level seen, and which source said it: the
  //      Message Stream's per-earbud minimum and BlueZ's rounded single figure
  //      are different measurements, and reading one after the other as a drop
  //      warns about arithmetic rather than about the battery. A level from a
  //      different source than the last one is therefore compared with nothing.
  //      `primed` absorbs the first level of the session so a shell restart with
  //      already-low earbuds stays quiet, while a connect that this follower
  //      witnesses arms the warning again — that one is news.
  property string lastSource: ""
  property int lastLevel: -1
  property bool primed: false
  property bool sawDisconnected: false

  // Warned about already, and remembered across a reload by the service, which
  // keeps one flag per address: two headsets draining at once are two warnings,
  // and one of them being silenced must not silence the other.
  readonly property bool notifiedLow: service && service.notifiedLow
    ? service.notifiedLow[address] === true : false
  function setNotifiedLow(value) {
    if (service) service.setNotifiedLow(address, value)
  }

  // What one line said for itself, as an object with only the keys that line
  // carried. Junk, an array or a blank line carried nothing. The merged state
  // cannot answer this: it keeps the keys earlier lines set, so the three-key
  // {address, stream, error} line the reader writes when the channel goes down
  // would look like it had brought a fresh left and right along with it.
  function readerLineFields(line) {
    var parsed = null
    try {
      parsed = JSON.parse(String(line || "").trim() || "{}")
    } catch (e) {
      return ({})
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return ({})
    return parsed
  }

  // One line of the reader's stdout that named this device. Called by the
  // service, which owns the process and routes by the line's `address`; a
  // follower never sees another device's lines and so cannot mix them up.
  function applyReaderLine(line) {
    var incoming = readerLineFields(line)
    var next = Model.mergeReaderLine(reading, line)
    reading = next
    if (next.stream === false) readerErrorRaw = String(next.error || "")
    else readerErrorRaw = ""
    // Only a line that carried a level is a reading: the stamp is how old the
    // levels on screen are, and a refresh is over when new ones arrive, not
    // when the reader says something else about itself.
    if (incoming.left !== undefined || incoming.right !== undefined
        || incoming.battery !== undefined) {
      readingStamp = Date.now()
      refreshing = false
    }
  }

  // One JSON line from the bridge. The mode is whatever the line says — a bridge
  // reports its device's whole state on every change — but the keys a line may
  // omit carry forward, because reading that silence as "unknown" would blank a
  // level the device never changed.
  function applyAncLine(line) {
    var parsed = null
    try {
      parsed = JSON.parse(String(line || "").trim() || "{}")
    } catch (e) {
      return
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return
    var cached = parsed.cached === true
    var carried = ["available", "level", "voice", "battery",
      "multipoint", "multipointChanging", "multipointError", "autoPowerOptions", "autoPower"]
    for (var i = 0; i < carried.length; i++) {
      var key = carried[i]
      if (parsed[key] === undefined && ancState[key] !== undefined) parsed[key] = ancState[key]
    }
    // A failed fresh query describes channel availability, not a loss of the
    // headset features already confirmed. Keep that snapshot and report the
    // error separately; onRunningChanged removes live write permission.
    if (parsed.modes !== true && parsed.error !== undefined && ancState.modes === true) {
      ancRunError = String(parsed.error || "")
      ancErrorRaw = ancRunError
      return
    }
    ancState = parsed
    if (parsed.modes === true) {
      if (cached) {
        // Useful for layout and read-only status only. A cached snapshot never
        // proves that this process owns Sony's control channel.
        ancAnswered = false
        return
      }
      ancAnswered = true
      ancErrorRaw = ""
      if (service) service.resetAncBackoff(ancBackoffKey)
      if (service) service.rememberControlState(address, parsed)
      Qt.callLater(function () { follower.applyDefaultOff() })
    } else if (parsed.error !== undefined) {
      ancRunError = String(parsed.error || "")
      ancErrorRaw = ancRunError
    }
  }

  function applyDefaultOff() {
    if (!defaultOffPending || !connected) return
    if (controlBackend !== "sony-v1") {
      defaultOffPending = false
      return
    }
    if (!ancSupported || !ancLive || modesAvailable.indexOf("off") === -1) return
    defaultOffPending = false
    if (ancMode !== "off") setAncMode("off")
  }

  // What this device serves, from its SDP record. Quickshell.Bluetooth exposes
  // no uuids property, and the list does not change while a device stays
  // connected, so it is read once per connection with the tool that prints it
  // rather than watched. One probe at a time, and no need to check whose answer
  // came back: this follower asks about one address and no other.
  function probeUuids() {
    if (!connected || address === "") {
      deviceUuids = []
      return
    }
    if (uuidProbe.running) return
    uuidProbe.command = ["/usr/bin/bluetoothctl", "info", address]
    uuidProbe.running = true
  }

  function probeCodecs() {
    if (!connected || address === "") {
      codecState = ({ options: [], active: "", activeLabel: "" })
      codecStamp = 0
      return
    }
    if (codecProbe.running) return
    codecProbe.command = ["/usr/bin/pactl", "list", "cards"]
    codecProbe.running = true
  }

  function setCodec(profile) {
    if (!connected || codecSetProcess.running) return false
    var resolved = Model.codecProfile(codecOptions, profile)
    if (resolved.indexOf("a2dp-sink") !== 0) return false
    codecError = ""
    codecSetProcess.command = ["/usr/bin/pactl", "set-card-profile",
      "bluez_card." + address.replace(/:/g, "_"), resolved]
    codecSetProcess.running = true
    return true
  }

  // Refresh means "ask the earbuds for a fresh battery reading". The device
  // pushes a reading when a level changes, so there is nothing to poll: dropping
  // the channel and letting it re-announce is the only way to ask for a figure
  // the device considers unchanged. The BLE address and the model id are not
  // readings — they identify the device — and dropping them would tear down the
  // listening-mode link for no reason, so they survive. Nothing else is cleared
  // either: the levels on screen stay until fresh ones replace them, because a
  // refresh that blanks the panel first is a refresh that looks like a fault.
  function refresh() {
    if (!connected) return
    probeCodecs()
    readerErrorRaw = ""
    // `r` is also the way past the bridge's backoff: a helper that failed
    // because a package was missing is retried on a pause that reaches five
    // minutes, and the person who just installed the package should not wait
    // for it. Forget the pause, let the bridge start now.
    if (service) {
      service.unparkAddress(address)
      service.resetAncBackoff(address)
    }
    if (classicRestart.running) { classicRestart.stop(); classicEnabled = true }
    if (!useFastPair || !service) return
    // The service cycles this device's channel and leaves every other device's
    // alone; it says whether the request went out at all, because a reader that
    // is between attempts has nothing to drop, and holding the rows on screen
    // for an answer that is not coming is worse than falling back to BlueZ.
    if (service.refreshReader(address)) {
      refreshing = true
      refreshGuard.restart()
    }
  }

  // A fresh run of the shared reader starts every device with a clean slate:
  // whatever the run that died complained about is not about this one.
  function clearReaderError() {
    readerErrorRaw = ""
  }

  function restoreControlState() {
    if (!service || address === "" || ancState.modes === true) return
    var cached = service.cachedControlState(address)
    if (cached && cached.modes === true) ancState = cached
  }

  function refreshIfStale() {
    if (!connected) return
    if (codecStamp === 0 || Date.now() - codecStamp > 5000) probeCodecs()
    if (readingStamp === 0 || Date.now() - readingStamp > stalerThanMs) refresh()
  }

  // The bridge is live for this backend: the one place a write to the headset
  // can go.
  function classicLive(backend) {
    return ancLive && classicBridge.running && controlBackend === backend
  }

  // True only when the write actually went out, so callers can say "unavailable"
  // rather than pretend the device was told. A mode this device does not offer
  // is not a write: the Sony over-ear has no TalkThru, and sending one would be
  // a command the headset answers by doing nothing.
  function setAncMode(mode) {
    if (!ancSupported || !ancLive) return false
    if (modesAvailable.indexOf(String(mode)) === -1) return false
    if (!classicBridge.running) return false
    classicBridge.write("set " + mode + "\n")
    return true
  }

  // How much of the room comes through in Ambient, 0-20. The bridge switches the
  // headset to ambient as part of it, because the level is stored only by a set
  // that carries it: sending a level while Noise Cancelling is on changes nothing.
  function setAmbientLevel(value) {
    if (!classicLive("sony-v1")) return false
    var level = Math.max(0, Math.min(20, Math.round(Number(value))))
    if (!isFinite(level)) return false
    classicBridge.write("level " + level + "\n")
    return true
  }

  function setAmbientVoice(on) {
    if (!classicLive("sony-v1")) return false
    classicBridge.write("voice " + (on ? "on" : "off") + "\n")
    return true
  }

  function setMultipoint(on) {
    if (!multipointKnown || multipointChanging || !classicLive("sony-v1")) return false
    classicBridge.write("multipoint " + (on ? "on" : "off") + "\n")
    return true
  }

  function setAutoPower(value) {
    var wanted = String(value || "")
    if (!autoPowerKnown || !classicLive("sony-v1")
        || autoPowerOptions.indexOf(wanted) === -1) return false
    classicBridge.write("auto-power " + wanted + "\n")
    return true
  }

  // Warn once per drain. The flag clears with 5 points of hysteresis so a level
  // wobbling across the threshold cannot warn twice.
  function checkLowBattery() {
    if (!notifyLow) return
    if (!connected) {
      setNotifiedLow(false)
      forgetLevelHistory()
      return
    }
    // No number is not a good number: a reader restarting drops the level to -1
    // for a second, and re-arming the warning there would send it twice for one
    // drain. The warning state survives the gap.
    if (level < 0) return

    // Compare like with like, or with nothing at all. A single-battery headset
    // is a third source, not a variety of either: its own figure and BlueZ's
    // rounded one describe the same battery through different instruments, and
    // a reader coming up would otherwise read as a drop from 100 to 90.
    var source = single ? "single" : (perBud ? "bud" : "bluez")
    var previous = source === lastSource ? lastLevel : -1
    lastSource = source
    lastLevel = level

    if (level >= lowThreshold + 5 || charging) setNotifiedLow(false)
    if (charging) return

    // The first level of the session is whatever the shell woke up to. It is a
    // baseline, not an event: earbuds that were already low before the shell
    // started are not news, and a restart must not warn about them again.
    if (!primed) {
      primed = true
      return
    }

    if (level > lowThreshold || notifiedLow) return
    var dropped = previous >= 0 && level < previous
    var firstSinceConnect = previous < 0
    if (!dropped && !firstSinceConnect) return

    setNotifiedLow(true)
    // Sent a turn later, not here. `level` is the lowest earbud, so it changes
    // as soon as one of them does, and reading the pair straight away can catch
    // the other one at its previous value — a warning that says "L 15% · R 40%"
    // when the line that triggered it said 15 and 8.
    Qt.callLater(sendLowBatteryWarning)
  }

  // Through the service, which owns the one notification process: two headsets
  // going flat in the same minute are two notifications, one after the other,
  // rather than one of them lost to a process that was already busy.
  function sendLowBatteryWarning() {
    if (!connected || level < 0 || !service) return
    service.notify(follower.name + ": low battery", Model.lowBatteryBody(follower.summary))
  }

  function forgetLevelHistory() {
    lastSource = ""
    lastLevel = -1
  }

  onLevelChanged: checkLowBattery()
  onChargingChanged: checkLowBattery()
  onLowThresholdChanged: checkLowBattery()

  // A device that this follower has seen sitting disconnected and then watched
  // connect is a real connect, and its first level is worth warning about. A
  // device that was already connected when the shell started merely appears,
  // and `primed` absorbs what it says.
  onConnectedChanged: {
    if (connected && address !== "" && service) service.rememberAddress(address)
    if (connected && sawDisconnected) primed = true
    if (!connected) {
      defaultOffPending = false
      if (hasDevice) sawDisconnected = true
      setNotifiedLow(false)
      forgetLevelHistory()
      reading = ({})
      readingStamp = 0
      readerErrorRaw = ""
      ancState = ({})
      ancAnswered = false
      // What the device serves is only known while it is here to be asked, and a
      // list left behind would keep a bridge armed for a device in its case.
      deviceUuids = []
      codecState = ({ options: [], active: "", activeLabel: "" })
      codecStamp = 0
      codecError = ""
    }
    if (connected) {
      restoreControlState()
      defaultOffPending = true
      probeUuids()
      probeCodecs()
    }
    checkLowBattery()
  }

  onHasDeviceChanged: if (hasDevice && !connected) sawDisconnected = true

  // A follower is built for a device that is connected already, most of the
  // time, and that fires neither handler above — both are changes, and there was
  // no change.
  Component.onCompleted: {
    if (connected && address !== "" && service) service.rememberAddress(address)
    if (connected) {
      restoreControlState()
      defaultOffPending = true
    }
    probeUuids()
    probeCodecs()
    checkLowBattery()
  }
  // A refresh that never lands must not hold the per-earbud rows on screen for
  // ever: after this long the channel is treated as gone and BlueZ's figure
  // takes over again.
  Timer {
    id: refreshGuard
    interval: 12000
    repeat: false
    onTriggered: follower.refreshing = false
  }

  // Lives only while the earbuds are connected and a BLE address is known. It
  // holds an open BLE link, which is not free for the earbuds' battery, so it
  // follows the same lifecycle as the Message Stream reader rather than running
  // forever. The address comes from that reader, so Fast Pair off means no mode
  // control at all.
  // The bridge. Lives only while a device that speaks Sony MDR v1 is connected.
  // Nothing else gates it: the channel is the device's own, so there is no BLE
  // address to wait for, no Fast Pair to depend on and no cache to consult —
  // the SDP UUID already said this device speaks the protocol. The one reason
  // not to run is that this address has already failed for good in this
  // session.
  Process {
    id: classicBridge
    running: follower.classicArmed
    command: follower.classicBridgePath !== ""
      ? [follower.classicBridgePath, follower.address]
      : ["true"]
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { follower.applyAncLine(line) }
    }
    stderr: StdioCollector { id: classicStderr; waitForEnd: true }
    // No bridge, no mode: a link that was killed leaves
    // its last report behind, and a LISTENING MODE row that no longer controls
    // anything is worse than no row.
    onRunningChanged: {
      if (running) {
        follower.ancRunError = ""
        follower.ancErrorRaw = ""
      }
      follower.ancAnswered = false
    }
    onExited: function(exitCode, exitStatus) {
      // The bridge's four exit codes: 0 clean stop · 1 transient, retry
      // with a growing pause · 3 linked but silent to every query type it knows
      // · 4 could not start at all. Both of the last two are about this device
      // rather than about this moment, so the address is parked for the session.
      // Nothing is written to disk: the SDP UUID makes the next session's
      // decision for free, and a headset that gains the feature in a firmware
      // update should not have to argue with a cache.
      //
      // The address is this follower's own, which is why the old service had to
      // remember which one a run was pointed at and this does not.
      // Exit 3 parks (the device answered none of the query types); exit 4 is
      // this machine's problem and backs off instead, message on screen.
      var retryableSonySilence = exitCode === 3 && follower.controlBackend === "sony-v1"
      if (exitCode === 3 && !retryableSonySilence && follower.service)
        follower.service.parkAddress(follower.address)
      // A device that linked and said nothing is not a fault to report.
      if (exitCode === 3 && !retryableSonySilence) {
        follower.ancRunError = ""
        follower.ancErrorRaw = ""
      } else if (retryableSonySilence) {
        follower.ancErrorRaw = "Sony control channel temporarily busy"
      } else if (exitCode !== 0 && follower.ancRunError === "") {
        follower.ancErrorRaw = Model.shortError(classicStderr.text, exitCode === 4
          ? "failed to start mode control"
          : "mode control link lost (exit " + exitCode + ")")
      }

      // Nothing cycles this bridge on purpose: the channel is the device's own
      // and its address is this follower's, so there is no rotated address to
      // follow and no re-aiming to do. Every exit waits out its backoff.
      follower.classicEnabled = false
      classicRestart.interval = follower.service
        ? follower.service.ancBackoffFor(follower.address) : 10000
      if ((exitCode === 1 || exitCode === 4 || retryableSonySilence) && follower.service)
        follower.service.bumpAncBackoff(follower.address)
      classicRestart.restart()
    }
  }

  Timer {
    id: classicRestart
    repeat: false
    onTriggered: follower.classicEnabled = true
  }

  // Reads the device's SDP UUIDs, which is how the backend is chosen. Started by
  // probeUuids() rather than by a `running` binding: this process exits as soon
  // as it has printed, and a binding that is still true at that moment is an
  // invitation to run it again for ever.
  Process {
    id: uuidProbe
    stdout: StdioCollector { id: uuidProbeOut; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A probe that failed says nothing about the device, and an empty list is
      // exactly that: no Sony UUID seen.
      follower.deviceUuids = exitCode === 0
        ? Model.uuidsFromBluetoothctl(uuidProbeOut.text)
        : []
    }
  }

  Process {
    id: codecProbe
    stdout: StdioCollector { id: codecProbeOut; waitForEnd: true }
    stderr: StdioCollector { id: codecProbeErr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0) {
        follower.codecState = Model.bluetoothCodecs(codecProbeOut.text, follower.address)
        follower.codecStamp = Date.now()
        follower.codecError = ""
      } else {
        follower.codecError = Model.shortError(codecProbeErr.text,
          "failed to read codecs")
      }
    }
  }

  Process {
    id: codecSetProcess
    stderr: StdioCollector { id: codecSetErr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0)
        follower.codecError = Model.shortError(codecSetErr.text,
          "failed to switch codec")
      codecSettle.restart()
    }
  }

  // PipeWire rebuilds the sink after a profile change. Let that settle before
  // reading the active profile, otherwise the old selection flashes back.
  Timer {
    id: codecSettle
    interval: 450
    repeat: false
    onTriggered: follower.probeCodecs()
  }
}
