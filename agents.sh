#!/bin/bash
# Omarchy agents widget helper.
#
#   agents.sh state   -> one JSON blob: every known agent with its label, icon,
#                        install state, whether it is the default, and whether
#                        it currently has / is focused in an agent terminal.
#   agents.sh list    -> just the JSON array of agents (a slice of state)
#   agents.sh active  -> just {focused, open}
#   agents.sh set ID  -> write ID to ~/.config/omarchy/defaults/agent
#
# The per-agent metadata (label, icon glyph, icon font) lives in agents.json
# beside this script. Everything else is derived.

set -uo pipefail

self_dir=$(dirname "$(readlink -f "$0")")
meta_path="$HOME/.config/omarchy/plugins/tomliu.agents/agents.json"
[[ -f $meta_path ]] || meta_path="$self_dir/agents.json"

# Fallback id list if the metadata file is missing.
KNOWN_AGENTS=(pi omp opencode claude codex crush grok gemini openclaw hermes copilot muse cursor-agent)

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

# Populates OPEN_IDS and FOCUSED.
scan_active() {
  OPEN_IDS=()
  FOCUSED=""
  local json active_addr addr pid id
  json=$(hyprctl clients -j 2>/dev/null) || json="[]"
  active_addr=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty' 2>/dev/null)

  while IFS=$'\t' read -r addr pid; do
    [[ -n $pid && -d /proc/$pid ]] || continue
    id=$(resolve_agent "$pid" 2>/dev/null) || continue
    [[ -n $id ]] || continue
    OPEN_IDS+=("$id")
    [[ -n $active_addr && $addr == "$active_addr" ]] && FOCUSED="$id"
  done < <(jq -r '.[] | select(.class == "org.omarchy.agent") | [.address, (.pid|tostring)] | @tsv' <<<"$json" 2>/dev/null)
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
*)
  echo "usage: agents.sh <state|list|active|set ID>" >&2
  exit 1
  ;;
esac
