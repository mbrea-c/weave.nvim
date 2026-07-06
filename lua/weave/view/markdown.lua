-- Treesitter-highlighted markdown as a reusable component (roadmap R6).
-- Store-agnostic on purpose — props in, vnodes out — so it can move into
-- fibrous unchanged if it earns it (tracker: "candidate for upstreaming").
--
-- `parse` is the pure half: markdown text → per-line fibrous span lists,
-- via the detached STRING parser (vim.treesitter.get_string_parser — no
-- scratch buffers) with the full injection stack: markdown → markdown_inline
-- → fenced-code languages. Capture names become "@<name>.<lang>" groups and
-- nvim's dotted-group fallback resolves them (@keyword.lua → @keyword), so
-- missing lang-specific groups degrade, never error. Trees apply
-- parent-first, so deeper (injected) captures override their host's.
--
-- Conceal is NOT extmark conceal: concealed bytes are simply omitted from
-- the emitted spans. No window ever needs conceallevel, and the layout/wrap
-- engine measures the text that is actually visible. A line whose content
-- conceals away entirely (fence delimiters) is dropped.
--
-- The Markdown component caches the parse per (text, conceal) on a ref —
-- "parse on settle": a settled entry parses exactly once, re-renders hit the
-- cache. While `live` (still streaming) it renders plain paragraphs and
-- never parses.

local ui = require("fibrous.inline.components")
local md_table = require("weave.view.markdown_table")

local M = {}

--- @class weave.markdown.Line
--- @field spans (string|{ [1]: string, hl: string })[] fibrous rich-text spans
--- @field nowrap boolean code-block lines must not wrap

