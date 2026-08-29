-- The settings window: the whole runtime-settings surface, grouped by scope,
-- controls shaped by setting type (native fibrous: checkbox / singleline
-- text_input / dropdown), preset buttons on top. Field controls are keyed on
-- the committed value, so an external change remounts them re-seeded.

local mount = require("fibrous.inline.mount")

local Logger = require("weave.utils.logger")
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

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

-- The window's field controls are subwindow floats anchored to the mount:
-- the FOCUSABLE ones are inputs (the dropdown popup is not focusable).
local function anchored_inputs(handle)
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].fibrous_anchor == handle.winid and vim.api.nvim_win_get_config(win).focusable ~= false then
      local buf = vim.api.nvim_win_get_buf(win)
      out[#out + 1] = { win = win, buf = buf, text = vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] or "" }
    end
  end
  return out
end

local function input_with(handle, text)
  for _, i in ipairs(anchored_inputs(handle)) do
    if i.text == text then
      return i
    end
  end
  local seen = {}
  for _, i in ipairs(anchored_inputs(handle)) do
    seen[#seen + 1] = i.text
  end
  error(("no input showing %q (inputs: %s)"):format(text, table.concat(seen, ", ")))
end

describe("view.settings_window", function()
  local saved_notify, notifications

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
    notifications = {}
    saved_notify = Logger.notify
    Logger.notify = function(msg)
      notifications[#notifications + 1] = msg
    end
  end)

  after_each(function()
    Logger.notify = saved_notify
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
    assert.truthy(text:find("Edit debounce (ms):", 1, true))
    assert.truthy(text:find("[ ] Gate writes on unseen edits", 1, true))
    assert.truthy(text:find("Agent brief:", 1, true))

    assert.truthy(text:find("View — this panel", 1, true))
    assert.truthy(text:find("[x] Show thinking", 1, true))
    assert.truthy(text:find("[x] Follow streaming", 1, true))

    assert.truthy(text:find("Global — this editor", 1, true))
    assert.truthy(text:find("[ ] Track user edits", 1, true))

    -- the field values live in the native controls' subwindow buffers
    input_with(handle, "7000")
    input_with(handle, "normal")
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
    assert.truthy(text_of(handle.bufnr):find("[x] Auto-send edits", 1, true))
    handle.unmount()
  end)

  it("commits an integer from its text_input on <CR>, coercing the string", function()
    local s = stores()
    local handle = mount_window(s)
    local input = input_with(handle, "7000")

    vim.api.nvim_set_current_win(input.win)
    vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "2500" })
    press("<CR>")

    assert.equal(2500, s.session:get("debounce_ms"))
    -- the committed value re-seeds the (remounted) field
    input_with(handle, "2500")
    handle.unmount()
  end)

  it("rejects an invalid integer without touching the store, leaving it to fix", function()
    local s = stores()
    local handle = mount_window(s)
    local input = input_with(handle, "7000")

    vim.api.nvim_set_current_win(input.win)
    vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "not-a-number" })
    press("<CR>")

    assert.equal(7000, s.session:get("debounce_ms"))
    input_with(handle, "not-a-number") -- typed text kept to fix
    assert.equal(1, #notifications)
    handle.unmount()
  end)

  it("picks an enum through the native dropdown", function()
    local s = stores()
    local handle = mount_window(s)
    local input = input_with(handle, "normal")

    -- focus opens the popup with the selection on the current value;
    -- <C-n> moves to the next option, <CR> commits it
    vim.api.nvim_set_current_win(input.win)
    press("<C-n>")
    press("<CR>")

    assert.equal("tutor", s.session:get("brief"))
    input_with(handle, "tutor")
    handle.unmount()
  end)

  it("re-seeds a field when its store changes underneath it", function()
    local s = stores()
    local handle = mount_window(s)
    input_with(handle, "7000")

    s.session:set("debounce_ms", 3000) -- another surface: preset, API, sidebar
    input_with(handle, "3000")
    handle.unmount()
  end)

  it("applies a preset to the right stores and shows the last-applied hint", function()
    local s = stores()
    local handle = mount_window(s)
    press_on(handle, "[tutor]")

    assert.is_true(s.global:get("track_edits"))
    -- tracking, but NOT auto-send: the shipped tutor speaks when you flush
    assert.is_false(s.session:get("auto_send_edits"))
    assert.equal("tutor", s.session:get("brief"))
    assert.equal(7000, s.session:get("debounce_ms")) -- partial: untouched
    assert.truthy(text_of(handle.bufnr):find("last applied: tutor", 1, true))
    input_with(handle, "tutor") -- the brief field followed
    handle.unmount()
  end)
end)
