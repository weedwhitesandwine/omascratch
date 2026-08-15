import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the Omascratch panel. A pencil glyph that toggles the panel
// through the same IPC route the keybind uses.
BarWidget {
  id: root
  moduleName: "io.github.weedwhitesandwine.omascratch"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "✎"
    tooltipText: "Omascratch"
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle io.github.weedwhitesandwine.omascratch")
    }
  }
}
