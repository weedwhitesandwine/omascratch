#!/usr/bin/env bash
# Omascratch hotkey helper. Runs ONLY when the user records a new shortcut in
# the panel's settings view — never on its own.
#
#   omascratch-ctl.sh bind "SUPER + X"   manage Omascratch's hotkey as a marked
#                                        block in ~/.config/hypr/bindings.lua
#                                        (replaces only its own block, never
#                                        another line)
#   omascratch-ctl.sh unbind             remove that block
set -euo pipefail

ID="io.github.weedwhitesandwine.omascratch"
TOGGLE="omarchy-shell shell toggle $ID"
BIND_FILE="$HOME/.config/hypr/bindings.lua"
MARK_IN="-- >>> omascratch hotkey (managed by Omascratch settings — change it there)"
MARK_OUT="-- <<< omascratch hotkey"
# Removing the plugin deletes this script, so nothing can take the block out on
# the way past. The block is inert once the id no longer resolves, but somebody
# reading their own bindings.lua months later has no plugin left to ask.
MARK_NOTE="-- If Omascratch has been uninstalled these lines do nothing: delete them."

# Where bindings.lua really lives. A dotfiles manager (stow, chezmoi) puts a
# symlink at ~/.config/hypr/bindings.lua pointing into its own repository;
# refusing outright left those users unable to rebind at all, and staging beside
# the LINK and renaming over it would replace the link with a plain file,
# orphaning the repo so every later change stopped reaching Hyprland. Resolving
# first means the write lands on the real file, in its own directory, and the
# link survives. Target and directory must both be the user's and writable by
# nobody else.
resolve_bind_file() {
  local real dir mode
  real=$(realpath -- "$BIND_FILE" 2>/dev/null) || return 1
  [[ -f $real ]] || return 1
  dir=$(dirname -- "$real")
  if [[ ! -O $real || ! -O $dir ]]; then
    echo "ERROR: refusing to write $real — it is not yours" >&2
    return 1
  fi
  mode=$(stat -c %a -- "$dir" 2>/dev/null) || return 1
  if (( 8#$mode & 8#022 )); then
    echo "ERROR: refusing to write into $dir — it is writable by others" >&2
    return 1
  fi
  printf '%s' "$real"
}

# An opening marker whose closing marker is missing would otherwise swallow
# every line after it: a `skip` flag cleared only by the terminator runs an
# unbalanced block to the end of the file, and the rest of the user's
# keybindings go with it, silently. A half-removed block is an ordinary thing to
# find — a hand edit, a merge conflict in a dotfiles repo — so a block that is
# not a matched, ordered pair is not a block this script understands, and it
# refuses to touch the file at all.
#
# Both this and strip_block read the file the write will land on — the resolved
# one — rather than the name it was reached by. Inspecting through the link and
# writing to its target leaves a window in which the link can be swung at
# another readable file between the two.
check_markers() {
  local file="$1" opens closes o c
  opens=$(grep -c -- ">>> omascratch hotkey" "$file" || true)
  closes=$(grep -c -- "<<< omascratch hotkey" "$file" || true)
  if (( opens != closes )); then
    echo "ERROR: refusing to edit $file — its omascratch hotkey block is not a matched pair ($opens opening, $closes closing)" >&2
    return 1
  fi
  if (( opens > 1 )); then
    echo "ERROR: refusing to edit $file — $opens omascratch hotkey blocks, expected at most one" >&2
    return 1
  fi
  if (( opens == 1 )); then
    o=$(grep -n -- ">>> omascratch hotkey" "$file" | head -1 | cut -d: -f1)
    c=$(grep -n -- "<<< omascratch hotkey" "$file" | head -1 | cut -d: -f1)
    if (( c < o )); then
      echo "ERROR: refusing to edit $file — its omascratch hotkey block closes before it opens" >&2
      return 1
    fi
  fi
  return 0
}

strip_block() {
  local file="$1"
  # Two things come out. The marked block, with the blank line above it: that
  # blank is ours, so stripping only the marked lines would leave one behind on
  # every re-bind, and three hotkey changes would mean three orphan blank lines
  # in a file the README promises is otherwise untouched. Blank lines the user
  # has of their own are held and re-emitted; exactly one, immediately above the
  # opening marker, is dropped.
  #
  # And any unmarked `o.bind` line for this plugin's own toggle — the shape
  # every install before 0.2.0 had, added by hand from the README. Leaving it
  # would bind the old shortcut and the new one to the same panel, with the
  # panel showing only the new one. It is this plugin's own line and no other,
  # matched on the full toggle command; a blank line beside it belongs to the
  # user and is kept.
  #
  # The line has to *start* with the call. Matching the call anywhere on the
  # line also matched `-- o.bind("SUPER + R", … omascratch …)`, which is what
  # somebody who has parked their old shortcut in a comment has — and deleting
  # a commented-out line is not migrating a binding, it is throwing away
  # something the user deliberately kept.
  awk -v toggle="$TOGGLE" '
    function flush(  i) { for (i = 0; i < pending; i++) print ""; pending = 0 }
    index($0, ">>> omascratch hotkey") { if (pending > 0) pending--; flush(); skip = 1; next }
    index($0, "<<< omascratch hotkey") { skip = 0; next }
    skip { next }
    index($0, toggle) && $0 ~ /^[[:space:]]*o\.bind\(/ { flush(); next }
    $0 == "" { pending++; next }
    { flush(); print }
    END { flush() }
  ' "$file"
}

# The shape a hotkey may have. Held in a variable because it contains spaces —
# and it must contain literal spaces, not [[:space:]], which also matches a
# newline and a tab. The settings card checks a literal space, so anything
# looser here is a gap between the two guards.
KEY_SHAPE='^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$'

case "${1:-}" in
  bind)
    NEWCOMBO="${2:?usage: omascratch-ctl.sh bind \"SUPER + X\"}"
    # This value ends up inside a Lua string in bindings.lua, so it is checked
    # here as well as in the panel — this file can be run without ever going
    # near the UI. A hotkey is modifiers plus one key and nothing else;
    # anything that does not match that shape is refused rather than escaped,
    # because there is no reason for it to exist.
    if ! [[ $NEWCOMBO =~ $KEY_SHAPE ]]; then
      echo "ERROR: refusing a hotkey that is not modifiers plus one key: $NEWCOMBO" >&2
      exit 2
    fi
    ;;
  unbind)
    NEWCOMBO=""
    ;;
  *)
    echo "usage: omascratch-ctl.sh {bind \"SUPER + X\"|unbind}" >&2
    exit 2
    ;;
