# Omarchy Agents

A bar widget for [Omarchy](https://github.com/basecamp/omarchy) that puts your
coding agents one click away: pick the default agent, open or switch to a
running agent's terminal, and read each subscription's usage — all from a single
bar icon.

It is a fork of Omarchy's built-in `omarchy.agents` widget. The usage dashboard
is upstream work; this fork layers an **agent picker and launcher** on top.

## Features

- **Agent picker** — one row per installed agent, with its own mark and an
  `open`/`active` marker when it has a terminal running.
- **Open or switch in one click** — clicking a row focuses that agent's terminal
  if it is already open, or launches it in a new one otherwise. Your default
  agent is never changed by a click.
- **Default agent** — the checkbox on a row writes your default
  (`~/.config/omarchy/defaults/agent`), so `omarchy agent` and the agent
  keybinding follow it.
- **Follows the focused terminal** — while the panel is open it tracks whichever
  agent terminal is focused, and the bar glyph becomes that agent's mark.
- **Usage dashboard** — rate-limit meters with pace, prepaid balance, tokens by
  day, and the all-time model breakdown for each subscription (Claude, Codex,
  Fireworks), unchanged from upstream.

## Requirements

- Omarchy with the shell running (built against the current alpha).
- `bash`, `jq`, and `hyprctl` — all present on a stock Omarchy install.
- At least one coding agent installed (Claude Code, Codex, Copilot, Antigravity, …).
  The picker lists only agents Omarchy treats as installed — a real install at
  `~/.local/bin/<id>`, or a package actually present in `mise` — so a stray
  `~/.local/bin` mise wrapper for an agent you never installed does not appear.

## Install

```bash
omarchy plugin add https://github.com/ridgegate/omarchy-agents.git --enable
```

This clones the repo to `~/.config/omarchy/plugins/agentselector.agents`, validates it,
and adds it to your bar. Since it declares `omarchy.clonedFrom: omarchy.agents`,
it takes the built-in's place in the bar.

If you end up with two agents icons, remove the built-in one:

```bash
omarchy plugin disable omarchy.agents
```

### Manual install (plain git)

```bash
git clone https://github.com/ridgegate/omarchy-agents.git \
  ~/.config/omarchy/plugins/agentselector.agents
omarchy-shell shell rescanPlugins
omarchy plugin enable agentselector.agents
```

The folder name must match the plugin `id` in `manifest.json` (`agentselector.agents`).

### Update

```bash
omarchy plugin update agentselector.agents
```

### Uninstall

```bash
omarchy plugin disable agentselector.agents
omarchy plugin remove agentselector.agents
```

After changing the plugin's QML by hand, run `omarchy restart shell` — a plain
`rescanPlugins` reloads the QML but does not always rebuild a bar widget's newly
added children.

## Usage

- Bar icon **left click** — open the panel.
- Bar icon **right click** — open Omarchy's own agent picker (`omarchy-agent --pick`).
- Bar icon **middle click** — switch to the next subscription.
- In the panel: click an **agent row** to open or switch to its terminal, click
  its **checkbox** to make it the default, `h`/`l` to switch subscription,
  `j`/`k` to scroll, `r`/Enter to refresh, Tab to the neighboring panel, Esc to
  close.
- IPC: `omarchy-shell omarchy.agents toggle` (also `open`, `close`, `refresh`).

## How it works

`agents.sh`, bundled next to `Panel.qml`, does the work:

- **Installed** — an agent is offered only when Omarchy would treat it as
  installed: a real install at `~/.local/bin/<id>` (a symlink, or a script
  Omarchy did not write), or a package that is actually in `mise`. The
  `~/.local/bin` mise wrapper Omarchy writes for each agent is ignored unless
  its package is really installed, so agents that are merely declared — or were
  uninstalled — do not appear. Each id's label, glyph, and icon font live in
  `agents.json`.
- **Default** — read from `~/.config/omarchy/defaults/agent`; `agents.sh set ID`
  writes it.
- **Open / focused** — `hyprctl clients -j` gives the pid of every
  `org.omarchy.agent` window; the agent is whichever known binary appears in
  that window's process tree (exe basename, a `cmdline` token, or an
  `…/installs/<id>/` path, so mise-shimmed agents resolve too). The focused one
  is the active window.
- **Clicking a row** — runs `agents.sh activate ID`, which focuses the agent's
  window if it is open, else launches it. Launching reuses Omarchy's own
  launcher (so each agent gets its usual flags and the shared
  `org.omarchy.agent` app-id) by swapping the default in for the moment of the
  launch and restoring it, so your default never changes.

The widget polls `agents.sh state` every 2 seconds (per bar instance).

## Panel

- **Agent** — the picker described above.
- **Hero** — the mark, the tool, and the plan it runs on ("Max 20x", "Pro").
- **Subscription switch** — one chip per enabled subscription; shown only when
  more than one is enabled.
- **Limits** — percentage of each allowance used, a meter, and the reset
  countdown.
- **Balance** — prepaid subscriptions report a credit ledger instead of limits.
- **Tokens by day / by model** — the last week, and the all-time model split.

## Data

Each subscription is one JSON record in
`~/.local/state/omarchy/agents/usage/`, written by `omarchy-agent-usage-update`.
The widget invokes it on its refresh timer and picks up any record that lands in
the directory. Adding a subscription never touches this plugin — see the
`claude`, `codex`, and `fireworks` collectors in Omarchy's `bin/`.

## Settings

Settings live in the widget's entry in `~/.config/omarchy/shell.json`, set with
`omarchy bar set agentselector.agents <key> <value>`:

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
omarchy bar set agentselector.agents providers '{
  "claude": { "enabled": true },
  "codex":  { "enabled": false },
  "fireworks": { "enabled": true }
}' --json
```

## The plugin id

The id is `agentselector.agents`, so `omarchy plugin add` installs it to
`~/.config/omarchy/plugins/agentselector.agents`. The id is just a namespace — it must
be unique on the machine and outside Omarchy's reserved `omarchy.*` namespace.
The widget finds its helper relative to its own file, so it keeps working if you
rename the id and folder together.

## Credits and license

Forked from Omarchy's built-in `omarchy.agents` widget — the usage dashboard and
the `assets/` marks are upstream work by the Omarchy authors. The agent picker,
`agents.sh`, and `agents.json` are additions in this fork.

MIT — see [LICENSE](LICENSE). Original copyright © David Heinemeier Hansson;
modifications © ridgegate.
