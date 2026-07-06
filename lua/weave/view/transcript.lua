-- The transcript: store.state → per-entry fibrous components (the design
-- decision recorded in open_tasks_and_issues.md — no raw managed buffer).
-- Every entry kind is its own component, mounted `memo = true` from the
-- entries timeline. The store's reassign discipline keeps unchanged entry
-- objects reference-stable, so a store mutation re-renders exactly the
-- changed entry; fibrous's paint descend + canvas growth keep the repaint
-- scoped to its rows. Line-building logic ported from agentic's
-- reactive/view/render.lua (transcript_lines).

local ui = require("fibrous.inline.components")
local Diff = require("weave.view.diff")
local Markdown = require("weave.view.markdown")
local Peek = require("weave.view.peek")
local Theme = require("weave.view.theme")
local use_store = require("weave.view.use_store")

local M = {}

-- The key that opens an entry's raw source in the peek modal. Weave's choice —
-- fibrous just routes declared keys to the on_key handler of the component under
-- the cursor; the panel mount declares this key, the entries below handle it.
M.PEEK_KEY = "K"

--- An `on_key` map (fibrous component keybinding) that opens `entry`'s raw source
--- in the peek modal.
--- @param entry weave.store.ChatEntry
--- @return table<string, fun()>
local function peek_keys(entry)
  return {
    [M.PEEK_KEY] = function()
      Peek.open(entry.text, entry.kind)
    end,
  }
end

--- Collapse any newlines in agent-supplied single-line text (titles, kinds).
--- Multi-line CONTENT goes through paragraphs, which handle "\n"; headers are
--- one row by design, so a stray newline must not break them in two.
--- @param text string|nil
--- @return string
local function one_line(text)
  return (tostring(text or ""):gsub("[\r\n]+", " "))
end

--- Human-readable title for a tool call, with a fallback chain so the header
--- is never empty: the agent-supplied title (carried as `argument`) wins;
--- else the file path; else a last-resort id label. Verified against
--- providers that omit the title (e.g. OpenCode edits arrive with only
--- kind + rawInput).
--- @param tc table ToolCallBlock
--- @return string title
local function tool_title(tc)
  if tc.argument and tc.argument ~= "" then
    return tc.argument
  end
  if tc.file_path and tc.file_path ~= "" then
    return vim.fn.fnamemodify(tc.file_path, ":~:.")
  end
  return "tool call " .. tc.tool_call_id
end
M.tool_title = tool_title

--- Max lines rendered for a single raw input/output block when expanded. MCP
--- results can be huge; cap them so one tool call can't flood the transcript.
--- The full value is always in the store.
local RAW_BLOCK_MAX_LINES = 40

--- Max lines for an inline diff preview. The full edit is on disk once
--- applied; this is a preview, not the source of truth.
local DIFF_PREVIEW_MAX_LINES = 60

--- One indented, dimmed metadata line ("    kind: execute").
local function meta_line(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "@comment" } } }
end

