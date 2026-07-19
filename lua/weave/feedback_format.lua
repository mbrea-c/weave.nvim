-- Turning a code-feedback item into the text an agent reads.
--
-- render() is deliberately pure over already-resolved entries: the wording is
-- the part most likely to need tuning against real agent behaviour, and it
-- should be adjustable without a buffer, an anchor or a session in play.
-- entries() is the impure half that resolves live comments into that shape.

local Store = require("weave.feedback_store")

local M = {}

--- @class weave.feedback.Entry
--- @field path string display path (relative to cwd where possible)
--- @field lnum integer
--- @field end_lnum integer
--- @field quote string[] the whole lines the comment points at
--- @field body string
--- @field source string
--- @field filetype string|nil fence language
--- @field orphaned boolean the anchored code is gone; the line number is stale
--- @field col integer|nil 1-based start column of a partial selection
--- @field end_col integer|nil 1-based end column of a partial selection

--- The fragment a partial selection actually covered, when it sits on one line.
--- A selection spanning several lines is not summarised: the quote already
--- carries it, and a mid-line splice of the first and last lines would read as
--- code that does not exist.
--- @param e weave.feedback.Entry
--- @return string|nil
local function fragment(e)
  if not e.col or not e.end_col or e.lnum ~= e.end_lnum then
    return nil
  end
  local line = e.quote[1]
  if type(line) ~= "string" then
    return nil
  end
  local frag = line:sub(e.col, e.end_col)
  -- A "fragment" that is the entire line tells the reader nothing the fence
  -- has not already said.
  if frag == "" or frag == line then
    return nil
  end
  return frag
end

--- @param e weave.feedback.Entry
--- @return string
local function location(e)
  if e.end_lnum and e.end_lnum > e.lnum then
    return ("%s:%d-%d"):format(e.path, e.lnum, e.end_lnum)
  end
  return ("%s:%d"):format(e.path, e.lnum)
end

--- @param entries weave.feedback.Entry[]
--- @return string
function M.render(entries)
  if #entries == 0 then
    return ""
  end
  local out = {
    ("Inline code feedback (%d comment%s):"):format(#entries, #entries == 1 and "" or "s"),
    "",
  }
  for i, e in ipairs(entries) do
    local head = ("%d. %s"):format(i, location(e))
    if e.source and e.source ~= "weave" then
      head = ("%d. [%s] %s"):format(i, e.source, location(e))
    end
    if e.orphaned then
      head = head .. " (stale: the code this pointed at has since been changed or deleted)"
    end
    out[#out + 1] = head
    out[#out + 1] = "```" .. (e.filetype or "")
    for _, line in ipairs(e.quote or {}) do
      out[#out + 1] = line
    end
    out[#out + 1] = "```"
    local frag = fragment(e)
    if frag then
      out[#out + 1] = ("(selected: %s)"):format(frag)
    end
    out[#out + 1] = e.body or ""
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

--- @param comment weave.feedback.Comment
--- @return weave.feedback.Entry
function M.entry(comment)
  local at = Store.resolve(comment)
  local filetype
  if comment.bufnr and vim.api.nvim_buf_is_valid(comment.bufnr) then
    filetype = vim.bo[comment.bufnr].filetype
  end
  if (filetype == nil or filetype == "") and comment.path ~= "" then
    filetype = vim.filetype.match({ filename = comment.path })
  end
  return {
    -- Relative where possible: the agent's cwd is the project root, and an
    -- absolute path buys nothing but noise.
    path = comment.path ~= "" and vim.fn.fnamemodify(comment.path, ":.") or "(unnamed buffer)",
    lnum = at.lnum,
    end_lnum = at.end_lnum,
    quote = comment.quote,
    body = comment.body,
    source = comment.source,
    filetype = (filetype ~= "" and filetype) or nil,
    orphaned = at.orphaned,
    col = at.col,
    end_col = at.end_col,
  }
end

--- @param item weave.feedback.Item
--- @return string
function M.format(item)
  local entries = {}
  for _, c in ipairs((item or {}).comments or {}) do
    entries[#entries + 1] = M.entry(c)
  end
  return M.render(entries)
end

return M
