# Omarchy Agents

An Omarchy bar widget that picks your default coding agent **and** shows its
usage. It is a fork of Omarchy's built-in `omarchy.agents` widget that adds an
agent picker on top of the existing usage dashboard.

One bar icon, one panel:

- **Agent picker** — a checkbox row per installed agent. Checked is the system
  default agent; picking a row both focuses that agent's usage view and writes
  it as the default (`~/.config/omarchy/defaults/agent`), so `omarchy-agent`
  and the agent keybinding follow along. A row shows `open`/`active` when it
  has a terminal open, and the focused one is highlighted.
- **Follows the focused terminal** — while the panel is open it auto-selects
  whichever agent terminal is focused, until you pick a row by hand. The bar
  glyph also changes to the focused agent's mark.
- **Usage dashboard** — rate-limit meters, prepaid balance, tokens by day, and
  the all-time model breakdown for each subscription (Claude, Codex,
  Fireworks), unchanged from the upstream widget.

## Requirements

- Omarchy (tested on `4.0.0.alpha`) with the shell running.
- `bash`, `jq`, `hyprctl` (all present on a stock Omarchy install).

## Install

```bash
omarchy plugin add https://github.com/<you>/omarchy-agents.git --enable
```

This widget declares `omarchy.clonedFrom: omarchy.agents`, so it is treated as a
drop-in replacement for the built-in agents widget. After enabling it, take the
built-in off the bar so you don't end up with two agents icons:

```bash
omarchy plugin disable omarchy.agents
```

If the picker or usage view looks stale after editing the plugin, run
`omarchy restart shell` (a plain `rescanPlugins` reloads the QML but does not
always rebuild a bar widget's newly added children).

## How the picker knows what's installed and focused

`agents.sh` (next to `Panel.qml`) does the work:

- **Installed** — an agent is offered when its command is on `PATH`, matching
  what `omarchy-default-agent` treats as an install. The label, glyph, and icon
  font for each id live in `agents.json`.
- **Default** — read from `~/.config/omarchy/defaults/agent`; `agents.sh set ID`
  writes it.
- **Open / focused** — `hyprctl clients -j` gives the pid of every
  `org.omarchy.agent` window; the agent is whichever known binary appears in
  that window's process tree (exe basename, `cmdline` token, or an
  `…/installs/<id>/` path, so mise-shimmed agents resolve too). The focused one
  is the active window.

The widget polls `agents.sh state` every 2 seconds (per bar instance).

## Panel

- **Agent** — the picker described above.
- **Hero** — the mark, the tool, and the plan it runs on ("Max 20x", "Pro").
- **Subscription switch** — one chip per enabled subscription; appears only when
  more than one is enabled.
- **Limits** — percentage of each allowance used, a meter, and the reset
  countdown.
- **Balance** — prepaid subscriptions report a credit ledger instead of limits.
- **Tokens by day / by model** — the last week, and the all-time model split.

Interactions: bar icon left = panel, right = launch the agent picker
(`omarchy-agent --pick`), middle = next subscription. In the panel: `h`/`l`
switch subscription, `j`/`k` scroll, `r`/Enter refresh, Tab moves to the
neighboring panel, Esc closes. IPC: `omarchy-shell shell toggle tomliu.agents`.

## Data

Each subscription is one JSON record in
`~/.local/state/omarchy/agents/usage/`, written by `omarchy-agent-usage-update`.
The widget invokes it on its refresh timer and picks up any record that lands in
the directory. Adding a subscription never touches this plugin — see the
`claude`, `codex`, and `fireworks` collectors in Omarchy's `bin/`.

## Settings

Settings live in the widget's entry in `~/.config/omarchy/shell.json`, set with
`omarchy bar set tomliu.agents <key> <value>`:

| Key | Default | What it does |
|---|---|---|
| `refreshIntervalSec` | `900` | How often the usage records regenerate |
| `syncMode` | `"Off"` | `"On"` writes this machine's snapshot and merges the others |
| `syncDir` | `""` | A folder synced by Syncthing, Dropbox, rsync, … |
| `syncFileName` | `<hostname>.json` | This machine's snapshot file |
| `syncDeviceId` | hostname | Stable device name inside the snapshot |

Per-subscription enablement is nested; pass the whole `providers` object as
JSON:

```bash
omarchy bar set tomliu.agents providers '{
  "claude": { "enabled": true },
  "codex":  { "enabled": false },
  "fireworks": { "enabled": true }
}' --json
```

## Credits and license

Forked from the Omarchy built-in `omarchy.agents` widget (the usage dashboard,
`Main.qml`, `Agent.qml`, and the `assets/` marks are upstream work). The agent
picker, `agents.sh`, and `agents.json` are additions in this fork.

MIT — see [LICENSE](LICENSE). Original copyright © David Heinemeier Hansson;
modifications © Tom Liu.
