import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

// Popout under the bar glyph: Audio presets (EverPop, Lofi Girl), custom URL,
// transport, and volume controls.
Panel {
  id: root
  moduleName: "promaa.youtube-radio"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  readonly property var barIdentity: hostWidget || root
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar && bar.fontFamily ? bar.fontFamily : Style.font.family

  readonly property bool ready: service !== null
  readonly property string status: ready ? service.status : "stopped"
  readonly property bool running: ready && service.running
  readonly property bool paused: ready && service.paused
  readonly property bool muted: ready && service.muted
  readonly property real volume: ready ? service.volume : 0
  readonly property real position: ready ? service.position : 0
  readonly property real duration: ready ? service.duration : 0
  readonly property bool seekable: ready && running && service.seekable && duration > 0
  readonly property string title: ready ? service.title : ""
  readonly property string savedUrl: ready ? service.url : ""
  readonly property string lastError: ready ? service.lastError : ""
  readonly property string stream: ready ? service.stream : ""
  readonly property string cookiesFile: ready ? service.cookies : ""
  readonly property string activePreset: ready ? service.activePresetId : ""
  readonly property var history: ready ? service.history : []
  readonly property var presets: ready ? service.presets : []

  readonly property string statusLabel: {
    if (!ready) return "Service non chargé"
    switch (status) {
      case "playing": return stream !== "" ? "Lecture · " + stream : "En lecture"
      case "paused": return stream !== "" ? "Pause · " + stream : "En pause"
      case "starting": return ready && service.probing ? "Résolution du flux audio…" : "Chargement du direct…"
      case "error": return "Erreur"
      default: return "Arrêté"
    }
  }

  readonly property string statusIcon: {
    switch (status) {
      case "playing": return "󰐊"
      case "paused": return "󰏤"
      case "starting": return "󰦖"
      case "error": return "󰀦"
      default: return "󰓛"
    }
  }

  property bool cursorActive: false
  property string focusSection: "presets"
  property int selectedIndex: 0

  readonly property var sections: {
    var s = ["presets", "transport"]
    if (seekable) s.push("position")
    s.push("volume", "url", "cookies")
    return s
  }
  onSectionsChanged: clampCursor()

  readonly property bool editing: urlField.activeFocus || cookiesField.activeFocus || historyPopup.opened

  function hasCursorOn(section, index) {
    return cursorActive && focusSection === section && selectedIndex === (index || 0)
  }

  function setCursor(section, index) {
    cursorActive = true
    focusSection = section
    selectedIndex = index || 0
  }

  function resetCursor() {
    cursorActive = false
    focusSection = "presets"
    selectedIndex = 0
  }

  function clampCursor() {
    if (sections.indexOf(focusSection) < 0) { focusSection = "presets"; selectedIndex = 0 }
  }

  function moveCursor(delta) {
    if (!cursorActive) { cursorActive = true; return }
    var i = sections.indexOf(focusSection)
    var next = Math.max(0, Math.min(sections.length - 1, i + delta))
    if (next === i) return
    focusSection = sections[next]
    selectedIndex = 0
  }

  function moveCursorH(delta) {
    if (!cursorActive) { cursorActive = true; return }
    if (!ready) return
    switch (focusSection) {
      case "presets": selectedIndex = Math.max(0, Math.min(presets.length - 1, selectedIndex + delta)); break
      case "transport": selectedIndex = Math.max(0, Math.min(2, selectedIndex + delta)); break
      case "position": seekRelative(delta * 5); break
      case "volume": service.setVolume(Math.max(0, Math.min(100, volume + delta * 5))); break
      case "url": selectedIndex = Math.max(0, Math.min(2, selectedIndex + delta)); break
    }
  }

  function activateCursor() {
    if (!ready) return
    switch (focusSection) {
      case "presets": if (presets[selectedIndex]) service.playPreset(presets[selectedIndex].id); break
      case "transport":
        if (selectedIndex === 0 && startButton.enabled) { running ? service.togglePause() : service.start() }
        else if (selectedIndex === 1 && stopButton.enabled) service.stop()
        else if (selectedIndex === 2) service.setMuted(!muted)
        break
      case "position": service.togglePause(); break
      case "volume": service.setMuted(!muted); break
      case "url":
        if (selectedIndex === 1) openHistory()
        else if (selectedIndex === 2) submitUrl()
        else { urlField.forceActiveFocus(); urlField.selectAll() }
        break
      case "cookies": cookiesField.forceActiveFocus(); cookiesField.selectAll(); break
    }
  }

  function seekRelative(secs) {
    if (root.seekable) root.service.seek(secs, "relative")
  }

  // The bar identifies this panel by the widget in its slot (hostWidget), so
  // switchPanel must pass that rather than the base Panel's `root`.
  function switchPanel(direction) {
    return root.bar ? root.bar.switchPanelFrom(root.barIdentity, direction) : false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar) root.bar.setCenterHoverRevealSuppressed(value)
  }

  function open() {
    resetCursor()
    root.controller.show()
    syncField()
    // After show: the popout handoff closes the previous panel, which clears the flag.
    Qt.callLater(function() { if (root.opened) setCenterHoverRevealSuppressed(true) })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function syncField() {
    if (!urlField.activeFocus) urlField.text = root.savedUrl
    if (!cookiesField.activeFocus) cookiesField.text = root.cookiesFile
  }

  onSavedUrlChanged: syncField()
  onCookiesFileChanged: syncField()

  function submitCookies() {
    if (!ready) return
    var value = cookiesField.text.trim()
    if (value === root.cookiesFile) return
    service.setCookies(value)
  }

  function submitUrl() {
    if (!ready) return
    var value = urlField.text.trim()
    if (value === "") return
    service.start(value)
    keyCatcher.forceActiveFocus()
  }

  function openHistory() {
    if (!ready || history.length === 0) return
    setCursor("url", 1)
    historyPopup.open()
  }

  function playHistory(index) {
    var entry = history[index]
    historyPopup.close()
    if (!ready || !entry) return
    urlField.text = entry.url
    service.start(entry.url)
    keyCatcher.forceActiveFocus()
  }

  function formatTime(secs) {
    var t = Math.max(0, Math.round(Number(secs) || 0))
    var h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), sec = t % 60
    var mm = h > 0 && m < 10 ? "0" + m : String(m)
    var ss = sec < 10 ? "0" + sec : String(sec)
    return (h > 0 ? h + ":" : "") + mm + ":" + ss
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.editing) return
        var t = event.text
        event.accepted = true
        if (event.key === Qt.Key_Escape) root.close()
        else if (event.key === Qt.Key_Tab) root.switchPanel(1)
        else if (event.key === Qt.Key_Backtab) root.switchPanel(-1)
        else if (event.key === Qt.Key_Down) root.moveCursor(1)
        else if (event.key === Qt.Key_Up) root.moveCursor(-1)
        else if (event.key === Qt.Key_Right) root.moveCursorH(1)
        else if (event.key === Qt.Key_Left) root.moveCursorH(-1)
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          if (root.cursorActive) root.activateCursor()
          else if (root.ready) { root.running ? root.service.togglePause() : root.service.start() }
        }
        else if (/^[1-9]$/.test(t)) { if (root.presets[t - 1]) root.service.playPreset(root.presets[t - 1].id) }
        else if (t === "l") root.seekRelative(5)
        else if (t === "h") root.seekRelative(-5)
        else if (t === "k") root.seekRelative(60)
        else if (t === "j") root.seekRelative(-60)
        else if (!root.ready) event.accepted = false
        else if (t === "p") { root.running ? root.service.togglePause() : root.service.start() }
        else if (t === "m") root.service.setMuted(!root.muted)
        else if (t === "s") root.service.stop()
        else if (t === "u" || t === "/") { urlField.forceActiveFocus(); urlField.selectAll() }
        else if (t === "r") root.openHistory()
        else event.accepted = false
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // ---- Now playing
        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.statusIcon
            color: root.status === "error" ? (root.bar ? root.bar.urgent : root.fg) : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
            opacity: root.status === "stopped" ? 0.5 : 1.0

            RotationAnimation on rotation {
              running: root.status === "starting"
              from: 0; to: 360
              duration: 1200
              loops: Animation.Infinite
              onRunningChanged: if (!running) heroIcon.rotation = 0
            }
          }

          Column {
            width: parent.width - heroIcon.width - parent.spacing
            spacing: Style.space(2)
            anchors.verticalCenter: parent.verticalCenter

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.title !== "" ? root.title : "YouTube Radio"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.lastError !== "" ? root.lastError : root.statusLabel
              color: root.lastError !== "" && root.bar ? root.bar.urgent : Qt.darker(root.fg, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              maximumLineCount: 2
              wrapMode: Text.WordWrap
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---- Radios en direct (Presets)
        PanelSectionHeader {
          text: "RADIOS EN DIRECT"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Row {
          id: presetRow
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.presets
            Button {
              required property var modelData
              required property int index
              width: (presetRow.width - presetRow.spacing * (root.presets.length - 1)) / root.presets.length
              iconText: modelData.icon
              text: modelData.shortTitle
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              selected: root.activePreset === modelData.id
              hasCursor: root.hasCursorOn("presets", index)
              onHovered: function(h) { if (h) root.setCursor("presets", index) }
              onClicked: root.service.playPreset(modelData.id)
            }
          }
        }

        // ---- Transport
        Row {
          width: parent.width
          spacing: Style.space(6)

          Button {
            id: startButton
            width: (parent.width - parent.spacing * 2) / 3
            hasCursor: root.hasCursorOn("transport", 0)
            onHovered: function(h) { if (h) root.setCursor("transport", 0) }
            iconText: root.running && !root.paused ? "󰏤" : "󰐊"
            text: root.running ? (root.paused ? "Reprendre" : "Pause") : "Lecture"
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            enabled: root.ready && (root.running || root.savedUrl !== "")
            onClicked: {
              if (root.running) root.service.togglePause()
              else root.service.start()
            }
          }

          Button {
            id: stopButton
            width: (parent.width - parent.spacing * 2) / 3
            hasCursor: root.hasCursorOn("transport", 1)
            onHovered: function(h) { if (h) root.setCursor("transport", 1) }
            iconText: "󰓛"
            text: "Arrêter"
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            enabled: root.ready && root.running
            onClicked: root.service.stop()
          }

          Button {
            width: (parent.width - parent.spacing * 2) / 3
            hasCursor: root.hasCursorOn("transport", 2)
            onHovered: function(h) { if (h) root.setCursor("transport", 2) }
            iconText: root.muted ? "󰝟" : "󰕾"
            text: root.muted ? "Rétablir" : "Couper"
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            selected: !root.muted
            enabled: root.ready
            onClicked: root.service.setMuted(!root.muted)
          }
        }

        // ---- Position (hidden for live streams)
        Item {
          width: parent.width
          visible: root.seekable
          implicitHeight: Math.max(positionHeader.implicitHeight, positionTime.implicitHeight)

          PanelSectionHeader {
            id: positionHeader
            text: "POSITION"
            foreground: root.fg
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: positionTime
            textFormat: Text.PlainText
            text: root.formatTime(positionSlider.dragging ? positionSlider.liveValue : root.position)
              + " / " + root.formatTime(root.duration)
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        CursorSurface {
          width: parent.width
          visible: root.seekable
          height: positionSlider.implicitHeight + Style.spacing.controlGap
          foreground: root.fg
          outline: true
          hasCursor: root.hasCursorOn("position")
          HoverHandler { onHoveredChanged: if (hovered) root.setCursor("position") }

          PanelSlider {
            id: positionSlider
            bar: root.bar
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            minimum: 0
            maximum: Math.max(1, root.duration)
            step: 1
            integer: true
            value: root.position
            enabled: root.seekable
            onReleased: function(v) { root.service.seek(v, "absolute") }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---- Volume
        Item {
          width: parent.width
          implicitHeight: Math.max(volumeHeader.implicitHeight, volumePercent.implicitHeight)

          PanelSectionHeader {
            id: volumeHeader
            text: "VOLUME"
            foreground: root.fg
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: volumePercent
            textFormat: Text.PlainText
            text: Math.round(volumeSlider.dragging ? volumeSlider.liveValue : root.volume) + "%"
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            opacity: root.muted ? 0.5 : 1.0
          }
        }

        CursorSurface {
          width: parent.width
          height: volumeSlider.implicitHeight + Style.spacing.controlGap
          foreground: root.fg
          outline: true
          hasCursor: root.hasCursorOn("volume")
          HoverHandler { onHoveredChanged: if (hovered) root.setCursor("volume") }

          PanelSlider {
            id: volumeSlider
            bar: root.bar
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            value: root.volume
            opacity: root.muted ? 0.5 : 1.0
            enabled: root.ready
            onReleased: function(v) { root.service.setVolume(v) }
            onRightClicked: root.service.setMuted(!root.muted)
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---- URL personnalisée
        PanelSectionHeader {
          text: "AUTRE URL OU VIDÉO"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Row {
          id: urlRow
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: urlField
            width: parent.width - historyButton.width - playButton.width - parent.spacing * 2
            placeholderText: "URL YouTube, mix, live..."
            foreground: root.fg
            font.family: root.fontFamily
            enabled: root.ready
            anchors.verticalCenter: parent.verticalCenter
            hasCursor: !activeFocus && root.hasCursorOn("url", 0)
            onHoveredChanged: if (hovered) root.setCursor("url", 0)

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                urlField.text = root.savedUrl
                keyCatcher.forceActiveFocus()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.submitUrl()
                event.accepted = true
              }
            }
          }

          PanelActionButton {
            id: historyButton
            iconText: historyPopup.opened ? "󰅃" : "󰅀"
            tooltipText: root.history.length ? "Historique récent" : "Aucun historique"
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            size: urlField.implicitHeight
            enabled: root.ready && root.history.length > 0
            hasCursor: root.hasCursorOn("url", 1)
            onHovered: function(h) { if (h) root.setCursor("url", 1) }
            anchors.verticalCenter: parent.verticalCenter
            onClicked: historyPopup.opened ? historyPopup.close() : root.openHistory()
          }

          PanelActionButton {
            id: playButton
            iconText: "󰐊"
            tooltipText: "Lancer cette URL"
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            size: urlField.implicitHeight
            enabled: root.ready && urlField.text.trim() !== ""
            hasCursor: root.hasCursorOn("url", 2)
            onHovered: function(h) { if (h) root.setCursor("url", 2) }
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.submitUrl()
          }

          QQC.Popup {
            id: historyPopup
            x: 0
            y: urlRow.height + Style.spacing.xxs
            width: urlRow.width
            readonly property var borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)
            readonly property int rows: root.history.length
            implicitHeight: rows * Style.spacing.popupRowHeight + Math.max(0, rows - 1) * Style.spacing.labelGap
              + Style.spacing.xxs + Border.top(borderSpec) + Border.bottom(borderSpec)
            padding: Style.spacing.hairline
            leftPadding: Border.left(borderSpec) + Style.spacing.hairline
            rightPadding: Border.right(borderSpec) + Style.spacing.hairline
            topPadding: Border.top(borderSpec) + Style.spacing.hairline
            bottomPadding: Border.bottom(borderSpec) + Style.spacing.hairline
            modal: false
            focus: true
            closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside

            background: BorderSurface {
              color: Color.popups.background
              borderSpec: historyPopup.borderSpec
              radius: Style.cornerRadius
            }

            onOpenedChanged: {
              if (opened) {
                historyList.currentIndex = 0
                Qt.callLater(function() { historyList.forceActiveFocus() })
              } else if (root.opened) {
                Qt.callLater(function() { keyCatcher.forceActiveFocus() })
              }
            }

            contentItem: ListView {
              id: historyList
              spacing: Style.spacing.labelGap
              implicitHeight: contentHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              model: root.history
              currentIndex: 0

              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                event.accepted = true
                if (event.key === Qt.Key_Escape) historyPopup.close()
                else if (event.key === Qt.Key_Down || event.text === "j")
                  historyList.currentIndex = Math.min(root.history.length - 1, historyList.currentIndex + 1)
                else if (event.key === Qt.Key_Up || event.text === "k")
                  historyList.currentIndex = Math.max(0, historyList.currentIndex - 1)
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)
                  root.playHistory(historyList.currentIndex)
                else event.accepted = false
              }

              delegate: Rectangle {
                required property var modelData
                required property int index
                width: historyList.width
                height: Style.spacing.popupRowHeight
                radius: Style.cornerRadius
                color: index === historyList.currentIndex
                  ? Style.hoverFillFor(root.fg, Color.accent)
                  : "transparent"

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.spacing.controlPaddingX
                  anchors.rightMargin: Style.spacing.controlPaddingX
                  text: modelData.title || modelData.url
                  color: index === historyList.currentIndex ? Style.hoverStateColor(root.fg, Color.accent) : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: historyList.currentIndex = parent.index
                  onClicked: root.playHistory(parent.index)
                }
              }
            }
          }
        }

        // ---- Cookies (optionnel)
        Column {
          width: parent.width
          spacing: Style.space(3)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Cookies (optionnel, pour vidéos avec authentification)"
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: cookiesField
            width: parent.width
            placeholderText: "brave+gnomekeyring:Default ou ~/cookies.txt"
            foreground: root.fg
            font.family: root.fontFamily
            enabled: root.ready
            hasCursor: !activeFocus && root.hasCursorOn("cookies")
            onHoveredChanged: if (hovered) root.setCursor("cookies")

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                cookiesField.text = root.cookiesFile
                keyCatcher.forceActiveFocus()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.submitCookies()
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }
            onActiveFocusChanged: if (!activeFocus) root.submitCookies()
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "1 EverPop · 2 Lofi Girl · Espace Lecture/Pause · m Silence · s Arrêt · u URL"
          color: Qt.darker(root.fg, 1.8)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
