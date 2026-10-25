local mount = require("fibrous.inline.mount")
local Store = require("weave.session_store")
local Feedback = require("weave.feedback")
local Draft = require("weave.feedback_store")
local Transcript = require("weave.view.transcript").Transcript

describe("first-class transcript feedback", function()
  local apps
  before_each(function()
    apps = {}; Draft._reset()
    require("weave.view.tool_call").reset()
    require("weave.view.renderers.task").install()
  end)
  after_each(function()
    Draft._reset()
    for _, app in ipairs(apps) do app.unmount() end
  end)
  local function open(store)
    local prefs = require("weave.view.prefs"):new()
    prefs:set("follow", false)
    local app = mount.floating(Transcript, { store = store, prefs = prefs },
      { width = 60, height = 20, mode = "scroll" })
    apps[#apps + 1] = app
    return app, prefs
  end
  local function comment(app, needle, body)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)) do
      local col = line:find(needle, 1, true)
      if col then return assert(Feedback.add({ bufnr = app.bufnr, body = body or "explain this",
        range = { lnum = row, end_lnum = row, col = col, end_col = col + #needle - 1 } })) end
    end
    error("missing text: " .. needle)
  end

  it("anchors to original message bytes, not a generated buffer filename or line", function()
    local store = Store:new()
    store:append_entry({ kind = "agent", text = "first **selected** word" })
    local app = open(store)
    local c = comment(app, "selected")
    assert.equal("transcript", c.target.kind)
    assert.equal(store:transcript().id, c.target.conversation_id)
    assert.equal(store:transcript().records[1].id, c.target.spans[1].entry_id)
    assert.equal(8, c.target.spans[1].start_byte)
    assert.is_false(Draft.resolve(c).orphaned)
    local formatted = require("weave.feedback_format").format(Draft.draft())
    assert.truthy(formatted:find("Transcript feedback", 1, true))
    assert.truthy(formatted:find("selected", 1, true))
    assert.falsy(formatted:find("(unnamed buffer)", 1, true))
  end)

  it("reprojects on resize and raw/prettified mode changes", function()
    local store = Store:new()
    store:append_entry({ kind = "agent", text = "first **selected** word after a longer introduction" })
    local app, prefs = open(store)
    local c = comment(app, "selected")
    vim.api.nvim_win_set_width(app.winid, 19); app.relayout()
    assert.equal("visible", Draft.resolve(c).state)
    prefs:set("conceal_markdown", false)
    assert.equal("visible", Draft.resolve(c).state)
    assert.equal(c.id, Draft.at_cursor(app.bufnr, Draft.resolve(c).lnum).id)
  end)

  it("keeps hidden comments live and never reattaches them to identical later text", function()
    local store = Store:new()
    store:append_entry({ kind = "agent", text = "selected" })
    local app = open(store)
    local c = comment(app, "selected")
    local id = c.target.spans[1].entry_id
    for i = 1, 45 do store:append_entry({ kind = "agent", text = "selected later " .. i }) end
    store:follow_window()
    assert.equal("hidden", Draft.resolve(c).state)
    assert.is_false(Draft.resolve(c).orphaned)
    assert.equal(id, c.target.spans[1].entry_id)
    assert.is_true(Feedback.goto_comment(c.id))
    assert.equal("visible", Draft.resolve(c).state)
    assert.is_true(#vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false) < 100)
  end)

  it("preserves a selection during streaming and marks reset targets unavailable", function()
    local store = Store:new()
    store:append_streaming_text("agent", "selected")
    local app = open(store)
    local c = comment(app, "selected")
    store:append_streaming_text("agent", " still streaming")
    assert.is_false(Draft.resolve(c).orphaned)
    store:reset()
    store:append_entry({ kind = "agent", text = "selected" })
    assert.equal("unavailable", Draft.resolve(c).state)
    assert.is_true(Draft.resolve(c).orphaned)
    assert.same({ "selected" }, c.quote)
  end)

  it("supports selections spanning multiple messages", function()
    local store = Store:new()
    store:append_entry({ kind = "agent", text = "first message" })
    store:append_entry({ kind = "agent", text = "second message" })
    local app = open(store)
    local c = assert(Feedback.add({ bufnr = app.bufnr, body = "these two",
      range = { lnum = 1, end_lnum = vim.api.nvim_buf_line_count(app.bufnr) } }))
    assert.equal(2, #c.target.spans)
    assert.is_false(c.target.spans[1].entry_id == c.target.spans[2].entry_id)
  end)

  it("flushes only the owning conversation and preserves other drafts and later edits", function()
    local a, b = Store:new(), Store:new()
    a:append_entry({ kind = "agent", text = "ALPHA" })
    b:append_entry({ kind = "agent", text = "BETA" })
    local aa, bb = open(a), open(b)
    local ca, cb = comment(aa, "ALPHA", "a question"), comment(bb, "BETA", "b question")
    local sa = { get_store = function() return a end }
    local message = Feedback.pending_message(sa)
    assert.truthy(message.text:find("a question", 1, true))
    assert.falsy(message.text:find("b question", 1, true))
    Draft.update(ca.id, "edited after enqueue")
    message.on_sent()
    assert.is_not_nil(Draft.get(ca.id))
    assert.is_not_nil(Draft.get(cb.id))
    Feedback.pending_message(sa).on_sent()
    assert.is_nil(Draft.get(ca.id))
    assert.is_not_nil(Draft.get(cb.id))
  end)

  it("retains live stream anchors across ACP updates that do not include output", function()
    local Tasks = require("weave.task_store")
    Tasks._reset()
    local task = assert(Tasks.start({ command = "printf LIVE_STDOUT" }))
    assert.is_true(vim.wait(5000, function() return task.status ~= "running" end, 10))
    local store = Store:new()
    task.owner = { get_store = function() return store end }
    store:upsert_tool_call({ tool_call_id = "live", kind = "execute", status = "in_progress",
      mcp = { server = "clankbox", tool = "weave_task_start" }, input = { command = task.command },
      body = { ("task %d started [weave task: %s]"):format(task.id, task.receipt) } })
    store:toggle_tool_call("live")
    open(store)
    local c
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.b[buf].weave_task_stream == "stdout" then
        c = assert(Feedback.add({ bufnr = buf, body = "live question",
          range = { lnum = 1, col = 1, end_col = #"LIVE_STDOUT" } }))
      end
    end
    assert(c, "missing stdout")
    store:upsert_tool_call({ tool_call_id = "live", status = "completed" })
    assert.is_false(Draft.resolve(c).orphaned)
    Tasks._reset()
  end)

  it("retains selected custom tool detail in a clearly coarse entry anchor", function()
    local store = Store:new()
    store:upsert_tool_call({ tool_call_id = "custom", kind = "other", status = "completed",
      argument = "Custom tool", body = { "CUSTOM_DETAIL" } })
    store:toggle_tool_call("custom")
    local app = open(store)
    local c = comment(app, "CUSTOM_DETAIL")
    assert.equal("entry", c.target.spans[1].precision)
    assert.same({ "CUSTOM_DETAIL" }, c.quote)
    assert.truthy(require("weave.feedback_format").format(Draft.draft()):find("(whole entry)", 1, true))
  end)

  it("marks a closed managed conversation unavailable without losing the quote", function()
    local store = Store:new()
    store:append_entry({ kind = "agent", text = "CLOSED_QUOTE" })
    local app = open(store)
    local Registry = require("weave.registry")
    local list, get, alive = Registry.list, Registry.get, true
    local entry = { key = 999999, session = { get_store = function() return store end } }
    Registry.list = function() return alive and { entry } or {} end
    Registry.get = function(key) if key == entry.key then return alive and entry or nil end; return get(key) end
    local ok, err = pcall(function()
      local c = comment(app, "CLOSED_QUOTE")
      assert.equal(entry.key, c.target.session_key)
      alive = false
      assert.equal("unavailable", Draft.resolve(c).state)
      assert.is_false(Feedback.goto_comment(c.id))
      assert.same({ "CLOSED_QUOTE" }, c.quote)
    end)
    Registry.list, Registry.get = list, get
    assert.is_true(ok, err)
  end)

  it("labels selections containing unmapped generated content as whole-entry feedback", function()
    local store = Store:new()
    store:append_entry({ kind = "agent", text = "prefix $\\alpha$ ending" })
    local app = open(store)
    local c = assert(Feedback.add({ bufnr = app.bufnr, body = "including the formula",
      range = { lnum = 1, end_lnum = 1 } }))
    assert.equal("entry", c.target.spans[1].precision)
    assert.equal("entry", c.target.spans[1].part)
  end)

  it("normalizes buffer zero before resolving a transcript selection", function()
    local store = Store:new()
    store:append_entry({ kind = "agent", text = "ZERO_TARGET" })
    local app = open(store)
    vim.api.nvim_set_current_win(app.winid)
    local c = assert(Feedback.add({ bufnr = 0, body = "zero",
      range = { lnum = 1, col = 1, end_col = 4 } }))
    assert.equal("transcript", c.target.kind)
    assert.equal(app.bufnr, c.bufnr)
  end)

  it("does not reroute transcript feedback through UI selection or a custom sink", function()
    local store = Store:new()
    store:append_entry({ kind = "agent", text = "ROUTED" })
    local app = open(store)
    local c = comment(app, "ROUTED")
    local Registry, Sinks = require("weave.registry"), require("weave.feedback_sinks")
    local list, current = Registry.list, require("weave").get_session
    local accepted, message, custom = 0, nil, false
    local owner = { get_store = function() return store end, send_batch = function(_, msgs)
      accepted = accepted + 1; message = msgs[1]; return true
    end }
    Registry.list = function() return { { key = 999, session = owner } } end
    require("weave").get_session = function() error("must not use UI selection") end
    local ok, err = pcall(function()
      Sinks._reset()
      assert.is_true(Feedback.send())
      assert.equal(1, accepted)
      assert.is_not_nil(Draft.get(c.id)) -- queued, not delivered
      message.on_sent()
      assert.is_nil(Draft.get(c.id))
      c = comment(app, "ROUTED")
      Sinks.register({ name = "weave", send = function() custom = true; return true end })
      local sent = Feedback.send()
      assert.falsy(sent)
      assert.is_false(custom)
      assert.is_not_nil(Draft.get(c.id))
    end)
    Registry.list, require("weave").get_session = list, current
    Sinks._reset()
    assert.is_true(ok, err)
  end)

  it("refuses mixed conversation sends and keeps unavailable targets out of new turns", function()
    local a, b = Store:new(), Store:new()
    a:append_entry({ kind = "agent", text = "A" })
    b:append_entry({ kind = "agent", text = "B" })
    local ca = comment(open(a), "A")
    local cb = comment(open(b), "B")
    assert.falsy(Feedback.send())
    assert.is_not_nil(Draft.get(ca.id))
    assert.is_not_nil(Draft.get(cb.id))
    a:reset()
    assert.is_nil(Feedback.pending_message({ get_store = function() return a end }))
    assert.falsy(Feedback.send())
    Feedback.discard({ session = { get_store = function() return b end } })
    assert.is_nil(Draft.get(cb.id))
    assert.is_not_nil(Draft.get(ca.id))
  end)

  it("defers per-byte source maps until the first comment in a conversation", function()
    local store = Store:new()
    store:append_entry({ kind = "agent", text = "**selected**" })
    local app = open(store)
    assert.is_nil(store.state.transcript_sources)
    comment(app, "selected")
    assert.is_true(store.state.transcript_sources)
    store:reset()
    assert.is_nil(store.state.transcript_sources)
  end)

  it("anchors command and separate stream selections even after panes unmount", function()
    local store = Store:new()
    store:upsert_tool_call({ tool_call_id = "task", kind = "other", status = "completed",
      mcp = { server = "clankbox", tool = "weave_task_status" }, input = { id = 42 },
      output = { command = "printf SELECT_COMMAND", stdout = "\27[32mSELECT_OUT\27[0m\n", stderr = "SELECT_ERR\n" } })
    store:toggle_tool_call("task")
    local app = open(store)
    local command = comment(app, "SELECT_COMMAND")
    assert.equal("tool.command", command.target.spans[1].part)
    local comments = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local stream = vim.b[buf].weave_task_stream
      if stream then
        local needle = stream == "stdout" and "SELECT_OUT" or "SELECT_ERR"
        local c = assert(Feedback.add({ bufnr = buf, body = "stream question",
          range = { lnum = 1, col = 1, end_col = #needle } }))
        assert.equal("tool." .. stream, c.target.spans[1].part)
        comments[#comments + 1] = c
      end
    end
    assert.equal(2, #comments)
    store:upsert_tool_call({ tool_call_id = "task", output = { command = "printf SELECT_COMMAND",
      stdout = "\27[32mSELECT_OUT\27[0m\nmore", stderr = "SELECT_ERR\n" } })
    assert.is_false(Draft.resolve(command).orphaned)
    for _, c in ipairs(comments) do assert.is_false(Draft.resolve(c).orphaned) end
    store:toggle_tool_call("task")
    for _, c in ipairs(comments) do assert.equal("hidden", Draft.resolve(c).state) end
    assert.is_true(Feedback.goto_comment(comments[1].id))
    assert.is_true(store.state.expanded.task)
    for _, c in ipairs(comments) do assert.equal("visible", Draft.resolve(c).state) end
  end)
end)
