-- The transcript: store.state → per-entry fibrous components (the design
-- decision recorded in open_tasks_and_issues.md — no raw managed buffer).
-- Every entry kind is its own component, mounted `memo = true` from the
-- entries timeline. The store's reassign discipline keeps unchanged entry
-- objects reference-stable, so a store mutation re-renders exactly the
-- changed entry; fibrous's paint descend + canvas growth keep the repaint
-- scoped to its rows. Line-building logic ported from agentic's
-- reactive/view/render.lua (transcript_lines).

local ui = require("fibrous.inline.components")
local Keys = require("weave.keys")
local Peek = require("weave.view.peek")
local Theme = require("weave.view.theme")
local ToolCall = require("weave.view.tool_call")
local use_store = require("weave.view.use_store")

local M = {}

-- The `peek` action opens an entry's raw source in the peek modal — fibrous
-- just routes declared keys to the on_key handler of the component under the
-- cursor; the panel mount declares the key(s) (Keys.lhs_list), the entries
-- below handle them.

--- An `on_key` map (fibrous component keybinding) that opens `entry`'s raw source
--- in the peek modal.
--- @param entry weave.store.ChatEntry
--- @return table<string, fun()>
local function peek_keys(entry)
  return Keys.on_key("peek", function()
    Peek.open(entry.text, entry.kind)
  end)
end

--- Collapse any newlines in agent-supplied single-line text (titles, kinds).
--- Multi-line CONTENT goes through paragraphs, which handle "\n"; headers are
--- one row by design, so a stray newline must not break them in two.
--- @param text string|nil
--- @return string
local function one_line(text)
  return (tostring(text or ""):gsub("[\r\n]+", " "))
end

-- Tool-call rendering (header/body/metadata subrenderers plus the override
-- registry) lives in weave.view.tool_call; re-exported because the panel and
-- specs reach for the title through here.
M.tool_title = ToolCall.tool_title

-- ── Entry components ─────────────────────────────────────────────────────────
-- Each takes reference-stable props (the entry/block object out of the store,
-- plus scalars), so `memo = true` mounting skips them whenever their slice of
-- state didn't change.

--- @param props { entry: weave.store.ChatEntry }
function M.UserEntry(_, props)
  return {
    comp = ui.row,
    props = { on_key = peek_keys(props.entry) },
    children = {
      { comp = ui.label, props = { text = "❯ ", style = { text_hl = Theme.USER_MSG_HL } } },
      { comp = ui.paragraph, props = { text = props.entry.text, style = { text_hl = Theme.USER_MSG_HL } } },
    },
  }
end

--- @param props { entry: weave.store.ChatEntry }
function M.ThoughtEntry(_, props)
  return {
    comp = ui.col,
    props = { on_key = peek_keys(props.entry) },
    children = {
      { comp = ui.label, props = { text = "[thinking]", style = { text_hl = Theme.THINKING_TAG_HL } } },
      {
        comp = ui.row,
        props = {},
        children = {
          { comp = ui.label, props = { text = "  " } },
          { comp = ui.paragraph, props = { text = props.entry.text, style = { text_hl = "@comment" } } },
        },
      },
    },
  }
end

--- Agent prose renders FLUSH-LEFT (no marker/indent) so markdown block
--- elements (headings, lists, fenced code) parse at column 0, through fibrous's
--- built-in `ui.markdown` (a pure-Lua parser feeding the shared document
--- renderer, with treesitter code highlighting where available). It parses once
--- and caches when settled; while still streaming (`live`) it renders the raw
--- text without parsing. The conceal_markdown pref ("Prettify markdown") maps
--- onto that same raw path: off = show the source, on = render it. Both inputs
--- are scalars, so the memo bailout invalidates exactly when they flip.
--- @param props { entry: weave.store.ChatEntry, live: boolean, conceal: boolean }
function M.AgentEntry(_, props)
  return {
    comp = ui.markdown,
    props = {
      text = props.entry.text,
      -- streaming OR "prettify off" both render the raw source (no parse)
      live = props.live or not props.conceal,
      on_key = peek_keys(props.entry),
    },
  }
end

--- One tool call. Rendering (and any registered override) lives in
--- weave.view.tool_call — see its header for the subrenderer/override
--- contract. This just forwards the store slice it was memo'd on.
--- @param props { store: weave.store.SessionStore, block: table, expanded: boolean, awaiting: boolean, show_diff: boolean }
function M.ToolCallEntry(_, props)
  return { comp = ToolCall.Dispatch, props = props }
end

