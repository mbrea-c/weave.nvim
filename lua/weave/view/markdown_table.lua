-- Pure-text GFM table alignment for the transcript (ported from agentic's
-- markdown_table). Claude emits ragged pipe-tables; aligning columns to a common
-- width makes them readable. This is a TEXT transform (not extmarks): it
-- reformats the lines before they reach markdown.parse, so the result is still
-- valid markdown that the existing highlight/conceal pass handles. No buffer
-- attach, no crash class. `format_lines` also reports which output lines belong
-- to a table, so the renderer can mark them nowrap (aligned columns reflow apart
-- if they wrap).
--
-- Correctness corners handled:
--   * `\|` escaped pipes are NOT cell separators (GFM rule).
--   * pipes inside inline code spans (`a | b`) are NOT separators.
--   * display WIDTH (vim.fn.strdisplaywidth) for padding, so CJK/emoji align.
--   * optional leading/trailing pipes; ragged cell counts (pad short rows).
--   * a block is only treated as a table when row 2 is a valid delimiter row.

local M = {}

--- Raw display width of a string (wide chars count as 2). Falls back to byte
--- length if vim isn't available (keeps the module unit-testable in plain Lua).
--- @param s string
--- @return integer
local function raw_width(s)
  if vim and vim.fn and vim.fn.strdisplaywidth then
    return vim.fn.strdisplaywidth(s)
  end
  return #s
end

--- Number of display cells a markdown marker run would CONCEAL in `s` — the
--- @conceal-captured characters the markdown_inline parser identifies (the `**`,
--- `_`, `` ` ``, `~~` delimiters). Used so column widths/padding reflect what the
--- user actually SEES when conceal is on (e.g. `**bold**` displays as 4 cells,
--- not 8). Only parses when `s` contains a potential marker char (cheap guard).
--- @param s string
--- @return integer concealed display cells
local function concealed_width(s)
  if not (vim and vim.treesitter) then
    return 0
  end
  if not s:find("[%*_`~]") then
    return 0 -- no marker chars → nothing concealed; skip the parse
  end
  local ok, parser = pcall(vim.treesitter.get_string_parser, s, "markdown_inline")
  if not ok or not parser then
    return 0
  end
  pcall(parser.parse, parser, true)
  local hidden = 0
  parser:for_each_tree(function(tstree, langtree)
    local q = vim.treesitter.query.get(langtree:lang(), "highlights")
    if not q then
      return
    end
    for id, node in q:iter_captures(tstree:root(), s, 0, -1) do
      if q.captures[id]:find("^conceal") then
        local _, sc, _, ec = node:range()
        hidden = hidden + (ec - sc)
      end
    end
  end)
  return hidden
end

