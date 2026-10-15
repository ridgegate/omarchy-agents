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
#
# The per-agent metadata (label, icon glyph, icon font) lives in agents.json
# beside this script. Everything else is derived.

set -uo pipefail

self_dir=$(dirname "$(readlink -f "$0")")
meta_path="$self_dir/agents.json"

# Fallback id list if the metadata file is missing.
KNOWN_AGENTS=(pi omp opencode claude codex crush grok gemini openclaw hermes copilot muse cursor-agent)

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

# command -v is the same PATH the omarchy wrappers use (mise shims and
# ~/.local/bin included), so it agrees with what omarchy-default-agent treats
# as an install.
is_installed() { command -v "$1" >/dev/null 2>&1; }

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
  f="$HOME/.config/omarchy/defaults/agent"
  prev=$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$id" >"$f"
  setsid bash -c 'cd "$HOME" && exec omarchy-agent' >/dev/null 2>&1 </dev/null &
  sleep 0.6
  if [[ -n $prev ]]; then printf '%s\n' "$prev" >"$f"; else rm -f "$f"; fi
}

build_state() {
  local default installed_json open_json
  default=$(default_agent)

  local -a installed=()
  local id
  while IFS= read -r id; do
    [[ -n $id ]] && is_installed "$id" && installed+=("$id")
  done < <(jq -r '.[].id' <<<"$meta")

  # Nothing installed: keep every known agent so the picker still has rows.
  if ((${#installed[@]} == 0)); then
    while IFS= read -r id; do [[ -n $id ]] && installed+=("$id"); done < <(jq -r '.[].id' <<<"$meta")
  fi
  installed_json=$(json_list "${installed[@]}")

  scan_active
  open_json=$(json_list "${OPEN_IDS[@]+"${OPEN_IDS[@]}"}")

  jq -n \
    --arg default "$default" \
    --arg focused "$FOCUSED" \
    --argjson meta "$meta" \
    --argjson installed "$installed_json" \
    --argjson open "$open_json" \
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
            focused: ($m.id == $focused)
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
*)
  echo "usage: agents.sh <state|list|active|set ID|focus ID|launch ID|activate ID>" >&2
  exit 1
  ;;
esac
