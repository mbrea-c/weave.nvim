local mount = require("fibrous.inline.mount")
local targets = require("fibrous.targets")
local mousemove = require("fibrous.inline.mousemove")
local SessionStore = require("weave.session_store")
local Prefs = require("weave.view.prefs")
local Theme = require("weave.view.theme")
local ToolCall = require("weave.view.tool_call")
local Transcript = require("weave.view.transcript")

local function lines(app)
  return vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)
end

local function move(app, row, col)
  vim.api.nvim_set_current_win(app.winid)
  vim.api.nvim_win_set_cursor(app.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = app.bufnr })
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

-- Only the headless pointer is stubbed; routing and activation are real.
local function click(app, row, col)
  mousemove._getmousepos = function()
    return { winid = app.winid, line = row, column = col + 1, coladd = 0,
      screenrow = 100 + row, screencol = 100 + col }
  end
  mousemove._on_move()
  move(app, row, col)
  vim.fn.maparg("<LeftRelease>", "n", false, true).callback()
end

local function highlighted(app, group, col, end_col)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(app.bufnr, -1, 0, -1, { details = true })) do
    if mark[2] == 0 and mark[4].hl_group == group and mark[3] <= col and mark[4].end_col >= end_col then
      return true
    end
  end
  return false
end

describe("tool-call disclosure control", function()
  local apps, saved_mouse
  before_each(function()
    apps, saved_mouse = {}, mousemove._getmousepos
    ToolCall.reset()
  end)
  after_each(function()
    for _, app in ipairs(apps) do app.unmount() end
    mousemove._getmousepos = saved_mouse
    ToolCall.reset()
  end)

  local function open(status, title, width)
    local store = SessionStore:new()
    store:upsert_tool_call({ tool_call_id = "t1", kind = "execute", argument = title or "list files",
      status = status == "awaiting_permission" and "in_progress" or status, input = { command = "ls" } })
    if status == "awaiting_permission" then
      store:enqueue_permission({ request = { toolCall = { toolCallId = "t1" }, options = {} }, respond = function() end })
    end
    local app = mount.floating(Transcript.Transcript, { store = store, prefs = Prefs:new() },
      { width = width or 60, height = 20, mode = "scroll" })
    apps[#apps + 1] = app
    return app, store
  end

  it("uses ASCII plus/minus controls while retaining every status color", function()
    for _, status in ipairs({ "pending", "in_progress", "completed", "failed", "awaiting_permission" }) do
      local app, store = open(status)
      assert.truthy(lines(app)[1]:find(" [+] ", 1, true), status)
      assert.is_true(highlighted(app, Theme.HEADER_HL[status], 1, 4), status)
      for _, circle in ipairs({ "○", "◐", "●", "✗" }) do assert.is_nil(lines(app)[1]:find(circle, 1, true)) end
      store:toggle_tool_call("t1")
      assert.truthy(lines(app)[1]:find(" [-] ", 1, true), status)
      app.unmount()
    end
  end)

  it("toggles only on the icon, not the padding, tag, or title, in either state", function()
    local app, store = open("completed")
    local header = lines(app)[1]
    for _, col in ipairs({ 0, header:find("[execute]", 1, true) - 1, header:find("list files", 1, true) - 1 }) do
      click(app, 1, col)
      assert.falsy(store.state.expanded.t1)
    end
    click(app, 1, 1)
    assert.is_true(store.state.expanded.t1)
    click(app, 1, header:find("list files", 1, true) - 1)
    assert.is_true(store.state.expanded.t1)
    click(app, 1, 1)
    assert.falsy(store.state.expanded.t1)
  end)

  it("does not toggle from a wrapped title continuation", function()
    local app, store = open("completed", ("long command argument "):rep(4), 28)
    assert.is_true(#lines(app) > 2)
    for _, col in ipairs({ 0, 1, 3, 6 }) do
      click(app, 2, col)
      assert.falsy(store.state.expanded.t1)
    end
    click(app, 1, 1)
    assert.is_true(store.state.expanded.t1)
  end)

  it("exposes only the three-cell control to Tab, Enter, and jump navigation", function()
    local app, store = open("completed")
    local list = targets.targets({ winid = app.winid })
    assert.equal(1, #list)
    assert.equal("button", list[1].role)
    assert.same({ 1, 1 }, list[1].pos)
    assert.same({ 1, 4 }, list[1].end_pos) -- exclusive end of the three ASCII cells
    move(app, 1, lines(app)[1]:find("list files", 1, true) - 1)
    press("<CR>")
    assert.falsy(store.state.expanded.t1)
    press("<Tab>")
    assert.same({ 1, 1 }, vim.api.nvim_win_get_cursor(app.winid))
    press("<CR>")
    assert.is_true(store.state.expanded.t1)
    press("<Space>")
    assert.falsy(store.state.expanded.t1)
  end)

  it("highlights only the disclosure glyph on hover", function()
    local app = open("completed")
    move(app, 1, 1)
    local ns = vim.api.nvim_get_namespaces().fibrous_inline_hover
    local marks = vim.api.nvim_buf_get_extmarks(app.bufnr, ns, 0, -1, { details = true })
    assert.equal(1, #marks)
    assert.equal(1, marks[1][3])
    assert.equal(4, marks[1][4].end_col)
    assert.equal(Theme.KIND_TAG_HL.completed, marks[1][4].hl_group)
    move(app, 1, lines(app)[1]:find("list files", 1, true) - 1)
    assert.equal(0, #vim.api.nvim_buf_get_extmarks(app.bufnr, ns, 0, -1, { details = true }))
  end)
end)
