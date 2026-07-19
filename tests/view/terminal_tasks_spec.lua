-- The terminal-task UI (design-agent-sandbox.md, phase 0c): projections of
-- the editor-global task store. Three surfaces: a sidebar section listing
-- RUNNING tasks (above Permissions), its header opening the full task list
-- (every task ever, with status flags), and per-task live views streaming
-- stdout/stderr as they arrive, with an in-view kill button. Real `sh -c`
-- processes drive every spec, like tasks_spec.

local mount = require("fibrous.inline.mount")

local TaskStore = require("weave.task_store")
local Theme = require("weave.view.theme")
local terminal_tasks = require("weave.view.terminal_tasks")

local function trimmed(bufnr)
  local out = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    out[i] = (l:gsub("%s+$", ""))
  end
  return out
end

local function text_of(bufnr)
  return table.concat(trimmed(bufnr), "\n")
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

local function marks_with(bufnr, hl)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    if m[4].hl_group == hl then
      out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col }
    end
  end
  return out
end

local function press_on(handle, needle)
  local row, col = locate(handle.bufnr, needle)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
  vim.api.nvim_set_current_win(handle.winid)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
end

--- Pump until `needle` shows in the buffer (or ms elapse); returns the text.
local function wait_text(bufnr, needle, ms)
  vim.wait(ms or 5000, function()
    return text_of(bufnr):find(needle, 1, true) ~= nil
  end, 10)
  return text_of(bufnr)
end

local function wait_done(task, ms)
  vim.wait(ms or 5000, function()
    return task.status ~= "running"
  end, 10)
  return task
end

--- The first editor-float (other than `exclude`) whose buffer contains
--- `needle`; pumps until one shows up.
local function wait_float(needle, exclude, ms)
  local win, buf
  vim.wait(ms or 5000, function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= exclude and vim.api.nvim_win_get_config(w).relative == "editor" then
        local b = vim.api.nvim_win_get_buf(w)
        if table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find(needle, 1, true) then
          win, buf = w, b
          return true
        end
      end
    end
    return false
  end, 10)
  return win, buf
end

local function mount_section()
  return mount.floating(terminal_tasks.Section, { width = 30 }, { width = 34, height = 14 })
end

