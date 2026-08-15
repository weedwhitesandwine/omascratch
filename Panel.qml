import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Corner-docked note scratchpad. Summoned via `omarchy-shell shell toggle
// io.github.weedwhitesandwine.omascratch` (bound to a Hyprland keybind, and/or the
// bar icon in BarWidget.qml). Notes autosave to disk on every edit; the gear
// button opens an in-place settings view for font size, screen corner, and
// the keybind itself.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool settingsOpen: false

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string pluginDir: homeDir + "/.config/omarchy/plugins/io.github.weedwhitesandwine.omascratch"
  readonly property string stateDir: homeDir + "/.local/state/omarchy/omascratch"
  readonly property string notesPath: stateDir + "/notes.txt"
  readonly property string settingsPath: stateDir + "/settings.json"

  // ---- persisted settings ----
  property int fontSize: 14
  property string position: "top-left" // top-left | top-right | bottom-left | bottom-right
  property string keybind: "SUPER + R"
  property bool stayOnTop: false
  property bool settingsLoaded: false

  // Read (not owned) so the panel can dodge whichever edge the Omarchy bar
  // is currently docked to — the bar itself is user-configurable via
  // `omarchy bar position top|bottom|left|right`.
  property string barPosition: "top"

  // ---- keybind recording ----
  property bool recording: false
  property string pendingCombo: ""
  property string recordError: ""
  property string applyStatus: "" // "" | "applying" | "error"
  property string applyError: ""

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: Style.space(340)
  property int cardHeight: Style.space(420)
  readonly property int gap: Style.gapsOut

  function open(payloadJson) {
    root.opened = true
    root.settingsOpen = false
    root.stayOnTop = false
    Qt.callLater(function() { textArea.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.recording = false
  }

  function dismiss() {
    root.opened = false
    root.recording = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.weedwhitesandwine.omascratch")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---------------------------------------------------------------- notes

  FileView {
    id: notesFile
    path: root.notesPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: textArea.text = text()
  }

  Timer {
    id: saveTimer
    interval: 400
    repeat: false
    onTriggered: notesFile.setText(textArea.text)
  }

  // -------------------------------------------------------------- settings

  Process {
    id: ensureDirsProc
    command: ["mkdir", "-p", root.stateDir]
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    onLoadFailed: root.loadSettings("")
  }

  // Read-only: tracks the live Omarchy bar position so the panel can avoid
  // the edge the bar occupies, whichever side the user has it docked to.
  FileView {
    id: barConfigFile
    path: root.homeDir + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadBarPosition(text())
    onFileChanged: reload()
  }

  function loadBarPosition(json) {
    try {
      var parsed = JSON.parse(json || "{}")
      var pos = parsed.bar && parsed.bar.position
      if (pos === "top" || pos === "bottom" || pos === "left" || pos === "right")
        root.barPosition = pos
    } catch (e) {
      // Keep the last-known position on a parse error.
    }
  }

  Timer {
    id: settingsSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushSettings()
  }

  function loadSettings(json) {
    var parsed = {}
    try { parsed = JSON.parse(json || "{}") } catch (e) { parsed = {} }
    if (typeof parsed.fontSize === "number") root.fontSize = parsed.fontSize
    if (typeof parsed.position === "string") root.position = parsed.position
    if (typeof parsed.keybind === "string") root.keybind = parsed.keybind
    root.settingsLoaded = true
  }

  function scheduleSettingsSave() {
    if (root.settingsLoaded) settingsSaveTimer.restart()
  }

  function flushSettings() {
    settingsFile.setText(JSON.stringify({
      fontSize: root.fontSize,
      position: root.position,
      keybind: root.keybind
    }, null, 2) + "\n")
  }

  onFontSizeChanged: scheduleSettingsSave()
  onPositionChanged: scheduleSettingsSave()
  onKeybindChanged: scheduleSettingsSave()

  Component.onCompleted: {
    ensureDirsProc.running = true
    Qt.callLater(function() { settingsFile.reload() })
  }

  function setFontSize(size) {
    root.fontSize = Math.max(10, Math.min(28, size))
  }

  function setPosition(pos) {
    root.position = pos
  }

  // ------------------------------------------------------- keybind capture

  function beginRecording() {
    root.recording = true
    root.recordError = ""
    root.pendingCombo = ""
    root.applyStatus = ""
    Qt.callLater(function() { recorder.forceActiveFocus() })
  }

  function cancelRecording() {
    root.recording = false
    root.recordError = ""
    root.pendingCombo = ""
  }

  function isBareModifier(key) {
    return key === Qt.Key_Super_L || key === Qt.Key_Super_R || key === Qt.Key_Meta
      || key === Qt.Key_Control || key === Qt.Key_Shift || key === Qt.Key_Alt || key === Qt.Key_AltGr
  }

  // Maps a Qt key code to the token Hyprland's bindings.lua combos use
  // (letters/digits uppercase, named keys lowercase to match this file's
  // existing convention, e.g. "SUPER + R", "SUPER + comma").
  function hyprKeyName(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F12) return "F" + (key - Qt.Key_F1 + 1)
    var names = {}
    names[Qt.Key_Space] = "SPACE"
    names[Qt.Key_Return] = "RETURN"
    names[Qt.Key_Enter] = "RETURN"
    names[Qt.Key_Escape] = "ESCAPE"
    names[Qt.Key_Tab] = "TAB"
    names[Qt.Key_Backspace] = "BACKSPACE"
    names[Qt.Key_Delete] = "Delete"
    names[Qt.Key_Home] = "Home"
    names[Qt.Key_End] = "End"
    names[Qt.Key_PageUp] = "PageUp"
    names[Qt.Key_PageDown] = "PageDown"
    names[Qt.Key_Left] = "left"
    names[Qt.Key_Right] = "right"
    names[Qt.Key_Up] = "up"
    names[Qt.Key_Down] = "down"
    names[Qt.Key_Comma] = "comma"
    names[Qt.Key_Period] = "period"
    names[Qt.Key_Minus] = "minus"
    names[Qt.Key_Equal] = "equal"
    names[Qt.Key_Slash] = "slash"
    names[Qt.Key_Backslash] = "backslash"
    names[Qt.Key_Semicolon] = "semicolon"
    names[Qt.Key_Apostrophe] = "apostrophe"
    names[Qt.Key_BracketLeft] = "bracketleft"
    names[Qt.Key_BracketRight] = "bracketright"
    names[Qt.Key_QuoteLeft] = "grave"
    return names[key] || ""
  }

  function handleRecordKey(event) {
    if (event.key === Qt.Key_Escape && event.modifiers === Qt.NoModifier) {
      root.cancelRecording()
      event.accepted = true
      return
    }
    if (root.isBareModifier(event.key)) {
      event.accepted = true
      return
    }

    var mods = []
    if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
    if (event.modifiers & Qt.AltModifier) mods.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")

    var keyStr = root.hyprKeyName(event.key)
    if (keyStr === "") {
      root.recordError = "Unsupported key — try a letter, digit, F-key, arrow, or punctuation key."
      event.accepted = true
      return
    }
    if (mods.length === 0) {
      root.recordError = "Add a modifier (Super/Ctrl/Alt/Shift) — a bare key would break typing everywhere."
      event.accepted = true
      return
    }

    root.recordError = ""
    root.pendingCombo = mods.join(" ") + " + " + keyStr
    event.accepted = true
  }

  function confirmRecording() {
    if (root.pendingCombo === "") return
    root.applyStatus = "applying"
    root.applyError = ""
    keybindProc.command = ["bash", root.pluginDir + "/set-keybind.sh", root.pendingCombo]
    keybindProc.running = true
  }

  Process {
    id: keybindProc
    stdout: StdioCollector { id: keybindStdout; waitForEnd: true }
    stderr: StdioCollector { id: keybindStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.keybind = root.pendingCombo
        root.applyStatus = ""
        root.recording = false
        root.pendingCombo = ""
      } else {
        root.applyStatus = "error"
        root.applyError = (keybindStderr.text || "").trim() || "Failed to apply keybind"
      }
    }
  }

  // --------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors {
      top: root.position === "top-left" || root.position === "top-right"
      bottom: root.position === "bottom-left" || root.position === "bottom-right"
      left: root.position === "top-left" || root.position === "bottom-left"
      right: root.position === "top-right" || root.position === "bottom-right"
    }
    // Clear whichever edge the Omarchy bar is docked to (top/bottom/left/
    // right, user-configurable) — otherwise this overlay-layer surface
    // paints over the bar's own icons, including the one that opened it,
    // eating clicks meant for the bar underneath.
    readonly property bool dockedTop: root.position === "top-left" || root.position === "top-right"
    readonly property bool dockedBottom: root.position === "bottom-left" || root.position === "bottom-right"
    readonly property bool dockedLeft: root.position === "top-left" || root.position === "bottom-left"
    readonly property bool dockedRight: root.position === "top-right" || root.position === "bottom-right"
    margins.top: (dockedTop && root.barPosition === "top") ? Style.bar.sizeHorizontal + root.gap : root.gap
    margins.bottom: (dockedBottom && root.barPosition === "bottom") ? Style.bar.sizeHorizontal + root.gap : root.gap
    margins.left: (dockedLeft && root.barPosition === "left") ? Style.bar.sizeVertical + root.gap : root.gap
    margins.right: (dockedRight && root.barPosition === "right") ? Style.bar.sizeVertical + root.gap : root.gap
    implicitWidth: root.cardWidth
    implicitHeight: root.cardHeight
    color: "transparent"
    WlrLayershell.namespace: "omascratch"
    // Top, not Overlay: Overlay sits above literally everything (even
    // fullscreen windows) and is what every quick-modal picker in this shell
    // uses (Emojis, Clipboard, Reminders) — surfaces meant to dominate input
    // until closed. The one first-party surface in this shell built to stay
    // mapped and coexist with normal windows, the bar itself, uses Top.
    WlrLayershell.layer: WlrLayer.Top
    // OnDemand, not Exclusive: this panel is meant to sit open in a corner
    // while you work in other windows. Exclusive grabs ALL keyboard input
    // system-wide for as long as it's mapped, which blocks typing/alt-tab
    // everywhere else. OnDemand only focuses this surface when it's
    // actually clicked into, and gives focus back on click-elsewhere.
    //
    // KNOWN LIMITATION (kept as-is; a view-only-while-pinned workaround
    // was tried and rejected as pointless): Hyprland has a confirmed
    // compositor bug (hyprwm/Hyprland#8293) where an on_demand layer
    // surface releasing focus back to an ALREADY-OPEN window updates
    // `hyprctl activewindow` correctly but never re-sends the actual
    // wl_keyboard.enter event, silently eating that window's keystrokes.
    // A newly-created window is unaffected (different focus path), which
    // is why pinning before opening the target app works fine. The usual
    // workaround, forcing Hyprland to re-run its focus logic via
    // `hyprctl dispatch focuscurrentorlast`, isn't reachable here: this
    // system's Hyprland build routes all dispatches through a restricted
    // Lua wrapper (hl.dsp.*) that doesn't expose it and has no raw
    // passthrough (confirmed via strings/Hyprland binary + live testing).
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    // Click-outside-to-dismiss, matching every other panel in this shell —
    // unless pinned via the pin button, in which case the panel stays open
    // so it can be used alongside other windows. SUPER+R (or whichever
    // keybind) always closes it either way, via root.toggle()/dismiss().
    //
    // KNOWN LIMITATION: when pinned, clicking into a window that was
    // already open before the panel doesn't reliably hand keyboard focus
    // to it (a newly-opened window works fine). Re-activating this grab
    // to try to fix that made things worse — reactivating it appears to
    // re-steal focus back onto the panel as a side effect — so that
    // attempt was reverted. Root cause is still open; see project notes.
    HyprlandFocusGrab {
      active: root.opened && !root.stayOnTop
      windows: [panel]
      onCleared: root.dismiss()
    }

    BorderSurface {
      id: card
      anchors.fill: parent
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      Item {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        ScrollView {
          visible: !root.settingsOpen
          anchors.fill: parent
          anchors.rightMargin: headerRow.width + Style.spacing.sm
          clip: true

          TextArea {
            id: textArea
            wrapMode: TextArea.Wrap
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
            color: root.foreground
            selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
            selectedTextColor: root.foreground
            placeholderText: "Scratchpad…"
            placeholderTextColor: Qt.darker(root.foreground, 1.6)
            background: Item {}

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.dismiss()
                event.accepted = true
              }
            }

            onTextChanged: saveTimer.restart()
          }
        }

        Flickable {
          visible: root.settingsOpen
          anchors.fill: parent
          anchors.rightMargin: headerRow.width + Style.spacing.sm
          contentWidth: width
          contentHeight: settingsColumn.implicitHeight
          clip: true

          Column {
            id: settingsColumn
            width: parent.width
            spacing: Style.spacing.lg

            Column {
              width: parent.width
              spacing: Style.spacing.xs

              Text {
                text: "Font size"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Row {
                spacing: Style.spacing.sm

                PanelActionButton {
                  iconText: "−"
                  foreground: root.foreground
                  onClicked: root.setFontSize(root.fontSize - 1)
                }

                Text {
                  text: root.fontSize + "px"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                PanelActionButton {
                  iconText: "+"
                  foreground: root.foreground
                  onClicked: root.setFontSize(root.fontSize + 1)
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.xs

              Text {
                text: "Position"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Grid {
                columns: 2
                spacing: Style.spacing.sm

                Button {
                  text: "Top-left"
                  bordered: true
                  selected: root.position === "top-left"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.setPosition("top-left")
                }
                Button {
                  text: "Top-right"
                  bordered: true
                  selected: root.position === "top-right"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.setPosition("top-right")
                }
                Button {
                  text: "Bottom-left"
                  bordered: true
                  selected: root.position === "bottom-left"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.setPosition("bottom-left")
                }
                Button {
                  text: "Bottom-right"
                  bordered: true
                  selected: root.position === "bottom-right"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.setPosition("bottom-right")
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.xs

              Text {
                text: "Keybind"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Button {
                text: root.recording ? (root.pendingCombo !== "" ? root.pendingCombo : "Press keys…") : root.keybind
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.recording ? root.cancelRecording() : root.beginRecording()
              }

              Item {
                id: recorder
                width: 1
                height: 1
                focus: root.recording
                Keys.onPressed: function(event) { root.handleRecordKey(event) }
              }

              Text {
                visible: root.recording
                text: "Press a shortcut with a modifier (e.g. Super+T). Esc to cancel."
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                width: parent.width
              }

              Text {
                visible: root.recordError !== ""
                text: root.recordError
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                width: parent.width
              }

              Row {
                visible: root.recording && root.pendingCombo !== ""
                spacing: Style.spacing.sm

                Button {
                  text: "Apply"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.confirmRecording()
                }
                Button {
                  text: "Cancel"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.cancelRecording()
                }
              }

              Text {
                visible: root.applyStatus === "applying"
                text: "Applying…"
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                visible: root.applyStatus === "error"
                text: "Failed: " + root.applyError
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                width: parent.width
              }
            }
          }
        }

        Row {
          id: headerRow
          anchors.top: parent.top
          anchors.right: parent.right
          spacing: Style.spacing.xs

          Button {
            id: pinButton
            text: "Pin"
            bordered: true
            selected: root.stayOnTop
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.xs
            tooltipText: root.stayOnTop
              ? "Pinned — clicking elsewhere won't close it"
              : "Pin to stay open while using other windows"
            onClicked: root.stayOnTop = !root.stayOnTop
          }

          PanelActionButton {
            id: gearButton
            iconText: root.settingsOpen ? "✕" : "󰒓"
            tooltipText: root.settingsOpen ? "Back to notes" : "Settings"
            foreground: root.foreground
            onClicked: root.settingsOpen = !root.settingsOpen
          }
        }
      }
    }
  }
}