esac

if [ ! -e "$BIND_FILE" ]; then
  echo "ERROR: $BIND_FILE not found" >&2
  exit 2
fi

REAL_BIND=$(resolve_bind_file) || exit 2
check_markers "$REAL_BIND" || exit 2

# The backup and the staged edit both live in the same directory as the resolved
# config, under unpredictable names created exclusively by mktemp — never
# following a symlink — so nothing can have been planted at either name, and the
# rename that swaps the edit in is a single atomic step on the same filesystem.
# The backup is only needed long enough to revert a bad edit.
DIR=$(dirname -- "$REAL_BIND")
BACKUP=$(mktemp "$DIR/.bindings.bak.XXXXXXXX")
TMP=$(mktemp "$DIR/.bindings.tmp.XXXXXXXX")
trap 'rm -f "$BACKUP" "$TMP"' EXIT
cp "$REAL_BIND" "$BACKUP"
chmod --reference="$REAL_BIND" "$TMP" 2>/dev/null || chmod 644 "$TMP"

strip_block "$REAL_BIND" > "$TMP"
if [ -n "$NEWCOMBO" ]; then
  {
    echo ""
    echo "$MARK_IN"
    echo "$MARK_NOTE"
    printf 'o.bind("%s", "Toggle Omascratch", "%s")\n' "$NEWCOMBO" "$TOGGLE"
    echo "$MARK_OUT"
  } >> "$TMP"
fi
mv -f "$TMP" "$REAL_BIND"

# From here the config on disk has already changed, so every failure has to put
# it back. `set -e` would abort before the revert and the EXIT trap would then
# delete the backup, leaving the file edited, unverified and unrecoverable — so
# these two calls are guarded rather than trusted.
restore() {
  cp "$BACKUP" "$REAL_BIND"
  hyprctl reload >/dev/null 2>&1 || true
}

if ! hyprctl reload >/dev/null 2>&1; then
  restore
  echo "ERROR: could not ask Hyprland to reload; the shortcut was put back" >&2
  exit 1
fi

# Capped where the bytes are produced rather than where they are shown. This
# goes to stderr, and the panel collects that whole stream into the shell
# process before anything looks at it — `hyprctl configerrors` on a config that
# is badly broken has no small upper bound, and the panel then renders it.
if ! ERRS="$(hyprctl configerrors 2>/dev/null | head -c 2000)"; then
  restore
  echo "ERROR: could not read Hyprland's config errors; the shortcut was put back" >&2
  exit 1
fi
if [ -n "$ERRS" ]; then
  restore
  echo "ERROR: $ERRS" >&2
  exit 1
fi

echo "OK: ${NEWCOMBO:-unbound}"
