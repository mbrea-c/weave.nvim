-- The transcript: store.state → per-entry fibrous components (the design
-- decision recorded in open_tasks_and_issues.md — no raw managed buffer).
-- Every entry kind is its own component, mounted `memo = true` from the
-- entries timeline. The store's reassign discipline keeps unchanged entry
-- objects reference-stable, so a store mutation re-renders exactly the
-- changed entry; fibrous's paint descend + canvas growth keep the repaint
-- scoped to its rows. Line-building logic ported from agentic's
-- reactive/view/render.lua (transcript_lines).

local ui = require("fibrous.inline.components")
local Json = require("weave.utils.json")
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

--- The same action over a TOOL CALL, whose raw source is the call itself:
--- indented JSON of the whole block. A tool call has no prose to show — the
--- entry IS the projection (a one-line header, a capped input dump), so the
--- peek is the only place the full command, arguments and output are legible.
--- @param block table normalized tool-call block
--- @return table<string, fun()>
local function tool_peek_keys(block)
  return Keys.on_key("peek", function()
    Peek.open(Json.pretty(block), ToolCall.tool_tag(block), "json")
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

-- ── Streaming prettify ───────────────────────────────────────────────────────
-- While the tail agent entry streams, a timer advances a SAFE PARSE BOUNDARY
-- through its text every STREAM_PARSE_MS: everything before the boundary
-- renders as parsed markdown, the remainder raw. Tokens still appear the
-- moment they arrive (the raw tail re-renders per chunk, no parse), and every
-- tick another stretch of a long response takes shape — instead of the whole
-- thing staying raw until the turn ends.

--- How often the streaming parse boundary advances (ms).
M.STREAM_PARSE_MS = 7000

--- The stable mount key of the streaming tail entry. The store REPLACES the
--- tail entry table on every chunk, so keying on the entry would remount the
--- component per chunk and throw away the parsed prefix's AST cache.
local STREAM_TAIL_KEY = "weave-stream-tail"

--- Byte index of the last safe parse boundary in `text`: the final "\n\n"
--- whose prefix leaves no code fence open (cutting inside a fence would render
--- its tail as prose). 0 when there is none. The prefix to parse is
--- `text:sub(1, cut - 1)`, the raw tail `text:sub(cut + 2)`.
--- @param text string
--- @return integer
function M.stream_cut(text)
  local best, fences, from = 0, 0, 1
  local len = #text
  while from <= len do
    local nl = text:find("\n", from, true)
    if text:sub(from, from + 2) == "```" then
      fences = fences + 1
    end
    if nl == from and from > 1 and fences % 2 == 0 then
      best = from - 1 -- the empty line: from-1 is the FIRST \n of the "\n\n"
    end
    if not nl then
      break
    end
    from = nl + 1
  end
  return best
end

-- ── Entry components ─────────────────────────────────────────────────────────
-- Each takes reference-stable props (the entry/block object out of the store,
-- plus scalars), so `memo = true` mounting skips them whenever their slice of
-- state didn't change.

--- The prompt body renders as markdown, gated by the same "Prettify markdown"
--- pref as agent prose. `conceal` off keeps the ORIGINAL raw path — our own
--- tinted paragraph, not ui.markdown's raw mode — so the pref-off rendering is
--- unchanged, and parsed blocks take the standard @markup styling with only
--- the ❯ marker tinted. The flip lives HERE, at the row level, rather than on
--- ui.markdown's `live` prop: it says what it means (weave picks raw vs
--- formatted), and it once dodged a since-fixed fibrous repaint gap (a
--- component swapping its inner root under a row left stale cells).
--- @param props { entry: weave.store.ChatEntry, conceal: boolean }
function M.UserEntry(_, props)
  local body
  if props.conceal then
    body = { comp = ui.markdown, props = { text = props.entry.text } }
  else
    body = { comp = ui.paragraph, props = { text = props.entry.text, style = { text_hl = Theme.USER_MSG_HL } } }
  end
  local children = {
    {
      comp = ui.row,
      props = {},
      children = {
        { comp = ui.label, props = { text = "❯ ", style = { text_hl = Theme.USER_MSG_HL } } },
        body,
      },
    },
  }
  -- What was handed over WITH the message: the transcript should show that an
  -- image went to the model, not just the sentence about it.
  for _, att in ipairs(props.entry.attachments or {}) do
    children[#children + 1] = {
      comp = ui.label,
      props = { text = "  📎 " .. att.name, style = { text_hl = "@comment" } },
    }
  end
  -- The bubble: user-tinted rounded border over a bg one step off Normal's,
  -- so the user's own words are findable at a glance while scrolling.
  return {
    comp = ui.col,
    props = {
      on_key = peek_keys(props.entry),
      style = {
        hl = Theme.USER_BUBBLE_HL,
        border = "rounded",
        border_hl = Theme.USER_BUBBLE_BORDER_HL,
        padding = { x = 1 },
      },
    },
    children = children,
  }
end

