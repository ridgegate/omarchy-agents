import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "omarchy.agents"
  ipcTarget: "omarchy.agents"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var providers: usage.enabledProviders
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }

  // --------------------------------------------------------------- agents
  //
  // The picker is driven by agents.sh, which reports every installed coding
  // agent with its label, its mark, whether it is the default, and whether it
  // currently has (or is focused in) an org.omarchy.agent terminal. The usage
  // dashboard below then follows whichever agent is selected.

  // Resolved next to this file, so the plugin works under any install id or
  // path — a rename, a fork, or a manual clone — instead of pinning
  // ~/.config/omarchy/plugins/<id>/agents.sh with a literal id.
  readonly property string helperScript: {
    var url = String(Qt.resolvedUrl("agents.sh"))
    return url.indexOf("file://") === 0 ? url.slice(7) : url
  }
  property var agentState: ({ "agents": [], "default": "", "focused": "" })
  readonly property var agentRows: agentState.agents || []
  property int agentRevision: 0
  property string defaultAgentId: ""
  property string focusedAgentId: ""
  // The agent whose row is selected. "" means the panel is browsing a
  // subscription provider directly (the pre-existing provider-switch path).
  property string selectedAgentId: ""
  property bool agentInit: false
  // Set when a row is picked by hand, so auto-follow stops overriding the
  // choice until the panel is reopened.
  property bool manualPick: false
  property string lastFollowedAgent: ""
  // The raw state text, so an identical poll does not rebuild every row.
  property string lastAgentStateText: ""

  // ------------------------------------------------------------- shortcuts
  //
  // One agent at a time can be in the shortcut editor. Modifiers come from
  // the keys held while recording or from the chips, so a combo Hyprland
  // already swallows (it never reaches the panel) can still be entered by
  // toggling its modifiers and pressing the bare key.
  property string editingAgentId: ""
  property bool modSuper: false
  property bool modShift: false
  property bool modCtrl: false
  property bool modAlt: false
  property string recordedKey: ""
  property string shortcutError: ""
  property bool shortcutBusy: false
  property var hyprBinds: []

  readonly property var editingAgentRow: {
    for (var i = 0; i < agentRows.length; i++)
      if (agentRows[i].id === editingAgentId) return agentRows[i]
    return null
  }
  readonly property string pendingCombo: comboString(modSuper, modShift, modCtrl, modAlt, recordedKey)
  readonly property string pendingProblem: comboProblem()
  readonly property string pendingConflict: comboConflict(pendingCombo)

  readonly property var focusedAgentRow: {
    for (var i = 0; i < agentRows.length; i++)
      if (agentRows[i].focused) return agentRows[i]
    return null
  }

  function providerForAgentId(id) {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === id) return providers[i]
    return null
  }

  function agentLabel(id) {
    for (var i = 0; i < agentRows.length; i++)
      if (agentRows[i].id === id) return String(agentRows[i].label || id)
    return String(id || "")
  }

  readonly property var selectedAgentProvider:
    selectedAgentId === "" ? null : providerForAgentId(selectedAgentId)
  // An agent with no usage collector gets a placeholder instead of a stale
  // subscription; browsing a provider directly keeps the old switch path.
  readonly property bool agentHasNoUsage:
    selectedAgentId !== "" && selectedAgentProvider === null
  readonly property var provider: agentHasNoUsage
    ? null
    : (providers.length > 0 ? providers[providerIndex] : null)

  property bool cursorActive: false

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property var limits: limitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  readonly property bool alarming: (!!headline && headline.percent >= 0.9) || balanceAlarming

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ------------------------------------------------------------ agent pick
  //
  // Clicking a row opens or switches to that agent's terminal and moves the
  // usage view onto it; the checkbox is the separate control that writes the
  // default agent, so `omarchy agent` and the keybinding follow along.

  function selectAgent(id) {
    if (id === "") return
    manualPick = true
    cursorActive = true
    focusAgent(id)
  }

  function focusAgent(id) {
    selectedAgentId = id
    var p = providerForAgentId(id)
    if (p) selectedProviderId = p.providerId
  }

  // A row click goes to the agent: focus its terminal if one is already open,
  // otherwise launch it in a new terminal. It also moves the usage view onto
  // that agent, but it deliberately leaves the *default* agent alone — the
  // checkbox is how you change which agent `omarchy agent` starts.
  function activateAgent(id) {
    if (id === "") return
    selectAgent(id)
    actionProc.command = [root.helperScript, "activate", id]
    if (!actionProc.running) actionProc.running = true
  }

  function setDefaultAgent(id) {
    if (id === "") return
    // Optimistic: the checkbox and the bar tooltip flip now, not in two ticks.
    defaultAgentId = id
    setAgentProc.command = [root.helperScript, "set", id]
    if (!setAgentProc.running) setAgentProc.running = true
  }

  function refreshAgentState() {
    if (!agentProc.running) agentProc.running = true
  }

  function applyAgentState(text) {
    if (String(text) === lastAgentStateText) { maybeFollowFocused(); return }
    var parsed
    try { parsed = JSON.parse(String(text || "")) } catch (e) { return }
    if (!parsed || !parsed.agents) return
    lastAgentStateText = String(text)
    agentState = parsed
    agentRevision++
    defaultAgentId = String(parsed.default || "")
    focusedAgentId = String(parsed.focused || "")
    if (!agentInit) {
      agentInit = true
      // Open where the data is: the focused agent if it has a usage collector,
      // else the default if it has one, else the first provider. The checkbox
      // still marks the default agent regardless of what is selected.
      var seed = ""
      if (focusedAgentId !== "" && providerForAgentId(focusedAgentId))
        seed = focusedAgentId
      else if (defaultAgentId !== "" && providerForAgentId(defaultAgentId))
        seed = defaultAgentId
      else if (providers.length > 0)
        seed = providers[0].providerId
      focusAgent(seed)
    }
    maybeFollowFocused()
  }

  // Auto-follow: while the panel is open and the user has not picked a row by
  // hand, a change of focused agent terminal moves the selection with it.
  function maybeFollowFocused() {
    var id = focusedAgentId
    if (id === "" || id === lastFollowedAgent) return
    lastFollowedAgent = id
    if (root.opened && !manualPick) focusAgent(id)
  }

  function startShortcutEdit(id) {
    if (id === "") return
    var current = ""
    for (var i = 0; i < agentRows.length; i++)
      if (agentRows[i].id === id) current = String(agentRows[i].shortcut || "")
    editingAgentId = id
    selectAgent(id)
    loadCombo(current)
    shortcutError = ""
    if (!bindsProc.running) bindsProc.running = true
    Qt.callLater(function() { recorder.forceActiveFocus() })
  }

  function endShortcutEdit() {
    editingAgentId = ""
    shortcutError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function loadCombo(combo) {
    var parts = String(combo || "").split("+").map(function(p) { return p.trim().toUpperCase() })
    modSuper = parts.indexOf("SUPER") >= 0
    modShift = parts.indexOf("SHIFT") >= 0
    modCtrl = parts.indexOf("CTRL") >= 0
    modAlt = parts.indexOf("ALT") >= 0
    var last = parts.length > 0 ? parts[parts.length - 1] : ""
    recordedKey = ["", "SUPER", "SHIFT", "CTRL", "ALT"].indexOf(last) >= 0 ? "" : last
  }

  function comboString(sup, shift, ctrl, alt, key) {
    if (key === "") return ""
    var parts = []
    if (sup) parts.push("SUPER")
    if (shift) parts.push("SHIFT")
    if (ctrl) parts.push("CTRL")
    if (alt) parts.push("ALT")
    parts.push(key)
    return parts.join(" + ")
  }

  // "SUPER + SHIFT + A" reads as "Super+Shift+A" on a row.
  function prettyCombo(combo) {
    if (String(combo || "") === "") return ""
    return String(combo).split("+").map(function(p) {
      p = p.trim()
      return p.length > 1 && !/^F\d+$/.test(p) ? p.charAt(0) + p.slice(1).toLowerCase() : p
    }).join("+")
  }

  // A bare letter would steal it from every text field, so a combo needs a
  // modifier unless its key is a function key.
  function comboProblem() {
    if (recordedKey === "") return ""
    if (!modSuper && !modShift && !modCtrl && !modAlt && !/^F\d+$/.test(recordedKey))
      return "Add a modifier (Super, Ctrl, or Alt) so the key still types normally."
    if (!modSuper && !modCtrl && !modAlt)
      return "Shift alone still types the key. Add Super, Ctrl, or Alt."
    return ""
  }

  function comboMask(combo) {
    var parts = String(combo).split("+").map(function(p) { return p.trim().toUpperCase() })
    var mask = 0
    if (parts.indexOf("SHIFT") >= 0) mask |= 1
    if (parts.indexOf("CTRL") >= 0) mask |= 4
    if (parts.indexOf("ALT") >= 0) mask |= 8
    if (parts.indexOf("SUPER") >= 0) mask |= 64
    return mask
  }

  // What the combo is bound to right now, other than this agent itself.
  function comboConflict(combo) {
    if (combo === "" || editingAgentId === "") return ""
    var parts = combo.split("+")
    var key = parts[parts.length - 1].trim().toUpperCase()
    var mask = comboMask(combo)
    var own = (editingAgentRow ? editingAgentRow.label : editingAgentId) + " (agent)"
    for (var i = 0; i < hyprBinds.length; i++) {
      var b = hyprBinds[i]
      if (String(b.submap || "") !== "" || b.mouse) continue
      if (Number(b.modmask) !== mask || String(b.key || "").toUpperCase() !== key) continue
      var desc = String(b.description || b.dispatcher || "another action")
      if (desc === own) continue
      return desc
    }
    return ""
  }

  // Qt key -> the xkb name Hyprland binds. Shifted digits map back to their
  // digit so Shift+1 records as 1, not "!".
  function keyNameFor(event) {
    var k = event.key
    if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(k)
    if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode(k)
    if (k >= Qt.Key_F1 && k <= Qt.Key_F24) return "F" + (k - Qt.Key_F1 + 1)
    var names = {}
    names[Qt.Key_Exclam] = "1"; names[Qt.Key_At] = "2"; names[Qt.Key_NumberSign] = "3"
    names[Qt.Key_Dollar] = "4"; names[Qt.Key_Percent] = "5"; names[Qt.Key_AsciiCircum] = "6"
    names[Qt.Key_Ampersand] = "7"; names[Qt.Key_Asterisk] = "8"; names[Qt.Key_ParenLeft] = "9"
    names[Qt.Key_ParenRight] = "0"
    names[Qt.Key_Return] = "RETURN"; names[Qt.Key_Enter] = "RETURN"; names[Qt.Key_Space] = "SPACE"
    names[Qt.Key_Tab] = "TAB"; names[Qt.Key_Backtab] = "TAB"; names[Qt.Key_Backspace] = "BACKSPACE"
    names[Qt.Key_Delete] = "DELETE"; names[Qt.Key_Insert] = "INSERT"; names[Qt.Key_Home] = "HOME"
    names[Qt.Key_End] = "END"; names[Qt.Key_PageUp] = "PRIOR"; names[Qt.Key_PageDown] = "NEXT"
    names[Qt.Key_Up] = "UP"; names[Qt.Key_Down] = "DOWN"; names[Qt.Key_Left] = "LEFT"
    names[Qt.Key_Right] = "RIGHT"
    names[Qt.Key_Minus] = "MINUS"; names[Qt.Key_Underscore] = "MINUS"
    names[Qt.Key_Equal] = "EQUAL"; names[Qt.Key_Plus] = "EQUAL"
    names[Qt.Key_Comma] = "COMMA"; names[Qt.Key_Less] = "COMMA"
    names[Qt.Key_Period] = "PERIOD"; names[Qt.Key_Greater] = "PERIOD"
    names[Qt.Key_Slash] = "SLASH"; names[Qt.Key_Question] = "SLASH"
    names[Qt.Key_Backslash] = "BACKSLASH"; names[Qt.Key_Bar] = "BACKSLASH"
    names[Qt.Key_Semicolon] = "SEMICOLON"; names[Qt.Key_Colon] = "SEMICOLON"
    names[Qt.Key_Apostrophe] = "APOSTROPHE"; names[Qt.Key_QuoteDbl] = "APOSTROPHE"
    names[Qt.Key_QuoteLeft] = "GRAVE"; names[Qt.Key_AsciiTilde] = "GRAVE"
    names[Qt.Key_BracketLeft] = "BRACKETLEFT"; names[Qt.Key_BraceLeft] = "BRACKETLEFT"
    names[Qt.Key_BracketRight] = "BRACKETRIGHT"; names[Qt.Key_BraceRight] = "BRACKETRIGHT"
    return names[k] || ""
  }

  function isModifierKey(k) {
    return k === Qt.Key_Shift || k === Qt.Key_Control || k === Qt.Key_Alt || k === Qt.Key_AltGr
      || k === Qt.Key_Meta || k === Qt.Key_Super_L || k === Qt.Key_Super_R
  }

  function recordKey(event) {
    if (event.key === Qt.Key_Escape) { endShortcutEdit(); return }
    var m = event.modifiers
    var held = (m & (Qt.MetaModifier | Qt.ShiftModifier | Qt.ControlModifier | Qt.AltModifier)) !== 0
    if (isModifierKey(event.key)) {
      // A modifier on its own lights its chip; the combo waits for a key.
      if (event.key === Qt.Key_Meta || event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R) modSuper = true
      if (event.key === Qt.Key_Shift) modShift = true
      if (event.key === Qt.Key_Control) modCtrl = true
      if (event.key === Qt.Key_Alt) modAlt = true
      return
    }
    // Enter with nothing held saves a finished combo instead of recording it.
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !held && recordedKey !== "") {
      saveShortcut()
      return
    }
    var name = keyNameFor(event)
    if (name === "") { shortcutError = "That key can't be bound. Try a letter, digit, or F-key."; return }
    shortcutError = ""
    // Held modifiers replace the chips; a bare key keeps whatever is toggled.
    if (held) {
      modSuper = (m & Qt.MetaModifier) !== 0
      modShift = (m & Qt.ShiftModifier) !== 0
      modCtrl = (m & Qt.ControlModifier) !== 0
      modAlt = (m & Qt.AltModifier) !== 0
    }
    recordedKey = name
  }

  function saveShortcut() {
    if (editingAgentId === "" || pendingCombo === "" || pendingProblem !== "" || shortcutBusy) return
    runShortcut(["set", editingAgentId, pendingCombo])
  }

  function clearShortcut() {
    if (editingAgentId === "" || shortcutBusy) return
    runShortcut(["clear", editingAgentId])
  }

  function runShortcut(args) {
    shortcutBusy = true
    shortcutError = ""
    shortcutProc.command = [root.helperScript, "shortcut"].concat(args)
    shortcutProc.running = true
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters and the hero speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title) {
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: Number(percent),
      resetAt: String(resetAt || "")
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return currencyPrefix(currency) + amount.toFixed(2)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. Limits live
  // in their own section; the hero just says what this is.
  function heroMeta(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return p.usageStatusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    if (today) return "Today"
    return dayName(date)
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Number(provider.todayPrompts || 0) + " prompts · "
        + Number(provider.todaySessions || 0) + " sessions"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  function modelRows(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, 4)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + usage.formatTokenCount(row.input)
      + " · out " + usage.formatTokenCount(row.output)
      + " · cache read " + usage.formatTokenCount(row.cacheRead)
      + " · cache write " + usage.formatTokenCount(row.cacheWrite)
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      return "Merged from " + provider.syncDeviceCount + " device" + (provider.syncDeviceCount === 1 ? "" : "s")
    return ""
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing
  // from this panel: assets/<id>.svg if it ships one, the module's bar glyph
  // if it doesn't.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  // The picker keeps the module in the bar even before any usage has been
  // recorded: a machine with agents installed always has something to show.
  visible: root.agentRows.length > 0 || providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (!opened) editingAgentId = ""; else {
    cursorActive = false
    nowMs = Date.now()
    // A fresh open clears the manual hold and re-syncs to whatever agent
    // terminal is focused right now.
    manualPick = false
    lastFollowedAgent = ""
    refreshAgentState()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  // ------------------------------------------------------------ agent scan
  //
  // Kept running whether or not the panel is open, because the bar glyph
  // follows the focused agent terminal. Two seconds is comfortably under the
  // time it takes to switch windows by hand.
  Process {
    id: agentProc
    running: false
    command: [root.helperScript, "state"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAgentState(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agents", text.trim())
    }
  }

  Process {
    id: setAgentProc
    running: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agents/set", text.trim())
    }
  }

  // focus/launch a specific agent when its row is clicked. Launches detach and
  // settle for under a second, so the next poll reflects the new window.
  Process {
    id: actionProc
    running: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agents/action", text.trim())
    }
  }

  Process {
    id: shortcutProc
    running: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.shortcutError = text.trim()
    }
    onExited: function(code) {
      root.shortcutBusy = false
      root.refreshAgentState()
      if (code === 0) root.endShortcutEdit()
      else if (root.shortcutError === "") root.shortcutError = "Saving the shortcut failed."
    }
  }

  Process {
    id: bindsProc
    running: false
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.hyprBinds = JSON.parse(String(text || "[]")) } catch (e) { root.hyprBinds = [] }
      }
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshAgentState()
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The mark changes to whichever agent terminal is focused, and falls back
    // to the generic agents glyph when none is.
    text: root.focusedAgentRow ? root.focusedAgentRow.icon : "󱚣"
    fontFamily: root.focusedAgentRow && String(root.focusedAgentRow.iconFont || "").length > 0
      ? String(root.focusedAgentRow.iconFont)
      : root.fontFamily
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.providerIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Taller than the control panels on purpose: this one is a dashboard, and
    // the whole point is reading limits and history without scrolling.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The shortcut recorder takes every key while it is open.
      blocked: root.editingAgentId !== ""

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        else if (t === "s" || t === "S") root.startShortcutEdit(root.selectedAgentId)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Agent picker: checkbox marks the default ----------
          Column {
            id: agentSection
            visible: root.agentRows.length > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              width: parent.width
              text: "AGENT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: root.agentRows

                AgentRow {
                  required property var modelData
                  width: agentSection.width
                  agent: modelData
                  selected: modelData.id === root.selectedAgentId
                  onPicked: root.activateAgent(modelData.id)
                  onDefaultPicked: root.setDefaultAgent(modelData.id)
                  onShortcutPicked: root.startShortcutEdit(modelData.id)
                }
              }
            }

            // ---------- Shortcut editor for one agent ----------
            Column {
              id: shortcutEditor
              visible: root.editingAgentId !== ""
              width: parent.width
              topPadding: Style.space(8)
              spacing: Style.space(8)

              PanelSectionHeader {
                width: parent.width
                text: "SHORTCUT · " + root.agentLabel(root.editingAgentId).toUpperCase()
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Row {
                id: modRow
                width: parent.width
                spacing: Style.spacing.sm
                readonly property real cellWidth: (width - spacing * 3) / 4

                Repeater {
                  model: [
                    { name: "Super", prop: "modSuper" },
                    { name: "Shift", prop: "modShift" },
                    { name: "Ctrl", prop: "modCtrl" },
                    { name: "Alt", prop: "modAlt" }
                  ]

                  Button {
                    required property var modelData
                    width: modRow.cellWidth
                    text: modelData.name
                    selected: root[modelData.prop]
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: {
                      root[modelData.prop] = !root[modelData.prop]
                      recorder.forceActiveFocus()
                    }
                  }
                }
              }

              // Takes keys while the editor is open; click it to re-arm after
              // using the chips.
              BorderSurface {
                id: recorderBox
                width: parent.width
                implicitHeight: recorderText.implicitHeight + Style.space(20)
                color: root.alpha(root.foreground, recorder.activeFocus ? 0.10 : 0.04)
                borderSpec: Border.flat(root.alpha(root.foreground, recorder.activeFocus ? 0.45 : 0.20), 1)
                radius: Style.cornerRadius

                Item {
                  id: recorder
                  anchors.fill: parent
                  focus: root.editingAgentId !== ""
                  Keys.onPressed: function(event) {
                    root.recordKey(event)
                    event.accepted = true
                  }
                }

                Text {
                  id: recorderText
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: root.pendingCombo !== ""
                    ? root.prettyCombo(root.pendingCombo)
                    : (root.modSuper || root.modShift || root.modCtrl || root.modAlt)
                      ? root.prettyCombo(root.comboString(root.modSuper, root.modShift, root.modCtrl, root.modAlt, "…"))
                      : "Press a key…"
                  color: root.pendingCombo !== "" ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: root.pendingCombo !== ""
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.IBeamCursor
                  onClicked: recorder.forceActiveFocus()
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: root.shortcutError !== "" ? root.shortcutError
                  : root.pendingProblem !== "" ? root.pendingProblem
                  : root.pendingConflict !== "" ? "Replaces “" + root.pendingConflict + "”."
                  : "Hold the modifiers and press a key, or toggle modifiers and press just the key. Enter saves, Esc cancels."
                color: root.shortcutError !== "" || root.pendingProblem !== "" ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Row {
                id: actionRow
                width: parent.width
                spacing: Style.spacing.sm
                readonly property bool hasShortcut:
                  !!root.editingAgentRow && String(root.editingAgentRow.shortcut || "") !== ""
                readonly property real cellWidth: (width - spacing * (hasShortcut ? 2 : 1)) / (hasShortcut ? 3 : 2)

                Button {
                  width: actionRow.cellWidth
                  text: root.shortcutBusy ? "Saving…" : "Save"
                  selected: root.pendingCombo !== "" && root.pendingProblem === ""
                  bordered: true
                  foreground: root.pendingCombo !== "" && root.pendingProblem === "" ? root.foreground : root.dim
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.saveShortcut()
                }

                Button {
                  visible: actionRow.hasShortcut
                  width: actionRow.cellWidth
                  text: "Remove"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.clearShortcut()
                }

                Button {
                  width: actionRow.cellWidth
                  text: "Cancel"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.endShortcutEdit()
                }
              }
            }
          }

          PanelSeparator {
            visible: agentSection.visible && (hero.visible || agentPlaceholder.visible)
            foreground: root.foreground
          }

          // ---------- Hero: provider mark · name · plan ----------
          PanelHero {
            id: hero
            visible: !!root.provider
            width: parent.width
            title: root.provider ? root.provider.providerName : ""
            meta: root.heroMeta(root.provider)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                id: heroMark
                property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
                // Provider objects are rebuilt on every refresh, which churns the
                // array's identity without changing its content. Restart the fallback
                // walk only when the URLs change: re-pointing source at a URL whose
                // load already failed emits no statusChanged, so an identity-only
                // reset would strand the walker on a missing -light twin.
                property string candidatesKey: candidates.join("\n")
                property int candidateIndex: 0
                onCandidatesKeyChanged: candidateIndex = 0

                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroMarkImage
                  anchors.fill: parent
                  source: heroMark.candidateIndex < heroMark.candidates.length ? heroMark.candidates[heroMark.candidateIndex] : ""
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                  // Advancing source from inside its own status change trips the
                  // binding-loop detector; defer the step one tick.
                  onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
                    Qt.callLater(function() { heroMark.candidateIndex++ })
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  visible: heroMarkImage.status !== Image.Ready
                  text: button.text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          // An agent with no usage collector: say so plainly instead of
          // leaving whatever subscription was showing before.
          Text {
            id: agentPlaceholder
            visible: root.agentHasNoUsage
            width: parent.width
            topPadding: Style.space(24)
            text: "No usage data is available for " + root.agentLabel(root.selectedAgentId) + ".\nIt has no usage collector yet."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.providers.length === 0 && !root.agentHasNoUsage
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Provider switch ----------
          Row {
            id: providerSwitch
            visible: root.providers.length > 1 && !root.agentHasNoUsage
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.providers.length > 0
              ? (width - spacing * (root.providers.length - 1)) / root.providers.length
              : 0

            Repeater {
              model: root.providers

              Button {
                required property var modelData
                required property int index

                width: providerSwitch.cellWidth
                text: modelData.providerName
                selected: index === root.providerIndex
                hasCursor: root.cursorActive && index === root.providerIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: {
                  root.cursorActive = true
                  // Browsing a subscription directly detaches from the agent
                  // picker without changing which agent is the default.
                  root.selectedAgentId = ""
                  root.selectProvider(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }
          }

          // ---------- Status ----------
          BorderSurface {
            visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.provider ? String(root.provider.authHelpText || "") : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Balance / limits ----------
          PanelSeparator {
            visible: balanceSection.visible || limitsSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            visible: !!root.balance
            width: parent.width
            spacing: Style.space(10)

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                text: "Prepaid credits"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                textFormat: Text.PlainText
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                color: root.balanceAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              alarming: root.balanceAlarming
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.balanceDetailText(root.balance)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                window: modelData
              }
            }
          }

          // ---------- Usage ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            visible: !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
            width: parent.width
            spacing: Style.spacing.md

            readonly property var days: root.provider ? (root.provider.recentDays || []) : []
            readonly property real peak: Math.max(1, root.weekPeak(root.provider))

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY DAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: usageSection.days

              DayRow {
                required property var modelData
                required property int index

                width: usageSection.width
                day: modelData
                ratio: Number(modelData.messageCount || 0) / usageSection.peak
                // By date, not by position: the Claude stats-cache fallback can
                // hand us a window that stops short of today.
                today: String(modelData.date || "") === root.todayDate()
              }
            }
          }

          // ---------- Models ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            visible: root.models.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY MODEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always full —
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // One picker row: a checkbox that sets the default agent, the agent's own
  // mark, its name, and a marker when its terminal is open (filled for focused).
  // Clicking the row itself opens or switches to the agent, not the checkbox.
  component AgentRow: Item {
    id: agentRow
    property var agent: null
    property bool selected: false

    readonly property bool isDefault:
      agent ? String(agent.id) === root.defaultAgentId : false
    readonly property bool running: agent ? agent.running === true : false
    readonly property bool focused: agent ? agent.focused === true : false
    // The mark shares the agent's own font when it has one (the Omarchy icon
    // font) and falls back to the bar font otherwise.
    readonly property string markFont:
      agent && String(agent.iconFont || "").length > 0 ? String(agent.iconFont) : root.fontFamily

    signal picked()
    signal defaultPicked()
    signal shortcutPicked()

    readonly property string shortcut: agent ? String(agent.shortcut || "") : ""
    readonly property bool hovered: rowMouse.containsMouse || chipMouse.containsMouse

    implicitHeight: Math.max(rowMark.implicitHeight, rowLabel.implicitHeight, checkBox.height)
      + Style.spacing.sm * 2

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: agentRow.selected ? root.alpha(root.foreground, 0.12) : "transparent"
      border.width: agentRow.selected ? 1 : 0
      border.color: root.alpha(root.foreground, 0.25)
    }

    // Filled when this agent is the default.
    Rectangle {
      id: checkBox
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.font.body
      height: Style.font.body
      radius: Math.round(width * 0.2)
      color: agentRow.isDefault ? root.foreground : "transparent"
      border.width: 1
      border.color: agentRow.isDefault ? root.foreground : root.dim

      Text {
        anchors.centerIn: parent
        visible: agentRow.isDefault
        text: "✓"
        color: root.surface
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Text {
      id: rowMark
      textFormat: Text.PlainText
      text: agentRow.agent ? agentRow.agent.icon : ""
      color: agentRow.selected || agentRow.focused ? root.foreground : root.dim
      font.family: agentRow.markFont
      font.pixelSize: Style.font.subtitle
      anchors.left: checkBox.right
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(24)
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      id: rowLabel
      textFormat: Text.PlainText
      text: agentRow.agent ? agentRow.agent.label : ""
      color: agentRow.selected ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: agentRow.isDefault
      anchors.left: rowMark.right
      anchors.leftMargin: Style.space(6)
      anchors.right: rowStatus.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
    }

    Item {
      id: rowStatus
      anchors.right: chip.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      implicitWidth: agentRow.running
        ? dot.width + Style.space(6) + statusText.implicitWidth
        : 0
      implicitHeight: Math.max(dot.height, statusText.implicitHeight)

      Rectangle {
        id: dot
        visible: agentRow.running
        width: Math.round(Style.font.body * 0.5)
        height: width
        radius: width / 2
        color: agentRow.focused ? root.foreground : root.dim
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: statusText
        visible: agentRow.running
        textFormat: Text.PlainText
        text: agentRow.focused ? "active" : "open"
        color: agentRow.focused ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.left: dot.right
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    // The agent's shortcut, or a "set key" hint while the row is hovered.
    // Clicking it opens the shortcut editor for this agent.
    Rectangle {
      id: chip
      readonly property bool shown: agentRow.shortcut !== "" || agentRow.hovered
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: chipText.implicitWidth + Style.space(12)
      height: chipText.implicitHeight + Style.space(4)
      radius: Style.cornerRadius
      color: chipMouse.containsMouse ? root.alpha(root.foreground, 0.16) : "transparent"
      border.width: 1
      border.color: root.alpha(root.foreground, agentRow.shortcut !== "" ? 0.35 : 0.18)
      opacity: shown ? 1 : 0

      Text {
        id: chipText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: agentRow.shortcut !== "" ? root.prettyCombo(agentRow.shortcut) : "set key"
        color: agentRow.shortcut !== "" ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: agentRow.picked()
    }

    MouseArea {
      id: chipMouse
      anchors.fill: chip
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: agentRow.shortcutPicked()
    }

    // The checkbox is its own target, stacked above the row's MouseArea so a
    // click on it sets the default instead of opening or switching the agent.
    MouseArea {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      width: checkBox.width + Style.space(12)
      height: parent.height
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: agentRow.defaultPicked()
    }
  }

  // A limit window: label and percentage, meter, and reset countdown.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property bool alarming: window && window.percent >= 0.9

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window && limitRow.window.percent >= 0
          ? Math.round(limitRow.window.percent * 100) + "%"
          : "—"
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window ? limitRow.window.percent : -1
      alarming: limitRow.alarming
    }

    Text {
      id: resetText
      textFormat: Text.PlainText
      width: parent.width
      text: {
        var remainingMs = root.resetMsFor(limitRow.window)
        return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: usage.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? usage.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
