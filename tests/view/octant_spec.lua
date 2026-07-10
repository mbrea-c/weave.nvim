-- The shared block-octant glyph table (weave.view.octant): a cell is a 2-column
-- x 4-row sub-canvas (8 sub-cells, 256 patterns). Bit layout: LEFT column = bits
-- 1,2,4,8 for rows TOP->bottom; RIGHT column = those << 4. The water indicator
-- and the sidebar's context bar both draw off this one verified table.

local octant = require("weave.view.octant")

describe("view.octant", function()
  it("maps landmark bitmaps to their glyphs", function()
    assert.equal(" ", octant.glyph(0)) -- nothing lit
    assert.equal("█", octant.glyph(255)) -- everything lit
    assert.equal("▌", octant.glyph(15)) -- left column full = left half block
    assert.equal("▐", octant.glyph(240)) -- right column full = right half block
  end)

  it("offers a braille fallback in the same bit layout", function()
    assert.equal("⣿", octant.glyph(255, "braille"))
    assert.equal("⠀", octant.glyph(0, "braille"))
  end)

  it("col_fill lights a column from the bottom up", function()
    assert.equal(0, octant.col_fill(0)) -- nothing
    assert.equal(8, octant.col_fill(1)) -- bottom row only
    assert.equal(12, octant.col_fill(2)) -- bottom two rows
    assert.equal(14, octant.col_fill(3)) -- bottom three rows
    assert.equal(15, octant.col_fill(4)) -- the whole column (▌ when it's the left one)
    assert.equal(15, octant.col_fill(9)) -- clamped at a full column
  end)
end)
