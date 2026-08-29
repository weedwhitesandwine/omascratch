import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

Item {
  id: root

  // A file this plugin reads but does not own can be anything by the time it
  // is opened: a link pointing elsewhere, a pipe that never produces anything,
  // or something far too large. `head` opens a path the ordinary way and would
  // follow the first and wait forever on the second, inside a shell process
  // that stays up for days. So the open refuses on its own terms and hands
  // back nothing at all rather than something over the ceiling. O_NOFOLLOW
  // covers the final name only — a link in a parent directory is still
  // followed, which is the same trust already placed in the home directory.
  readonly property string safeRead: [
    'import os, stat, sys',
    'path = sys.argv[1]; ceiling = int(sys.argv[2])',
    'try:',
    '    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)',
    'except FileNotFoundError:',
    '    raise SystemExit(2)',
    'except OSError:',
    '    raise SystemExit(1)',
    'try:',
    '    if not stat.S_ISREG(os.fstat(fd).st_mode):',
    '        raise SystemExit(1)',
    '    with os.fdopen(fd, "rb") as handle:',
    '        fd = None',
    '        raw = handle.read(ceiling + 1)',
    'except OSError:',
    '    raise SystemExit(1)',
    'finally:',
    '    if fd is not None:',
    '        os.close(fd)',
    'if len(raw) > ceiling:',
    '    raise SystemExit(1)',
    'sys.stdout.buffer.write(raw)'
  ].join("
")

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

  property int fontSize: 14
  property string position: "top-left"
  // Empty until the user binds one. A fresh install has no block in
  // bindings.lua, so a default of "SUPER + R" here would have the panel
  // reporting a shortcut that is bound to nothing.
  property string keybind: ""
  property bool stayOnTop: false
  property bool settingsLoaded: false

  property string barPosition: "top"

  property bool recording: false
  property string pendingCombo: ""
  property string recordError: ""
  property string applyStatus: ""
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

  // The gear is a click target only, so without these the settings view is
  // unreachable from the keyboard — and the notes view holds the focus the
  // whole time it is open. Focus moves with the view: the panel closes itself
  // when its focus grab is cleared, so a view whose key handler nothing is
  // focused on would swallow Escape and answer to nothing else.
  function openSettings() {
    root.settingsOpen = true
    Qt.callLater(function() { settingsKeys.forceActiveFocus() })
  }

  function closeSettings() {
    root.settingsOpen = false
    root.recording = false
    Qt.callLater(function() { textArea.forceActiveFocus() })
  }

  function isSettingsShortcut(event) {
    return event.key === Qt.Key_Comma && (event.modifiers & Qt.ControlModifier)
  }

  // Everything read off disk goes through a reader that puts the ceiling in
  // front of the read rather than behind it. FileView cannot stop short of the
  // end of a file — by the time text() exists the whole file is in a shell that
  // stays up for days — so it keeps the writing and stops doing the reading,
  // with blockAllReads set so it never pulls a file into memory. The notes are
  // the user's own, but they sit on disk where a restored backup can leave
  // anything, and shell.json belongs to Omarchy rather than to this plugin.
  readonly property int notesCeiling: 4 * 1024 * 1024
  readonly property int settingsCeiling: 256 * 1024
  readonly property int barConfigCeiling: 1024 * 1024

  // The bar's own hidden flag, watched the way the bar itself watches it.
  property bool barHidden: false
  FileView {
    path: root.homeDir + "/.local/state/omarchy/toggles/bar-off"
    watchChanges: true
    blockAllReads: true
    preload: false
    printErrors: false
    onFileChanged: root.checkBarHidden()
    onPathChanged: root.checkBarHidden()
  }
  function checkBarHidden() { barHiddenProc.running = false; barHiddenProc.running = true }
  Process {
    id: barHiddenProc
    command: ["test", "-f", root.homeDir + "/.local/state/omarchy/toggles/bar-off"]
    onExited: function(code) { root.barHidden = (code === 0) }
  }

  FileView {
    id: notesFile
    path: root.notesPath
    watchChanges: true
    atomicWrites: true
    blockAllReads: true
    preload: false
    printErrors: false
    // Saving changes the file, which fires this. Re-reading then replaces the
    // editor's contents with what was on disk a moment ago — losing anything
    // typed while the reader was starting up, and dropping the cursor to the
    // top of the note mid-sentence. Our own writes are skipped; someone
    // else's are still picked up.
    onFileChanged: {
      if (root.savingNow) { root.savingNow = false; return }
      root.readNotes()
    }
  }
  property bool savingNow: false

  function readNotes() { notesReader.running = false; notesReader.running = true }
  function readSettings() { settingsReader.running = false; settingsReader.running = true }
  function readBarConfig() { barConfigReader.running = false; barConfigReader.running = true }

  // Notes are plain text, so an empty answer is a legitimate value — which
  // makes "the read was refused" and "the file is empty" the same string. The
  // reader reports refusal as a failing exit status instead, and the editor is
  // only filled from a read that actually succeeded: assigning the empty
  // answer would blank the editor, and the autosave would then write that
  // emptiness over the real notes a moment later.
  property string notesPending: ""
  Process {
    id: notesReader
    command: ["python3", "-c", root.safeRead,
              root.notesPath, String(root.notesCeiling)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.notesPending = text
    }
    onExited: function(code) {
      if (code === 0) textArea.text = root.notesPending
      root.notesPending = ""
    }
  }

  Process {
    id: settingsReader
    command: ["python3", "-c", root.safeRead,
              root.settingsPath, String(root.settingsCeiling)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadSettings(text)
    }
    // A missing settings file means first run, and the defaults are the truth.
    // A read that FAILED means nothing of the sort — treating the two alike
    // let one bad read at startup stand the defaults up as real settings, and
    // the next nudge of any control then wrote them over the saved position,
    // size and shortcut. Exit 2 is the reader's way of saying the file is not
    // there; anything else leaves settings unloaded, so nothing is saved over.
    onExited: function(code) {
      if (root.settingsLoaded) return
      if (code === 2) root.loadSettings("")
    }
  }

  Process {
    id: barConfigReader
    command: ["python3", "-c", root.safeRead,
              root.homeDir + "/.config/omarchy/shell.json", String(root.barConfigCeiling)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadBarPosition(text)
    }
  }

  Timer {
    id: saveTimer
    interval: 400
    repeat: false
    onTriggered: { root.savingNow = true; notesFile.setText(textArea.text) }
  }

  Process {
    id: ensureDirsProc
    command: ["mkdir", "-p", root.stateDir]
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: false
    atomicWrites: true
    blockAllReads: true
    preload: false
    printErrors: false
  }

  FileView {
    path: root.homeDir + "/.config/omarchy/shell.json"
    watchChanges: true
    blockAllReads: true
    preload: false
    printErrors: false
    onFileChanged: root.readBarConfig()
  }

  function loadBarPosition(json) {
    try {
      var parsed = JSON.parse(json || "{}")
      var pos = parsed.bar && parsed.bar.position
      if (pos === "top" || pos === "bottom" || pos === "left" || pos === "right")
        root.barPosition = pos
    } catch (e) {
    }
  }

  Timer {
    id: settingsSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushSettings()
  }

  // A hotkey is modifiers then one key. This value is substituted into
  // bindings.lua as Lua source, so anything else is refused rather than
  // escaped — here, and again in omascratch-ctl.sh, since the file can be edited
  // or restored without going near this panel.
  readonly property var keybindPattern:
    /^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$/

  function validKeybind(v) {
    return typeof v === "string" && v.length <= 40 && root.keybindPattern.test(v)
  }

  readonly property var positions: ["top-left", "top-right", "bottom-left", "bottom-right"]

  // A settings file can be hand-edited or restored from a mangled backup, so
  // what comes out of it goes through the same limits as what comes out of the
  // steppers. A font size of 400 or a card four pixels wide is unusable, and
  // the steppers clamp relative to the loaded value, so it cannot be undone
  // from the panel either. An unknown position leaves every anchor false and
  // the card docked to nothing.
  function loadSettings(json) {
    var parsed = {}
    try { parsed = JSON.parse(json || "{}") } catch (e) { parsed = {} }
    if (typeof parsed.fontSize === "number") root.setFontSize(parsed.fontSize)
    if (typeof parsed.position === "string"
        && root.positions.indexOf(parsed.position) !== -1) root.position = parsed.position
    if (parsed.keybind === "" || root.validKeybind(parsed.keybind))
      root.keybind = parsed.keybind
    if (typeof parsed.cardWidth === "number") root.setCardWidth(parsed.cardWidth)
    if (typeof parsed.cardHeight === "number") root.setCardHeight(parsed.cardHeight)
    root.settingsLoaded = true
  }

  function scheduleSettingsSave() {
    if (root.settingsLoaded) settingsSaveTimer.restart()
  }

  function flushSettings() {
    settingsFile.setText(JSON.stringify({
      fontSize: root.fontSize,
      position: root.position,
      keybind: root.keybind,
      cardWidth: root.cardWidth,
      cardHeight: root.cardHeight
    }, null, 2) + "\n")
  }

  onFontSizeChanged: scheduleSettingsSave()
  onPositionChanged: scheduleSettingsSave()
  onKeybindChanged: scheduleSettingsSave()
  onCardWidthChanged: scheduleSettingsSave()
  onCardHeightChanged: scheduleSettingsSave()

  Component.onCompleted: {
    ensureDirsProc.running = true
    Qt.callLater(function() {
      root.readSettings()
      root.readNotes()
      root.readBarConfig()
      root.checkBarHidden()
    })
  }

  function setFontSize(size) {
    root.fontSize = Math.max(10, Math.min(28, size))
  }

  function setCardWidth(width) {
    root.cardWidth = Math.max(220, Math.min(900, width))
  }

  function setCardHeight(height) {
    root.cardHeight = Math.max(200, Math.min(900, height))
  }

  function setPosition(pos) {
    root.position = pos
  }

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
    // The recorder keeps the focus once it has it, and its handler answers
    // every key while it does — so Escape after a cancel would cancel a
    // recording that had already stopped instead of leaving the settings view.
    Qt.callLater(function() { settingsKeys.forceActiveFocus() })
  }

  function isBareModifier(key) {
    return key === Qt.Key_Super_L || key === Qt.Key_Super_R || key === Qt.Key_Meta
      || key === Qt.Key_Control || key === Qt.Key_Shift || key === Qt.Key_Alt || key === Qt.Key_AltGr
  }

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
    // Spelled the way both validators accept, not the way Hyprland prints
    // them: the recorder invites the user to press these keys, so producing a
    // name that is then refused on Apply makes the invitation a lie. Twenty of
    // the twenty-five named keys used to be refused this way.
    names[Qt.Key_Delete] = "DELETE"
    names[Qt.Key_Insert] = "INSERT"
    names[Qt.Key_Home] = "HOME"
    names[Qt.Key_End] = "END"
    names[Qt.Key_PageUp] = "PAGE_UP"
    names[Qt.Key_PageDown] = "PAGE_DOWN"
    names[Qt.Key_Left] = "LEFT"
    names[Qt.Key_Right] = "RIGHT"
    names[Qt.Key_Up] = "UP"
    names[Qt.Key_Down] = "DOWN"
    names[Qt.Key_Comma] = "COMMA"
    names[Qt.Key_Period] = "PERIOD"
    names[Qt.Key_Minus] = "MINUS"
    names[Qt.Key_Equal] = "EQUAL"
    names[Qt.Key_Slash] = "SLASH"
    names[Qt.Key_Backslash] = "BACKSLASH"
    names[Qt.Key_Semicolon] = "SEMICOLON"
    names[Qt.Key_Apostrophe] = "APOSTROPHE"
    names[Qt.Key_BracketLeft] = "BRACKETLEFT"
    names[Qt.Key_BracketRight] = "BRACKETRIGHT"
    names[Qt.Key_QuoteLeft] = "GRAVE"
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
    // Shift on its own does not qualify: "SHIFT + T" binds capital T
    // globally, so typing one anywhere would open the scratchpad.
    if (mods.length === 1 && mods[0] === "SHIFT") {
      root.recordError = "Shift on its own is not enough — hold Super, Ctrl or Alt as well, or a capital letter would open this everywhere."
      event.accepted = true
      return
    }
    if (mods.length === 0) {
      root.recordError = "Add a modifier (Super, Ctrl or Alt) — a bare key would break typing everywhere."
      event.accepted = true
      return
    }
    if (mods.length > 1) {
      root.recordError = "Use exactly one modifier — combos with two or more fail to apply on this system."
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
    root.clearing = false
    keybindProc.command = ["bash", root.pluginDir + "/omascratch-ctl.sh", "bind", root.pendingCombo]
    keybindProc.running = true
  }

  // Takes the block back out of bindings.lua. Same script, same verification
  // and same revert-on-failure as binding — an unbind that left Hyprland
  // unable to parse its own config would be no better than a bad bind.
  property bool clearing: false
  function clearKeybind() {
    if (root.keybind === "") return
    root.applyStatus = "applying"
    root.applyError = ""
    root.clearing = true
    keybindProc.command = ["bash", root.pluginDir + "/omascratch-ctl.sh", "unbind"]
    keybindProc.running = true
  }

  Process {
    id: keybindProc
    stdout: StdioCollector { id: keybindStdout; waitForEnd: true }
    stderr: StdioCollector { id: keybindStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.keybind = root.clearing ? "" : root.pendingCombo
        root.applyStatus = ""
        root.recording = false
        root.pendingCombo = ""
        root.clearing = false
        Qt.callLater(function() { settingsKeys.forceActiveFocus() })
      } else {
        root.applyStatus = "error"
        root.clearing = false
        root.applyError = (keybindStderr.text || "").trim() || "Failed to apply keybind"
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors {
      top: root.position === "top-left" || root.position === "top-right"
      bottom: root.position === "bottom-left" || root.position === "bottom-right"
      left: root.position === "top-left" || root.position === "bottom-left"
      right: root.position === "top-right" || root.position === "bottom-right"
    }
    readonly property bool dockedTop: root.position === "top-left" || root.position === "top-right"
    readonly property bool dockedBottom: root.position === "bottom-left" || root.position === "bottom-right"
    readonly property bool dockedLeft: root.position === "top-left" || root.position === "bottom-left"
    readonly property bool dockedRight: root.position === "top-right" || root.position === "bottom-right"
    // Leave room for the bar only when there is a bar to leave room for.
    // Omarchy hides it with an on-disk flag rather than through shell.json,
    // so a hidden bar left the card floating a bar's height from an empty
    // screen edge.
    margins.top: (dockedTop && root.barPosition === "top" && !root.barHidden)
                 ? Style.bar.sizeHorizontal + root.gap : root.gap
    margins.bottom: (dockedBottom && root.barPosition === "bottom" && !root.barHidden)
                    ? Style.bar.sizeHorizontal + root.gap : root.gap
    margins.left: (dockedLeft && root.barPosition === "left") ? Style.bar.sizeVertical + root.gap : root.gap
    margins.right: (dockedRight && root.barPosition === "right") ? Style.bar.sizeVertical + root.gap : root.gap
    implicitWidth: root.cardWidth
    implicitHeight: root.cardHeight
    color: "transparent"
    WlrLayershell.namespace: "omascratch"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

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

        // The header sits in a strip of its own rather than floating over the
        // top-right corner. Keeping space clear beside it cost the full width
        // of both buttons on every line of the note, all the way down the
        // card, to keep two lines clear of them.
        ScrollView {
          id: notesScroll
          visible: !root.settingsOpen
          anchors.fill: parent
          anchors.topMargin: headerRow.height + Style.spacing.xs
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

          TextArea {
            id: textArea
            wrapMode: TextArea.Wrap
            // The scrollbar is painted over the text rather than beside it, so
            // without a gutter the last character of a full line sits under it.
            // Reserved whether or not the bar is showing: making the gutter
            // conditional would change the wrap width, which changes the
            // content height, which is what decides whether the bar shows.
            rightPadding: notesScroll.ScrollBar.vertical.width + Style.spacing.xs
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
              } else if (root.isSettingsShortcut(event)) {
                root.openSettings()
                event.accepted = true
              }
            }

            onTextChanged: saveTimer.restart()
          }
        }

        Flickable {
          visible: root.settingsOpen
          anchors.fill: parent
          anchors.topMargin: headerRow.height + Style.spacing.xs
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
                textFormat: Text.PlainText
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
                  textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                text: "Size"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Row {
                spacing: Style.spacing.sm

                PanelActionButton {
                  iconText: "−"
                  foreground: root.foreground
                  onClicked: root.setCardWidth(root.cardWidth - 20)
                }

                Text {
                  textFormat: Text.PlainText
                  text: "W " + root.cardWidth
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                PanelActionButton {
                  iconText: "+"
                  foreground: root.foreground
                  onClicked: root.setCardWidth(root.cardWidth + 20)
                }
              }

              Row {
                spacing: Style.spacing.sm

                PanelActionButton {
                  iconText: "−"
                  foreground: root.foreground
                  onClicked: root.setCardHeight(root.cardHeight - 20)
                }

                Text {
                  textFormat: Text.PlainText
                  text: "H " + root.cardHeight
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                PanelActionButton {
                  iconText: "+"
                  foreground: root.foreground
                  onClicked: root.setCardHeight(root.cardHeight + 20)
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.xs

              Text {
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                text: "Keybind"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Row {
                spacing: Style.spacing.sm

                Button {
                  text: root.recording
                    ? (root.pendingCombo !== "" ? root.pendingCombo : "Press keys…")
                    : (root.keybind !== "" ? root.keybind : "Not bound")
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.recording ? root.cancelRecording() : root.beginRecording()
                }

                // Uninstalling deletes the script that takes the block out of
                // bindings.lua, so this is the only thing that can remove it —
                // which is why the line below says so while there is one.
                Button {
                  text: "Clear"
                  bordered: true
                  visible: root.keybind !== "" && !root.recording
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  tooltipText: "Remove the shortcut from bindings.lua"
                  onClicked: root.clearKeybind()
                }
              }

              Item {
                id: recorder
                width: 1
                height: 1
                focus: root.recording
                Keys.onPressed: function(event) { root.handleRecordKey(event) }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.recording
                // The second sentence is the one people need. A combination
                // Hyprland has already bound is swallowed by the compositor and
                // never reaches this panel, so the recorder simply sits there
                // showing nothing — which reads as broken rather than as taken.
                text: "Press a shortcut with one modifier (e.g. Super+T). Esc to cancel. "
                  + "A combination Hyprland already uses never reaches here — if nothing "
                  + "appears, that key is taken."
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                visible: root.keybind !== "" && !root.recording && root.applyStatus === ""
                text: "Bound in a marked block in ~/.config/hypr/bindings.lua. Press Clear "
                  + "before uninstalling — removal deletes the script that would take it out."
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                visible: root.applyStatus === "applying"
                text: "Applying…"
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                textFormat: Text.PlainText
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

        // Holds the focus while the settings view is up, so Escape and Ctrl+,
        // are answered there as well as in the notes view. A focus holder
        // rather than a control — everything visible in that view is a click
        // target with its own handler.
        Item {
          id: settingsKeys
          width: 1
          height: 1
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || root.isSettingsShortcut(event)) {
              root.closeSettings()
              event.accepted = true
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
            onClicked: root.settingsOpen ? root.closeSettings() : root.openSettings()
          }
        }
      }
    }
  }
}
