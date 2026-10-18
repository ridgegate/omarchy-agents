#!/bin/bash
# Omarchy agents widget helper.
#
#   agents.sh state   -> one JSON blob: every known agent with its label, icon,
#                        install state, whether it is the default, and whether
#                        it currently has / is focused in an agent terminal.
#   agents.sh list    -> just the JSON array of agents (a slice of state)
#   agents.sh active  -> just {focused, open}
#   agents.sh set ID  -> write ID to ~/.config/omarchy/defaults/agent
#   agents.sh focus ID   -> focus ID's terminal if it is open (fails if not)
#   agents.sh launch ID  -> open ID in a new Omarchy agent terminal
#   agents.sh activate ID -> focus ID's terminal if open, else launch it
#   agents.sh hide ID    -> leave ID out of the panel's agent list
#   agents.sh show ID    -> put ID back in the list
#   agents.sh shortcut set ID COMBO -> bind COMBO (e.g. "SUPER + SHIFT + A") to
#                        activate ID; a combo belongs to one agent at a time
#   agents.sh shortcut clear ID     -> drop ID's shortcut
#   agents.sh shortcut apply        -> regenerate the Hyprland module from the store
#
# The per-agent metadata (label, icon glyph, icon font) lives in agents.json
# beside this script. Everything else is derived.

set -uo pipefail

self_dir=$(dirname "$(readlink -f "$0")")
meta_path="$self_dir/agents.json"

# Fallback id list if the metadata file is missing.
KNOWN_AGENTS=(pi omp opencode claude codex crush grok gemini agy openclaw hermes copilot muse cursor-agent)

# Shortcuts are stored as {id: combo} and compiled into a Lua module that
# ~/.config/hypr/bindings.lua requires, so they survive shell and plugin reloads.
shortcuts_path="$HOME/.config/omarchy/agent-shortcuts.json"
shortcuts_lua="$HOME/.config/hypr/agent-shortcuts.lua"
hypr_bindings="$HOME/.config/hypr/bindings.lua"
# Agents left out of the panel's list, as a JSON array of ids. Hiding only
# tidies the menu: a hidden agent keeps its shortcut and still launches.
hidden_path="$HOME/.config/omarchy/agents-hidden.json"

# id -> Hyprland window address for agents that currently have a terminal open.
declare -A ID_ADDR=()

if [[ -f $meta_path ]]; then
  meta=$(cat "$meta_path")