--- The HEAD permission request with its option buttons, plus a "1 of N" line
--- when more are queued. Pressing an option pops the head (promoting the
--- next) and answers the agent via the request's own respond closure — the
--- consumer side of the queue pattern in session_store.lua.
--- @param props { store: weave.store.SessionStore, permission: weave.store.PendingPermission, count: integer }
function M.PermissionBlock(_, props)
  local request = props.permission.request
  local tc = request.toolCall or {}
  local title = tc.title or ("tool call " .. tostring(tc.toolCallId or "?"))

  local children = {
    { comp = ui.label, props = { text = "Permission required", style = { text_hl = "Title" } } },
  }
  if (props.count or 1) > 1 then
    children[#children + 1] = {
      comp = ui.label,
      props = { text = string.format("(1 of %d pending)", props.count), style = { text_hl = "@comment" } },
    }
  end
  children[#children + 1] = { comp = ui.label, props = { text = one_line(title) } }

  local buttons = {}
  for _, opt in ipairs(request.options or {}) do
    buttons[#buttons + 1] = {
      comp = ui.button,
      props = {
        label = opt.name or opt.optionId,
        on_press = function()
          -- Pop first, then answer: respond only talks to the agent, queue
          -- management is ours (no double-pop; see the store's queue note).
          local head = props.store:pop_permission()
          if head then
            head.respond(opt.optionId)
          end
        end,
      },
    }
  end
  -- A column, not a row: labels carry the resource an "always" rule persists
  -- for, and a row lays its children on one line with the overflow clipped
  -- (fibrous rows do not flex-wrap), so long options lost their tail off the
  -- right edge. Stacked they always fit, and it matches the sidebar's list.
  children[#children + 1] = { comp = ui.col, props = {}, children = buttons }

  return {
    comp = ui.col,
    props = { style = { border = "rounded", padding = { x = 1 } } },
    children = children,
  }
end

-- ── The transcript ───────────────────────────────────────────────────────────

--- The timeline: one memo'd component per entry, tool calls resolved through
--- the keyed table so live updates re-render just that call; queued prompts
--- after the timeline; the pending-permission block last. View prefs gate
--- thought entries and diff previews (`prefs` is a required prop — the hook
--- subscription must be unconditional).
--- @param ctx table
--- @param props { store: weave.store.SessionStore, prefs: weave.view.Prefs }
function M.Transcript(ctx, props)
  local store = props.store
  local state = use_store(ctx, store)
  local prefs = use_store(ctx, props.prefs)

  -- A pending permission targets one tool call; that call renders as
  -- "awaiting_permission" regardless of its raw status.
  local awaiting_id = state.permission
    and state.permission.request
    and state.permission.request.toolCall
    and state.permission.request.toolCall.toolCallId

  -- Tail window: render only entries[window_start .. #entries] (the store caps
  -- this on a huge session; the panel slides it while following). Older entries
  -- collapse behind an expander so relayout/resize cost stays bounded — see
  -- SessionStore.WINDOW / open_tasks_and_issues.md.
  local window_start = state.window_start or 1
  local children = {}

  if window_start > 1 then
    local older = window_start - 1
    children[#children + 1] = {
      comp = ui.button,
      props = {
        theme = false, -- bare row, no button chrome (like the tool-call header)
        label = { { string.format("▸ %d older messages", older), hl = "@comment" } },
        on_press = function()
          store:reveal_older()
        end,
      },
    }
  end

  for i = window_start, #state.entries do
    local entry = state.entries[i]
    if entry.kind == "tool_call" then
      local tc = state.tool_calls[entry.tool_call_id]
      if tc then
        children[#children + 1] = {
          comp = M.ToolCallEntry,
          -- `key` = the entry's stable identity, so fibrous's cursor anchor keeps
          -- the reader's place on THIS entry across a resize/thinking-toggle
          -- relayout (positional reconciliation reuses fibers by index).
          key = entry,
          memo = true,
          props = {
            store = store,
            block = tc,
            expanded = state.expanded[entry.tool_call_id] == true,
            awaiting = awaiting_id == entry.tool_call_id,
            show_diff = prefs.show_diffs,
          },
        }
      end
    elseif entry.kind == "user" then
      children[#children + 1] = { comp = M.UserEntry, key = entry, memo = true, props = { entry = entry } }
    elseif entry.kind == "thought" then
      if prefs.show_thoughts then
        children[#children + 1] = { comp = M.ThoughtEntry, key = entry, memo = true, props = { entry = entry } }
      end
    elseif entry.kind == "agent" then
      children[#children + 1] = {
        comp = M.AgentEntry,
        key = entry,
        memo = true,
        props = {
          entry = entry,
          -- Only the timeline TAIL can still be streaming: an entry settles
          -- for good the moment anything follows it or the turn goes idle.
          live = i == #state.entries and state.status == "generating",
          conceal = prefs.conceal_markdown == true,
        },
      }
    end
  end

  -- Queued prompts no longer render here: they stack in the prompt block, above
  -- the input box (view/prompt.lua), so you can edit/reorder/cancel them there.

  if state.permission then
    children[#children + 1] = {
      comp = M.PermissionBlock,
      props = { store = store, permission = state.permission, count = state.permission_count },
    }
  end

  if #children == 0 then
    children[1] = { comp = ui.label, props = { text = "(no messages yet)", style = { text_hl = "@comment" } } }
  end

  return { comp = ui.col, props = { gap = 1 }, children = children }
end

return M
