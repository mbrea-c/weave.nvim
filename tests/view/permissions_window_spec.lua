-- The permission-preset configuration window (design-agent-sandbox.md,
-- phase 1): a floating fibrous modal over the editor-global engine — every
-- preset with its source tag and the active marker (a row activates it), the
-- active preset's rules, and the runtime editing flow: [edit]/[new] open a
-- preset as a Lua table in an acwrite scratch float where :w applies it as a
-- runtime preset (shadowing by name) and [delete] drops a runtime def.

local mount = require("fibrous.inline.mount")

local Permissions = require("weave.permissions")
local permissions_window = require("weave.view.permissions_window")

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

--- Pump until `needle` shows in the buffer (or ms elapse); returns the text.
local function wait_text(bufnr, needle, ms)
  vim.wait(ms or 5000, function()
    return text_of(bufnr):find(needle, 1, true) ~= nil
  end, 10)
  return text_of(bufnr)
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

describe("view.permissions_window", function()
  after_each(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
        -- a left-behind editor float may hold unsaved edits; drop them so the
        -- wipe on close can't error
        pcall(function()
          vim.bo[vim.api.nvim_win_get_buf(win)].modified = false
        end)
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    Permissions._reset()
  end)

  it("lists every preset with source tags; the active is marked; a row activates", function()
    local app = permissions_window.open()
    local text = text_of(app.bufnr)
    assert.truthy(text:find("● Normal (ask)", 1, true))
    assert.truthy(text:find("○ Auto (allow all)", 1, true))
    assert.truthy(text:find("○ Allow edits", 1, true))
    assert.truthy(text:find("builtin", 1, true))
    -- the active preset's rules render under it
    assert.truthy(text:find("acp:*", 1, true))
    assert.truthy(text:find("ask", 1, true))

    press_on(app, "Auto (allow all)")
    wait_text(app.bufnr, "● Auto (allow all)")
    assert.equal("auto", Permissions.active().name)
    app.unmount()
  end)

  it("[edit] opens the active preset as Lua; :w applies it as a runtime preset", function()
    local app = permissions_window.open()
    press_on(app, "[edit]")
    local ewin, ebuf = wait_float("normal", app.winid)
    assert.is_not_nil(ewin, "the preset editor float")
    assert.equal("acwrite", vim.bo[ebuf].buftype)

    vim.api.nvim_buf_set_lines(ebuf, 0, -1, false, {
      "{",
      '  name = "normal",',
      '  label = "Normal (locked down)",',
      "  rules = {",
      '    { tool = "*", decision = "deny" },',
      "  },",
      "}",
    })
    vim.api.nvim_buf_call(ebuf, function()
      vim.cmd("silent write")
    end)
    -- the editor closed itself; the runtime def shadows the builtin
    assert.is_false(vim.api.nvim_win_is_valid(ewin))
    assert.equal("runtime", Permissions.get("normal").source)
    assert.equal("deny", Permissions.resolve({ tool = "weave:read" }))
    wait_text(app.bufnr, "Normal (locked down)")
    assert.truthy(text_of(app.bufnr):find("runtime", 1, true))
    app.unmount()
  end)

  it(":w with broken content keeps the editor open and the engine unchanged", function()
    local app = permissions_window.open()
    press_on(app, "[edit]")
    local ewin, ebuf = wait_float("normal", app.winid)
    vim.api.nvim_buf_set_lines(ebuf, 0, -1, false, { "{ name = " })
    vim.api.nvim_buf_call(ebuf, function()
      vim.cmd("silent! write")
    end)
    assert.is_true(vim.api.nvim_win_is_valid(ewin))
    assert.equal("builtin", Permissions.get("normal").source)

    -- a well-formed table that fails validation is also refused
    vim.api.nvim_buf_set_lines(ebuf, 0, -1, false, { '{ name = "x", rules = { { decision = "maybe" } } }' })
    vim.api.nvim_buf_call(ebuf, function()
      vim.cmd("silent! write")
    end)
    assert.is_true(vim.api.nvim_win_is_valid(ewin))
    assert.is_nil(Permissions.get("x"))
    app.unmount()
  end)

  it("[new] seeds a template; :w creates the preset and it appears in the list", function()
    local app = permissions_window.open()
    press_on(app, "[new]")
    local ewin, ebuf = wait_float("my-preset", app.winid)
    assert.is_not_nil(ewin, "the template editor float")
    vim.api.nvim_buf_set_lines(ebuf, 0, -1, false, {
      '{ name = "docs-only", label = "Docs only", rules = {',
      '  { tool = "weave:write", resource = "*.md", decision = "allow" },',
      '  { tool = "weave:write", decision = "deny" },',
      '  { tool = "*", decision = "allow" },',
      "} }",
    })
    vim.api.nvim_buf_call(ebuf, function()
      vim.cmd("silent write")
    end)
    assert.equal("runtime", Permissions.get("docs-only").source)
    wait_text(app.bufnr, "Docs only")
    app.unmount()
  end)

  it("[delete] drops the active preset's runtime def, revealing the shadowed one", function()
    Permissions.save_preset({
      name = "auto",
      label = "Auto (shadowed)",
      rules = { { tool = "*", decision = "allow" } },
    })
    Permissions.set_active("auto")
    local app = permissions_window.open()
    wait_text(app.bufnr, "[delete]")
    press_on(app, "[delete]")
    wait_text(app.bufnr, "Auto (allow all)")
    assert.equal("builtin", Permissions.get("auto").source)
    -- no runtime def left anywhere → no delete button
    assert.is_nil(text_of(app.bufnr):find("[delete]", 1, true))
    app.unmount()
  end)

  it("q closes the window", function()
    local app = permissions_window.open()
    vim.api.nvim_set_current_win(app.winid)
    vim.api.nvim_feedkeys("q", "xt", false)
    assert.is_false(vim.api.nvim_win_is_valid(app.winid))
  end)
end)
