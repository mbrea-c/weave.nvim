-- The transcript view (roadmap R4): per-entry fibrous components projecting
-- store.state — the design decided against agentic's raw managed buffer.
-- Entries render as memo'd components, so a store mutation re-renders exactly
-- the changed entry (asserted here via host-node reference stability, the
-- contract fibrous's `memo = true` + reassign discipline provide).

local mount = require("fibrous.inline.mount")
local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")

local SessionStore = require("weave.session_store")
local Prefs = require("weave.view.prefs")
local transcript = require("weave.view.transcript")
local Theme = require("weave.view.theme")

local function trimmed(bufnr)
  local out = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    out[i] = (l:gsub("%s+$", ""))
  end
  return out
end

-- Extmark spans with the given hl group, as { row, col, end_col } triples.
local function marks_with(bufnr, hl)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    if m[4].hl_group == hl then
      out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col }
    end
  end
  return out
end

local function move_cursor(handle, row, col)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
end

local function press(handle, key)
  vim.api.nvim_set_current_win(handle.winid)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

-- Find "needle" in the buffer; returns 1-based row and 0-based col.
local function locate(bufnr, needle)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local col = l:find(needle, 1, true)
    if col then
      return i, col - 1
    end
  end
  error("not found in buffer: " .. needle)
end

local function mount_transcript(store, width, prefs)
  return mount.floating(
    transcript.Transcript,
    { store = store, prefs = prefs or Prefs:new() },
    { width = width or 60, height = 20, mode = "scroll" }
  )
end

local function tool_header(status, kind, title, expanded)
  local chevron = expanded and Theme.CHEVRON.expanded or Theme.CHEVRON.collapsed
  return chevron
    .. " "
    .. Theme.STATUS_ICON[status]
    .. " "
    .. Theme.KIND_ICON[kind]
    .. "["
    .. kind
    .. "] "
    .. title
end