--- Visible display width of a cell. When `conceal` is true, subtracts the markdown
--- markers that conceal hides, so aligned columns match what the user sees.
--- @param s string
--- @param conceal boolean|nil
--- @return integer
local function width(s, conceal)
  local w = raw_width(s)
  if conceal then
    w = w - concealed_width(s)
  end
  return w
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split a markdown table row into raw (untrimmed) cells, honoring GFM escaping.
--- A `|` separates cells ONLY when it is not backslash-escaped (`\|`) and not
--- inside an inline-code span (delimited by runs of backticks). Leading and
--- trailing unescaped pipes are treated as row delimiters, not empty cells.
--- Returns nil if the line contains no unescaped, non-code pipe at all (so it's
--- not a table row).
--- @param line string
--- @return string[]|nil cells (trimmed)
function M.split_row(line)
  local cells = {}
  local buf = {}
  local i = 1
  local n = #line
  local code_run = 0 -- length of the backtick run that opened the current code span (0 = not in code)
  local saw_pipe = false

  local function flush()
    cells[#cells + 1] = trim(table.concat(buf))
    buf = {}
  end

  while i <= n do
    local ch = line:sub(i, i)
    if ch == "\\" and i < n then
      -- escaped char: keep both bytes verbatim, never a separator.
      buf[#buf + 1] = line:sub(i, i + 1)
      i = i + 2
    elseif ch == "`" then
      -- count the backtick run length.
      local j = i
      while j <= n and line:sub(j, j) == "`" do
        j = j + 1
      end
      local run = j - i
      if code_run == 0 then
        code_run = run -- open a code span
      elseif code_run == run then
        code_run = 0 -- close it (only a matching-length run closes)
      end
      buf[#buf + 1] = line:sub(i, j - 1)
      i = j
    elseif ch == "|" and code_run == 0 then
      saw_pipe = true
      flush()
      i = i + 1
    else
      buf[#buf + 1] = ch
      i = i + 1
    end
  end
  flush()

  if not saw_pipe then
    return nil
  end

  -- Drop the empty leading/trailing cells produced by border pipes (a row
  -- written "| a | b |" yields {"", "a", "b", ""}). Only strip ONE empty cell
  -- at each end, and only if a border pipe was actually present there.
  if line:match("^%s*|") then
    table.remove(cells, 1)
  end
  if line:match("|%s*$") then
    cells[#cells] = nil
  end
  return cells
end

--- Parse a GFM delimiter row (| --- | :--: | ---: |) into per-column alignment,
--- or nil if `line` isn't a valid delimiter row. Every cell must be a run of
--- dashes with optional leading/trailing colons (and at least one dash).
--- @param line string
--- @return ("left"|"right"|"center"|"none")[]|nil
function M.parse_delimiter(line)
  local cells = M.split_row(line)
  if not cells or #cells == 0 then
    return nil
  end
  local aligns = {}
  for _, c in ipairs(cells) do
    if not c:match("^:?%-+:?$") then
      return nil
    end
    local l = c:sub(1, 1) == ":"
    local r = c:sub(-1) == ":"
    aligns[#aligns + 1] = (l and r) and "center" or r and "right" or l and "left" or "none"
  end
  return aligns
end

--- Pad `s` to display `target_width`, honoring alignment. Never truncates.
--- `conceal` makes the width measurement account for hidden markdown markers, so
--- the gap reflects the cell's VISIBLE width (more padding for `**bold**` etc).
--- @param s string
--- @param target_width integer
--- @param align "left"|"right"|"center"|"none"
--- @param conceal boolean|nil
--- @return string
local function pad(s, target_width, align, conceal)
  local gap = target_width - width(s, conceal)
  if gap <= 0 then
    return s
  end
  if align == "right" then
    return string.rep(" ", gap) .. s
  elseif align == "center" then
    local left = math.floor(gap / 2)
    return string.rep(" ", left) .. s .. string.rep(" ", gap - left)
  end
  return s .. string.rep(" ", gap)
end

--- Build a delimiter cell of the given width honoring alignment colons.
--- @param w integer column display width
--- @param align "left"|"right"|"center"|"none"
--- @return string
local function delimiter_cell(w, align)
  -- Ensure at least 3 dashes worth of room is handled by the caller's min width.
  if align == "center" then
    return ":" .. string.rep("-", math.max(1, w - 2)) .. ":"
  elseif align == "right" then
    return string.rep("-", math.max(1, w - 1)) .. ":"
  elseif align == "left" then
    return ":" .. string.rep("-", math.max(1, w - 1))
  end
  return string.rep("-", w)
end

--- Align a contiguous block of table lines (header, delimiter, then data rows).
--- Returns the reformatted lines, or nil if `block` is not a valid table (caller
--- then leaves the lines untouched). The block must be at least header+delimiter.
--- `conceal` measures cell widths by their VISIBLE width (markdown markers like
--- `**`/`` ` `` hidden), so columns align to what the user sees when conceal is on.
--- @param block string[] raw table lines
--- @param conceal boolean|nil
--- @return string[]|nil
function M.align_block(block, conceal)
  if #block < 2 then
    return nil
  end
  local header = M.split_row(block[1])
  local aligns = M.parse_delimiter(block[2])
  if not header or not aligns then
    return nil
  end

  local rows = { header }
  for k = 3, #block do
    local r = M.split_row(block[k])
    if r then
      rows[#rows + 1] = r
    end
  end

  -- Column count is the max across header and all rows (ragged rows are padded
  -- with empty cells; extra cells in a data row still get their own column).
  local ncol = #header
  for _, r in ipairs(rows) do
    ncol = math.max(ncol, #r)
  end
  -- Alignment for a column beyond the delimiter's count defaults to "none".
  local function align_of(c)
    return aligns[c] or "none"
  end

  -- Column display widths, floored at 3 so the delimiter always has >=3 dashes.
  local w = {}
  for c = 1, ncol do
    w[c] = 3
  end
  for _, r in ipairs(rows) do
    for c = 1, ncol do
      w[c] = math.max(w[c], width(r[c] or "", conceal))
    end
  end

  local out = {}

  -- Header
  do
    local cells = {}
    for c = 1, ncol do
      cells[c] = pad(header[c] or "", w[c], align_of(c), conceal)
    end
    out[#out + 1] = "| " .. table.concat(cells, " | ") .. " |"
  end
  -- Delimiter
  do
    local cells = {}
    for c = 1, ncol do
      cells[c] = delimiter_cell(w[c], align_of(c))
    end
    out[#out + 1] = "| " .. table.concat(cells, " | ") .. " |"
  end
  -- Data rows (rows[1] is the header)
  for k = 2, #rows do
    local cells = {}
    for c = 1, ncol do
      cells[c] = pad(rows[k][c] or "", w[c], align_of(c), conceal)
    end
    out[#out + 1] = "| " .. table.concat(cells, " | ") .. " |"
  end

  return out
end

--- Reformat all GFM tables within `lines`, leaving non-table lines untouched.
--- A table starts where a row line is immediately followed by a valid delimiter
--- row, and runs while subsequent lines remain table rows (and not a new
--- delimiter). Returns a NEW list of lines (may differ in length per line, never
--- in count — alignment changes widths, not row counts) plus a parallel boolean
--- array flagging which output lines are (aligned) table rows, for nowrap.
--- @param lines string[]
--- @param conceal boolean|nil measure cell widths by visible (post-conceal) width
--- @return string[] out, boolean[] is_table
function M.format_lines(lines, conceal)
  local out = {}
  local is_table = {}
  local function emit(line, table_row)
    out[#out + 1] = line
    is_table[#out] = table_row or false
  end
  local i = 1
  local n = #lines
  while i <= n do
    local is_row = M.split_row(lines[i]) ~= nil
    local next_is_delim = lines[i + 1] and M.parse_delimiter(lines[i + 1]) ~= nil
    if is_row and next_is_delim then
      -- Gather the block: header, delimiter, then consecutive data-row lines.
      -- A data row stops the scan when it's NOT a table row, when it's itself
      -- a delimiter, OR when it's the HEADER of a new back-to-back table
      -- (a row immediately followed by another delimiter) — otherwise that
      -- header would be swallowed as a data row of the current table.
      local j = i + 2
      while
        j <= n
        and M.split_row(lines[j]) ~= nil
        and M.parse_delimiter(lines[j]) == nil
        and not (lines[j + 1] and M.parse_delimiter(lines[j + 1]) ~= nil)
      do
        j = j + 1
      end
      local block = {}
      for k = i, j - 1 do
        block[#block + 1] = lines[k]
      end
      local aligned = M.align_block(block, conceal)
      if aligned and #aligned == #block then
        for _, l in ipairs(aligned) do
          emit(l, true)
        end
      else
        -- Couldn't align (or row-count mismatch): pass through verbatim.
        for _, l in ipairs(block) do
          emit(l, false)
        end
      end
      i = j
    else
      emit(lines[i], false)
      i = i + 1
    end
  end
  return out, is_table
end

return M