describe("view.terminal_tasks", function()
  before_each(function()
    TaskStore._reset()
  end)

  after_each(function()
    -- close any float a test left behind (stacked live views, the list)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    TaskStore._reset()
    terminal_tasks._tail_lines = 200
  end)

  it("truncate collapses whitespace and clamps to width with an ellipsis", function()
    assert.equal("short", terminal_tasks.truncate("short", 20))
    assert.equal("echo a b", terminal_tasks.truncate("echo a\n  b", 20))
    local cut = terminal_tasks.truncate("a very long command line indeed", 12)
    assert.is_true(vim.api.nvim_strwidth(cut) <= 12)
    assert.truthy(cut:find("…$"))
  end)

  it("tail keeps the last lines and counts what it dropped", function()
    local lines, omitted = terminal_tasks.tail("a\nb\nc\n", 2)
    assert.same({ "b", "c" }, lines)
    assert.equal(1, omitted)
    lines, omitted = terminal_tasks.tail("", 5)
    assert.same({}, lines)
    assert.equal(0, omitted)
    lines, omitted = terminal_tasks.tail("x\ny", 5)
    assert.same({ "x", "y" }, lines)
    assert.equal(0, omitted)
  end)

  it("the sidebar section shows running tasks only, live", function()
    local handle = mount_section()
    assert.truthy(text_of(handle.bufnr):find("Terminal tasks", 1, true))
    assert.truthy(text_of(handle.bufnr):find("(none running)", 1, true))

    -- a started task appears with the running glyph
    local long = assert(TaskStore.start({ command = "sleep 5" }))
    local text = wait_text(handle.bufnr, "[1] sleep 5")
    assert.truthy(text:find("[1] sleep 5", 1, true))
    assert.truthy(text:find("■", 1, true))
    assert.falsy(text:find("(none running)", 1, true))

    -- a task that exits leaves the RUNNING section (the full list keeps it)
    local quick = assert(TaskStore.start({ command = "echo quick" }))
    wait_done(quick)
    vim.wait(5000, function()
      return text_of(handle.bufnr):find("[2]", 1, true) == nil
    end, 10)
    assert.is_nil(text_of(handle.bufnr):find("[2]", 1, true))
    assert.truthy(text_of(handle.bufnr):find("[1] sleep 5", 1, true))

    -- killing the last runner empties the section again
    TaskStore.kill(long.id)
    wait_text(handle.bufnr, "(none running)")
    assert.truthy(text_of(handle.bufnr):find("(none running)", 1, true))
    handle.unmount()
  end)

  it("the header opens the full task list with status flags; rows open live views", function()
    local ok_t = assert(TaskStore.start({ command = "printf 'ok-%s\\n' one" }))
    local bad = assert(TaskStore.start({ command = "exit 3" }))
    local victim = assert(TaskStore.start({ command = "sleep 5" }))
    local runner = assert(TaskStore.start({ command = "sleep 5" }))
    wait_done(ok_t)
    wait_done(bad)
    TaskStore.kill(victim.id)
    wait_done(victim)

    local handle = mount_section()
    wait_text(handle.bufnr, "[4]")
    press_on(handle, "Terminal tasks")
    local win, buf = wait_float("Terminal tasks (4)", handle.winid)
    assert.is_not_nil(win, "the full task list float")

    -- every task ever, with its status flag — completed and killed included
    local content = text_of(buf)
    assert.truthy(content:find("[1] printf", 1, true))
    assert.truthy(content:find("exited (code 0)", 1, true))
    assert.truthy(content:find("exited (code 3)", 1, true))
    assert.truthy(content:find("killed (signal 15)", 1, true))
    assert.truthy(content:find(("running (pid %d)"):format(runner.pid), 1, true))
    assert.equal(1, #marks_with(buf, Theme.TASK_ICON_HL.completed))
    assert.equal(2, #marks_with(buf, Theme.TASK_ICON_HL.failed))
    assert.equal(1, #marks_with(buf, Theme.TASK_ICON_HL.in_progress))

    -- a row opens that task's live view (finished tasks included)
    press_on({ bufnr = buf, winid = win }, "[1] printf")
    local vwin, vbuf = wait_float("task 1: exited (code 0)", win)
    assert.is_not_nil(vwin, "the live task view float")
    assert.truthy(text_of(vbuf):find("ok-one", 1, true))
    assert.is_nil(text_of(vbuf):find("kill task", 1, true))

    -- q closes each float
    vim.api.nvim_set_current_win(vwin)
    vim.api.nvim_feedkeys("q", "xt", false)
    assert.is_false(vim.api.nvim_win_is_valid(vwin))
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_feedkeys("q", "xt", false)
    assert.is_false(vim.api.nvim_win_is_valid(win))

    TaskStore.kill(runner.id)
    handle.unmount()
  end)

  it("the live view streams output as it arrives and kills from its button", function()
    local handle = mount_section()
    local cmd = [[printf 'out-%s\n' alpha; sleep 0.3; printf 'out-%s\n' beta; printf 'err-%s\n' oops >&2; sleep 5]]
    assert(TaskStore.start({ command = cmd }))
    wait_text(handle.bufnr, "[1]")
    press_on(handle, "[1]")
    local win, buf = wait_float("task 1: running (pid", handle.winid)
    assert.is_not_nil(win, "the live task view float")

    -- output arrives WHILE the view is open — no reopen between chunks
    assert.truthy(wait_text(buf, "out-alpha"):find("out-alpha", 1, true))
    assert.truthy(wait_text(buf, "out-beta"):find("out-beta", 1, true))
    assert.truthy(wait_text(buf, "err-oops"):find("err-oops", 1, true))
    locate(buf, "stderr")

    -- the kill button ends the task; the view flips to killed and the button goes
    press_on({ bufnr = buf, winid = win }, "kill task")
    wait_text(buf, "killed (signal")
    assert.truthy(text_of(buf):find("task 1: killed (signal", 1, true))
    assert.is_nil(text_of(buf):find("kill task", 1, true))

    vim.api.nvim_set_current_win(win)
    vim.api.nvim_feedkeys("q", "xt", false)
    assert.is_false(vim.api.nvim_win_is_valid(win))
    handle.unmount()
  end)

  it("caps each stream at the tail and reports the omitted lines", function()
    terminal_tasks._tail_lines = 3
    local task = assert(TaskStore.start({ command = "seq 11 19" }))
    wait_done(task)
    local app = terminal_tasks.open_task_view(task.id)
    local text = text_of(app.bufnr)
    assert.truthy(text:find("(… 6 earlier lines omitted)", 1, true))
    assert.truthy(text:find("17", 1, true))
    assert.truthy(text:find("19", 1, true))
    assert.is_nil(text:find("12", 1, true))
    -- an untouched stream reads (empty); a finished view has no kill button
    assert.truthy(text:find("(empty)", 1, true))
    assert.is_nil(text:find("kill task", 1, true))
    app.unmount()
  end)
end)