--- Collect the parser's language trees parent-first (application order:
--- later, deeper trees override).
--- @param ltree vim.treesitter.LanguageTree
--- @param out vim.treesitter.LanguageTree[]
local function collect_trees(ltree, out)
  out[#out + 1] = ltree
  for _, child in pairs(ltree:children()) do
    collect_trees(child, out)
  end
end

--- @param lines string[] source lines
--- @return weave.markdown.Line[] plain one span per line, no highlights
local function plain_lines(lines)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = { spans = { l }, nowrap = false }
  end
  return out
end

--- Parse markdown into per-line span lists.
--- @param text string
--- @param opts? { conceal?: boolean }
--- @return weave.markdown.Line[] lines
function M.parse(text, opts)
  opts = opts or {}
  -- Parse newline-terminated input: the bundled queries key some conceal
  -- patterns on the closing newline (an unterminated ``` fence keeps its
  -- closing delimiter visible otherwise). The synthetic last line is dropped
  -- below, so the output line count matches the input exactly.
  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  local src_lines = vim.split(text, "\n", { plain = true })
  table.remove(src_lines)

  -- Align GFM tables first: a pure-text transform to still-valid markdown, so
  -- the treesitter pass highlights the padded cells and conceal still applies.
  -- `table_rows[i]` flags the aligned table lines, rendered nowrap below (their
  -- columns reflow apart if they wrap). Row count is preserved, so the capture
  -- → src_line mapping stays 1:1.
  local table_rows
  src_lines, table_rows = md_table.format_lines(src_lines, opts.conceal)
  text = table.concat(src_lines, "\n") .. "\n"

  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "markdown")
  if not ok or not parser then
    return plain_lines(src_lines)
  end
  local parsed = pcall(function()
    parser:parse(true)
  end)
  if not parsed then
    return plain_lines(src_lines)
  end

  -- Per row (1-based): hl ranges in application order (later wins) and
  -- conceal ranges; cols are 1-based bytes, end-exclusive.
  local hls = {} --- @type table<integer, { s: integer, e: integer, hl: string }[]>
  local conceals = {} --- @type table<integer, { s: integer, e: integer }[]>
  local nowrap_rows = {} --- @type table<integer, boolean>

  local trees = {}
  collect_trees(parser, trees)
  for _, ltree in ipairs(trees) do
    local lang = ltree:lang()
    local query = vim.treesitter.query.get(lang, "highlights")
    if query then
      for _, tree in pairs(ltree:trees()) do
        for id, node, metadata in query:iter_captures(tree:root(), text) do
          local name = query.captures[id]
          if name ~= "spell" and name ~= "nospell" then
            local per = metadata[id]
            local conceal = per and per.conceal
            if conceal == nil then
              conceal = metadata.conceal
            end
            if conceal == nil and name == "conceal" then
              conceal = ""
            end

            local sr, sc, er, ec = node:range()
            -- Fenced/indented code blocks must never wrap. The block capture
            -- ends at (er, 0) exclusive, i.e. covers rows sr .. er-1.
            if lang == "markdown" and name == "markup.raw.block" then
              for row = sr + 1, (ec == 0 and er or er + 1) do
                nowrap_rows[row] = true
              end
            end

            for row = sr, er do
              local line = src_lines[row + 1]
              if line then
                local s = (row == sr) and sc + 1 or 1
                local e = (row == er) and ec + 1 or #line + 1
                e = math.min(e, #line + 1)
                if e > s then
                  if conceal ~= nil then
                    local rc = conceals[row + 1] or {}
                    rc[#rc + 1] = { s = s, e = e }
                    conceals[row + 1] = rc
                  end
                  if name ~= "conceal" then
                    local rh = hls[row + 1] or {}
                    rh[#rh + 1] = { s = s, e = e, hl = "@" .. name .. "." .. lang }
                    hls[row + 1] = rh
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  -- Assemble: per line, walk the bytes, skip concealed ones (when asked),
  -- attribute each kept byte to the LAST covering hl range, merge runs.
  local out = {}
  for row, line in ipairs(src_lines) do
    local row_hls = hls[row] or {}
    local row_conceals = (opts.conceal and conceals[row]) or {}

    local spans = {}
    local run_text, run_hl = {}, nil
    local function flush_run()
      if #run_text > 0 then
        local chunk = table.concat(run_text)
        spans[#spans + 1] = run_hl and { chunk, hl = run_hl } or chunk
        run_text = {}
      end
    end

    for i = 1, #line do
      local concealed = false
      for _, c in ipairs(row_conceals) do
        if i >= c.s and i < c.e then
          concealed = true
          break
        end
      end
      if not concealed then
        local hl
        for _, h in ipairs(row_hls) do
          if i >= h.s and i < h.e then
            hl = h.hl
          end
        end
        if hl ~= run_hl then
          flush_run()
          run_hl = hl
        end
        run_text[#run_text + 1] = line:sub(i, i)
      end
    end
    flush_run()

    -- A non-empty source line whose content concealed away entirely (fence
    -- delimiters) disappears; genuine blank lines stay.
    local dropped = opts.conceal and #line > 0 and #spans == 0
    if not dropped then
      out[#out + 1] = { spans = spans, nowrap = nowrap_rows[row] or table_rows[row] or false }
    end
  end
  return out
end

--- The markdown component. While `live`, renders plain (no parse — cheap
--- enough for every stream tick); once settled, parses ONCE per
--- (text, conceal) and caches on a ref.
--- @param ctx table
--- @param props { text: string, live?: boolean, conceal?: boolean, style?: table }
function M.Markdown(ctx, props)
  local cache = ctx.use_ref()
  local text = props.text or ""
  local children = {}

  if props.live then
    -- Match parse's line accounting: a terminating newline is a line ENDING,
    -- not an extra empty line — no phantom line disappearing on settle.
    if text:sub(-1) == "\n" then
      text = text:sub(1, -2)
    end
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
      children[#children + 1] = { comp = ui.paragraph, props = { text = l } }
    end
  else
    local conceal = props.conceal or false
    if cache.text ~= text or cache.conceal ~= conceal then
      cache.text, cache.conceal = text, conceal
      cache.lines = M.parse(text, { conceal = conceal })
    end
    for _, line in ipairs(cache.lines) do
      local node_text = #line.spans > 0 and line.spans or ""
      children[#children + 1] = {
        comp = line.nowrap and ui.label or ui.paragraph,
        props = { text = node_text },
      }
    end
  end

  return { comp = ui.col, props = { style = props.style }, children = children }
end

return M
