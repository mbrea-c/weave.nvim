-- weave.view.float: the chrome every popup shares — q/<Esc> closes, and so
-- does moving focus anywhere outside the float.
--
-- "Outside" is the whole point: a fibrous mount's own controls live in
-- SEPARATE floats anchored to it (w:fibrous_anchor), so a naive check would
-- dismiss the settings window the moment you focused its debounce field. The
-- ownership walk is what makes the rule usable, so most of this file is about
-- windows that must NOT count as leaving.

local Float = require("weave.view.float")
local Settings = require("weave.settings")

--- Let scheduled work run (the dismissal is deferred out of the autocmd).
local function pump()
  vim.wait(30, function()
    return false
  end)
end

describe("view.float", function()
  local base, opened

  --- A float, optionally anchored to `anchor` the way fibrous marks its
  --- subwindow floats.
  local function float(anchor)
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 10,
      height = 3,
      style = "minimal",
    })
    if anchor then
      vim.w[win].fibrous_anchor = anchor
    end
    opened[#opened + 1] = win
    return win
  end

  before_each(function()
    base = vim.api.nvim_get_current_win()
    opened = {}
  end)

  after_each(function()
    for _, win in ipairs(opened) do
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_win_is_valid(base) then
      vim.api.nvim_set_current_win(base)
    end
    Settings._reset()
  end)

  describe("ownership", function()
    it("counts the root itself", function()
      local root = float()
      assert.is_true(Float.owns(root, root))
    end)

    it("counts a subwindow anchored to the root", function()
      local root = float()
      assert.is_true(Float.owns(root, float(root)))
    end)

    it("counts a subwindow nested inside a container, up the whole chain", function()
      local root = float()
      local container = float(root)
      local leaf = float(container)
      assert.is_true(Float.owns(root, leaf))
    end)

    it("does not count an unrelated window, or another popup's subwindow", function()
      local root = float()
      local other = float()
      assert.is_false(Float.owns(root, other))
      assert.is_false(Float.owns(root, float(other)))
      assert.is_false(Float.owns(root, base))
    end)

    it("answers false for a window that is gone, rather than erroring", function()
      local root = float()
      local dead = float(root)
      vim.api.nvim_win_close(dead, true)
      assert.is_false(Float.owns(root, dead))
      assert.is_false(Float.owns(root, nil))
    end)

    -- The bound exists so a cycle cannot hang the editor inside an autocmd.
    it("gives up on an anchor cycle", function()
      local a, b = float(), float()
      vim.w[a].fibrous_anchor = b
      vim.w[b].fibrous_anchor = a
      assert.is_false(Float.owns(float(), a))
    end)
  end)

  describe("dismiss on unfocus", function()
    it("fires when focus lands outside", function()
      local win = float()
      local closed = 0
      Float.dismiss_on_unfocus(win, {
        on_unfocus = function()
          closed = closed + 1
        end,
      })
      vim.api.nvim_set_current_win(win)
      assert.equal(0, closed)

      vim.api.nvim_set_current_win(base)
      pump()
      assert.equal(1, closed)
    end)

    it("does not fire for the float's own controls", function()
      local win = float()
      local closed = 0
      Float.dismiss_on_unfocus(win, {
        on_unfocus = function()
          closed = closed + 1
        end,
      })
      vim.api.nvim_set_current_win(win)
      local input = float(win)
      local nested = float(input)

      vim.api.nvim_set_current_win(input)
      pump()
      vim.api.nvim_set_current_win(nested)
      pump()
      vim.api.nvim_set_current_win(win)
      pump()
      assert.equal(0, closed)

      -- and still dismisses once focus really does leave
      vim.api.nvim_set_current_win(base)
      pump()
      assert.equal(1, closed)
    end)

    it("fires once, however many windows you visit afterwards", function()
      local win = float()
      local closed = 0
      Float.dismiss_on_unfocus(win, {
        on_unfocus = function()
          closed = closed + 1
        end,
      })
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_set_current_win(base)
      pump()
      vim.api.nvim_set_current_win(float())
      vim.api.nvim_set_current_win(base)
      pump()
      assert.equal(1, closed)
    end)

    -- The escape hatch for a popup holding unsaved state (the permission
    -- preset editor): it is asked every time, and a yes leaves the float be.
    it("respects keep_open, and dismisses once it relents", function()
      local win = float()
      local closed, hold = 0, true
      Float.dismiss_on_unfocus(win, {
        on_unfocus = function()
          closed = closed + 1
        end,
        keep_open = function()
          return hold
        end,
      })
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_set_current_win(base)
      pump()
      assert.equal(0, closed)

      hold = false
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_set_current_win(base)
      pump()
      assert.equal(1, closed)
    end)

    it("stops watching when the float goes by another road", function()
      local win = float()
      local closed = 0
      Float.dismiss_on_unfocus(win, {
        on_unfocus = function()
          closed = closed + 1
        end,
      })
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_close(win, true) -- q, unmount, :q
      pump()
      vim.api.nvim_set_current_win(base)
      pump()
      assert.equal(0, closed)
    end)

    it("can be cancelled", function()
      local win = float()
      local closed = 0
      local cancel = Float.dismiss_on_unfocus(win, {
        on_unfocus = function()
          closed = closed + 1
        end,
      })
      vim.api.nvim_set_current_win(win)
      cancel()
      cancel() -- idempotent
      vim.api.nvim_set_current_win(base)
      pump()
      assert.equal(0, closed)
    end)
  end)

  -- The end-to-end shape, against a REAL popup: the settings window survives
  -- being typed into and closes when you go back to your code. This is the
  -- case the ownership walk exists for, so it is worth one live mount.
  describe("a real popup", function()
    local function open_settings()
      return require("weave.view.settings_window").open({
        view = Settings.new_view(),
        session = Settings.for_session({}),
      })
    end

    local function inputs_of(app)
      local out = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.w[win].fibrous_anchor == app.winid and vim.api.nvim_win_get_config(win).focusable ~= false then
          out[#out + 1] = win
        end
      end
      return out
    end

    it("stays open while you use its own fields", function()
      local app = open_settings()
      local fields = inputs_of(app)
      assert.is_true(#fields > 0, "the settings window has focusable controls")

      vim.api.nvim_set_current_win(fields[1])
      pump()
      assert.is_true(vim.api.nvim_win_is_valid(app.winid))
      app.unmount()
    end)

    it("closes when focus goes back to the editor", function()
      local app = open_settings()
      assert.is_true(vim.api.nvim_win_is_valid(app.winid))

      vim.api.nvim_set_current_win(base)
      pump()
      assert.is_false(vim.api.nvim_win_is_valid(app.winid))
    end)
  end)
end)
