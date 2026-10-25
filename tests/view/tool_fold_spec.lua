local panel = require("weave.view.panel")
local Store = require("weave.session_store")
local Prefs = require("weave.view.prefs")
local ToolCall = require("weave.view.tool_call")
local Config = require("weave.config")

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

describe("entry-wide tool fold keys", function()
  local handles, saved_key, saved_lines
  before_each(function()
    handles, saved_key, saved_lines = {}, Config.keys.toggle_tool_call, vim.o.lines
    ToolCall.reset()
  end)
  after_each(function()
    for _, handle in ipairs(handles) do handle.close() end
    Config.keys.toggle_tool_call, vim.o.lines = saved_key, saved_lines
    ToolCall.reset()
  end)

  local function open()
    local store, prefs = Store:new(), Prefs:new()
    prefs:set("follow", false)
    local handle = panel.open({ store = store, prefs = prefs, width = 90, sidebar_width = 15 })
    handles[#handles + 1] = handle
    return handle, store
  end
  local function at(handle, needle, key)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(handle.transcript.bufnr, 0, -1, false)) do
      local col = line:find(needle, 1, true)
      if col then
        vim.api.nvim_set_current_win(handle.transcript.winid)
        vim.api.nvim_win_set_cursor(handle.transcript.winid, { row, col - 1 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.transcript.bufnr })
        if key then press(key) end
        return row
      end
    end
    error("missing transcript text: " .. needle)
  end
  local function put(store, id, title, extra)
    store:upsert_tool_call(vim.tbl_extend("force", {
      tool_call_id = id, argument = title, kind = "other", status = "completed",
    }, extra or {}))
  end

  it("toggles from padding, tag, and title without widening Enter activation", function()
    local handle, store = open()
    put(store, "first", "HEADER_TITLE")
    for _, needle in ipairs({ " ", "[other]", "HEADER_TITLE" }) do
      at(handle, needle, "<CR>")
      assert.falsy(store.state.expanded.first)
      at(handle, needle, "za")
      assert.is_true(store.state.expanded.first)
      at(handle, needle, "<CR>")
      assert.is_true(store.state.expanded.first)
      at(handle, needle, "za")
      assert.falsy(store.state.expanded.first)
    end
  end)

  it("toggles from wrapped header lines and expanded body, not adjacent prose", function()
    local handle, store = open()
    store:append_entry({ kind = "agent", text = "OUTSIDE_BEFORE" })
    put(store, "first", ("wrapped header "):rep(14), { body = { "BODY_MARKER" } })
    put(store, "second", "SECOND_TOOL")
    store:append_entry({ kind = "agent", text = "OUTSIDE_AFTER" })
    local row = at(handle, "wrapped header")
    vim.api.nvim_win_set_cursor(handle.transcript.winid, { row + 1, 3 })
    press("za")
    assert.is_true(store.state.expanded.first)
    at(handle, "OUTSIDE_BEFORE", "za")
    at(handle, "OUTSIDE_AFTER", "za")
    assert.is_true(store.state.expanded.first)
    assert.falsy(store.state.expanded.second)
    at(handle, "BODY_MARKER", "<CR>")
    assert.is_true(store.state.expanded.first)
    at(handle, "BODY_MARKER", "za")
    assert.falsy(store.state.expanded.first)
    assert.falsy(store.state.expanded.second)
    at(handle, "SECOND_TOOL", "za")
    assert.is_true(store.state.expanded.second)
    assert.falsy(store.state.expanded.first)
  end)

  it("does not activate a body button when folding a custom renderer", function()
    local ui, presses = require("fibrous.inline.components"), 0
    ToolCall.register({ name = "fold-test", match = function(block) return block.tool_call_id == "custom" end,
      render = function(_, props)
        return { comp = ToolCall.Entry, props = vim.tbl_extend("force", {}, props, {
          render_metadata = function()
            return { comp = ui.button, props = { theme = false, label = "BODY_ACTION",
              on_press = function() presses = presses + 1 end } }
          end,
        }) }
      end })
    local handle, store = open()
    put(store, "custom", "CUSTOM_TOOL")
    at(handle, "CUSTOM_TOOL", "za")
    assert.is_true(store.state.expanded.custom)
    at(handle, "BODY_ACTION", "<CR>")
    assert.equal(1, presses)
    assert.is_true(store.state.expanded.custom)
    at(handle, "BODY_ACTION", "za")
    assert.equal(1, presses)
    assert.falsy(store.state.expanded.custom)
  end)

  it("honors rebound and disabled toggle actions independently of Enter", function()
    Config.keys.toggle_tool_call = { "gT", "<F6>" }
    local handle, store = open()
    put(store, "first", "REBIND_TOOL")
    at(handle, "REBIND_TOOL", "gT")
    assert.is_true(store.state.expanded.first)
    at(handle, "REBIND_TOOL", "<F6>")
    assert.falsy(store.state.expanded.first)
    handle.close()
    Config.keys.toggle_tool_call = false
    local disabled, other = open()
    put(other, "disabled", "DISABLED_TOOL")
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(disabled.transcript.bufnr, "n")) do
      assert.is_false(map.lhs == "za" or map.lhs == "gT")
    end
    at(disabled, "[+]", "<CR>")
    assert.is_true(other.state.expanded.disabled)
  end)

  for _, name in ipairs({ "stdout", "stderr" }) do
    it("folds the owning tool from its focused " .. name .. " buffer", function()
      vim.o.lines = 60
      require("weave.view.renderers.task").install()
      local handle, store = open()
      put(store, "task", "STREAM_TOOL", { mcp = { server = "clankbox", tool = "weave_task_status" },
        input = { id = 42 }, output = { [name] = "STREAM_CONTENT" } })
      put(store, "second", "SECOND_TOOL")
      at(handle, "task 42", "za")
      assert.is_true(store.state.expanded.task)
      local stream
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[buf].weave_task_stream == name then stream = buf; break end
      end
      assert.is_not_nil(stream)
      local win = vim.fn.win_findbuf(stream)[1]
      assert.is_not_nil(win)
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 1, 3 })
      press("<CR>")
      assert.is_true(store.state.expanded.task)
      press("za")
      assert.falsy(store.state.expanded.task)
      assert.falsy(store.state.expanded.second)
      assert.is_false(vim.api.nvim_buf_is_valid(stream))
      assert.equal(handle.transcript.winid, vim.api.nvim_get_current_win())
    end)
  end
end)
