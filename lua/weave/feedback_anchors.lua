-- Extmark anchoring for code feedback, in BOTH directions. A note points at a
-- span of code, and that span MOVES: the user edits above it, and more to the
-- point the agent edits above it, which is the whole reason the feedback
-- exists. Storing {file, line} would mean sending the agent a quote that no
-- longer matches what is at that line by the time it reads it.
--
-- The layer is parameterized over namespace and highlight because the same
-- mechanism serves the user's outgoing comments (weave.feedback) and the
-- agent's incoming annotations (weave.annotations). They must NOT share a
-- namespace: `at` is a reverse lookup, and one that mixed the two would answer
-- "dismiss the annotation under my cursor" with somebody else's comment.
-- weave.feedback_anchors itself IS the comment layer, re-exported at module
-- level, so every existing call site reads unchanged.
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

--- @class weave.feedback.AnchorLayer
--- @field NS integer namespace handle
--- @field HL string highlight group the span carries
--- @field set fun(bufnr: integer, range: weave.feedback.Range, extra?: table): integer|nil
--- @field range fun(bufnr: integer, id: integer): weave.feedback.Range|nil
--- @field clear fun(bufnr: integer, id: integer)
--- @field clear_all fun(bufnr: integer)
--- @field at fun(bufnr: integer, lnum: integer): integer[]

--- One anchor namespace. Two layers over the same buffer never see each
--- other's marks.
--- @param opts { name: string, hl: string }
--- @return weave.feedback.AnchorLayer
function M.layer(opts)
  local L = { NS = vim.api.nvim_create_namespace(opts.name), HL = opts.hl }

  --- Place an anchor over `range`, highlighted as this layer's feedback.
  --- `extra` is merged into the extmark options, which is how an annotation
  --- hangs its message off the same mark that highlights the span — one
  --- primitive doing the highlight, the anchor and the rendering at once.
  --- @param bufnr integer
  --- @param range weave.feedback.Range
  --- @param extra table|nil extra nvim_buf_set_extmark options
  --- @return integer|nil extmark id
  function L.set(bufnr, range, extra)
    if not valid(bufnr) then
      return nil
    end
    local last = math.min(range.end_lnum or range.lnum, vim.api.nvim_buf_line_count(bufnr))
    local mark_opts = {
      end_row = last - 1,
      -- inclusive 1-based -> exclusive 0-based is the identity
      end_col = range.end_col or #line_at(bufnr, last),
      hl_group = L.HL,
      invalidate = true,
      undo_restore = false,
    }
    for k, v in pairs(extra or {}) do
      mark_opts[k] = v
    end
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, L.NS, range.lnum - 1, (range.col or 1) - 1, mark_opts)
    if not ok then
      return nil
    end
    return id
  end

  --- Where the anchor sits NOW, or nil if its text was deleted.
  --- @param bufnr integer
  --- @param id integer
  --- @return weave.feedback.Range|nil
  function L.range(bufnr, id)
    if not valid(bufnr) or type(id) ~= "number" then
      return nil
    end
    local ok, mark = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, L.NS, id, { details = true })
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
  function L.clear(bufnr, id)
    if valid(bufnr) and type(id) == "number" then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, L.NS, id)
    end
  end

  --- @param bufnr integer
  function L.clear_all(bufnr)
    if valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, L.NS, 0, -1)
    end
  end

  --- Every anchor whose span covers `lnum`. This is the reverse lookup behind
  --- "edit the comment I am sitting on".
  --- @param bufnr integer
  --- @param lnum integer 1-based
  --- @return integer[]
  function L.at(bufnr, lnum)
    local out = {}
    if not valid(bufnr) then
      return out
    end
    local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, bufnr, L.NS, 0, -1, { details = true })
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

  return L
end

--- The USER's outgoing comments (weave.feedback), re-exported at module level.
local comments = M.layer({ name = "weave_code_feedback", hl = Theme.CODE_FEEDBACK_HL })
M.NS, M.HL = comments.NS, comments.HL
M.set, M.range, M.clear, M.clear_all, M.at =
  comments.set, comments.range, comments.clear, comments.clear_all, comments.at

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
