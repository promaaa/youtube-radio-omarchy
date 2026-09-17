import QtQuick
import qs.Commons
import qs.Ui

// Bar glyph for YouTube Radio.
// Left click: open panel · Middle click: pause / resume · Right click: start / stop
BarWidget {
  id: root
  moduleName: "promaa.youtube-radio"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(root.moduleName) : null
  readonly property string status: service ? service.status : "stopped"
  readonly property bool active: status === "playing" || status === "starting"

  function injectPanel() {
    var p = panelLoader.item
    if (!p) return
    p.bar = root.bar
    p.settings = root.settings
    p.service = root.service
    p.anchorItem = button
    p.hostWidget = root
  }

  // Shape contract the bar routes summon/hide/toggle and popout switching through:
  // open/close/opened/popoutSwitchClosing/closeForPopoutSwitch on the slot widget.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰎈"
    slotSize: Style.bar.iconSlot
    opacity: root.active ? 1.0 : (root.status === "paused" ? 0.75 : 0.45)
    tooltipText: root.service && root.service.title ? root.service.title : "YouTube Radio"

    Behavior on opacity { NumberAnimation { duration: 160 } }

    onPressed: function(b) {
      if (root.service && b === Qt.RightButton) root.service.toggle()
      else if (root.service && b === Qt.MiddleButton) root.service.togglePause()
      else root.toggle()
    }
  }
}
