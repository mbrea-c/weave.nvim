-- The keybinding surface: every key weave binds comes from ONE named-action
-- table (Config.keys), so a user can rebind or disable any of them without
-- patching view code. This spec pins the contract the view layer relies on —
-- normalization of the config value shapes, per-action default modes, and the
-- disable path — plus the invariant that every action a view module asks for
-- actually exists (a typo'd action name must fail loudly, not silently bind
-- nothing).

local Config = require("weave.config")
local Keys = require("weave.keys")

--- Run `fn` with Config.keys[action] temporarily set to `value`.
local function with_key(action, value, fn)
  local saved = Config.keys[action]
  Config.keys[action] = value
  local ok, err = pcall(fn)
  Config.keys[action] = saved
  if not ok then
    error(err, 0)
  end
end

local function scratch()
  return vim.api.nvim_create_buf(false, true)
end

--- The lhs of every map on `bufnr` in `mode`, as a set keyed by RAW bytes
--- (get_keymap reports display form — <C-S> for <C-s> — so both sides go
--- through replace_termcodes).
local function maps_of(bufnr, mode)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode or "n")) do
    out[vim.api.nvim_replace_termcodes(m.lhs, true, true, true)] = true
  end
  return out
end

--- Set lookup through the same normalization.
local function has_map(maps, lhs)
  return maps[vim.api.nvim_replace_termcodes(lhs, true, true, true)] or false
end

describe("weave.keys", function()
  it("every action has a default, a description and a scope", function()
    assert.is_true(#Keys.ACTIONS > 0)
    local seen = {}
    for _, action in ipairs(Keys.ACTIONS) do
      assert.equal("string", type(action.name))
      assert.is_false(seen[action.name] or false) -- names are unique
      seen[action.name] = true
      assert.equal("string", type(action.desc))
      assert.is_true(Keys.SCOPES[action.scope] == true)
      assert.is_not_nil(Config.keys[action.name]) -- shipped default
    end
  end)

  it("normalizes the three config value shapes", function()
    -- a bare string is one normal-mode binding
    with_key("sessions", ";;S", function()
      assert.same({ { lhs = ";;S", mode = { "n" } } }, Keys.get("sessions"))
    end)
    -- a list binds each entry
    with_key("sessions", { ";;S", "<F5>" }, function()
      assert.same({
        { lhs = ";;S", mode = { "n" } },
        { lhs = "<F5>", mode = { "n" } },
      }, Keys.get("sessions"))
    end)
    -- an entry table carries its own modes
    with_key("sessions", { { ";;S", mode = { "n", "i" } } }, function()
      assert.same({ { lhs = ";;S", mode = { "n", "i" } } }, Keys.get("sessions"))
    end)
  end)

  it("keeps each action's default mode when the user does not say", function()
    -- prompt actions are insert+normal by default: rebinding must not silently
    -- drop the insert-mode half
    assert.same({ "n", "i" }, Keys.get("submit")[1].mode)
    with_key("submit", "<C-CR>", function()
      assert.same({ { lhs = "<C-CR>", mode = { "n", "i" } } }, Keys.get("submit"))
    end)
    -- panel actions are normal-mode only
    assert.same({ "n" }, Keys.get("sessions")[1].mode)
  end)

  it("false (or an empty list) disables an action", function()
    for _, off in ipairs({ false, {} }) do
      with_key("peek", off, function()
        assert.same({}, Keys.get("peek"))
      end)
    end
  end)

  it("errors on an unknown action name", function()
    assert.is_false(pcall(Keys.get, "no_such_action"))
  end)

  it("map() binds every lhs of an action on the buffer, in its modes", function()
    local bufnr = scratch()
    local fired = 0
    with_key("submit", { "<C-s>", "<F5>" }, function()
      Keys.map(bufnr, "submit", function()
        fired = fired + 1
      end)
    end)
    for _, mode in ipairs({ "n", "i" }) do
      local maps = maps_of(bufnr, mode)
      assert.is_true(has_map(maps, "<C-s>"))
      assert.is_true(has_map(maps, "<F5>"))
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("map() binds nothing for a disabled action", function()
    local bufnr = scratch()
    with_key("peek", false, function()
      Keys.map(bufnr, "peek", function() end)
    end)
    assert.same({}, maps_of(bufnr))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("lhs_list() gives the bare keys (for fibrous on_key routing)", function()
    with_key("peek", { "K", "gp" }, function()
      assert.same({ "K", "gp" }, Keys.lhs_list("peek"))
    end)
  end)

  it("on_key() builds a fibrous on_key map with one entry per lhs", function()
    local fired = 0
    with_key("peek", { "K", "gp" }, function()
      local map = Keys.on_key("peek", function()
        fired = fired + 1
      end)
      assert.equal("function", type(map["K"]))
      assert.equal("function", type(map["gp"]))
      map["gp"]()
    end)
    assert.equal(1, fired)
  end)

  it("permission_prefix answers option N by appending the digit", function()
    local bufnr = scratch()
    local answered
    with_key("permission_prefix", ";#", function()
      Keys.map_permissions(bufnr, function(i)
        answered = i
      end)
    end)
    local maps = maps_of(bufnr)
    for i = 1, 9 do
      assert.is_true(has_map(maps, ";#" .. i))
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
    vim.api.nvim_buf_delete(bufnr, { force = true })
    assert.is_nil(answered) -- nothing fired just from binding
  end)
end)
