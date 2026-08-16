-- The settings window: the whole runtime-settings surface, grouped by scope,
-- controls shaped by setting type, preset buttons on top.

local mount = require("fibrous.inline.mount")

local Settings = require("weave.settings")
local window = require("weave.view.settings_window")

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

local function locate(bufnr, needle)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local col = l:find(needle, 1, true)
    if col then
      return i, col - 1
    end
  end
  error("not found in buffer: " .. needle)
end

local function press_on(handle, needle)
  local row, col = locate(handle.bufnr, needle)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
  vim.api.nvim_set_current_win(handle.winid)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
end

describe("view.settings_window", function()
  local saved_notify

  local function stores()
    return {
      view = Settings.new_view(),
      session = Settings.for_session({}),
      global = Settings.global(),
    }
  end

  local function mount_window(s)
    return mount.floating(window.Window, { stores = s }, { width = 52, height = 40 })
  end

  before_each(function()
    Settings._reset()
    saved_notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    vim.notify = saved_notify
    Settings._reset()
  end)

  it("renders presets and every scope group with type-shaped controls", function()
    local handle = mount_window(stores())
    local text = text_of(handle.bufnr)

    assert.truthy(text:find("Presets", 1, true))
    assert.truthy(text:find("[tutor]", 1, true))
    assert.truthy(text:find("[normal]", 1, true))

    assert.truthy(text:find("Session — this conversation", 1, true))
    assert.truthy(text:find("[ ] Auto-send edits", 1, true))
    assert.truthy(text:find("Edit debounce (ms): 7000", 1, true))
    assert.truthy(text:find("[ ] Gate writes on unseen edits", 1, true))
    assert.truthy(text:find("Agent brief: normal", 1, true))

    assert.truthy(text:find("View — this panel", 1, true))
    assert.truthy(text:find("[x] Show thinking", 1, true))
    assert.truthy(text:find("[x] Follow streaming", 1, true))

    assert.truthy(text:find("Global — this editor", 1, true))
    assert.truthy(text:find("[ ] Track user edits", 1, true))
    handle.unmount()
  end)

  it("says so instead of guessing when there is no session", function()
    local handle = mount_window({ global = Settings.global(), view = Settings.new_view() })
    assert.truthy(text_of(handle.bufnr):find("(no active session)", 1, true))
    handle.unmount()
  end)

  it("toggles a boolean straight into its store, and re-renders checked", function()
    local s = stores()
    local handle = mount_window(s)
    press_on(handle, "Auto-send edits")

    assert.is_true(s.session:get("auto_send_edits"))
    assert.is_false(s.view:get("show_thoughts") == false) -- untouched neighbour
    assert.truthy(text_of(handle.bufnr):find("[x] Auto-send edits", 1, true))
    handle.unmount()
  end)

  it("edits an integer through vim.ui.input, coercing the string", function()
    local s = stores()
    local handle = mount_window(s)
    local saved_input = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm("2500")
    end
    press_on(handle, "Edit debounce")
    vim.ui.input = saved_input

    assert.equal(2500, s.session:get("debounce_ms"))
    assert.truthy(text_of(handle.bufnr):find("Edit debounce (ms): 2500", 1, true))
    handle.unmount()
  end)

  it("rejects an invalid integer without touching the store", function()
    local s = stores()
    local handle = mount_window(s)
    local saved_input = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm("not-a-number")
    end
    press_on(handle, "Edit debounce")
    vim.ui.input = saved_input

    assert.equal(7000, s.session:get("debounce_ms"))
    handle.unmount()
  end)

  it("picks an enum through vim.ui.select", function()
    local s = stores()
    local handle = mount_window(s)
    local saved_select = vim.ui.select
    local offered
    vim.ui.select = function(items, _, on_choice)
      offered = items
      on_choice("tutor")
    end
    press_on(handle, "Agent brief")
    vim.ui.select = saved_select

    assert.same(Settings.enum_options("brief"), offered)
    assert.equal("tutor", s.session:get("brief"))
    assert.truthy(text_of(handle.bufnr):find("Agent brief: tutor", 1, true))
    handle.unmount()
  end)

  it("applies a preset to the right stores and shows the last-applied hint", function()
    local s = stores()
    local handle = mount_window(s)
    press_on(handle, "[tutor]")

    assert.is_true(s.global:get("track_edits"))
    assert.is_true(s.session:get("auto_send_edits"))
    assert.equal("tutor", s.session:get("brief"))
    assert.equal(7000, s.session:get("debounce_ms")) -- partial: untouched
    assert.truthy(text_of(handle.bufnr):find("last applied: tutor", 1, true))
    handle.unmount()
  end)
end)
