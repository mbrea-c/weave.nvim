local Panel = require("weave.view.panel")
local Store = require("weave.session_store")
local Prefs = require("weave.view.prefs")
local Config = require("weave.config")
local api = vim.api

local function seeded()
  local store = Store:new()
  for i = 1, 240 do
    store:append_entry({kind = "user", text = ("message-%04d"):format(i)})
  end
  store:follow_window()
  return store
end

local function screen(win)
  local top = api.nvim_win_call(win, vim.fn.winsaveview).topline - 1
  return table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), top,
    top + api.nvim_win_get_height(win), false), "\n")
end

describe("viewport transcript", function()
  it("paints the first message after a native jump from the followed tail", function()
    local store, prefs = seeded(), Prefs:new()
    local p = Panel.open({store = store, prefs = prefs, content_visibility = "auto"})
    local win = p.transcript.winid
    assert.is_true(api.nvim_buf_line_count(p.transcript.bufnr) >= 240)
    prefs:set("follow", false)
    api.nvim_win_set_cursor(win, {1, 0})
    api.nvim_exec_autocmds("WinScrolled", {pattern = tostring(win)})
    assert.is_true(vim.wait(1000, function() return screen(win):find("message%-0001") ~= nil end))
    assert.falsy(screen(win):find("older messages"))
    store:append_entry({kind = "agent", text = "new tail"})
    assert.truthy(screen(win):find("message%-0001"))
    p.close()
  end)

  it("honors setup and repeated source jumps to an entry taller than the preceding viewport", function()
    local store, prefs = seeded(), Prefs:new()
    store:append_entry({kind = "agent", text = ("long message\n"):rep(100)})
    store:append_entry({kind = "user", text = "target entry"})
    for _ = 1, 40 do store:append_entry({kind = "agent", text = "another entry"}) end
    prefs:set("follow", false)
    local previous = Config.view.content_visibility
    Config.view.content_visibility = "auto"
    local p = Panel.open({store = store, prefs = prefs})
    Config.view.content_visibility = previous
    assert.truthy(p.visibility)
    for _ = 1, 2 do
      store:reveal_entry(242)
      assert.truthy(screen(p.transcript.winid):find("target entry"))
      api.nvim_win_set_cursor(p.transcript.winid, {1, 0})
      p.visibility:refresh()
    end
    p.close()
  end)

  it("remeasures filtered thoughts and handles a session reset", function()
    local store, prefs = Store:new(), Prefs:new()
    for i = 1, 24 do store:append_entry({kind = "thought", text = "thought " .. i}) end
    store:append_entry({kind = "user", text = "visible after thoughts"})
    prefs:set("follow", false)
    prefs:set("show_thoughts", false)
    local p = Panel.open({store = store, prefs = prefs, content_visibility = "auto"})
    local win = p.transcript.winid
    assert.is_true(vim.wait(1000, function() return screen(win):find("visible after thoughts") ~= nil end))
    prefs:set("show_thoughts", true)
    store:reveal_entry(1)
    assert.is_true(vim.wait(1000, function() return screen(win):find("thought 1") ~= nil end))
    store:reset()
    assert.truthy(screen(win):find("no messages yet"))
    store:append_entry({kind = "user", text = "new conversation"})
    assert.truthy(screen(win):find("new conversation"))
    p.close()
  end)

  it("keeps comments live while unmounted and materializes their exact entry on navigation", function()
    local Feedback, Draft = require("weave.feedback"), require("weave.feedback_store")
    Draft._reset()
    local store, prefs = seeded(), Prefs:new()
    prefs:set("follow", false)
    local p = Panel.open({ store = store, prefs = prefs, content_visibility = "auto" })
    store:reveal_entry(1)
    local comment
    for row, line in ipairs(api.nvim_buf_get_lines(p.transcript.bufnr, 0, -1, false)) do
      local col = line:find("message-0001", 1, true)
      if col then
        comment = assert(Feedback.add({ bufnr = p.transcript.bufnr, body = "remember this",
          range = { lnum = row, end_lnum = row, col = col, end_col = col + #"message-0001" - 1 } }))
        break
      end
    end
    assert.truthy(comment)
    local id = comment.target.spans[1].entry_id
    store:reveal_entry(240)
    assert.equal("hidden", Draft.resolve(comment).state)
    assert.is_true(Feedback.goto_comment(comment.id))
    assert.equal("visible", Draft.resolve(comment).state)
    assert.equal(id, comment.target.spans[1].entry_id)
    assert.truthy(screen(p.transcript.winid):find("message%-0001"))
    p.close()
    Draft._reset()
  end)

  it("creates and tears down separate expanded task stream buffers in the viewport", function()
    local ToolCall = require("weave.view.tool_call")
    ToolCall.reset()
    require("weave.view.renderers.task").install()
    local store, prefs = seeded(), Prefs:new()
    store:upsert_tool_call({ tool_call_id = "viewport-task", kind = "execute", status = "completed",
      mcp = { server = "clankbox", tool = "weave_task_start" },
      input = { command = "printf viewport" }, output = { stdout = "viewport stdout", stderr = "viewport stderr" } })
    local p = Panel.open({ store = store, prefs = prefs, content_visibility = "auto" })
    local function streams()
      local result = {}
      for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_valid(buf) and vim.b[buf].weave_task_stream then
          result[vim.b[buf].weave_task_stream] = buf
        end
      end
      return result
    end
    assert.same({}, streams())
    store:toggle_tool_call("viewport-task")
    local shown = streams()
    assert.truthy(shown.stdout)
    assert.truthy(shown.stderr)
    assert.equal("viewport stdout", api.nvim_buf_get_lines(shown.stdout, 0, -1, false)[1])
    prefs:set("follow", false)
    store:reveal_entry(1)
    assert.is_true(vim.wait(1000, function() return not api.nvim_buf_is_valid(shown.stdout) end))
    store:reveal_entry(241)
    assert.truthy(streams().stdout)
    store:toggle_tool_call("viewport-task")
    assert.same({}, streams())
    p.close()
    ToolCall.reset()
  end)

  it("renders and answers a live permission block at the followed tail", function()
    local store, prefs = seeded(), Prefs:new()
    local p = Panel.open({ store = store, prefs = prefs, content_visibility = "auto" })
    local answer
    store:enqueue_permission({
      request = { toolCall = { toolCallId = "approval", title = "viewport approval" },
        options = { { optionId = "allow", name = "Allow", kind = "allow_once" } } },
      respond = function(value) answer = value end,
    })
    local text = table.concat(api.nvim_buf_get_lines(p.transcript.bufnr, 0, -1, false), "\n")
    assert.truthy(text:find("Permission required", 1, true))
    local permission = store:pop_permission()
    permission.respond("allow")
    assert.equal("allow", answer)
    text = table.concat(api.nvim_buf_get_lines(p.transcript.bufnr, 0, -1, false), "\n")
    assert.falsy(text:find("Permission required", 1, true))
    p.close()
  end)
end)