--- Tutor-mode sends: weave talking to the agent on the user's behalf. One
--- labelled line, quiet, with the payload behind the peek key — the payload is
--- a diff of everything the user just did, and pasting that into the timeline
--- every debounce window would bury the conversation it exists to support.
--- @param props { entry: weave.store.ChatEntry }
function M.TutorEntry(_, props)
  local entry = props.entry
  return {
    comp = ui.col,
    props = {
      on_key = Keys.on_key("peek", function()
        Peek.open(entry.payload or entry.text or "", "tutor", "diff")
      end),
    },
    children = {
      {
        comp = ui.row,
        props = {},
        children = {
          { comp = ui.label, props = { text = "⇅ ", style = { text_hl = Theme.TUTOR_MSG_HL } } },
          {
            comp = ui.paragraph,
            props = { text = one_line(entry.text), style = { text_hl = Theme.TUTOR_MSG_HL } },
          },
        },
      },
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
---
--- A streaming entry with prettify on additionally takes `cut`, the Transcript
--- debounce's safe boundary (M.stream_cut): the prefix before it renders
--- parsed — its text only changes on a tick, so ui.markdown's AST cache holds
--- between chunks — and the tail after it raw, so tokens still appear
--- instantly. gap = 1 matches the doc renderer's block spacing, keeping the
--- raw tail one blank row under the last parsed block like the "\n\n" it
--- replaced.
--- @param props { entry: weave.store.ChatEntry, live: boolean, conceal: boolean, cut?: integer }
function M.AgentEntry(_, props)
  local entry = props.entry
  if props.live and props.conceal and (props.cut or 0) > 0 then
    local children = {
      { comp = ui.markdown, props = { text = entry.text:sub(1, props.cut - 1) } },
    }
    local tail = entry.text:sub(props.cut + 2)
    if tail ~= "" then
      children[#children + 1] = { comp = ui.paragraph, props = { text = tail } }
    end
    return { comp = ui.col, props = { gap = 1, on_key = peek_keys(entry) }, children = children }
  end
  return {
    comp = ui.markdown,
    props = {
      text = entry.text,
      -- streaming OR "prettify off" both render the raw source (no parse)
      live = props.live or not props.conceal,
      on_key = peek_keys(entry),
    },
  }
end

--- One tool call. Rendering (and any registered override) lives in
--- weave.view.tool_call — see its header for the subrenderer/override
--- contract. This just forwards the store slice it was memo'd on.
---
--- The peek key rides on a wrapper col rather than on the rendering, so it
--- covers a REGISTERED renderer's entry too: whatever someone else chose to
--- draw, K still shows the call weave actually received.
--- @param props { store: weave.store.SessionStore, block: table, expanded: boolean, awaiting: boolean, show_diff: boolean }
function M.ToolCallEntry(_, props)
  return {
    comp = ui.col,
    props = { on_key = tool_peek_keys(props.block) },
    children = { { comp = ToolCall.Dispatch, props = props } },
  }
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

  -- Streaming prettify debounce: while the tail agent entry streams (and
  -- "Prettify markdown" is on), a repeating timer re-derives the safe parse
  -- boundary from the CURRENT text and bumps `stream_tick` when it moved —
  -- that re-render is the only time the parsed prefix changes, so the parse
  -- runs once per tick, never per chunk. The ref carries {index, cut} for the
  -- render below; the effect re-keys on the tail's index, so a new streaming
  -- entry resets the boundary and the turn's end stops the timer.
  local stream = ctx.use_ref()
  local stream_tick = ctx.use_state(0)
  stream_tick.get() -- the bump is what re-renders us when the boundary moves
  local tail_i = #state.entries
  local streaming_tail = state.status == "generating"
    and tail_i > 0
    and state.entries[tail_i].kind == "agent"
    and prefs.conceal_markdown == true
  ctx.use_effect(function()
    stream.index = streaming_tail and tail_i or nil
    stream.cut = 0
    if not streaming_tail then
      return
    end
    local timer = vim.uv.new_timer()
    timer:start(
      M.STREAM_PARSE_MS,
      M.STREAM_PARSE_MS,
      vim.schedule_wrap(function()
        local s = store.state
        local entry = stream.index and s.entries[stream.index]
        if s.status ~= "generating" or not entry or entry.kind ~= "agent" then
          return -- settling re-runs the effect; it will stop this timer
        end
        local cut = M.stream_cut(entry.text)
        if cut ~= stream.cut then
          stream.cut = cut
          stream_tick.set(stream_tick.get() + 1)
        end
      end)
    )
    return function()
      -- nil-ing the index bails any tick already scheduled behind this
      -- cleanup (it would otherwise set state on a settled or unmounted tree)
      stream.index = nil
      timer:stop()
      timer:close()
    end
  end, { streaming_tail and tail_i or false })

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
      children[#children + 1] = {
        comp = M.UserEntry,
        key = entry,
        memo = true,
        props = { entry = entry, conceal = prefs.conceal_markdown == true },
      }
    elseif entry.kind == "tutor" then
      children[#children + 1] = { comp = M.TutorEntry, key = entry, memo = true, props = { entry = entry } }
    elseif entry.kind == "thought" then
      if prefs.show_thoughts then
        children[#children + 1] = { comp = M.ThoughtEntry, key = entry, memo = true, props = { entry = entry } }
      end
    elseif entry.kind == "agent" then
      -- Only the timeline TAIL can still be streaming: an entry settles
      -- for good the moment anything follows it or the turn goes idle.
      local live = i == #state.entries and state.status == "generating"
      children[#children + 1] = {
        comp = M.AgentEntry,
        -- The streaming tail keys on a SENTINEL: the store replaces the tail
        -- entry table on every chunk, and an entry key would remount the
        -- component (and drop the parsed prefix's AST cache) per chunk. It
        -- re-keys onto the settled entry once the turn ends.
        key = live and STREAM_TAIL_KEY or entry,
        memo = true,
        props = {
          entry = entry,
          live = live,
          conceal = prefs.conceal_markdown == true,
          cut = (live and stream.index == i) and stream.cut or nil,
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
