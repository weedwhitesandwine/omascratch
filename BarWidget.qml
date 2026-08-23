import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.weedwhitesandwine.omascratch"

  // showIcon=false collapses the widget to nothing: the plugin stays
  // enabled and the keybind keeps working, the bar just shows no icon.
  // `omarchy bar set <id> showIcon false` without --json stores the *string*
  // "false", which is not the boolean, so a strict test left the icon showing
  // and the setting silently ignored.
  readonly property bool showIcon: {
    var v = setting("showIcon", true)
    return !(v === false || v === "false" || v === 0 || v === "0")
  }

  implicitWidth: showIcon ? button.implicitWidth : 0
  implicitHeight: showIcon ? button.implicitHeight : 0

  WidgetButton {
    id: button
    visible: root.showIcon
    anchors.fill: parent
    bar: root.bar
    text: "〰"
    foreground: "#FFD500"
    fontSize: Style.font.body * 1.4
    textRotation: 45
    tooltipText: "Omascratch"
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle io.github.weedwhitesandwine.omascratch")
    }
  }
}