else
  meta=$(printf '%s\n' "${KNOWN_AGENTS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | map({id: ., label: ., icon: "", iconFont: ""})')
fi

json_list() {
  if (($# == 0)); then echo '[]'; else printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))'; fi
}

default_agent() {
  local f="$HOME/.config/omarchy/defaults/agent"
  [[ -f $f ]] && head -n1 "$f" 2>/dev/null | tr -d '[:space:]'
}

# An agent counts as installed the way Omarchy's own agent setup does: a real
# install at ~/.local/bin/<id> (a symlink or a script Omarchy did not write), or
# a tool that is actually installed in mise. The ~/.local/bin/<id> mise wrapper
# exists for every agent Omarchy has ever set as default — it installs on first
# run — so its mere presence proves nothing. For those, ask mise whether the
# package the wrapper would run is really installed.
is_installed() {
  local id=$1 f="$HOME/.local/bin/$id" line pkg
  if [[ -e $f ]]; then
    if [[ -L $f ]] || ! grep -q '^mise use -g' "$f" 2>/dev/null; then
      return 0
    fi
    while IFS= read -r line; do
      [[ $line == 'exec mise x '* ]] || continue
      pkg=${line#exec mise x }
      pkg=${pkg%% -- *}
      pkg=${pkg#\"}
      pkg=${pkg%\"}
      break
    done <"$f"
    if [[ -n $pkg ]] && mise where "$pkg" >/dev/null 2>&1; then return 0; fi
    return 1
  fi
  command -v "$id" >/dev/null 2>&1
}

# --- active terminal resolution -------------------------------------------
#
# hyprctl gives the pid of each org.omarchy.agent window; the agent is whichever
# known binary appears in that window's process tree. We look at each
# descendant's exe basename, its cmdline token basenames, and any
# .../installs/<id>/ path so mise-shimmed agents (gemini -> node) resolve too.

resolve_agent() {
  local root=$1 id
  local -a queue=("$root")
  local -a seen=()
  local p exe cmd hay tok base

  while ((${#queue[@]})); do
    p=${queue[0]}
    queue=("${queue[@]:1}")
    [[ " ${seen[*]} " == *" $p "* ]] && continue
    seen+=("$p")

    exe=$(readlink -f "/proc/$p/exe" 2>/dev/null || true)
    base=$(basename "$exe" 2>/dev/null || true)
    for id in "${KNOWN_AGENTS[@]}"; do
      [[ $base == "$id" ]] && { echo "$id"; return 0; }
    done

    cmd=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null || true)
    hay="$exe $cmd"
    for id in "${KNOWN_AGENTS[@]}"; do
      [[ $hay == *"/installs/$id/"* ]] && { echo "$id"; return 0; }
    done

    for tok in $cmd; do
      base=$(basename "${tok%%=*}" 2>/dev/null || true)
      for id in "${KNOWN_AGENTS[@]}"; do
        [[ $base == "$id" ]] && { echo "$id"; return 0; }
      done
    done

    while read -r tok; do
      [[ -n $tok ]] && queue+=("$tok")
    done < <(tr ' ' '\n' <"/proc/$p/task/$p/children" 2>/dev/null)
  done
  return 1
}

# Populates OPEN_IDS, FOCUSED, and ID_ADDR.
scan_active() {
  OPEN_IDS=()
  FOCUSED=""
  ID_ADDR=()
  local json active_addr addr pid id
  json=$(hyprctl clients -j 2>/dev/null) || json="[]"
  active_addr=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty' 2>/dev/null)

  while IFS=$'\t' read -r addr pid; do
    [[ -n $pid && -d /proc/$pid ]] || continue
    id=$(resolve_agent "$pid" 2>/dev/null) || continue
    [[ -n $id ]] || continue
    OPEN_IDS+=("$id")
    if [[ -n $active_addr && $addr == "$active_addr" ]]; then
      # The focused window wins, but keep a real address recorded.
      FOCUSED="$id"
      ID_ADDR[$id]="$addr"
    else
      # First window seen for this agent, unless the focused one already set it.
      [[ -n ${ID_ADDR[$id]:-} ]] || ID_ADDR[$id]="$addr"
    fi
  done < <(jq -r '.[] | select(.class == "org.omarchy.agent") | [.address, (.pid|tostring)] | @tsv' <<<"$json" 2>/dev/null)
}

# Focus the terminal of an already-open agent by its window address.
focus_agent() {
  local id=$1 addr
  scan_active
  addr=${ID_ADDR[$id]:-}
  [[ -n $addr ]] || return 1
  # Hyprland 0.56+ (Lua config) parses dispatch as Lua, so the classic
  # `focuswindow address:...` string is rejected. Newer first, older fallback.
  if hyprctl eval "hl.dispatch(hl.dsp.focus{window=\"address:$addr\"})" >/dev/null 2>&1; then
    return 0
  fi
  hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
}

# Launch an agent in a new Omarchy agent terminal.
#
# Omarchy only launches the *default* agent: `omarchy-agent` reads
# ~/.config/omarchy/defaults/agent and then execs the matching command (each
# agent has its own flags, e.g. `gemini --yolo`). To honour "clicking an agent
# should not change my default", borrow that launcher without leaving the
# default changed: swap the file in, launch, restore. omarchy-agent reads the
# file immediately, long before it blocks on the terminal, so we detach it and
# restore after a short settle rather than waiting on it.
launch_agent() {
  local id=$1 f prev
  [[ -n $id ]] || { echo "launch needs an agent id" >&2; exit 1; }
  is_installed "$id" || { echo "$id is not installed" >&2; exit 1; }

  # Agents Omarchy's own launcher does not know how to start are launched
  # directly in an agent terminal, with the same unattended flag the Omarchy
  # ones use. Startup flags for these live here.
  # Start where you are working: the focused terminal's directory, as Omarchy's
  # own terminal binding does. omarchy-agent moves a $HOME start to ~/Work.
  local dir
  dir=$(omarchy-cmd-terminal-cwd 2>/dev/null)
  [[ -d $dir ]] || dir="$HOME"

  local -a direct=()
  case $id in
  agy) direct=(agy --dangerously-skip-permissions) ;;
  esac
  if ((${#direct[@]})); then
    [[ $dir == "$HOME" && -d $HOME/Work ]] && dir="$HOME/Work"
    setsid bash -c 'cd "$1" && shift && exec omarchy-launch-tui --app-id=org.omarchy.agent "$@"' \
      _ "$dir" "${direct[@]}" >/dev/null 2>&1 </dev/null &
    return 0
  fi

  f="$HOME/.config/omarchy/defaults/agent"
  prev=$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$id" >"$f"
  setsid bash -c 'cd "$1" && exec omarchy-agent' _ "$dir" >/dev/null 2>&1 </dev/null &
  sleep 0.6
  if [[ -n $prev ]]; then printf '%s\n' "$prev" >"$f"; else rm -f "$f"; fi
}

shortcuts() {
  local s
  s=$(cat "$shortcuts_path" 2>/dev/null) || s='{}'
  jq -e 'type == "object"' <<<"$s" >/dev/null 2>&1 || s='{}'
  printf '%s\n' "$s"
}

hidden() {
  local h
  h=$(cat "$hidden_path" 2>/dev/null) || h='[]'
  jq -e 'type == "array"' <<<"$h" >/dev/null 2>&1 || h='[]'
  printf '%s\n' "$h"
}

set_hidden() {
  local id=$1 hide=$2 next
  [[ -n $id ]] || { echo "needs an agent id" >&2; exit 1; }
  next=$(hidden | jq -c --arg id "$id" --argjson hide "$hide" \
    'map(select(. != $id)) + (if $hide then [$id] else [] end)')
  mkdir -p "$(dirname "$hidden_path")"
  printf '%s\n' "$next" >"$hidden_path"
}

lua_quote() {
  local v=${1//\\/\\\\}
  printf '"%s"' "${v//\"/\\\"}"
}

# Write the Lua module from the store. Each combo is unbound first so it wins
# over an Omarchy default or an earlier personal binding on the same keys.
write_shortcuts_lua() {
  local id combo label cmd
  mkdir -p "$(dirname "$shortcuts_lua")"
  {
    echo "-- Generated by the Agents bar widget (agentselector.agents). Assign agent"
    echo "-- shortcuts from the widget (or: agents.sh shortcut set ID COMBO) instead of"
    echo "-- editing this file."
    while IFS=$'\t' read -r id combo; do
      [[ -n $id && -n $combo ]] || continue
      label=$(jq -r --arg id "$id" '(.[] | select(.id == $id) | .label) // $id' <<<"$meta")
      cmd="$(printf '%q' "$self_dir/agents.sh") activate $(printf '%q' "$id")"
      echo
      echo "hl.unbind($(lua_quote "$combo"))"
      echo "o.bind($(lua_quote "$combo"), $(lua_quote "$label (agent)"), $(lua_quote "$cmd"))"
    done < <(shortcuts | jq -r 'to_entries[] | [.key, .value] | @tsv')
  } >"$shortcuts_lua.tmp" && mv "$shortcuts_lua.tmp" "$shortcuts_lua"
}

# The module only takes effect once bindings.lua requires it. It goes last, so
# an agent shortcut wins over a personal binding on the same keys.
ensure_required() {
  [[ -f $hypr_bindings ]] || return 0
  grep -q 'require("hypr.agent-shortcuts")' "$hypr_bindings" && return 0
  printf '\n-- Agent shortcuts assigned from the Agents bar widget (agentselector.agents).\nrequire("hypr.agent-shortcuts")\n' >>"$hypr_bindings"
}

# Rebuild the module and reload Hyprland. A combo Hyprland rejects rolls the
# store and the module back to what they were, so a bad key never sticks.
apply_shortcuts() {
  local before=$1 errors
  write_shortcuts_lua
  ensure_required
  hyprctl reload >/dev/null 2>&1
  errors=$(hyprctl configerrors 2>/dev/null | grep -v '^\s*$')
  if [[ -n $errors ]] && grep -q 'agent-shortcuts' <<<"$errors"; then
    printf '%s\n' "$before" >"$shortcuts_path"
    write_shortcuts_lua
    hyprctl reload >/dev/null 2>&1
    echo "Hyprland rejected the shortcut: $errors" >&2
    return 1
  fi
}

# Only combos the panel can record: modifiers from Hyprland's own spelling and
# one key that xkb knows by name. Hyprland binds an unknown key name without
# complaint, so the check has to happen here.
valid_combo() {
  local -a parts
  local part key n
  IFS='+' read -ra parts <<<"$1"
  n=${#parts[@]}
  ((n >= 1)) || return 1
  key=$(tr -d '[:space:]' <<<"${parts[n - 1]}")
  for part in "${parts[@]:0:n-1}"; do
    part=$(tr -d '[:space:]' <<<"$part")
    [[ ${part^^} =~ ^(SUPER|SHIFT|CTRL|ALT)$ ]] || return 1
  done
  [[ $key =~ ^([A-Za-z0-9]|F([1-9]|1[0-9]|2[0-4]))$ ]] && return 0
  [[ ${key^^} =~ ^(RETURN|SPACE|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PRIOR|NEXT|UP|DOWN|LEFT|RIGHT|MINUS|EQUAL|COMMA|PERIOD|SLASH|BACKSLASH|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT)$ ]]
}

shortcut_cmd() {
  local action=${1:-} id=${2:-} combo=${3:-} before
  before=$(shortcuts)
  mkdir -p "$(dirname "$shortcuts_path")"
  case $action in
  set)
    [[ -n $id && -n $combo ]] || { echo "shortcut set needs an agent id and a combo" >&2; exit 1; }
    valid_combo "$combo" || { echo "Not a combo Hyprland can bind: $combo" >&2; exit 1; }
    jq --arg id "$id" --arg combo "$combo" \
      'with_entries(select(.value != $combo)) + {($id): $combo}' <<<"$before" >"$shortcuts_path"
    ;;
  clear)
    [[ -n $id ]] || { echo "shortcut clear needs an agent id" >&2; exit 1; }
    jq --arg id "$id" 'del(.[$id])' <<<"$before" >"$shortcuts_path"
    ;;
  apply) ;;
  *) echo "usage: agents.sh shortcut <set ID COMBO|clear ID|apply>" >&2; exit 1 ;;
  esac
  apply_shortcuts "$before" || exit 1
}

build_state() {
  local default installed_json open_json
  default=$(default_agent)

  local -a installed=()
  local id
  while IFS= read -r id; do
    [[ -n $id ]] && is_installed "$id" && installed+=("$id")
  done < <(jq -r '.[].id' <<<"$meta")
  installed_json=$(json_list "${installed[@]}")

  scan_active
  open_json=$(json_list "${OPEN_IDS[@]+"${OPEN_IDS[@]}"}")

  jq -n \
    --arg default "$default" \
    --arg focused "$FOCUSED" \
    --argjson meta "$meta" \
    --argjson installed "$installed_json" \
    --argjson open "$open_json" \
    --argjson shortcuts "$(shortcuts)" \
    --argjson hidden "$(hidden)" \
    '
    {
      default: $default,
      focused: $focused,
      agents: [
        $meta[]
        | . as $m
        | select($installed | index($m.id))
        | {
            id: $m.id,
            label: $m.label,
            icon: $m.icon,
            iconFont: ($m.iconFont // ""),
            isDefault: ($m.id == $default),
            running: (($open | index($m.id)) != null),
            focused: ($m.id == $focused),
            shortcut: ($shortcuts[$m.id] // ""),
            hidden: (($hidden | index($m.id)) != null)
          }
      ]
    }'
}

case "${1:-state}" in
state) build_state ;;
list) build_state | jq '.agents' ;;
active) scan_active; jq -n --arg focused "$FOCUSED" --argjson open "$(json_list "${OPEN_IDS[@]+"${OPEN_IDS[@]}"}")" '{focused: $focused, open: $open}' ;;
set)
  shift
  id=${1:-}
  [[ -n $id ]] || { echo "set needs an agent id" >&2; exit 1; }
  mkdir -p "$HOME/.config/omarchy/defaults"
  printf '%s\n' "$id" >"$HOME/.config/omarchy/defaults/agent"
  ;;
focus)
  shift
  id=${1:-}
  [[ -n $id ]] || { echo "focus needs an agent id" >&2; exit 1; }
  focus_agent "$id" || { echo "$id is not open" >&2; exit 1; }
  ;;
launch)
  shift
  launch_agent "${1:-}"
  ;;
activate)
  shift
  id=${1:-}
  [[ -n $id ]] || { echo "activate needs an agent id" >&2; exit 1; }
  # Open or switch: focus the existing terminal, otherwise start one.
  focus_agent "$id" || launch_agent "$id"
  ;;
shortcut)
  shift
  shortcut_cmd "$@"
  ;;
hide) set_hidden "${2:-}" true ;;
show) set_hidden "${2:-}" false ;;
*)
  echo "usage: agents.sh <state|list|active|set ID|focus ID|launch ID|activate ID|hide ID|show ID|shortcut ...>" >&2
  exit 1
  ;;
esac
