-- The markdown component (roadmap R6): treesitter-highlighted markdown as a
-- reusable, store-agnostic component — props in, vnodes out. `parse` is the
-- pure half: text → per-line fibrous span lists, using the detached STRING
-- parser (no scratch buffers) with injections (markdown_inline, fenced-code
-- languages). Conceal is done by OMITTING the concealed bytes from the
-- emitted spans — no window conceallevel involved, and wrapping sees the
-- true visible text. The component caches the parse per (text, conceal):
-- entries parse once when they settle, never per flush ("parse on settle").

local mount = require("fibrous.inline.mount")
local markdown = require("weave.view.markdown")

local SAMPLE = table.concat({
  "# Title",
  "",
  "Some **bold** and `code`.",
  "",
  "```lua",
  "local x = 1",
  "```",
}, "\n")

--- The concatenated text of one parsed line.
local function line_text(line)
  local parts = {}
  for _, span in ipairs(line.spans) do
    parts[#parts + 1] = type(span) == "string" and span or span[1]
  end
  return table.concat(parts)
end

--- The hl of the span containing `needle` (first occurrence) on `line`.
local function hl_of(line, needle)
  for _, span in ipairs(line.spans) do
    local text = type(span) == "string" and span or span[1]
    if text:find(needle, 1, true) then
      return type(span) == "table" and span.hl or nil
    end
  end
  error("needle not in line: " .. needle)
end

--- Buffer lines with the canvas's right padding stripped.
local function trimmed(bufnr)
  local out = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    out[i] = (l:gsub("%s+$", ""))
  end
  return out
end

local function marks_with(bufnr, hl)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    if m[4].hl_group == hl then
      out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col }
    end
  end
  return out
end

describe("view.markdown parse", function()
  it("maps captures to per-line spans, injections included", function()
    local lines = markdown.parse(SAMPLE)
    assert.equal(7, #lines)
    for i, expected in ipairs(vim.split(SAMPLE, "\n", { plain = true })) do
      assert.equal(expected, line_text(lines[i]))
    end

    assert.equal("@markup.heading.1.markdown", hl_of(lines[1], "Title"))
    assert.equal("@markup.strong.markdown_inline", hl_of(lines[3], "bold"))
    assert.equal("@markup.raw.markdown_inline", hl_of(lines[3], "code"))
    -- The fenced block is highlighted by the INJECTED language.
    assert.equal("@keyword.lua", hl_of(lines[6], "local"))
    assert.equal("@number.lua", hl_of(lines[6], "1"))
  end)

  it("code lines are nowrap; prose lines wrap", function()
    local lines = markdown.parse(SAMPLE)
    assert.is_false(lines[3].nowrap)
    assert.is_true(lines[6].nowrap)
  end)

  it("conceal omits markup bytes and drops fully-concealed lines", function()
    local lines = markdown.parse(SAMPLE, { conceal = true })
    -- The fence delimiter lines conceal to nothing and are dropped:
    -- title, blank, prose, blank, code.
    assert.equal(5, #lines)
    assert.equal("Some bold and code.", line_text(lines[3]))
    assert.equal("local x = 1", line_text(lines[5]))
    -- Concealing never breaks the highlight attribution.
    assert.equal("@markup.strong.markdown_inline", hl_of(lines[3], "bold"))
    assert.equal("@keyword.lua", hl_of(lines[5], "local"))
  end)

  it("plain and blank lines pass through", function()
    local lines = markdown.parse("a\n\nb")
    assert.equal(3, #lines)
    assert.equal("a", line_text(lines[1]))
    assert.equal("", line_text(lines[2]))
    assert.equal("b", line_text(lines[3]))
  end)
end)

describe("view.markdown component", function()
  it("renders highlighted markdown; conceal is a prop", function()
    local handle = mount.floating(markdown.Markdown, { text = SAMPLE }, { width = 60, height = 12 })
    assert.equal("Some **bold** and `code`.", trimmed(handle.bufnr)[3])
    assert.equal(1, #marks_with(handle.bufnr, "@markup.strong.markdown_inline"))
    assert.equal(1, #marks_with(handle.bufnr, "@keyword.lua"))

    handle.set_props({ text = SAMPLE, conceal = true })
    assert.equal("Some bold and code.", trimmed(handle.bufnr)[3])
    assert.equal(1, #marks_with(handle.bufnr, "@markup.strong.markdown_inline"))
    handle.unmount()
  end)

  it("live text renders plain and parses once it settles", function()
    local handle =
      mount.floating(markdown.Markdown, { text = "streaming **now**", live = true }, { width = 60, height = 6 })
    assert.equal("streaming **now**", trimmed(handle.bufnr)[1])
    assert.equal(0, #marks_with(handle.bufnr, "@markup.strong.markdown_inline"))

    handle.set_props({ text = "streaming **now**", live = false })
    assert.equal(1, #marks_with(handle.bufnr, "@markup.strong.markdown_inline"))
    handle.unmount()
  end)

  it("parses once per (text, conceal) — re-renders hit the cache", function()
    local real_parse = markdown.parse
    local calls = 0
    markdown.parse = function(...)
      calls = calls + 1
      return real_parse(...)
    end

    local handle = mount.floating(markdown.Markdown, { text = "some **bold**" }, { width = 60, height = 6 })
    assert.equal(1, calls)
    -- A re-render with the same text (fresh props table: no memo bailout)
    -- reuses the cached parse …
    handle.set_props({ text = "some **bold**" })
    assert.equal(1, calls)
    -- … and changed text or conceal parses again.
    handle.set_props({ text = "some **bold**!" })
    assert.equal(2, calls)
    handle.set_props({ text = "some **bold**!", conceal = true })
    assert.equal(3, calls)

    markdown.parse = real_parse
    handle.unmount()
  end)
end)
