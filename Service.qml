import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import "Model.js" as Model

// Everything about the earbuds that must exist exactly once, and one follower
// per set of earbuds that is connected.
//
// A bar surface exists per monitor, so Panel.qml is built once per screen. Two
// Message Stream readers would fight over the single RFCOMM channel BlueZ hands
// out, two BLE bridges would each hold a link open on the earbuds' radio, and
// one drained battery would produce as many warnings as you have monitors.
// Loaded as a service instead, this runs once for the session; every panel finds
// it with shell.serviceFor("sony-xm4") and only draws what it says.
//
// What it does not do is talk to a device. It used to follow one — the best of
// whatever was paired — and two headsets connected at the same
// time were one widget arguing with itself: the pick moved, the helpers were
// re-aimed, and lines from the reader that had just been killed landed after the
// switch, putting one device's name over the other's levels. So the device half
// moved into DeviceFollower.qml, one instance per connected device, each pinned
// to its address for its lifetime. This file keeps what they share:
//
//   the settings          pushed in by the panel, the same for every device
//   the device list       from BlueZ, which is what followers are made from
//   the Fast Pair reader  one process for every device, because BlueZ hands out
//                         one Message Stream registration per system and not
//                         per device; its lines are routed by the address each
//                         one carries
//   the caches            mode support on disk, parked models and addresses,
//                         the retry backoff, the warned-about flags
//   the notification      one process, one queue, however many headsets
//   the IPC surface       which answers for one device or for all of them
//
// Two sources of battery, in order of what they can say:
//
//   gfps-reader   sits on the Google Fast Pair Message Stream (an RFCOMM
//                 channel these earbuds serve for Android's battery UI) and
//                 reports left, right and case separately, 0-100, with a
//                 charging flag — or one battery for the whole set, on a
//                 headset that has only one. It streams: the device pushes a
//                 new reading when a level changes.
//   BlueZ         org.bluez.Battery1, one number for the whole set, rounded to
//                 ten steps by the HFP indicator it comes from. The fallback
//                 for a device with no Message Stream.
Item {
  id: root

  property var shell: null

  // ---- Settings. The service has no shell.json entry of its own: each panel
  //      instance pushes the widget's settings in with Binding. The values below
  //      are what the service runs on until one does, so a service with no
  //      widget on any bar behaves like a widget with default settings.
  //
  //      These defaults must stay in step with manifest.json's
  //      barWidget.defaults and with the setting() fallbacks in Panel.qml.
  property string deviceMatch: ""
  property bool useFastPair: true
  property bool useModeControl: true
  property bool autoReconnect: true
  property bool autoAudioHandoff: true
  property int audioHandoffDelay: 3
  property int lowThreshold: 20
  property bool notifyLow: true

  // The media service is the state drawn by Omarchy's media widget. Merely
  // observing it does not open an audio stream; Firefox owns the PipeWire
  // stream. A transition to pause is nevertheless the best exact signal that
  // the user is done with that stream, so it drives the delayed A2DP handoff.
  readonly property var mediaService: shell ? shell.firstPartyServiceFor("omarchy.media") : null
  readonly property var activeMediaPlayer: mediaService ? mediaService.activePlayer : null
  readonly property bool localMediaPlaying: activeMediaPlayer ? !!activeMediaPlayer.isPlaying : false
  property bool sawLocalMediaPlayer: false

  onActiveMediaPlayerChanged: {
    if (activeMediaPlayer) sawLocalMediaPlayer = true
    scheduleAudioHandoff()
  }
  onLocalMediaPlayingChanged: {
    if (localMediaPlaying) claimAudioForPlayback()
    else scheduleAudioHandoff()
  }


  // ---- Which devices, from BlueZ.
  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
  // Model.followedAddresses reads connected/battery off each device while this
  // binding evaluates, so it re-runs when any of them changes — not only when a
  // device is added or removed. Every connected match is followed; with nothing
  // connected it names the one device the widget would have picked, so the panel
  // can still say which earbuds it is waiting for.
  readonly property var followedAddresses: Model.followedAddresses(devices, deviceMatch, persisted.lastAddress)

  // ---- The followers, and the order the bar and the panel take them in.
  //
  //      `followers` is creation order, which is whatever order the addresses
  //      turned up in; `followed` is the order a person reads — connected first,
  //      then the set used last, then by name. The panel draws one icon per
  //      entry and the IPC answers for `primary` when nobody said which device.
  property var followers: []
  readonly property var followed: Model.sortFollowers(followers, persisted.lastAddress)
  readonly property var primary: followed.length > 0 ? followed[0] : null

  readonly property string pluginId: "sony-xm4"

  // Which addresses have a follower, as a model rather than as a list, because a
  // list assigned wholesale rebuilds every delegate: a second headset connecting would
  // tear down the first one's reader and bridge and open them again a moment later,
  // which is exactly the mixing this refactor exists to stop. Rows are added and
  // removed one at a time instead, and an untouched row keeps its follower —
  // and with it, its processes.
  ListModel { id: followerRows }

  function syncFollowers() {
    var wanted = followedAddresses
    for (var i = followerRows.count - 1; i >= 0; i--)
      if (wanted.indexOf(followerRows.get(i).deviceAddress) === -1) followerRows.remove(i)
    for (var j = 0; j < wanted.length; j++) {
      var known = false
      for (var k = 0; k < followerRows.count; k++)
        if (followerRows.get(k).deviceAddress === wanted[j]) { known = true; break }
      if (!known) followerRows.append({ deviceAddress: wanted[j] })
    }
  }

  function rebuildFollowers() {
    var list = []
    for (var i = 0; i < followerHost.count; i++) {
      var object = followerHost.objectAt(i)
      if (object) list.push(object)
    }
    followers = list
  }

  onFollowedAddressesChanged: syncFollowers()
  Component.onCompleted: {
    syncFollowers()
    if (activeMediaPlayer) sawLocalMediaPlayer = true
    Qt.callLater(function () {
      root.probeAudioTarget()
      root.scheduleAudioHandoff()
    })
  }

  Instantiator {
    id: followerHost
    model: followerRows
    delegate: DeviceFollower {
      // Taken from the row as a required property rather than off the injected
      // model object: the follower has an `address` of its own, and a role that
      // arrives under the same name is one shadowing away from a follower
      // pointed at nothing.
      required property string deviceAddress

      service: root
      address: deviceAddress
    }
    onObjectAdded: root.rebuildFollowers()
    onObjectRemoved: root.rebuildFollowers()
  }

  // The follower an IPC caller meant. No word means the primary device, which is
  // what every no-argument call answers for; a word that names none of them is
  // null, and each method says so in whatever its own vocabulary is.
  // The address an `openFor` IPC call asked the panel to show. Set, then read by
  // the panel; cleared by nobody — the next request simply overwrites it, and a
  // repeated request for the same address is re-signalled by blanking first.
  property string openRequest: ""

  // "x y w h" of the open popup card in logical screen pixels, written by the
  // panel that is open; "" while none is. Read by tools/gallery-shot.
  property string panelRect: ""

  function followerFor(which) {
    var index = Model.findByWhich(followed, which)
    return index >= 0 ? followed[index] : null
  }

  // ---- Host-side multipoint handoff and reconnection.
  //
  // Sony chooses the active source itself. The only reliable control Linux has
  // without guessing private Sony commands is to disable its own audio profile,
  // which stops the silent PCM stream Firefox may leave behind. The helper
  // resolves the sink by Bluetooth address, never by a user-provided shell
  // fragment, and pactl keeps the Bluetooth ACL/multipoint links intact.
  property var audioTargets: ({})
  property var audioErrors: ({})
  property string hostAudioAddress: ""
  property string hostAudioWanted: ""
  property string hostAudioPrevious: "computer"
  property string hostAudioOutput: ""
  property string audioStatusAddress: ""

  function mappedValue(map, address, fallback) {
    var value = map ? map[String(address || "")] : undefined
    return value === undefined ? fallback : value
  }

  function setMappedValue(map, address, value) {
    var key = String(address || "")
    var next = {}
    for (var name in map) next[name] = map[name]
    if (value === undefined || value === "") delete next[key]
    else next[key] = value
    return next
  }

  function audioTargetFor(follower) {
    return follower ? mappedValue(audioTargets, follower.address, "computer") : "computer"
  }

  function audioErrorFor(follower) {
    return follower ? mappedValue(audioErrors, follower.address, "") : ""
  }

  function audioChangingFor(follower) {
    return !!follower && hostAudioProcess.running && hostAudioAddress === follower.address
  }

  function setAudioTarget(follower, target) {
    var wanted = String(target)
    if (!follower || !follower.connected || ["computer", "other"].indexOf(wanted) === -1)
      return false
    if (hostAudioProcess.running) return false
    hostAudioAddress = follower.address
    hostAudioWanted = wanted
    hostAudioPrevious = audioTargetFor(follower)
    hostAudioOutput = ""
    audioTargets = setMappedValue(audioTargets, follower.address, wanted)
    audioErrors = setMappedValue(audioErrors, follower.address, undefined)
    hostAudioProcess.command = [hostAudioPath,
      wanted === "other" ? "release" : "claim", follower.address]
    hostAudioProcess.running = true
    return true
  }

  function applyHostAudioResult(text) {
    hostAudioOutput = String(text || "").trim()
    var result = null
    try { result = JSON.parse(hostAudioOutput) } catch (error) {}
    if (result && result.ok === true) {
      audioTargets = setMappedValue(audioTargets, hostAudioAddress,
        result.target === "other" ? "other" : "computer")
      audioErrors = setMappedValue(audioErrors, hostAudioAddress, undefined)
    } else {
      var message = result && result.error ? String(result.error) : "Failed to switch audio source"
      audioTargets = setMappedValue(audioTargets, hostAudioAddress, hostAudioPrevious)
      audioErrors = setMappedValue(audioErrors, hostAudioAddress, message)
      if (hostAudioWanted === "computer" && localMediaPlaying)
        audioClaimRetry.restart()
    }
    // Play may have resumed while a release command was in flight. Give it the
    // computer immediately instead of waiting for another MPRIS transition.
    if (localMediaPlaying && mappedValue(audioTargets, hostAudioAddress, "computer") === "other")
      Qt.callLater(claimAudioForPlayback)
  }

  function probeAudioTarget() {
    if (!primary || !primary.connected || audioStatusProcess.running) return
    audioStatusAddress = primary.address
    audioStatusProcess.command = [hostAudioPath, "status", primary.address]
    audioStatusProcess.running = true
  }

  function applyAudioStatus(text) {
    var result = null
    try { result = JSON.parse(String(text || "").trim()) } catch (error) {}
    if (!result || result.ok !== true || audioStatusAddress === "") return
    audioTargets = setMappedValue(audioTargets, audioStatusAddress,
      result.target === "other" ? "other" : "computer")
  }

  function scheduleAudioHandoff() {
    audioHandoffTimer.stop()
    if (!autoAudioHandoff || localMediaPlaying || !sawLocalMediaPlayer) return
    if (!primary || !primary.connected || !primary.multipointEnabled) return
    if (audioTargetFor(primary) !== "computer") return
    audioHandoffTimer.interval = Math.max(1, audioHandoffDelay) * 1000
    audioHandoffTimer.restart()
  }

  function claimAudioForPlayback() {
    audioHandoffTimer.stop()
    if (!autoAudioHandoff || !localMediaPlaying || !primary || !primary.connected) return
    if (audioTargetFor(primary) === "other") setAudioTarget(primary, "computer")
  }

  Timer {
    id: audioHandoffTimer
    repeat: false
    onTriggered: {
      if (!root.localMediaPlaying && root.primary && root.primary.connected
          && root.primary.multipointEnabled)
        root.setAudioTarget(root.primary, "other")
    }
  }

  Timer {
    id: audioClaimRetry
    interval: 4000
    repeat: false
    onTriggered: root.claimAudioForPlayback()
  }

  Timer {
    id: audioStatusDelay
    interval: 800
    repeat: false
    onTriggered: root.probeAudioTarget()
  }

  Connections {
    target: root.primary
    ignoreUnknownSignals: true
    function onConnectedChanged() {
      if (!root.primary) return
      if (!root.primary.connected) {
        root.audioTargets = root.setMappedValue(
          root.audioTargets, root.primary.address, "computer")
        audioHandoffTimer.stop()
      } else {
        root.probeAudioTarget()
        root.scheduleAudioHandoff()
      }
    }
    function onMultipointEnabledChanged() { root.scheduleAudioHandoff() }
  }

  onAutoAudioHandoffChanged: scheduleAudioHandoff()
  onAudioHandoffDelayChanged: scheduleAudioHandoff()
  onPrimaryChanged: {
    probeAudioTarget()
    scheduleAudioHandoff()
  }

  readonly property var reconnectDevice: Model.deviceByAddress(devices, persisted.lastAddress)
  readonly property bool reconnectNeeded: autoReconnect && !!reconnectDevice
    && reconnectDevice.paired === true && reconnectDevice.connected !== true

  Timer {
    interval: 15000
    repeat: true
    triggeredOnStart: true
    running: root.reconnectNeeded
    onTriggered: {
      if (autoReconnectProcess.running || !root.reconnectDevice) return
      autoReconnectProcess.command = ["bluetoothctl", "connect", root.reconnectDevice.address]
      autoReconnectProcess.running = true
    }
  }

  Process { id: autoReconnectProcess }

  Process {
    id: hostAudioProcess
    onExited: audioStatusDelay.restart()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyHostAudioResult(text)
    }
  }


  Process {
    id: audioStatusProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAudioStatus(text)
    }
  }

  // ---- The Fast Pair reader: one process, however many devices.
  //
  //      BlueZ registers an org.bluez.Profile1 per UUID for the whole system
  //      rather than per device, so the second reader to ask is told the UUID
  //      is taken — and with two Fast Pair sets connected, one of them lost its
  //      per-earbud levels. So the reader lives here, holding the one
  //      registration and serving every followed device down one pipe: each
  //      line it writes for a device carries that device's `address`, which is
  //      what routes it to a follower, and a line without one is the process
  //      saying it cannot do the job for any of them.
  //
  //      The mode bridge stays with its follower: a link to one device that
  //      collides with nothing.
  readonly property string readerPath: Qt.resolvedUrl("gfps-reader").toString().replace(/^file:\/\//, "")
  // Resolved here so every follower gets the same absolute path. DeviceFollower
  // used to resolve them itself, and a Process whose command was bound before
  // the UUID probe settled started as QList("", address).
  readonly property string sonyV1BridgePath: Qt.resolvedUrl("sony-v1-bridge").toString().replace(/^file:\/\//, "")
  readonly property string hostAudioPath: Qt.resolvedUrl("host-audio").toString().replace(/^file:\/\//, "")
  // The devices the reader is asked to hold a channel open for. A follower for
  // a device that is not connected is kept so the widget can name what it is
  // waiting for, but it has nothing to open.
  readonly property var readerAddresses: Model.readerAddresses(followed)
  readonly property bool readerRunning: gfpsReader.running
  property bool readerEnabled: true
  property int readerBackoffMs: 8000
  // What the running process has been told to follow, so a device connecting or
  // going away is one line on its stdin rather than a restart: restarting drops
  // the registration, and with it every other device's channel.
  property var readerFollowing: []
  // What the reader last said about itself, as opposed to about a device. Every
  // follower shows it, because a reader that cannot run is every device's
  // problem; `readerRunError` is the same thing kept so an exit can tell a
  // process that explained itself from one that simply died.
  property string readerError: ""
  property string readerRunError: ""

  // One line of the reader's stdout, to whichever follower it is about.
  function applyReaderLine(line) {
    var address = Model.readerLineAddress(line)
    if (address !== "") {
      var follower = followerWithAddress(address)
      if (follower) follower.applyReaderLine(line)
      // A run that got a device's line out is a healthy one; the next failure
      // starts its backoff from the bottom again.
      readerBackoffMs = 8000
      return
    }
    // No address: the line is about the reader itself. `{stream: false, error}`
    // is a failure every device is down with, and a line saying the stream is
    // back is the reader saying that failure is over — nothing else ever would.
    // Anything that parses to neither said nothing about anything.
    var fields = Model.mergeReaderLine({}, line)
    if (fields.stream === undefined) return
    if (fields.stream === false) {
      readerError = String(fields.error || "")
      readerRunError = readerError
    } else {
      readerError = ""
      readerRunError = ""
      readerBackoffMs = 8000
    }
  }

  // The follower an address belongs to. Model.deviceByAddress matches on the
  // `address` property, which a follower carries as surely as a BlueZ device
  // does — and matches it case-insensitively, so a line's address needs no
  // agreement with BlueZ about how to write one.
  function followerWithAddress(address) {
    return Model.deviceByAddress(followers, address)
  }

  // Tell the running reader what changed. Nothing to do when it is not running:
  // the addresses go on its command line, and it follows them at start.
  function syncReader() {
    if (!gfpsReader.running) return
    var wanted = readerAddresses
    var told = readerFollowing
    for (var i = 0; i < told.length; i++)
      if (wanted.indexOf(told[i]) === -1) gfpsReader.write("unfollow " + told[i] + "\n")
    for (var j = 0; j < wanted.length; j++)
      if (told.indexOf(wanted[j]) === -1) gfpsReader.write("follow " + wanted[j] + "\n")
    readerFollowing = wanted.slice()
  }

  onReaderAddressesChanged: syncReader()

  // Ask one device for a fresh reading. True when the request actually went
  // out, because a follower that is told nothing happened must not blank its
  // rows waiting for an answer that is not coming.
  function refreshReader(address) {
    if (!useFastPair) return false
    if (gfpsReader.running && readerFollowing.indexOf(String(address).toUpperCase()) !== -1) {
      gfpsReader.write("refresh " + address + "\n")
      return true
    }
    // Nothing to re-open — the reader is between attempts, or was never allowed
    // to start. Bring the next attempt forward instead of latching it off.
    readerBackoffMs = 8000
    readerRestart.stop()
    readerEnabled = true
    return false
  }

  // The reader takes its addresses from the command line, and `running` and
  // `command` are both bound to readerAddresses. QML does not promise which of
  // the two settles first, and seen live it was `running`: the process launched
  // as QList(readerPath) with no address at all, and readerFollowing was then
  // set from a list the reader never heard. The first device to connect was
  // never followed — drawn as headphones off BlueZ's one figure — while a second one arrived by `follow` on
  // stdin and worked. Armed one event-loop turn later instead, the same as
  // classicArmed in DeviceFollower, so the command has caught up
  // by the time the process starts.
  readonly property bool readerWanted: root.useFastPair && root.readerAddresses.length > 0
    && root.readerEnabled
  property bool readerArmed: false
  onReaderWantedChanged: {
    if (!readerWanted) { readerArmed = false; return }
    Qt.callLater(function () { readerArmed = root.readerWanted })
  }

  Process {
    id: gfpsReader
    running: root.readerArmed
    command: [root.readerPath].concat(root.readerAddresses)
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { root.applyReaderLine(line) }
    }
    stderr: StdioCollector { id: readerStderr; waitForEnd: true }
    // A fresh run starts with a clean slate, the same as the bridges: whatever
    // the run that died complained about is not about this one, and leaving it
    // on screen would read as a live fault while the channels are open.
    onRunningChanged: {
      if (running) {
        root.readerError = ""
        root.readerRunError = ""
        // Started from the command line above, which is the address list as it
        // was when the process started.
        root.readerFollowing = root.readerAddresses.slice()
        for (var i = 0; i < root.followers.length; i++) root.followers[i].clearReaderError()
      } else {
        root.readerFollowing = []
      }
    }
    onExited: function(exitCode, exitStatus) {
      // A clean exit is the reader that was asked to stop — Fast Pair switched
      // off, the last device gone — and it has finished rather than failed.
      // Anything else is a failure that should not be retried tightly.
      var deliberate = exitCode === 0
      // A helper that died without saying why on stdout still said something on
      // stderr — a missing python module, most often, which is worth printing
      // rather than leaving the panel to shrug.
      if (!deliberate && root.readerRunError === "")
        root.readerError = Model.shortError(readerStderr.text,
          "the Fast Pair reader stopped (exit " + exitCode + ")")
      root.readerEnabled = false
      readerRestart.interval = deliberate ? 600 : root.readerBackoffMs
      // Doubling up to five minutes: the usual reasons a reader dies are the
      // earbuds dropping the channel and another program holding the Message
      // Stream, and neither is fixed by asking again straight away.
      if (!deliberate) root.readerBackoffMs = Math.min(300000, root.readerBackoffMs * 2)
      readerRestart.restart()
    }
  }

  Timer {
    id: readerRestart
    repeat: false
    onTriggered: root.readerEnabled = true
  }

  // ---- Caches the followers share, because they outlive any one of them.
  //
  // Addresses whose Sony bridge failed for good this session.
  property var sonyParked: ({})
  // How long to wait before the next attempt, keyed by Classic address: a
  // device that is out of reach must not be dialled every ten seconds all
  // afternoon.
  property var ancBackoff: ({})

  function ancBackoffFor(key) {
    var value = ancBackoff[String(key)]
    return typeof value === "number" && value > 0 ? value : 10000
  }

  function bumpAncBackoff(key) {
    var next = {}
    for (var name in ancBackoff) next[name] = ancBackoff[name]
    next[String(key)] = Math.min(300000, ancBackoffFor(key) * 2)
    ancBackoff = next
  }

  function resetAncBackoff(key) {
    if (ancBackoff[String(key)] === undefined) return
    var next = {}
    for (var name in ancBackoff) next[name] = ancBackoff[name]
    delete next[String(key)]
    ancBackoff = next
  }

  function parkAddress(value) {
    if (String(value || "") === "") return
    var next = {}
    for (var key in sonyParked) next[key] = sonyParked[key]
    next[String(value)] = true
    sonyParked = next
  }

  function unparkAddress(value) {
    var wanted = String(value || "")
    if (wanted === "" || sonyParked[wanted] !== true) return
    var next = {}
    for (var key in sonyParked)
      if (key !== wanted) next[key] = sonyParked[key]
    sonyParked = next
  }

  // Last device-authored control snapshot. Sony permits only one owner of its
  // vendor channel, so Sound Connect on the second multipoint host can make the
  // live bridge temporarily unavailable. Keeping the last confirmed snapshot
  // prevents the panel from pretending the headset lost its features; callers
  // still use ancLive before any write, so cached state is never written to.
  function cachedControlState(address) {
    var all = persisted.controlState
    if (!all || typeof all !== "object") return ({})
    var value = all[String(address || "")]
    return value && typeof value === "object" ? value : ({})
  }

  function rememberControlState(address, state) {
    var key = String(address || "")
    if (key === "" || !state || state.modes !== true) return
    var snapshot = {}
    var fields = ["modes", "mode", "available", "level", "voice",
      "battery", "multipoint", "multipointChanging",
      "autoPowerOptions", "autoPower"]
    for (var i = 0; i < fields.length; i++)
      if (state[fields[i]] !== undefined) snapshot[fields[i]] = state[fields[i]]
    // A pending switch is not a confirmed device state and must not survive a
    // shell restart as a spinner that can never complete.
    snapshot.multipointChanging = false
    var current = persisted.controlState
    if (!current || typeof current !== "object") current = ({})
    var next = {}
    for (var name in current) next[name] = current[name]
    next[key] = snapshot
    persisted.controlState = next
  }

  // Which devices have been warned about, by address, and remembered across a
  // reload. One flag per address rather than one flag: two headsets draining in
  // the same hour are two warnings, and clearing one must not re-arm the other.
  readonly property var notifiedLow: persisted.notifiedLow

  function setNotifiedLow(address, value) {
    var key = String(address || "")
    if (key === "") return
    var current = persisted.notifiedLow
    if (!current || typeof current !== "object") current = ({})
    if ((current[key] === true) === (value === true)) return
    var next = {}
    for (var name in current) next[name] = current[name]
    if (value) next[key] = true
    else delete next[key]
    persisted.notifiedLow = next
  }

  // The address the widget falls back to while nothing is connected, and the
  // tie-breaker in the ranking. `followedAddresses` is picked with it and every
  // follower's address is read off that list, so writing it from a follower's
  // handler would close a binding loop. Defer the write to the next event-loop
  // turn; the value it records is the same.
  function rememberAddress(value) {
    if (persisted.lastAddress === value) return
    Qt.callLater(function () { persisted.lastAddress = value })
  }

  // ---- The notification, sent for whichever device ran low. One process, and a
  //      queue behind it: a Process that is already running would drop the
  //      second warning, and two flat headsets are two things worth saying.
  property var notifyQueue: []

  function notify(title, body) {
    var next = notifyQueue.slice()
    next.push({ title: String(title), body: String(body) })
    notifyQueue = next
    sendNextNotification()
  }

  function sendNextNotification() {
    if (notifyProcess.running || notifyQueue.length === 0) return
    var pending = notifyQueue[0]
    notifyQueue = notifyQueue.slice(1)
    notifyProcess.command = [
      "omarchy-notification-send",
      "-u", "critical",
      "-g", Model.HEADPHONES_GLYPH,
      pending.title,
      pending.body
    ]
    notifyProcess.running = true
  }

  // ---- The IPC surface, `omarchy-shell sony-xm4 <method>`. It lives here and
  //      not in Panel.qml because a target may be registered once and a bar
  //      surface exists per monitor: two screens would mean two handlers
  //      fighting over the name "sony-xm4". The panel methods go the long way
  //      round through the shell, which finds whichever bar is showing the
  //      widget; everything else is answered from the followers' state, which
  //      is the same state every panel draws.
  //
  //      Each question comes in two forms: the plain one, which answers for the
  //      primary device — the first icon in the bar — and a `…For` one that
  //      takes a trailing `which`, a case-insensitive substring of a name or an
  //      address, and answers for the device that matches. Two names rather than
  //      one optional argument because an IPC function's arity is fixed:
  //      quickshell refuses a call with one argument too few or too many, and a
  //      typed parameter may not carry a default. `status` with no argument is
  //      the exception that needs no `which` at all — it lists every device the
  //      widget follows, one per line.
  IpcHandler {
    target: "sony-xm4"

    function open(): void { if (root.shell) root.shell.summon(root.pluginId) }
    // openFor names the device the panel should show before it opens; the panel
    // watches `openRequest` and moves its selection to that follower.
    function panelRect(): string { return root.panelRect }
    function openFor(which: string): string {
      var follower = root.followerFor(which)
      if (!follower) return "no device matching: " + which
      root.openRequest = ""
      root.openRequest = follower.address
      if (root.shell) root.shell.summon(root.pluginId)
      return "ok"
    }
    function close(): void { if (root.shell) root.shell.hide(root.pluginId) }
    function show(): void { if (root.shell) root.shell.summon(root.pluginId) }
    function hide(): void { if (root.shell) root.shell.hide(root.pluginId) }
    function toggle(): void { if (root.shell) root.shell.toggle(root.pluginId) }

    function refresh(): void { if (root.primary) root.primary.refresh() }
    function refreshFor(which: string): void {
      var follower = root.followerFor(which)
      if (follower) follower.refresh()
    }

    // Every device the widget follows, one line each, so a script can see the
    // whole desk in one call. Nothing followed is the one line the single-device
    // version always printed: there is nothing to enumerate.
    function status(): string {
      var list = root.followed
      if (list.length === 0) return Model.tooltip({ hasDevice: false })
      var lines = []
      for (var i = 0; i < list.length; i++) lines.push(Model.tooltip(list[i].summary))
      return lines.join("\n")
    }
    function statusFor(which: string): string {
      var follower = root.followerFor(which)
      return follower ? Model.tooltip(follower.summary) : root.noSuchDevice(which)
    }

    // The one number the bar carries: the headset's own figure where there is
    // one battery, otherwise the lowest earbud, or BlueZ's rounded single
    // figure when the Message Stream has said nothing.
    function battery(): string { return String(root.primary ? root.primary.level : -1) }
    function batteryFor(which: string): string { return root.levelOf(which, "level") }

    // The device's current BLE address, published only on the Message Stream.
    function bleAddress(): string { return String(root.primary ? root.primary.bleAddress : "") }
    function bleAddressFor(which: string): string {
      var follower = root.followerFor(which)
      return follower ? String(follower.bleAddress) : ""
    }

    // Three answers, and the caller can act on each: a mode to use, "pending"
    // while the bridge is coming up — wait and ask again — and "unsupported"
    // for earbuds this shell cannot ask, where the only way to a mode is to
    // open a link yourself.
    function mode(): string { return root.modeOf(root.primary) }
    function modeFor(which: string): string { return root.modeOf(root.followerFor(which)) }

    // Same three states, one word each: "ok" the frame went out, "busy" the
    // bridge is up but not answering yet, so the same set is worth offering
    // again, and "unavailable" there is no bridge to write through at all — or
    // the device has answered and does not offer this mode, which is a settled
    // no rather than something to try again.
    function setMode(mode: string): string { return root.writeMode(root.primary, mode) }
    function setModeFor(mode: string, which: string): string {
      return root.writeMode(root.followerFor(which), mode)
    }

    // Active host-side Bluetooth codec and the codecs this connection actually
    // offers. Unlike listening mode these are PipeWire profiles, so changing
    // one cannot alter ANC. Labels are accepted by setCodec for convenient IPC.
    function codec(): string { return root.codecOf(root.primary) }
    function codecFor(which: string): string { return root.codecOf(root.followerFor(which)) }
    function codecs(): string { return root.codecsOf(root.primary) }
    function codecsFor(which: string): string { return root.codecsOf(root.followerFor(which)) }
    function setCodec(codec: string): string { return root.writeCodec(root.primary, codec) }
    function setCodecFor(codec: string, which: string): string {
      return root.writeCodec(root.followerFor(which), codec)
    }

    // Host-side source selection for a multipoint headset. "other" disables
    // only this computer's audio profile; "computer" restores A2DP and selects it.
    function audioSource(): string { return root.audioTargetFor(root.primary) }
    function audioSourceFor(which: string): string {
      return root.audioTargetFor(root.followerFor(which))
    }
    function setAudioSource(source: string): string {
      return root.setAudioTarget(root.primary, source) ? "ok" : "unavailable"
    }
    function setAudioSourceFor(source: string, which: string): string {
      return root.setAudioTarget(root.followerFor(which), source) ? "ok" : "unavailable"
    }

    // Sony v1 settings exposed only after the headset itself advertises them.
    function multipoint(): string { return root.multipointOf(root.primary) }
    function multipointFor(which: string): string {
      return root.multipointOf(root.followerFor(which))
    }
    function setMultipoint(on: string): string {
      return root.writeMultipoint(root.primary, on)
    }
    function setMultipointFor(on: string, which: string): string {
      return root.writeMultipoint(root.followerFor(which), on)
    }
    function powerOffSetting(): string { return root.autoPowerOf(root.primary) }
    function powerOffSettingFor(which: string): string {
      return root.autoPowerOf(root.followerFor(which))
    }
    function setPowerOffSetting(value: string): string {
      return root.writeAutoPower(root.primary, value)
    }
    function setPowerOffSettingFor(value: string, which: string): string {
      return root.writeAutoPower(root.followerFor(which), value)
    }

    // The Ambient dial, 0-20. -1 while nothing has said.
    function ambientLevel(): string { return String(root.primary ? root.primary.ambientLevel : -1) }
    function ambientLevelFor(which: string): string { return root.levelOf(which, "ambientLevel") }

    // Sets it, and switches the device to Ambient with it, because the amount is
    // stored only by a set that carries it. "unavailable" for a device with no
    // dial, or no bridge to write through.
    function setAmbientLevel(level: int): string {
      return root.writeAmbientLevel(root.primary, level)
    }
    function setAmbientLevelFor(level: int, which: string): string {
      return root.writeAmbientLevel(root.followerFor(which), level)
    }

    // Focus on Voice, the other half of Ambient. "on" or "off", and empty while
    // the bridge has not answered yet.
    function ambientVoice(): string { return root.voiceOf(root.primary) }
    function ambientVoiceFor(which: string): string { return root.voiceOf(root.followerFor(which)) }

    // Takes the same words a setting does — on/off, true/false, 1/0 — because
    // the shell hands IPC arguments over as strings whatever they look like.
    function setAmbientVoice(on: string): string {
      return root.writeAmbientVoice(root.primary, on)
    }
    function setAmbientVoiceFor(on: string, which: string): string {
      return root.writeAmbientVoice(root.followerFor(which), on)
    }

    // The three components, each -1 when it reports nothing. All three read -1
    // on a headset with one battery for the whole set: it has no left earbud,
    // and `battery` above is where its figure lives.
    function left(): string { return String(root.primary ? root.primary.leftLevel : -1) }
    function leftFor(which: string): string { return root.levelOf(which, "leftLevel") }
    function right(): string { return String(root.primary ? root.primary.rightLevel : -1) }
    function rightFor(which: string): string { return root.levelOf(which, "rightLevel") }
    function batteryCase(): string { return String(root.primary ? root.primary.caseLevel : -1) }
    function batteryCaseFor(which: string): string { return root.levelOf(which, "caseLevel") }

    // Which components say they are charging, for looking into the cases where
    // that is not what you expected. Empty means none of them said so, and
    // "battery" is the whole set on a headset that has only one.
    function charging(): string { return root.chargingOf(root.primary) }
    function chargingFor(which: string): string { return root.chargingOf(root.followerFor(which)) }
  }

  // ---- What the two forms of each method above share, so the pair cannot drift
  //      apart. A null follower is a device nobody could find, and each of these
  //      answers that in the vocabulary its own method already had: an unknown
  //      number is -1, an unreachable mode is "unsupported", a write that never
  //      went out is "unavailable".
  function noSuchDevice(which) {
    return "no device matching: " + String(which)
  }

  function levelOf(which, key) {
    var follower = followerFor(which)
    return String(follower ? follower[key] : -1)
  }

  function modeOf(follower) {
    if (!follower) return "unsupported"
    // A cached Sony state remains a truthful read, but writeMode still requires
    // ancLive and therefore cannot send through a channel we do not own.
    if (follower.ancMode !== "") return follower.ancMode
    if (follower.bridgeRunning) return "pending"
    return "unsupported"
  }

  function writeMode(follower, mode) {
    if (["off", "anc", "wind", "ambient", "talkthru"].indexOf(String(mode)) === -1)
      return "unknown mode: " + mode
    if (!follower) return "unavailable"
    if (follower.setAncMode(mode)) return "ok"
    if (follower.ancLive) return "unavailable"
    return follower.bridgeRunning ? "busy" : "unavailable"
  }

  function codecOf(follower) {
    if (!follower) return ""
    return follower.codecActiveLabel
  }

  function codecsOf(follower) {
    if (!follower) return ""
    var labels = []
    for (var i = 0; i < follower.codecOptions.length; i++)
      labels.push(String(follower.codecOptions[i].label))
    return labels.join(",")
  }

  function writeCodec(follower, codec) {
    if (!follower) return "unavailable"
    return follower.setCodec(codec) ? "ok" : "unavailable"
  }

  function multipointOf(follower) {
    if (!follower || !follower.multipointKnown) return ""
    return follower.multipointEnabled ? "on" : "off"
  }

  function writeMultipoint(follower, on) {
    if (!follower || !follower.multipointKnown) return "unavailable"
    return follower.setMultipoint(Model.asBool(on, false)) ? "ok" : "busy"
  }

  function autoPowerOf(follower) {
    return follower && follower.autoPowerKnown ? follower.autoPower : ""
  }

  function writeAutoPower(follower, value) {
    if (!follower) return "unavailable"
    return follower.setAutoPower(String(value)) ? "ok" : "unavailable"
  }

  function writeAmbientLevel(follower, level) {
    return follower && follower.setAmbientLevel(level) ? "ok" : "unavailable"
  }

  function writeAmbientVoice(follower, on) {
    return follower && follower.setAmbientVoice(Model.asBool(on, false)) ? "ok" : "unavailable"
  }

  function voiceOf(follower) {
    if (!follower || !follower.ambientControls) return ""
    return follower.ambientVoice ? "on" : "off"
  }

  function chargingOf(follower) {
    if (!follower) return ""
    var parts = []
    if (follower.singleCharging) parts.push("battery")
    if (follower.leftCharging) parts.push("left")
    if (follower.rightCharging) parts.push("right")
    if (follower.caseCharging) parts.push("case")
    return parts.join(",")
  }

  PersistentProperties {
    id: persisted
    reloadableId: "sony-xm4"
    // Which devices have already been warned about, keyed by address. It was one
    // boolean while the widget followed one device; an old boolean restored into
    // this reads as an empty map, which costs at most one repeated warning.
    property var notifiedLow: ({})
    property var controlState: ({})
    // Which earbuds to name while nothing is connected, so a widget set to stay
    // visible does not offer to show the battery of a headset you last used in
    // another room.
    property string lastAddress: ""
  }

  Process {
    id: notifyProcess
    onExited: root.sendNextNotification()
  }
}
