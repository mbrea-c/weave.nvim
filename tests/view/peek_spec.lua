-- The peek float (weave.view.peek): an entry's RAW source, wrapped and
-- read-only, dismissed with q / <Esc> — or by focusing anything else, since it
-- is a glance and not a window to arrange things around.

local Peek = require("weave.view.peek")

local function lines_of(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

--- Let a scheduled callback (the unfocus close) run.
local function pump()
  vim.wait(50, function()
    return false
  end, 5)
end

describe("view.peek", function()
  local origin

  before_each(function()
    origin = vim.api.nvim_get_current_win()
  end)

  after_each(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= origin and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end)

  it("shows the raw text wrapped, read-only, and focused", function()
    local win = Peek.open("# heading\na very long line", "agent")
    assert.is_not_nil(win)
    assert.same({ "# heading", "a very long line" }, lines_of(win))
    assert.is_true(vim.wo[win].wrap)
    assert.is_false(vim.bo[vim.api.nvim_win_get_buf(win)].modifiable)
    assert.equal(win, vim.api.nvim_get_current_win())
  end)

  it("takes a filetype, so a tool call's JSON highlights as JSON", function()
    local win = Peek.open('{\n  "kind": "execute"\n}', "w:task_start", "json")
    assert.equal("json", vim.bo[vim.api.nvim_win_get_buf(win)].filetype)
  end)

  it("defaults to markdown, and declines to open on empty text", function()
    local win = Peek.open("plain", "user")
    assert.equal("markdown", vim.bo[vim.api.nvim_win_get_buf(win)].filetype)
    assert.is_nil(Peek.open("", "user"))
    assert.is_nil(Peek.open(nil, "user"))
  end)

  it("closes on the close_float key", function()
    local win = Peek.open("body", "agent")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "xt", false)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("closes when focus leaves it", function()
    local win = Peek.open("body", "agent")
    assert.is_true(vim.api.nvim_win_is_valid(win))
    vim.api.nvim_set_current_win(origin)
    pump()
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)
end)