describe("view.transcript entries", function()
  it("renders the empty placeholder", function()
    local store = SessionStore:new()
    local handle = mount_transcript(store)
    assert.same({ "(no messages yet)" }, trimmed(handle.bufnr))
    handle.unmount()
  end)

  it("renders user, thought, and agent entries in timeline order", function()
    local store = SessionStore:new()
    store:append_entry({ kind = "user", text = "run the tests" })
    store:append_streaming_text("thought", "hmm")
    store:append_streaming_text("agent", "on it")

    local handle = mount_transcript(store)
    assert.same({
      "❯ run the tests",
      "",
      "[thinking]",
      "  hmm",
      "",
      "on it",
    }, trimmed(handle.bufnr))
    handle.unmount()
  end)

  it("indents continuation lines of a multi-line user prompt", function()
    local store = SessionStore:new()
    store:append_entry({ kind = "user", text = "first\nsecond" })
    local handle = mount_transcript(store)
    assert.same({ "❯ first", "  second" }, trimmed(handle.bufnr))
    handle.unmount()
  end)

  it("streams live: chunks appended after mount show up coalesced", function()
    local store = SessionStore:new()
    local handle = mount_transcript(store)
    store:append_streaming_text("agent", "hel")
    store:append_streaming_text("agent", "lo")
    assert.same({ "hello" }, trimmed(handle.bufnr))
    handle.unmount()
  end)

  it("agent markdown: settled entries highlight+conceal, the streaming tail stays plain", function()
    local store = SessionStore:new()
    store:append_entry({ kind = "agent", text = "settled **bold** prose" })
    -- A user entry breaks streaming coalescing, like a real next turn.
    store:append_entry({ kind = "user", text = "next" })
    local handle = mount_transcript(store)
    -- Settled: parsed, and conceal_markdown (default on) strips the markers.
    assert.equal("settled bold prose", trimmed(handle.bufnr)[1])
    assert.equal(1, #marks_with(handle.bufnr, "@markup.strong"))

    -- A streaming tail renders plain — no parse per tick, markers visible.
    store:set_status("generating")
    store:append_streaming_text("agent", "streaming **loud**")
    assert.equal("streaming **loud**", trimmed(handle.bufnr)[5])
    assert.equal(1, #marks_with(handle.bufnr, "@markup.strong"))

    -- Turn end settles it: parsed and concealed like any other entry.
    store:set_status("idle")
    assert.equal("streaming loud", trimmed(handle.bufnr)[5])
    assert.equal(2, #marks_with(handle.bufnr, "@markup.strong"))
    handle.unmount()
  end)

  it("toggling conceal_markdown re-renders settled prose, live", function()
    local store = SessionStore:new()
    store:append_entry({ kind = "agent", text = "some **bold** here" })
    local prefs = Prefs:new()
    local handle = mount_transcript(store, nil, prefs)
    assert.equal("some bold here", trimmed(handle.bufnr)[1])

    prefs:toggle("conceal_markdown")
    -- "Prettify" off shows the raw source, rendered plain (no markdown parse,
    -- so no @markup highlighting) — the widget's raw path.
    assert.equal("some **bold** here", trimmed(handle.bufnr)[1])
    assert.equal(0, #marks_with(handle.bufnr, "@markup.strong"))
    handle.unmount()
  end)

  it("does NOT render queued prompts (they live in the prompt block now)", function()
    local store = SessionStore:new()
    store:append_streaming_text("agent", "busy")
    store:enqueue_prompt("and then this")
    local handle = mount_transcript(store)
    -- queued prompts stack in the prompt block (view/prompt.lua), not here
    assert.same({ "busy" }, trimmed(handle.bufnr))
    handle.unmount()
  end)
end)

describe("view.transcript tail window", function()
  local K = SessionStore.WINDOW

  -- append n user entries e1..eN
  local function seed(store, n)
    for i = 1, n do
      store:append_entry({ kind = "user", text = "e" .. i })
    end
  end

  local function count_prompts(bufnr)
    local n = 0
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:find("❯ ", 1, true) then
        n = n + 1
      end
    end
    return n
  end

  it("renders only entries from window_start, behind an older-messages expander", function()
    local store = SessionStore:new()
    seed(store, K + 5)
    store:follow_window() -- the panel's job; window_start = 6
    local handle = mount_transcript(store)
    local text = table.concat(trimmed(handle.bufnr), "\n")

    assert.truthy(text:find("▸ 5 older messages", 1, true), "expander missing")
    assert.equal(K, count_prompts(handle.bufnr))
    assert.falsy(text:find("❯ e1\n", 1, true) or text:match("❯ e1$"), "collapsed entry leaked")
    assert.falsy(text:find("❯ e5\n", 1, true), "collapsed entry leaked")
    assert.truthy(text:find("❯ e6", 1, true), "first windowed entry missing")
    assert.truthy(text:find("❯ e35", 1, true), "newest entry missing")
    handle.unmount()
  end)

  it("shows no expander when the window already covers every entry", function()
    local store = SessionStore:new()
    seed(store, 3)
    store:follow_window() -- no-op at <= K
    local handle = mount_transcript(store)
    local text = table.concat(trimmed(handle.bufnr), "\n")
    assert.falsy(text:find("older messages", 1, true))
    assert.truthy(text:find("❯ e1", 1, true))
    handle.unmount()
  end)

  it("pressing the expander reveals the previous window of older entries", function()
    local store = SessionStore:new()
    seed(store, K + 5)
    store:follow_window() -- window_start = 6
    local handle = mount_transcript(store)

    local row, col = locate(handle.bufnr, "older messages")
    move_cursor(handle, row, col)
    press(handle, "<CR>")

    assert.equal(1, store.state.window_start)
    local text = table.concat(trimmed(handle.bufnr), "\n")
    assert.falsy(text:find("older messages", 1, true), "expander should be gone once fully revealed")
    assert.truthy(text:find("❯ e1", 1, true), "oldest entry not revealed")
    handle.unmount()
  end)
end)

describe("view.transcript tool calls", function()
  it("renders a collapsed header from the title chain", function()
    local store = SessionStore:new()
    store:upsert_tool_call({ tool_call_id = "t1", kind = "execute", argument = "ls -la", status = "pending" })
    local handle = mount_transcript(store)
    assert.same({ tool_header("pending", "execute", "ls -la") }, trimmed(handle.bufnr))
    handle.unmount()
  end)

  it("expanding in the store reveals metadata and capped raw input", function()
    local store = SessionStore:new()
    store:upsert_tool_call({
      tool_call_id = "t1",
      kind = "execute",
      argument = "ls",
      status = "pending",
      input = { cmd = "ls" },
    })
    local handle = mount_transcript(store)

    store:toggle_tool_call("t1")
    assert.same({
      tool_header("pending", "execute", "ls", true),
      "    kind: execute",
      "    status: pending",
      "    input:",
      "    │ {",
      '    │   cmd = "ls"',
      "    │ }",
    }, trimmed(handle.bufnr))

    store:toggle_tool_call("t1")
    assert.same({ tool_header("pending", "execute", "ls") }, trimmed(handle.bufnr))
    handle.unmount()
  end)

  it("<CR> on the header toggles expansion", function()
    local store = SessionStore:new()
    store:upsert_tool_call({ tool_call_id = "t1", kind = "read", argument = "a.txt", status = "completed" })
    local handle = mount_transcript(store)

    move_cursor(handle, 1, 0)
    press(handle, "<CR>")
    assert.is_true(store.state.expanded.t1)
    local lines = trimmed(handle.bufnr)
    assert.equal("    kind: read", lines[2])

    press(handle, "<CR>")
    assert.falsy(store.state.expanded.t1)
    handle.unmount()
  end)

  it("renders an interleaved unified diff with Diff* highlights", function()
    local store = SessionStore:new()
    store:upsert_tool_call({
      tool_call_id = "e1",
      kind = "edit",
      file_path = "a.lua",
      status = "completed",
      diff = { old = { "local a = 1" }, new = { "local a = 2" } },
    })
    local handle = mount_transcript(store)

    local lines = trimmed(handle.bufnr)
    assert.equal(tool_header("completed", "edit", "a.lua"), lines[1])
    assert.equal("    @@ -1 +1 @@", lines[2])
    assert.equal("    -local a = 1", lines[3])
    assert.equal("    +local a = 2", lines[4])
    assert.same({ { row = 2, col = 4, end_col = 16 } }, marks_with(handle.bufnr, "DiffDelete"))
    assert.same({ { row = 3, col = 4, end_col = 16 } }, marks_with(handle.bufnr, "DiffAdd"))
    handle.unmount()
  end)

  it("a pending permission overrides the targeted call's status glyph", function()
    local store = SessionStore:new()
    store:upsert_tool_call({ tool_call_id = "t1", kind = "execute", argument = "rm -rf", status = "in_progress" })
    store:enqueue_permission({
      request = { toolCall = { toolCallId = "t1", kind = "execute" }, options = {} },
      respond = function() end,
    })
    local handle = mount_transcript(store)
    local header = trimmed(handle.bufnr)[1]
    assert.truthy(header:find(Theme.STATUS_ICON.awaiting_permission, 1, true))
    handle.unmount()
  end)
end)

describe("view.transcript permission block", function()
  local function pending(store, id, respond)
    store:enqueue_permission({
      request = {
        toolCall = { toolCallId = id, kind = "execute" },
        options = {
          { optionId = "allow", name = "Allow", kind = "allow_once" },
          { optionId = "reject", name = "Reject", kind = "reject_once" },
        },
      },
      respond = respond or function() end,
    })
  end

  it("renders the head request with its option buttons", function()
    local store = SessionStore:new()
    pending(store, "t1")
    pending(store, "t2")
    local handle = mount_transcript(store, 40)

    local lines = table.concat(trimmed(handle.bufnr), "\n")
    assert.truthy(lines:find("Permission required", 1, true))
    assert.truthy(lines:find("(1 of 2 pending)", 1, true))
    assert.truthy(lines:find("tool call t1", 1, true))
    assert.truthy(lines:find("Allow", 1, true))
    assert.truthy(lines:find("Reject", 1, true))
    handle.unmount()
  end)

  it("pressing an option answers the agent, pops the head, and promotes the next", function()
    local store = SessionStore:new()
    local answered = {}
    pending(store, "t1", function(option_id)
      answered[#answered + 1] = option_id
    end)
    pending(store, "t2")
    local handle = mount_transcript(store, 40)

    local row, col = locate(handle.bufnr, "Allow")
    move_cursor(handle, row, col)
    press(handle, "<CR>")

    assert.same({ "allow" }, answered)
    assert.equal(1, store.state.permission_count)
    assert.equal("t2", store.state.permission.request.toolCall.toolCallId)
    assert.truthy(table.concat(trimmed(handle.bufnr), "\n"):find("tool call t2", 1, true))
    handle.unmount()
  end)

  it("disappears when the queue drains", function()
    local store = SessionStore:new()
    store:append_streaming_text("agent", "done")
    pending(store, "t1")
    local handle = mount_transcript(store, 40)
    store:drain_permissions()
    assert.same({ "done" }, trimmed(handle.bufnr))
    handle.unmount()
  end)
end)

describe("view.transcript memoization", function()
  it("a store mutation keeps every unchanged entry's host node", function()
    local store = SessionStore:new()
    store:append_entry({ kind = "user", text = "hi" })
    store:append_streaming_text("agent", "hello")
    store:upsert_tool_call({ tool_call_id = "t1", kind = "execute", argument = "ls", status = "pending" })

    local host = inline_host.new({
      get_size = function()
        return { width = 60 }
      end,
    })
    local root = runtime.create_root(transcript.Transcript, { store = store, prefs = Prefs:new() }, { host = host })
    root:render()

    local user_node = host.tree.children[1]
    local agent_node = host.tree.children[2]
    local tool_node = host.tree.children[3]

    -- appending re-renders the list; the three existing entries bail out
    store:append_entry({ kind = "user", text = "more" })
    assert.rawequal(user_node, host.tree.children[1])
    assert.rawequal(agent_node, host.tree.children[2])
    assert.rawequal(tool_node, host.tree.children[3])

    -- updating ONE tool call rebuilds only its node
    store:upsert_tool_call({ tool_call_id = "t1", status = "completed" })
    assert.rawequal(user_node, host.tree.children[1])
    assert.rawequal(agent_node, host.tree.children[2])
    assert.is_false(rawequal(tool_node, host.tree.children[3]))

    root:unmount()
  end)

  it("unmounting unsubscribes from the store", function()
    local store = SessionStore:new()
    local handle = mount_transcript(store)
    handle.unmount()
    assert.has_no_error(function()
      store:append_entry({ kind = "user", text = "after" })
    end)
    assert.equal(0, #store._subscribers)
  end)
end)

describe("view.transcript prefs", function()
  it("show_thoughts=false hides thought entries, live", function()
    local store = SessionStore:new()
    store:append_entry({ kind = "user", text = "q" })
    store:append_streaming_text("thought", "hmm")
    store:append_streaming_text("agent", "a")
    local prefs = Prefs:new()
    local handle = mount_transcript(store, nil, prefs)

    prefs:toggle("show_thoughts")
    assert.same({ "❯ q", "", "a" }, trimmed(handle.bufnr))

    prefs:toggle("show_thoughts")
    assert.same({ "❯ q", "", "[thinking]", "  hmm", "", "a" }, trimmed(handle.bufnr))
    handle.unmount()
  end)

  it("show_diffs=false hides the diff preview but keeps the header, live", function()
    local store = SessionStore:new()
    store:upsert_tool_call({
      tool_call_id = "e1",
      kind = "edit",
      file_path = "a.lua",
      status = "completed",
      diff = { old = { "local a = 1" }, new = { "local a = 2" } },
    })
    local prefs = Prefs:new()
    local handle = mount_transcript(store, nil, prefs)

    prefs:toggle("show_diffs")
    assert.same({ tool_header("completed", "edit", "a.lua") }, trimmed(handle.bufnr))
    assert.same({}, marks_with(handle.bufnr, "DiffAdd"))

    prefs:toggle("show_diffs")
    assert.equal("    +local a = 2", trimmed(handle.bufnr)[4])
    handle.unmount()
  end)

  it("unmounting unsubscribes from prefs too", function()
    local store = SessionStore:new()
    local prefs = Prefs:new()
    local handle = mount_transcript(store, nil, prefs)
    handle.unmount()
    assert.equal(0, #prefs._subscribers)
  end)
end)
