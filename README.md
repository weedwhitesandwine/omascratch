# Omascratch

A quick-note scratchpad for [Omarchy](https://omarchy.org/) that docks to a
corner of your screen. Toggle it with a keybind or the bar icon, type,
close — your text is still there next time.

## Features

- Notes autosave to disk as you type (debounced, no save button).
- Docks to any of the four screen corners.
- Adjustable font size.
- The toggle keybind is rebindable from inside the panel itself — no manual
  editing of Hyprland config required.
- Optional status-bar icon (pencil glyph) that toggles the same panel.

## Install

```
omarchy plugin add https://github.com/weedwhitesandwine/Omascratch.git --enable
```

Add the bar icon (optional):

```
omarchy bar put io.github.weedwhitesandwine.omascratch --section right
```

Add a keybind, e.g. in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + R", "Toggle Omascratch", "omarchy-shell shell toggle io.github.weedwhitesandwine.omascratch")
```

(Or skip this — set it from the panel's own settings view instead; see
below.)

## Usage

- Open/close: your keybind, or the bar icon, or
  `omarchy-shell shell toggle io.github.weedwhitesandwine.omascratch`.
- `Escape` closes the panel while the notes view has focus.
- Click the gear icon (top-right of the card) to open settings:
  - **Font size** — `−`/`+` steppers, 10–28px.
  - **Position** — top-left / top-right / bottom-left / bottom-right.
  - **Keybind** — click the current combo, press a new one (must include a
    modifier), click Apply.

## External dependencies and system-level modifications

This plugin runs `bash`, `awk`, `mkdir`, `cp`, and `hyprctl` via Quickshell's
`Process` — all standard on any Omarchy install, no extra packages required.

**The keybind picker in Settings modifies `~/.config/hypr/bindings.lua`.**
When you record and apply a new shortcut, `set-keybind.sh`:

1. Backs up `bindings.lua` to `bindings.lua.bak.<unix-timestamp>` (not
   auto-deleted — clean these up yourself periodically if you rebind often).
2. Rewrites the specific `o.bind(...)` line that toggles Omascratch,
   identified by matching the exact `omarchy-shell shell toggle
   io.github.weedwhitesandwine.omascratch` command string — no other line is touched.
3. Runs `hyprctl reload` and checks `hyprctl configerrors`.
4. If the reload produces any config error, restores the backup and reloads
   again — a bad rebind can't leave Hyprland in a broken state.

This is the only system configuration file this plugin ever writes to, and
only in response to an explicit action in the settings view (never
automatically).

## State files

- `~/.local/state/omarchy/omascratch/notes.txt` — your notes, plain text.
- `~/.local/state/omarchy/omascratch/settings.json` — font size, position,
  keybind. Created on first change; sensible defaults apply until then
  (14px, top-left, `SUPER + R`).

## License

MIT — see [LICENSE](LICENSE).