--- Append labels for a labeled, indented, truncated vim.inspect dump of an
--- arbitrary tool input/output table. No-op when the value is absent.
--- @param children table[] accumulator of component specs
--- @param label string e.g. "input" / "output"
--- @param value table|nil
local function append_raw_block(children, label, value)
  if value == nil then
    return
  end
  children[#children + 1] = meta_line("    " .. label .. ":")
  local lines = vim.split(vim.inspect(value), "\n")
  local shown = math.min(#lines, RAW_BLOCK_MAX_LINES)
  for i = 1, shown do
    children[#children + 1] = { comp = ui.label, props = { text = "    │ " .. lines[i] } }
  end
  if #lines > shown then
    children[#children + 1] = meta_line(string.format("    │ … %d more lines", #lines - shown))
  end
end

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
--- elements (headings, lists, fenced code) parse at column 0, through the
--- markdown component (R6): `live` while this entry is still streaming (no
--- parse per tick), parsed once + cached when it settles; `conceal` follows
--- the conceal_markdown pref. Both are scalars, so the memo bailout
--- invalidates exactly when they flip.
--- @param props { entry: weave.store.ChatEntry, live: boolean, conceal: boolean }
function M.AgentEntry(_, props)
  return {
    comp = Markdown.Markdown,
    props = {
      text = props.entry.text,
      live = props.live,
      conceal = props.conceal,
      on_key = peek_keys(props.entry),
    },
  }
end

--- A prompt held while a turn is in flight, rendered dimmed with a marker so
--- the user sees what will be sent automatically when the turn ends.
--- @param props { text: string }
function M.QueuedEntry(_, props)
  return {
    comp = ui.row,
    props = {},
    children = {
      { comp = ui.label, props = { text = "⏳ ", style = { text_hl = "@comment" } } },
      { comp = ui.paragraph, props = { text = props.text, style = { text_hl = "@comment" } } },
    },
  }
end

--- One tool call: always a rich header row (chevron, status glyph, kind
--- glyph + tag, title) that toggles expansion on <CR>/click; an inline diff
--- preview for edits (gated by the show_diff pref, passed as a scalar prop so
--- the memo bailout invalidates when it flips); metadata/raw-I/O/body rows
--- only when expanded.
--- @param props { store: weave.store.SessionStore, block: table, expanded: boolean, awaiting: boolean, show_diff: boolean }
function M.ToolCallEntry(_, props)
  local tc = props.block
  local effective_status = props.awaiting and "awaiting_permission" or (tc.status or "pending")
  local status_icon = Theme.STATUS_ICON[effective_status] or "○"
  local kind_icon = Theme.KIND_ICON[tc.kind or "other"] or Theme.KIND_ICON.other
  local chevron = props.expanded and Theme.CHEVRON.expanded or Theme.CHEVRON.collapsed
  -- Header + [kind] tag share the status colour; the tag is bold so the tool
  -- type stays emphasized while the whole header signals state at a glance.
  local header_hl = Theme.HEADER_HL[effective_status] or "Function"
  local tag_hl = Theme.KIND_TAG_HL[effective_status] or "Function"

  local children = {
    {
      comp = ui.button,
      props = {
        theme = false, -- bare header, no button chrome
        label = {
          { chevron .. " ", hl = "@comment" },
          { status_icon .. " ", hl = header_hl },
          { kind_icon, hl = header_hl },
          { "[" .. one_line(tc.kind or "tool") .. "] ", hl = tag_hl },
          { one_line(tool_title(tc)), hl = header_hl },
        },
        on_press = function()
          props.store:toggle_tool_call(tc.tool_call_id)
        end,
      },
    },
  }

  -- The diff renders inline (not behind the expand toggle) so an edit shows
  -- what changed at a glance. Expand reveals the SECONDARY metadata below.
  if tc.diff and props.show_diff ~= false then
    children[#children + 1] = {
      comp = Diff.Diff,
      props = {
        old = tc.diff.old,
        new = tc.diff.new,
        max_lines = DIFF_PREVIEW_MAX_LINES,
        indent = "    ",
      },
    }
  end

  if props.expanded then
    if tc.kind then
      children[#children + 1] = meta_line("    kind: " .. tc.kind)
    end
    if tc.file_path then
      children[#children + 1] = meta_line("    file: " .. tc.file_path)
    end
    children[#children + 1] = meta_line("    status: " .. (tc.status or "pending"))

    -- Raw input/output: the only detail MCP/other tools provide (they send
    -- no content/body). Rendered for every kind that carries them.
    append_raw_block(children, "input", tc.input)
    append_raw_block(children, "output", tc.output)

    for _, body_line in ipairs(tc.body or {}) do
      -- A body element may itself contain newlines (it's content, not a
      -- label); paragraphs handle those, keeping the "│" gutter per row.
      for _, physical in ipairs(vim.split(body_line, "\n")) do
        children[#children + 1] = { comp = ui.label, props = { text = "    │ " .. physical } }
      end
    end
  end

  return { comp = ui.col, props = {}, children = children }
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
  children[#children + 1] = { comp = ui.row, props = { gap = 1 }, children = buttons }

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

  local children = {}
  for i, entry in ipairs(state.entries) do
    if entry.kind == "tool_call" then
      local tc = state.tool_calls[entry.tool_call_id]
      if tc then
        children[#children + 1] = {
          comp = M.ToolCallEntry,
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
      children[#children + 1] = { comp = M.UserEntry, memo = true, props = { entry = entry } }
    elseif entry.kind == "thought" then
      if prefs.show_thoughts then
        children[#children + 1] = { comp = M.ThoughtEntry, memo = true, props = { entry = entry } }
      end
    elseif entry.kind == "agent" then
      children[#children + 1] = {
        comp = M.AgentEntry,
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

  for _, text in ipairs(state.queued) do
    children[#children + 1] = { comp = M.QueuedEntry, memo = true, props = { text = text } }
  end

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
