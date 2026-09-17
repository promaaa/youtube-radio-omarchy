pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick

// Lightweight background YouTube audio & live radio player for Omarchy.
// Uses headless mpv (--no-video) with yt-dlp to stream audio with minimal CPU/RAM.
Item {
  id: root

  property var shell
  property var manifest

  readonly property string pluginId:
    manifest && manifest.id ? String(manifest.id) : "promaa.youtube-radio"

  readonly property string home: Quickshell.env("HOME")
  readonly property string runtimeDir: {
    var dir = Quickshell.env("XDG_RUNTIME_DIR")
    return dir ? String(dir) : "/tmp"
  }
  readonly property string socketPath: runtimeDir + "/omarchy-youtube-radio.sock"

  // ------------------------------------------------------------ Presets

  readonly property var presets: [
    {
      id: "everpop",
      title: "EverPop 7080 Pop Radio",
      shortTitle: "EverPop 7080",
      icon: "󰎈",
      url: "https://www.youtube.com/channel/UCuhbvx36nseQJnvHQ02XDWw/live",
      fallbackUrl: "https://www.youtube.com/watch?v=D4H7ItMDIGU"
    },
    {
      id: "lofigirl",
      title: "Lofi Girl (Live Radio)",
      shortTitle: "Lofi Girl",
      icon: "󰠃",
      url: "https://www.youtube.com/@LofiGirl/live",
      fallbackUrl: "https://www.youtube.com/watch?v=jfKfPfyJRdk"
    }
  ]

  function presetForId(id) {
    for (var i = 0; i < presets.length; i++) {
      if (presets[i].id === id) return presets[i]
    }
    return null
  }

  function presetForUrl(targetUrl) {
    if (!targetUrl) return null
    for (var i = 0; i < presets.length; i++) {
      var p = presets[i]
      if (p.url === targetUrl || (p.fallbackUrl && p.fallbackUrl === targetUrl)) return p
      // Also match channel or video ids
      if (targetUrl.indexOf("UCuhbvx36nseQJnvHQ02XDWw") !== -1 || targetUrl.indexOf("D4H7ItMDIGU") !== -1) {
        if (p.id === "everpop") return p
      }
      if (targetUrl.indexOf("@LofiGirl") !== -1 || targetUrl.indexOf("jfKfPfyJRdk") !== -1) {
        if (p.id === "lofigirl") return p
      }
    }
    return null
  }

  // ------------------------------------------------------------ Settings

  FileView {
    id: userShellConfig
    path: root.home + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.settingsRevision++
  }
  property int settingsRevision: 0

  QtObject {
    id: settings

    readonly property var entry: {
      var revision = root.settingsRevision
      var config = null
      if (root.shell && root.shell.shellConfig) {
        config = root.shell.shellConfig
      } else {
        try {
          config = JSON.parse(String(userShellConfig.text() || "{}"))
        } catch (e) {
          config = null
        }
      }
      if (!config) return ({})
      var lists = []
      if (config.bar && config.bar.layout) {
        var sections = ["left", "center", "right"]
        for (var s = 0; s < sections.length; s++)
          if (Array.isArray(config.bar.layout[sections[s]])) lists.push(config.bar.layout[sections[s]])
      }
      if (Array.isArray(config.plugins)) lists.push(config.plugins)
      for (var l = 0; l < lists.length; l++)
        for (var i = 0; i < lists[l].length; i++)
          if (lists[l][i] && String(lists[l][i].id) === root.pluginId) return lists[l][i]
      return ({})
    }

    readonly property string url: typeof entry.url === "string" ? entry.url : ""
    readonly property bool playing: entry.playing === true
    readonly property bool muted: entry.muted === true
    readonly property real volume: isFinite(Number(entry.volume)) ? Math.max(0, Math.min(100, Number(entry.volume))) : 50
    readonly property string cookiesFile: typeof entry.cookiesFile === "string" ? entry.cookiesFile.trim() : ""
    readonly property string cookiesFromBrowser: typeof entry.cookiesFromBrowser === "string" ? entry.cookiesFromBrowser.trim() : ""
    readonly property var history: {
      if (!Array.isArray(entry.history)) return []
      var out = []
      for (var i = 0; i < entry.history.length && out.length < root.historyLimit; i++) {
        var h = entry.history[i]
        if (!h || typeof h.url !== "string" || h.url === "") continue
        out.push({ url: h.url, title: typeof h.title === "string" ? h.title : "" })
      }
      return out
    }
  }

  function persistMany(changes) {
    if (!shell || typeof shell.updateEntryInline !== "function") return false
    var next = { id: root.pluginId }
    for (var k in settings.entry)
      if (k !== "id") next[k] = settings.entry[k]
    for (var c in changes) next[c] = changes[c]
    shell.updateEntryInline(root.pluginId, next)
    return true
  }

  function persist(key, value) {
    var changes = {}
    changes[key] = value
    persistMany(changes)
    return value
  }

  // ------------------------------------------------------------ Public State

  readonly property bool running: mpvProc.running
  readonly property bool probing: probeProc.running
  readonly property string url: settings.url
  readonly property string cookiesFile: settings.cookiesFile
  readonly property string cookiesFromBrowser: settings.cookiesFromBrowser
  readonly property string cookies: settings.cookiesFile !== "" ? settings.cookiesFile : settings.cookiesFromBrowser

  property bool paused: false
  property bool muted: settings.muted
  property real volume: settings.volume
  property string title: ""
  property real position: 0
  property real duration: 0
  property bool seekable: false
  property bool isLive: false
  property string stream: ""
  property string activeUrl: ""
  property string activePresetId: ""
  property string lastError: ""
  property string stderrTail: ""
  property bool stopRequested: false
  property bool loaded: false

  readonly property string status: {
    if (!running) {
      if (probing) return "starting"
      return lastError ? "error" : "stopped"
    }
    if (lastError && !loaded) return "error"
    if (!ipcConnected || !loaded) return "starting"
    return paused ? "paused" : "playing"
  }

  readonly property int historyLimit: 10
  readonly property var history: settings.history

  function historyWith(url, title) {
    var next = [{ url: url, title: String(title || "") }]
    var old = settings.history
    for (var i = 0; i < old.length && next.length < historyLimit; i++)
      if (old[i].url !== url) next.push(old[i])
    return JSON.stringify(next) === JSON.stringify(old) ? null : next
  }

  function refreshHistoryTitle(url, title) {
    var old = settings.history
    if (!url || !title || !old.length || old[0].url !== url || old[0].title === title) return
    if (url.slice(-title.length) === title) return
    persist("history", historyWith(url, title))
  }

  function clearHistory() {
    persist("history", [])
  }

  function fallbackTitle(url) {
    var p = presetForUrl(url)
    if (p) return p.title
    var s = String(url || "")
    if (/^\//.test(s)) return s.split("/").pop()
    return s
  }

  function isPlayableUrl(value) {
    var s = String(value || "").trim()
    return /^(https?:\/\/|ytdl:\/\/|\/)/.test(s)
  }

  function needsProbe(value) {
    return /^(https?:\/\/|ytdl:\/\/)/.test(String(value || ""))
  }

  function normalizeUrl(value) {
    var s = String(value || "").trim()
    if (/^[A-Za-z0-9_-]{11}$/.test(s)) return "https://www.youtube.com/watch?v=" + s
    return s
  }

  // ------------------------------------------------------------ Control

  function buildCommand(url) {
    var cmd = [
      "mpv",
      "--no-video",
      "--input-ipc-server=" + socketPath,
      "--volume=" + Math.round(settings.volume),
      "--mute=" + (settings.muted ? "yes" : "no"),
      "--ytdl=yes",
      "--ytdl-format=bestaudio/best",
      "--keep-open=no",
      "--msg-level=all=warn"
    ]
    if (!root.isLive) cmd.push("--loop-file=inf")
    var raw = []
    if (settings.cookiesFile !== "") raw.push("cookies=" + settings.cookiesFile)
    if (settings.cookiesFromBrowser !== "") raw.push("cookies-from-browser=" + settings.cookiesFromBrowser)
    if (raw.length) cmd.push("--ytdl-raw-options=" + raw.join(",").replace(/"/g, ""))
    cmd.push(url)
    return cmd
  }

  property string pendingUrl: ""

  function playPreset(presetId) {
    var p = presetForId(presetId)
    if (!p) return false
    activePresetId = p.id
    return start(p.url)
  }

  function start(value) {
    var url = normalizeUrl(value || settings.url || presets[0].url)
    if (!isPlayableUrl(url)) {
      lastError = url ? "URL invalide: " + url : "Aucune URL sélectionnée"
      return false
    }

    var matchedPreset = presetForUrl(url)
    activePresetId = matchedPreset ? matchedPreset.id : ""

    lastError = ""
    stopRequested = false
    retryTimer.stop()
    retries = 0

    if (needsProbe(url)) {
      runProbe(url, "start")
      return true
    }
    title = ""
    stream = ""
    launch(url)
    return true
  }

  function launch(url) {
    pendingUrl = url
    var changes = {}
    if (url !== settings.url || !settings.playing) {
      changes.url = url
      changes.playing = true
    }
    var hist = historyWith(url, title || fallbackTitle(url))
    if (hist) changes.history = hist
    if (Object.keys(changes).length) persistMany(changes)

    if (mpvProc.running) {
      activeUrl = url
      loaded = false
      ipcSend(["loadfile", url, "replace"])
      if (paused) setPaused(false)
      return
    }
    if (!cleanupProc.running) cleanupProc.running = true
  }

  function launchPending() {
    console.log("youtube-radio: launchPending url=" + pendingUrl + " running=" + mpvProc.running)
    if (!pendingUrl || mpvProc.running) return
    activeUrl = pendingUrl
    loaded = false
    mpvProc.command = buildCommand(pendingUrl)
    mpvProc.running = true
  }

  function stop(persistState) {
    if (persistState !== false && settings.playing) persist("playing", false)
    stopRequested = true
    lastError = ""
    retryTimer.stop()
    if (mpvProc.running) {
      ipcSend(["quit"])
      quitGrace.restart()
    }
  }

  function toggle() {
    if (running) stop()
    else start()
    return running
  }

  function ipcSend(command) {
    if (!ipcConnected) return false
    var msg = Array.isArray(command) ? { command: command } : command
    ipc.write(JSON.stringify(msg) + "\n")
    ipc.flush()
    return true
  }

  function setPaused(value) {
    paused = !!value
    ipcSend(["set_property", "pause", paused])
  }

  function togglePause() {
    setPaused(!paused)
  }

  function seek(secs, mode) {
    var n = Number(secs)
    if (!isFinite(n) || !running || !loaded || !seekable) return false
    mode = mode === "absolute" ? "absolute" : "relative"
    var target = mode === "absolute" ? n : position + n
    if (duration > 0) target = Math.max(0, Math.min(duration, target))
    else target = Math.max(0, target)
    if (!ipcSend(["seek", target, "absolute"])) return false
    position = target
    pollPosition()
    return true
  }

  function pollPosition() {
    ipcSend({ command: ["get_property", "time-pos"], request_id: 1001 })
  }

  function setMuted(value) {
    muted = !!value
    persist("muted", muted)
    ipcSend(["set_property", "mute", muted])
  }

  function setVolume(value) {
    var v = Math.max(0, Math.min(100, Math.round(Number(value))))
    if (!isFinite(v)) return
    volume = v
    persist("volume", v)
    ipcSend(["set_property", "volume", v])
  }

  function setCookies(value) {
    var v = String(value || "").trim()
    var changes = { cookiesFile: "", cookiesFromBrowser: "" }
    if (/^[~\/]/.test(v)) changes.cookiesFile = v.replace(/^~(?=\/|$)/, home)
    else if (v !== "") changes.cookiesFromBrowser = v
    persistMany(changes)
    if (running) restart()
    return changes.cookiesFile || changes.cookiesFromBrowser
  }

  function restart() {
    if (!running) return
    restartPending = true
    stop(false)
  }
  property bool restartPending: false

  // ------------------------------------------------------------ yt-dlp Probe

  property string probeUrl: ""
  property string probeReason: "start"

  function runProbe(url, reason) {
    probeUrl = url
    probeReason = reason
    if (probeProc.running) return
    probeNow()
  }

  function probeNow() {
    var target = probeUrl.replace(/^ytdl:\/\//, "")
    var script = 'out=$(timeout 45 yt-dlp --no-playlist --no-warnings -f "bestaudio/best" '
      + '--print "T:%(title)s" --print "A:%(acodec)s" --print "L:%(is_live)s" '
      + '${2:+--cookies "$2"} ${3:+--cookies-from-browser "$3"} -- "$1" 2>&1); rc=$?; '
      + 'printf "R:%s\\nU:%s\\n%s\\n" "$rc" "$1" "$out"'
    probeProc.command = ["bash", "-c", script, "yt-dlp-probe", target,
                         settings.cookiesFile, settings.cookiesFromBrowser]
    probeProc.running = true
  }

  Process {
    id: probeProc
    stdout: StdioCollector {
      onStreamFinished: root.probeFinished(text)
    }
  }

  function probeFinished(text) {
    var rc = -1, url = "", title = "", acodec = "", isLiveStr = "", err = ""
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("R:") === 0) rc = parseInt(line.slice(2), 10)
      else if (line.indexOf("U:") === 0) url = line.slice(2)
      else if (line.indexOf("T:") === 0) title = line.slice(2)
      else if (line.indexOf("A:") === 0) acodec = line.slice(2)
      else if (line.indexOf("L:") === 0) isLiveStr = line.slice(2)
      else if (/^ERROR:/.test(line)) err = line
    }
    var target = probeUrl.replace(/^ytdl:\/\//, "")
    if (url !== target) {
      if (probeUrl) probeNow()
      return
    }
    if (probeReason === "start" && stopRequested) return

    if (rc === 0) {
      root.title = title
      root.isLive = isLiveStr === "True" || isLiveStr === "true"
      root.stream = describeAudioStream(acodec, root.isLive)
      lastError = ""
      console.log("youtube-radio: resolved " + probeUrl + " as " + root.stream + " (live=" + root.isLive + ")")
      if (probeReason === "start") launch(probeUrl)
      else if (mpvProc.running) ipcSend(["loadfile", probeUrl, "replace"])
      return
    }

    // Try fallback URL if preset
    var p = presetForUrl(probeUrl)
    if (p && p.fallbackUrl && probeUrl !== p.fallbackUrl) {
      console.log("youtube-radio: primary url failed, trying fallback: " + p.fallbackUrl)
      runProbe(p.fallbackUrl, probeReason)
      return
    }

    lastError = probeError(err, rc)
    console.log("youtube-radio: probe failed rc=" + rc + ": " + lastError)
    if (probeReason === "retry") scheduleRetry()
  }

  function describeAudioStream(acodec, isLive) {
    var prefix = isLive ? "Live · " : ""
    var a = String(acodec || "").trim()
    if (a && a !== "NA" && a !== "none") {
      var aName = /^opus/i.test(a) ? "Opus"
        : /^mp4a/i.test(a) || /^aac/i.test(a) ? "AAC"
        : a.toUpperCase()
      return prefix + "Audio (" + aName + ")"
    }
    return prefix + "Audio"
  }

  function probeError(err, rc) {
    if (rc === 124) return "yt-dlp a expiré en résolvant le flux audio"
    if (rc === 127 || /command not found/.test(err)) return "yt-dlp n'est pas installé"
    var s = String(err || "")
      .replace(/^ERROR:\s*/, "")
      .replace(/^\[[^\]]+\]\s*/, "")
      .replace(/^[A-Za-z0-9_-]{11}:\s*/, "")
    s = s.split(/\.?\s+Use --cookies/)[0].split(/\s+See\s+https?:/)[0].trim()
    if (/not a bot|sign in|login required|age/i.test(s))
      s += ". YouTube demande une session connectée (Cookies dans le panneau)"
    return s || "Échec yt-dlp (code " + rc + ")"
  }

  // ------------------------------------------------------------ Processes

  Process {
    id: cleanupProc
    command: ["pkill", "-9", "-f", "input-ipc-server=" + root.socketPath]
    onExited: root.launchPending()
  }

  Process {
    id: mpvProc
    stderr: SplitParser {
      onRead: function(line) {
        var s = String(line || "").trim()
        if (!s) return
        console.log("youtube-radio: " + s)
        if (/error|failed|ERROR/i.test(s)) root.stderrTail = s
      }
    }
    onStarted: {
      root.stopRequested = false
      root.stderrTail = ""
      reconnect.restart()
    }
    onExited: function(exitCode, exitStatus) {
      console.log("youtube-radio: mpv exited code=" + exitCode + " stopRequested=" + root.stopRequested)
      root.ipcDisconnect()
      quitGrace.stop()
      killGrace.stop()
      root.loaded = false
      if (!root.restartPending) {
        root.title = ""
        root.stream = ""
      }
      if (!root.stopRequested && exitCode !== 0) {
        if (!root.lastError)
          root.lastError = exitCode === 255 || exitCode === -1
            ? "mpv n'a pas pu démarrer"
            : (root.stderrTail || "mpv s'est arrêté avec le code " + exitCode)
      }
      if (root.restartPending) {
        root.restartPending = false
        root.pendingUrl = root.activeUrl
        Qt.callLater(root.launchPending)
      }
    }
  }

  Timer {
    id: quitGrace
    interval: 1500
    onTriggered: if (mpvProc.running) { mpvProc.signal(15); killGrace.restart() }
  }

  Timer {
    id: killGrace
    interval: 1500
    onTriggered: if (mpvProc.running) {
      console.log("youtube-radio: sending SIGKILL to mpv")
      mpvProc.signal(9)
    }
  }

  Timer {
    id: startWatchdog
    interval: 30000
    running: mpvProc.running && !root.ipcConnected && !root.stopRequested
    onTriggered: {
      root.lastError = "mpv n'a pas répondu sur le socket"
      root.stopRequested = true
      mpvProc.signal(9)
    }
  }

  property bool restored: false

  function restoreIfNeeded() {
    if (restored || !settings.entry || settings.entry.id !== root.pluginId) return
    restored = true
    console.log("youtube-radio: restore playing=" + settings.playing + " url=" + settings.url)
    pendingUrl = ""
    if (!cleanupProc.running) cleanupProc.running = true
    if (settings.playing && settings.url) start(settings.url)
  }

  onSettingsRevisionChanged: restoreIfNeeded()
  onShellChanged: restoreIfNeeded()
  Component.onCompleted: restoreIfNeeded()

  Timer {
    interval: 3000
    running: !root.restored
    onTriggered: if (!root.restored) { root.restored = true; cleanupProc.running = true }
  }

  Component.onDestruction: {
    if (mpvProc.running) mpvProc.signal(9)
  }

  // ------------------------------------------------------------ MPV IPC

  Loader {
    id: ipcLoader
    active: false
    onLoaded: if (item && item.connected) root.ipcSubscribe(item)
    sourceComponent: Socket {
      id: sock
      property bool subscribed: false
      path: root.socketPath
      connected: true
      parser: SplitParser {
        onRead: function(line) {
          var s = String(line || "").trim()
          if (!s) return
          var msg
          try { msg = JSON.parse(s) } catch (e) { return }
          root.handleIpc(msg)
        }
      }
      onConnectionStateChanged: {
        if (connected) root.ipcSubscribe(sock)
        else root.ipcLost()
      }
      onError: function(err) { root.ipcLost() }
    }
  }

  readonly property var ipc: ipcLoader.item
  readonly property bool ipcConnected: ipc ? ipc.connected === true : false

  function ipcSubscribe(socket) {
    if (!socket || socket.subscribed || !socket.connected) return
    socket.subscribed = true
    var props = ["pause", "mute", "volume", "media-title", "duration", "seekable"]
    for (var i = 0; i < props.length; i++)
      socket.write(JSON.stringify({ command: ["observe_property", i + 1, props[i]] }) + "\n")
    socket.write(JSON.stringify({ command: ["get_property", "pause"] }) + "\n")
    socket.flush()
  }

  function ipcConnect() {
    ipcLoader.active = false
    ipcLoader.active = true
  }

  function ipcDisconnect() {
    ipcLoader.active = false
  }

  function ipcLost() {
    if (mpvProc.running && !stopRequested) reconnect.restart()
  }

  Timer {
    id: reconnect
    interval: 400
    onTriggered: {
      if (!mpvProc.running || root.stopRequested || root.ipcConnected) return
      root.ipcConnect()
    }
  }

  Timer {
    interval: 2000
    repeat: true
    running: mpvProc.running && !root.ipcConnected && !reconnect.running
    onTriggered: reconnect.restart()
  }

  Timer {
    interval: 1000
    repeat: true
    running: mpvProc.running && root.ipcConnected && root.loaded && !root.paused
    onTriggered: root.pollPosition()
  }

  function handleIpc(msg) {
    if (!msg) return
    if (msg.event === "property-change") {
      if (msg.name === "pause") paused = msg.data === true
      else if (msg.name === "mute") muted = msg.data === true
      else if (msg.name === "volume" && isFinite(Number(msg.data))) volume = Number(msg.data)
      else if (msg.name === "media-title" && typeof msg.data === "string" && msg.data !== "") {
        title = msg.data
        if (loaded) refreshHistoryTitle(activeUrl, title)
      }
      else if (msg.name === "duration") duration = isFinite(Number(msg.data)) && Number(msg.data) > 0 ? Number(msg.data) : 0
      else if (msg.name === "seekable") seekable = msg.data === true
    } else if (msg.request_id === 1001) {
      if (msg.error === "success" && isFinite(Number(msg.data))) position = Number(msg.data)
    } else if (msg.event === "file-loaded") {
      loaded = true
      lastError = ""
      retries = 0
      position = 0
      pollPosition()
      refreshHistoryTitle(activeUrl, title)
    } else if (msg.event === "end-file") {
      position = 0
      duration = 0
      seekable = false
      if (msg.reason === "error") {
        lastError = "Erreur de lecture: " + (msg.file_error || "inconnu")
        loaded = false
        scheduleRetry()
      }
    }
  }

  property int retries: 0
  readonly property int maxRetries: 6

  function scheduleRetry() {
    if (stopRequested || restartPending || !activeUrl) return
    if (retries >= maxRetries) {
      lastError += " (abandon après " + maxRetries + " tentatives)"
      return
    }
    retries += 1
    retryTimer.interval = Math.min(120000, 4000 * Math.pow(2, retries - 1))
    retryTimer.restart()
  }

  Timer {
    id: retryTimer
    onTriggered: {
      if (!mpvProc.running || root.stopRequested) return
      console.log("youtube-radio: retry " + root.retries + " for " + root.activeUrl)
      if (root.needsProbe(root.activeUrl)) root.runProbe(root.activeUrl, "retry")
      else root.ipcSend(["loadfile", root.activeUrl, "replace"])
    }
  }

  // ------------------------------------------------------------ CLI (IPC)

  // omarchy-shell youtube-radio <verb> [arg]
  IpcHandler {
    target: "youtube-radio"

    function play(url: string): string {
      return root.start(url) ? "ok" : root.lastError
    }

    function preset(name: string): string {
      return root.playPreset(name) ? "ok" : "preset not found (use: everpop, lofigirl)"
    }

    function stop(): string {
      root.stop()
      return "ok"
    }

    function toggle(): string {
      root.toggle()
      return root.running ? "stopping" : "starting"
    }

    function pause(value: string): string {
      if (value === "true" || value === "false") root.setPaused(value === "true")
      else if (value === "toggle") root.togglePause()
      else if (value !== "get") return "usage: pause get|true|false|toggle"
      return root.paused ? "true" : "false"
    }

    function mute(value: string): string {
      if (value === "true" || value === "false") root.setMuted(value === "true")
      else if (value === "toggle") root.setMuted(!root.muted)
      else if (value !== "get") return "usage: mute get|true|false|toggle"
      return root.muted ? "true" : "false"
    }

    function volume(value: string): string {
      if (value !== "get") {
        var n = Number(value)
        if (!isFinite(n)) return "usage: volume get|<0-100>"
        root.setVolume(n)
      }
      return String(Math.round(root.volume))
    }

    function seek(value: string): string {
      var v = String(value).trim()
      if (v !== "get") {
        var n = Number(v)
        if (!isFinite(n) || v === "") return "usage: seek get|+<secs>|-<secs>|<secs>"
        if (!root.seek(n, /^[+-]/.test(v) ? "relative" : "absolute"))
          return root.running ? (root.seekable ? "not loaded" : "not seekable") : "not running"
      }
      return Math.round(root.position) + "/" + Math.round(root.duration)
    }

    function url(value: string): string {
      if (value !== "get") return root.start(value) ? "ok" : root.lastError
      return root.url
    }

    function cookies(value: string): string {
      if (value === "get") return root.cookies
      return root.setCookies(value)
    }

    function history(value: string): string {
      if (value === "clear") { root.clearHistory(); return "ok" }
      if (value !== "get") return "usage: history get|clear"
      return JSON.stringify(root.history)
    }

    function status(): string {
      return JSON.stringify({
        status: root.status,
        ipc: root.ipcConnected,
        probing: root.probing,
        url: root.url,
        activePreset: root.activePresetId,
        title: root.title,
        stream: root.stream,
        isLive: root.isLive,
        paused: root.paused,
        muted: root.muted,
        volume: Math.round(root.volume),
        position: Math.round(root.position),
        duration: Math.round(root.duration),
        seekable: root.seekable,
        cookiesFile: root.cookiesFile,
        cookiesFromBrowser: root.cookiesFromBrowser,
        error: root.lastError
      })
    }
  }
}
