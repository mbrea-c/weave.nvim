local Sidebar = require("weave.view.sidebar")
local Peek = require("weave.view.peek")
local Tasks = require("weave.view.terminal_tasks")
local TaskStore = require("weave.task_store")

describe("popup geometry", function()
  local columns, lines, close
  before_each(function()
    columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 201, 51
  end)
  after_each(function()
    if close then close(); close = nil end
    TaskStore._reset()
    vim.o.columns, vim.o.lines = columns, lines
  end)

  it("fits the rendered plan, including wrapped rows, as the plan grows and shrinks", function()
    local store = require("weave.session_store"):new()
    local app = Sidebar.open_tasks_list(store)
    close = app.unmount
    local function height() return vim.api.nvim_win_get_height(app.winid) end
    assert.equal(160, vim.api.nvim_win_get_width(app.winid))
    assert.equal(vim.api.nvim_buf_line_count(app.bufnr), height())
    local empty = height()
    store:set_plan({ { content = ("a long plan item "):rep(90), status = "pending" } }, "acp")
    assert.is_true(vim.wait(500, function()
      return height() > empty and height() == vim.api.nvim_buf_line_count(app.bufnr)
    end))
    store:set_plan({}, "acp")
    assert.is_true(vim.wait(500, function() return height() == empty end))
  end)

  it("uses the available width for feedback labels", function()
    local store = require("weave.feedback_store")
    local buf = vim.api.nvim_create_buf(false, true)
    store._reset()
    store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = ("x"):rep(80) .. " tail" })
    local app = require("weave.view.feedback").open_list()
    close = function()
      app.unmount()
      store._reset()
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    local lines = vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)
    assert.truthy(table.concat(lines, "\n"):find("tail", 1, true))
  end)

  it("gives a streaming task a stable viewport until the editor resizes", function()
    local task = assert(TaskStore.start({ command = "sleep 0.2; seq 150" }))
    local app = Tasks.open_task_view(task.id)
    close = app.unmount
    local function height() return vim.api.nvim_win_get_height(app.winid) end
    local before = height()
    assert.equal(160, vim.api.nvim_win_get_width(app.winid))
    assert.is_true(vim.wait(5000, function()
      return vim.api.nvim_buf_line_count(app.bufnr) > before
    end))
    assert.equal(before, height())
    vim.o.columns, vim.o.lines = 36, 14
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert.is_true(vim.wait(500, function()
      return vim.api.nvim_win_get_width(app.winid) <= 30 and height() <= 8
    end))
  end)

  it("drops its resize listener even when a popup closes with events suppressed", function()
    local function listeners()
      return #vim.api.nvim_get_autocmds({ event = "VimResized" })
    end
    local before = listeners()
    local win = Peek.open("short text")
    vim.api.nvim_win_call(win, function() vim.cmd("noautocmd close") end)
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert.equal(before, listeners())
  end)

  it("measures wrapped screen rows in native peek and refits at a new width", function()
    local win = Peek.open(("word "):rep(100))
    close = function() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end end
    assert.equal(160, vim.api.nvim_win_get_width(win))
    assert.equal(vim.api.nvim_win_text_height(win, {}).all, vim.api.nvim_win_get_height(win))
    vim.o.columns, vim.o.lines = 36, 14
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert.is_true(vim.wait(500, function()
      return vim.api.nvim_win_get_width(win) <= 30 and vim.api.nvim_win_get_height(win) == 8
    end))
  end)
end)
