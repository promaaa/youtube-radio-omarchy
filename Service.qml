pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick

// Background YouTube audio & live radio player: headless mpv (--no-video) + yt-dlp.
Item {
  id: root

  property var shell
  property var manifest

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "promaa.youtube-radio"
  readonly property string home: Quickshell.env("HOME")
  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-youtube-radio.sock"

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
    for (var i = 0; i < presets.length; i++)
      if (presets[i].id === id) return presets[i]
    return null
  }

  function presetForUrl(url) {
    var s = String(url || "")
    for (var i = 0; i < presets.length; i++) {
      var p = presets[i]
      if (s === p.url || s === p.fallbackUrl || s.indexOf(p.fallbackUrl.split("v=")[1]) !== -1) return p
    }
    return null
  }

  // ------------------------------------------------------------ Settings
  // The scoped plugin shell API exposes no live config, so read shell.json
  // directly and let the watcher keep it fresh.

  property var config: ({})

  FileView {
    path: root.home + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.config = JSON.parse(text()) } catch (e) { root.config = {} } }
  }

  QtObject {
    id: settings

    readonly property var entry: {
      var c = root.config
      var lists = []
      if (c.bar && c.bar.layout)
        for (var s of ["left", "center", "right"])
          if (Array.isArray(c.bar.layout[s])) lists.push(c.bar.layout[s])
      if (Array.isArray(c.plugins)) lists.push(c.plugins)
      for (var l = 0; l < lists.length; l++)
        for (var i = 0; i < lists[l].length; i++)
          if (lists[l][i] && lists[l][i].id === root.pluginId) return lists[l][i]
      return ({})
    }

    readonly property string url: typeof entry.url === "string" ? entry.url : ""
    readonly property bool playing: entry.playing === true
    readonly property bool muted: entry.muted === true
    readonly property real volume: isFinite(Number(entry.volume)) ? Math.max(0, Math.min(100, Number(entry.volume))) : 50
    readonly property string cookiesFile: typeof entry.cookiesFile === "string" ? entry.cookiesFile.trim() : ""
    readonly property string cookiesFromBrowser: typeof entry.cookiesFromBrowser === "string" ? entry.cookiesFromBrowser.trim() : ""
    readonly property var history: {
      var out = []
      var src = Array.isArray(entry.history) ? entry.history : []
      for (var i = 0; i < src.length && out.length < root.historyLimit; i++) {
        var h = src[i]
        if (h && typeof h.url === "string" && h.url !== "")
          out.push({ url: h.url, title: typeof h.title === "string" ? h.title : "" })
      }
      return out
    }
  }

  function persistMany(changes) {
    if (!shell) return
    var next = { id: root.pluginId }
    for (var k in settings.entry) if (k !== "id") next[k] = settings.entry[k]
    for (var c in changes) next[c] = changes[c]
    shell.updateEntryInline(root.pluginId, next)
  }

  function persist(key, value) {
    var changes = {}
    changes[key] = value
    persistMany(changes)
  }

  // ------------------------------------------------------------ Public State

  readonly property bool running: mpvProc.running
  readonly property bool probing: probeProc.running
  readonly property string url: settings.url
  readonly property string cookiesFile: settings.cookiesFile
  readonly property string cookiesFromBrowser: settings.cookiesFromBrowser
  readonly property string cookies: settings.cookiesFile || settings.cookiesFromBrowser

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
  property bool restartPending: false
  property string pendingUrl: ""

  readonly property string status: {
    if (!running) return probing ? "starting" : lastError ? "error" : "stopped"
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
    if (url.slice(-title.length) === title) return // mpv echoing a local filename
    persist("history", historyWith(url, title))
  }

  function fallbackTitle(url) {
    var p = presetForUrl(url)
    if (p) return p.title
    var s = String(url || "")
    return s.charAt(0) === "/" ? s.split("/").pop() : s
  }

  function isPlayableUrl(s) { return /^(https?:\/\/|ytdl:\/\/|\/)/.test(s) }
  function needsProbe(s) { return /^(https?:\/\/|ytdl:\/\/)/.test(s) }

  function normalizeUrl(value) {
    var s = String(value || "").trim()
    return /^[A-Za-z0-9_-]{11}$/.test(s) ? "https://www.youtube.com/watch?v=" + s : s
  }

  // ------------------------------------------------------------ Control

  function buildCommand(url) {
    var cmd = [
      "mpv", "--no-video",
      "--input-ipc-server=" + socketPath,
      "--volume=" + Math.round(settings.volume),
      "--mute=" + (settings.muted ? "yes" : "no"),
      "--ytdl=yes", "--ytdl-format=bestaudio/best",
      "--keep-open=no", "--msg-level=all=warn"
    ]
    if (!isLive) cmd.push("--loop-file=inf")
    var raw = []
    if (settings.cookiesFile) raw.push("cookies=" + settings.cookiesFile)
    if (settings.cookiesFromBrowser) raw.push("cookies-from-browser=" + settings.cookiesFromBrowser)
    if (raw.length) cmd.push("--ytdl-raw-options=" + raw.join(",").replace(/"/g, ""))
    cmd.push(url)
    return cmd
  }

  function playPreset(presetId) {
    var p = presetForId(presetId)
    return p ? start(p.url) : false
  }

  function start(value) {
    var url = normalizeUrl(value || settings.url || presets[0].url)
    if (!isPlayableUrl(url)) {
      lastError = url ? "URL invalide: " + url : "Aucune URL sélectionnée"
      return false
    }
    var p = presetForUrl(url)
    activePresetId = p ? p.id : ""
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
    cleanupProc.running = true
  }

  function launchPending() {
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
  }

  function restart() {
    if (!running) return
    restartPending = true
    stop(false)
  }

  function ipcSend(command) {
    if (!ipcConnected) return false
    ipc.write(JSON.stringify(Array.isArray(command) ? { command: command } : command) + "\n")
    ipc.flush()
    return true
  }

  function setPaused(value) {
    paused = !!value
    ipcSend(["set_property", "pause", paused])
  }

  function togglePause() { setPaused(!paused) }

  function seek(secs, mode) {
    var n = Number(secs)
    if (!isFinite(n) || !loaded || !seekable) return false
    var target = Math.max(0, (mode === "absolute" ? 0 : position) + n)
    if (duration > 0) target = Math.min(duration, target)
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
    else changes.cookiesFromBrowser = v
    persistMany(changes)
    if (running) restart()
    return changes.cookiesFile || changes.cookiesFromBrowser
  }

  // ------------------------------------------------------------ yt-dlp Probe

  property string probeUrl: ""
  property string probeReason: "start"

  function runProbe(url, reason) {
    probeUrl = url
    probeReason = reason
    if (!probeProc.running) probeNow()
  }

  function probeNow() {
    var script = 'out=$(timeout 45 yt-dlp --no-playlist --no-warnings -f "bestaudio/best" '
      + '--print "T:%(title)s" --print "A:%(acodec)s" --print "L:%(is_live)s" '
      + '${2:+--cookies "$2"} ${3:+--cookies-from-browser "$3"} -- "$1" 2>&1); rc=$?; '
      + 'printf "R:%s\\nU:%s\\n%s\\n" "$rc" "$1" "$out"'
    probeProc.command = ["bash", "-c", script, "yt-dlp-probe", probeUrl.replace(/^ytdl:\/\//, ""),
                         settings.cookiesFile, settings.cookiesFromBrowser]
    probeProc.running = true
  }

  Process {
    id: probeProc
    stdout: StdioCollector { onStreamFinished: root.probeFinished(text) }
  }

  function probeFinished(text) {
    var f = { R: "-1", U: "", T: "", A: "", L: "" }, err = ""
    for (var line of String(text || "").split("\n")) {
      if (line.charAt(1) === ":" && line.charAt(0) in f) f[line.charAt(0)] = line.slice(2)
      else if (/^ERROR:/.test(line)) err = line
    }
    if (f.U !== probeUrl.replace(/^ytdl:\/\//, "")) { // stale result; a newer probe was requested
      if (probeUrl) probeNow()
      return
    }
    if (probeReason === "start" && stopRequested) return

    var rc = parseInt(f.R, 10)
    if (rc === 0) {
      title = f.T
      isLive = /^true$/i.test(f.L)
      stream = describeAudioStream(f.A, isLive)
      lastError = ""
      if (probeReason === "start") launch(probeUrl)
      else if (mpvProc.running) ipcSend(["loadfile", probeUrl, "replace"])
      return
    }

    var p = presetForUrl(probeUrl)
    if (p && probeUrl !== p.fallbackUrl) {
      runProbe(p.fallbackUrl, probeReason)
      return
    }
    lastError = probeError(err, rc)
    console.log("youtube-radio: probe failed rc=" + rc + ": " + lastError)
    if (probeReason === "retry") scheduleRetry()
  }

  function describeAudioStream(acodec, live) {
    var a = String(acodec || "")
    var name = /^opus/i.test(a) ? "Opus" : /^(mp4a|aac)/i.test(a) ? "AAC"
      : a && a !== "NA" && a !== "none" ? a.toUpperCase() : ""
    return (live ? "Live · " : "") + "Audio" + (name ? " (" + name + ")" : "")
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

  // Kill any mpv orphaned by a previous shell instance before binding the socket.
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
        if (/error|failed/i.test(s)) root.stderrTail = s
      }
    }
    onStarted: {
      root.stopRequested = false
      root.stderrTail = ""
    }
    onExited: function(exitCode) {
      ipcLoader.active = false
      quitGrace.stop()
      killGrace.stop()
      root.loaded = false
      if (!root.restartPending) {
        root.title = ""
        root.stream = ""
      }
      if (!root.stopRequested && exitCode !== 0 && !root.lastError)
        root.lastError = exitCode === 255 || exitCode === -1
          ? "mpv n'a pas pu démarrer"
          : (root.stderrTail || "mpv s'est arrêté avec le code " + exitCode)
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
    onTriggered: if (mpvProc.running) mpvProc.signal(9)
  }

  Timer {
    interval: 30000
    running: mpvProc.running && !root.ipcConnected && !root.stopRequested
    onTriggered: {
      root.lastError = "mpv n'a pas répondu sur le socket"
      root.stopRequested = true
      mpvProc.signal(9)
    }
  }

  // Resume where the last shell instance left off, once our shell.json entry is known.
  // Deferred: inside onConfigChanged the settings.* bindings have not re-evaluated yet.
  property bool restored: false
  onConfigChanged: Qt.callLater(function() {
    if (restored || !settings.entry.id) return
    restored = true
    if (settings.playing && settings.url) start(settings.url)
  })

  Component.onDestruction: if (mpvProc.running) mpvProc.signal(9)

  // ------------------------------------------------------------ MPV IPC
  // The socket is recreated on every attempt: a Quickshell Socket does not retry
  // after a failed connect, and mpv only creates the socket once it is up.

  Loader {
    id: ipcLoader
    active: false
    onLoaded: if (item.connected) root.ipcSubscribe(item)
    sourceComponent: Socket {
      id: sock
      property bool subscribed: false
      path: root.socketPath
      connected: true
      parser: SplitParser {
        onRead: function(line) {
          try { root.handleIpc(JSON.parse(line)) } catch (e) {}
        }
      }
      onConnectionStateChanged: if (connected) root.ipcSubscribe(sock)
    }
  }

  readonly property var ipc: ipcLoader.item
  readonly property bool ipcConnected: ipc ? ipc.connected === true : false

  function ipcSubscribe(socket) {
    if (socket.subscribed) return
    socket.subscribed = true
    var props = ["pause", "mute", "volume", "media-title", "duration", "seekable"]
    for (var i = 0; i < props.length; i++)
      socket.write(JSON.stringify({ command: ["observe_property", i + 1, props[i]] }) + "\n")
    socket.flush()
  }

  Timer {
    interval: 400
    repeat: true
    running: mpvProc.running && !root.ipcConnected && !root.stopRequested
    onTriggered: { ipcLoader.active = false; ipcLoader.active = true }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.loaded && root.seekable && !root.paused
    onTriggered: root.pollPosition()
  }

  function handleIpc(msg) {
    if (!msg) return
    if (msg.event === "property-change") {
      var d = msg.data
      switch (msg.name) {
        case "pause": paused = d === true; break
        case "mute": muted = d === true; break
        case "volume": if (isFinite(Number(d))) volume = Number(d); break
        case "duration": duration = Number(d) > 0 ? Number(d) : 0; break
        case "seekable": seekable = d === true; break
        case "media-title":
          if (typeof d === "string" && d !== "") {
            title = d
            if (loaded) refreshHistoryTitle(activeUrl, title)
          }
      }
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
      if (root.needsProbe(root.activeUrl)) root.runProbe(root.activeUrl, "retry")
      else root.ipcSend(["loadfile", root.activeUrl, "replace"])
    }
  }

  // ------------------------------------------------------------ CLI (IPC)
  // omarchy-shell youtube-radio <verb> [arg]

  IpcHandler {
    target: "youtube-radio"

    function play(url: string): string { return root.start(url) ? "ok" : root.lastError }
    function preset(name: string): string { return root.playPreset(name) ? "ok" : "preset not found (use: everpop, lofigirl)" }
    function stop(): string { root.stop(); return "ok" }
    function toggle(): string { root.toggle(); return root.running ? "stopping" : "starting" }

    function pause(value: string): string {
      if (value === "true" || value === "false") root.setPaused(value === "true")
      else if (value === "toggle") root.togglePause()
      else if (value !== "get") return "usage: pause get|true|false|toggle"
      return String(root.paused)
    }

    function mute(value: string): string {
      if (value === "true" || value === "false") root.setMuted(value === "true")
      else if (value === "toggle") root.setMuted(!root.muted)
      else if (value !== "get") return "usage: mute get|true|false|toggle"
      return String(root.muted)
    }

    function volume(value: string): string {
      if (value !== "get") {
        if (!isFinite(Number(value))) return "usage: volume get|<0-100>"
        root.setVolume(Number(value))
      }
      return String(Math.round(root.volume))
    }

    function seek(value: string): string {
      var v = String(value).trim()
      if (v !== "get") {
        if (v === "" || !isFinite(Number(v))) return "usage: seek get|+<secs>|-<secs>|<secs>"
        if (!root.seek(Number(v), /^[+-]/.test(v) ? "relative" : "absolute"))
          return root.running ? (root.seekable ? "not loaded" : "not seekable") : "not running"
      }
      return Math.round(root.position) + "/" + Math.round(root.duration)
    }

    function url(value: string): string {
      return value === "get" ? root.url : root.start(value) ? "ok" : root.lastError
    }

    function cookies(value: string): string {
      return value === "get" ? root.cookies : root.setCookies(value)
    }

    function history(value: string): string {
      if (value === "clear") { root.persist("history", []); return "ok" }
      return value === "get" ? JSON.stringify(root.history) : "usage: history get|clear"
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
