-- Navigating to a comment's code. The sidebar no longer lists comments inline,
-- so this is the only way back to a commented span from the UI, and it has to
-- land in a window the user can actually edit in: not a float, and not one of
-- weave's own nofile panes.

local Feedback = require("weave.feedback")
local Store = require("weave.feedback_store")

local seq = 0
local function file_buf(lines)
  seq = seq + 1
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(buf, ("/tmp/weave-goto-%d.lua"):format(seq))
  return buf
end

describe("feedback.goto_comment", function()
  local base

  before_each(function()
    Store._reset()
    vim.cmd("silent! only")
    base = vim.api.nvim_get_current_win()
  end)

  it("puts the cursor on the commented line", function()
    local buf = file_buf({ "one", "two", "three", "four" })
    vim.api.nvim_win_set_buf(base, buf)
    local c = Store.add({ bufnr = buf, range = { lnum = 3, end_lnum = 3 }, body = "x" })

    assert.is_true(Feedback.goto_comment(c.id))
    assert.equal(buf, vim.api.nvim_win_get_buf(0))
    assert.equal(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("follows the anchor after the code moved", function()
    local buf = file_buf({ "one", "two", "three" })
    vim.api.nvim_win_set_buf(base, buf)
    local c = Store.add({ bufnr = buf, range = { lnum = 3, end_lnum = 3 }, body = "x" })
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted", "inserted" })

    assert.is_true(Feedback.goto_comment(c.id))
    assert.equal(5, vim.api.nvim_win_get_cursor(0)[1])
  end)

  -- Activating a comment from the list float must not retarget the float
  -- itself, and must not hijack the transcript pane either.
  it("skips floats and nofile panes when picking a window", function()
    local buf = file_buf({ "alpha", "beta" })
    vim.api.nvim_win_set_buf(base, buf)
    local c = Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "x" })

    local scratch = vim.api.nvim_create_buf(false, true)
    local float = vim.api.nvim_open_win(scratch, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 10,
      height = 3,
    })
    assert.equal(float, vim.api.nvim_get_current_win())

    assert.is_true(Feedback.goto_comment(c.id))
    assert.equal(base, vim.api.nvim_get_current_win())
    assert.equal(2, vim.api.nvim_win_get_cursor(base)[1])
    pcall(vim.api.nvim_win_close, float, true)
  end)

  it("declines a comment that is gone", function()
    assert.is_false(Feedback.goto_comment(4242))
  end)

  -- An orphaned comment still knows where its code was LAST seen; jumping
  -- there beats refusing to move.
  it("jumps to the last known line of an orphaned comment", function()
    local buf = file_buf({ "one", "two", "three" })
    vim.api.nvim_win_set_buf(base, buf)
    local c = Store.add({ bufnr = buf, range = { lnum = 3, end_lnum = 3 }, body = "x" })
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})

    assert.is_true(Feedback.goto_comment(c.id))
    assert.equal(buf, vim.api.nvim_win_get_buf(0))
  end)
end)
