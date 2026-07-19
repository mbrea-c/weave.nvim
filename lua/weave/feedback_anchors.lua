-- Extmark anchoring for inline code feedback. A comment points at a span of
-- code, and that span MOVES: the user edits above it, and more to the point the
-- agent edits above it, which is the whole reason the feedback exists. Storing
-- {file, line} would mean sending the agent a quote that no longer matches what
-- is at that line by the time it reads it.
--
-- So a comment stores an extmark, and a line number is derived from it only at
-- render and at send time. Neovim does the shifting for us, and one primitive
-- covers three jobs at once: the yellow highlight, the anchor, and the reverse
-- lookup that "edit the comment under my cursor" needs (see M.at).
--
-- Ranges here are 1-based and INCLUSIVE on both ends, in buffer coordinates:
-- { lnum, end_lnum, col?, end_col? }, where omitting col/end_col means the
-- whole line span. Extmark coordinates (0-based row, exclusive end col) stay
-- inside this module.
--
-- Two deliberate choices:
--
--   * Default gravity. Text typed at either boundary lands OUTSIDE the comment
--     rather than being absorbed into it. A commented span that quietly grows
--     to swallow later edits would misreport what the user actually pointed at.
--   * invalidate + undo_restore = false. When the anchored lines are deleted
--     the mark goes away instead of collapsing to a zero-width point, so
--     M.range returns nil and the caller can honestly say the comment is
--     orphaned rather than silently pointing at whatever moved into its place.

local Theme = require("weave.view.theme")

local M = {}

M.NS = vim.api.nvim_create_namespace("weave_code_feedback")
M.HL = Theme.CODE_FEEDBACK_HL

--- @class weave.feedback.Range
--- @field lnum integer 1-based first line
--- @field end_lnum integer 1-based last line (inclusive)
--- @field col integer|nil 1-based first byte column (inclusive); nil = line start
--- @field end_col integer|nil 1-based last byte column (inclusive); nil = line end

local function valid(bufnr)
  return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr)
end

--- @param bufnr integer
--- @param lnum integer 1-based
--- @return string
local function line_at(bufnr, lnum)
  return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
end

--- Place an anchor over `range`, highlighted as code feedback.
--- @param bufnr integer
--- @param range weave.feedback.Range
--- @return integer|nil extmark id
function M.set(bufnr, range)
  if not valid(bufnr) then
    return nil
  end
  local last = math.min(range.end_lnum or range.lnum, vim.api.nvim_buf_line_count(bufnr))
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.NS, range.lnum - 1, (range.col or 1) - 1, {
    end_row = last - 1,
    -- inclusive 1-based -> exclusive 0-based is the identity
    end_col = range.end_col or #line_at(bufnr, last),
    hl_group = M.HL,
    invalidate = true,
    undo_restore = false,
  })
  if not ok then
    return nil
  end
  return id
end

--- Where the anchor sits NOW, or nil if its text was deleted.
--- @param bufnr integer
--- @param id integer
--- @return weave.feedback.Range|nil
function M.range(bufnr, id)
  if not valid(bufnr) or type(id) ~= "number" then
    return nil
  end
  local ok, mark = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, M.NS, id, { details = true })
  if not ok or not mark or mark[1] == nil then
    return nil
  end
  local details = mark[3] or {}
  if details.invalid then
    return nil
  end
  return {
    lnum = mark[1] + 1,
    end_lnum = (details.end_row or mark[1]) + 1,
    col = mark[2] + 1,
    end_col = details.end_col or mark[2],
  }
end

--- @param bufnr integer
--- @param id integer
function M.clear(bufnr, id)
  if valid(bufnr) and type(id) == "number" then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, M.NS, id)
  end
end

--- Every anchor whose span covers `lnum`. This is the reverse lookup behind
--- "edit the comment I am sitting on".
--- @param bufnr integer
--- @param lnum integer 1-based
--- @return integer[]
function M.at(bufnr, lnum)
  local out = {}
  if not valid(bufnr) then
    return out
  end
  local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, bufnr, M.NS, 0, -1, { details = true })
  if not ok then
    return out
  end
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    local first, last = mark[2] + 1, (details.end_row or mark[2]) + 1
    if not details.invalid and lnum >= first and lnum <= last then
      out[#out + 1] = mark[1]
    end
  end
  return out
end

--- The text a range covers, as WHOLE lines even when the range is a partial
--- column selection. The quote is what re-anchoring searches for after a
--- buffer unload (see M.find), and a mid-line fragment is far more likely to
--- match in several places than the lines that contain it.
--- @param bufnr integer
--- @param range weave.feedback.Range
--- @return string[]
function M.quote(bufnr, range)
  if not valid(bufnr) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(bufnr, range.lnum - 1, (range.end_lnum or range.lnum), false)
end

--- Locate `quote` in the buffer again, returning its 1-based first line. Used
--- to re-place an anchor whose extmark died with its buffer. First match wins:
--- with no anchor left there is no better tiebreak available, and reporting the
--- first plausible home beats dropping the comment on the floor.
--- @param bufnr integer
--- @param quote string[]
--- @return integer|nil
function M.find(bufnr, quote)
  if not valid(bufnr) or type(quote) ~= "table" or #quote == 0 then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = 1, #lines - #quote + 1 do
    local hit = true
    for j = 1, #quote do
      if lines[i + j - 1] ~= quote[j] then
        hit = false
        break
      end
    end
    if hit then
      return i
    end
  end
  return nil
end

return M
