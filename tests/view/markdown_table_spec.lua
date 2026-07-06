-- Pure-text GFM table alignment (ported from agentic). Claude emits ragged
-- pipe-tables; this reformats the source lines into column-aligned ones that are
-- still valid markdown, so the existing highlight/conceal pass renders them.
-- These pin the pure transform; markdown_spec covers the parse() integration.

local mt = require("weave.view.markdown_table")

describe("view.markdown_table split_row", function()
  it("splits on unescaped pipes, trims, and strips border pipes", function()
    assert.same({ "a", "b", "c" }, mt.split_row("| a | b | c |"))
    assert.same({ "a", "b" }, mt.split_row("a | b"))
  end)

  it("returns nil for a line with no unescaped pipe", function()
    assert.is_nil(mt.split_row("just text"))
  end)

  it("does not split on escaped pipes (GFM \\|)", function()
    assert.same({ "a \\| b", "c" }, mt.split_row("a \\| b | c"))
  end)

  it("does not split on pipes inside an inline-code span", function()
    assert.same({ "`a | b`", "c" }, mt.split_row("`a | b` | c"))
  end)
end)

describe("view.markdown_table parse_delimiter", function()
  it("recognizes a delimiter row and its per-column alignment", function()
    assert.same({ "none", "left", "right", "center" }, mt.parse_delimiter("| --- | :--- | ---: | :---: |"))
  end)

  it("rejects rows that are not delimiter rows", function()
    assert.is_nil(mt.parse_delimiter("| a | b |"))
    assert.is_nil(mt.parse_delimiter("plain"))
  end)
end)

describe("view.markdown_table align_block", function()
  it("aligns a ragged table to common column widths (min 3)", function()
    local out = mt.align_block({ "| Name | Age |", "|---|---|", "| Bob | 30 |", "| Alexandra | 5 |" })
    assert.same({
      "| Name      | Age |",
      "| --------- | --- |",
      "| Bob       | 30  |",
      "| Alexandra | 5   |",
    }, out)
  end)

  it("honors the delimiter's alignment colons", function()
    local out = mt.align_block({ "| a | bb |", "| :-- | --: |", "| xxxx | y |" })
    assert.same({
      "| a    |  bb |",
      "| :--- | --: |",
      "| xxxx |   y |",
    }, out)
  end)

  it("returns nil when the second line is not a delimiter", function()
    assert.is_nil(mt.align_block({ "| a | b |", "| c | d |" }))
  end)
end)

describe("view.markdown_table format_lines", function()
  it("aligns table blocks, leaves other lines untouched, preserves the line count", function()
    local src = { "intro", "| a | bb |", "|-|-|", "| ccc | d |", "outro" }
    local out, is_table = mt.format_lines(src)
    assert.equal(#src, #out)
    assert.same({
      "intro",
      "| a   | bb  |",
      "| --- | --- |",
      "| ccc | d   |",
      "outro",
    }, out)
    -- and it flags which output lines belong to a table (for nowrap rendering)
    assert.is_true(is_table[2])
    assert.is_true(is_table[3])
    assert.is_true(is_table[4])
    assert.is_false(is_table[1])
    assert.is_false(is_table[5])
  end)
end)
