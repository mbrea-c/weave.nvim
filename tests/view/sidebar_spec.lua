-- The sidebar (roadmap R5): the panel's metadata column — session info, the
-- view-pref checkboxes, the rotating hint, the plan/tasks block, and the
-- permission block (mode + head request with numbered options). A pure
-- projection of SessionStore + Prefs, mounted fixed-mode in its own window.

local mount = require("fibrous.inline.mount")

local SessionStore = require("weave.session_store")
local Prefs = require("weave.view.prefs")
local sidebar = require("weave.view.sidebar")
local Theme = require("weave.view.theme")

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

local function mount_sidebar(store, prefs)
  return mount.floating(
    sidebar.Sidebar,
    { store = store, prefs = prefs or Prefs:new() },
    { width = 34, height = 30 }
  )
end

describe("view.sidebar", function()
  it("renders every section for a fresh session", function()
    local store = SessionStore:new()
    local handle = mount_sidebar(store)
    local text = text_of(handle.bufnr)

    assert.truthy(text:find("Session", 1, true))
    assert.truthy(text:find("(connecting…)", 1, true))
    assert.truthy(text:find("[x] Show thinking", 1, true))
    assert.truthy(text:find("[x] Show edit diffs", 1, true))
    assert.truthy(text:find("[x] Prettify markdown", 1, true))
    assert.truthy(text:find("[x] Follow streaming", 1, true))
    assert.truthy(text:find("Usage", 1, true))
    assert.truthy(text:find("(no usage yet)", 1, true))
    assert.truthy(text:find("Hint", 1, true))
    assert.truthy(text:find("Tasks", 1, true))
    assert.truthy(text:find("(no tasks)", 1, true))
    assert.truthy(text:find("Permissions", 1, true))
    assert.truthy(text:find("Mode: Normal (ask)  (;;p)", 1, true))
    handle.unmount()
  end)

  it("projects usage live: context used/total with percent, and cost when charged", function()
    local store = SessionStore:new()
    local handle = mount_sidebar(store)

    store:set_usage({ used = 7837, size = 200000, cost = { amount = 0.42, currency = "USD" } })
    local text = text_of(handle.bufnr)
    assert.truthy(text:find("7,837 / 200,000", 1, true)) -- thousands-separated
    assert.truthy(text:find("(4%)", 1, true)) -- 7837/200000 ≈ 3.9% → 4%
    assert.truthy(text:find("$0.42", 1, true))
    assert.falsy(text:find("(no usage yet)", 1, true))

    -- a zero cost (free/subscription model) shows no cost line, just context
    store:set_usage({ used = 100, size = 200000, cost = { amount = 0, currency = "USD" } })
    assert.falsy(text_of(handle.bufnr):find("Cost:", 1, true))
    handle.unmount()
  end)

  it("projects session meta and permission mode live", function()
    local store = SessionStore:new()
    local handle = mount_sidebar(store)

    store:set_meta({ provider = "Kiro ACP", agent = "kiro 1.0", model = "sonnet", mode = "dev" })
    local text = text_of(handle.bufnr)
    assert.truthy(text:find("Provider: Kiro ACP", 1, true))
    assert.truthy(text:find("Agent: kiro 1.0", 1, true))
    assert.truthy(text:find("Model: sonnet", 1, true))
    assert.truthy(text:find("Mode: dev", 1, true))
    assert.falsy(text:find("(connecting…)", 1, true))

    store:cycle_permission_mode()
    assert.truthy(text_of(handle.bufnr):find("Mode: Auto (allow all)  (;;p)", 1, true))
    handle.unmount()
  end)

  it("plan tasks: status glyphs with coloured icons; done/failed text struck through", function()
    local store = SessionStore:new()
    store:set_plan({
      { content = "write specs", status = "completed" },
      { content = "implement", status = "in_progress" },
      { content = "ship it", status = "pending" },
      { content = "old idea", status = "failed" },
    }, "acp")
    local handle = mount_sidebar(store)

    -- glyphs: pending □ / in-progress ■ / done ✔ / failed ✖
    local done_row, done_col = locate(handle.bufnr, "✔ write specs")
    locate(handle.bufnr, "■ implement")
    locate(handle.bufnr, "□ ship it")
    local failed_row = locate(handle.bufnr, "✖ old idea")

    -- the icons carry their own status colour (pending stays plain)...
    local amber = marks_with(handle.bufnr, Theme.TASK_ICON_HL.in_progress)
    assert.equal(1, #amber)
    local green = marks_with(handle.bufnr, Theme.TASK_ICON_HL.completed)
    assert.equal(1, #green)
    assert.equal(done_row - 1, green[1].row)
    local red = marks_with(handle.bufnr, Theme.TASK_ICON_HL.failed)
    assert.equal(1, #red)

    -- ...and only the TEXT of done/failed tasks is dimmed + struck through:
    -- the strikethrough starts after the icon, which is never struck
    local struck = marks_with(handle.bufnr, Theme.TASK_DONE_HL)
    assert.equal(2, #struck)
    assert.same({ done_row - 1, failed_row - 1 }, { struck[1].row, struck[2].row })
    assert.is_true(struck[1].col > done_col)
    handle.unmount()
  end)

  it("sections are self-contained: TasksSection mounts standalone and updates live", function()
    local store = SessionStore:new()
    local handle = mount.floating(sidebar.TasksSection, { store = store }, { width = 30, height = 6 })
    assert.truthy(text_of(handle.bufnr):find("Tasks", 1, true))
    assert.truthy(text_of(handle.bufnr):find("(no tasks)", 1, true))

    -- its own use_store subscription re-renders it without the Sidebar shell
    store:set_plan({ { content = "solo", status = "in_progress" } }, "acp")
    assert.truthy(text_of(handle.bufnr):find("■ solo", 1, true))
    assert.falsy(text_of(handle.bufnr):find("(no tasks)", 1, true))
    handle.unmount()
  end)

  it("shows the head permission request with numbered options", function()
    local store = SessionStore:new()
    store:enqueue_permission({
      request = {
        toolCall = { toolCallId = "t1", title = "run ls", kind = "execute" },
        options = {
          { optionId = "allow", name = "Allow", kind = "allow_once" },
          { optionId = "reject", name = "Reject", kind = "reject_once" },
        },
      },
      respond = function() end,
    })
    store:enqueue_permission({
      request = { toolCall = { toolCallId = "t2" }, options = {} },
      respond = function() end,
    })
    local handle = mount_sidebar(store)

    local text = text_of(handle.bufnr)
    assert.truthy(text:find("(1 of 2 pending)", 1, true))
    assert.truthy(text:find("run ls", 1, true))
    assert.truthy(text:find("[1] Allow", 1, true))
    assert.truthy(text:find("[2] Reject", 1, true))

    store:drain_permissions()
    assert.falsy(text_of(handle.bufnr):find("[1] Allow", 1, true))
    handle.unmount()
  end)

  it("checkbox <CR> flips the pref and the mark", function()
    local store = SessionStore:new()
    local prefs = Prefs:new()
    local handle = mount_sidebar(store, prefs)

    press_on(handle, "Show thinking")
    assert.is_false(prefs.state.show_thoughts)
    assert.truthy(text_of(handle.bufnr):find("[ ] Show thinking", 1, true))

    press_on(handle, "Show thinking")
    assert.is_true(prefs.state.show_thoughts)
    handle.unmount()
  end)

  it("rotates the hint live", function()
    local store = SessionStore:new()
    local handle = mount_sidebar(store)
    store:rotate_hint()
    -- the shown hint is whatever the store now holds (may wrap: check prefix)
    local prefix = store.state.hint:sub(1, 20)
    assert.truthy(text_of(handle.bufnr):find(prefix, 1, true))
    handle.unmount()
  end)
end)
