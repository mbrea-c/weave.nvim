-- The "busy" water indicator: a 1-D Hooke's-law height field (columns coupled
-- by springs) rendered on ONE row with Unicode-16 block octants — 2 sub-columns
-- × 4 sub-rows per cell, filled from the bottom up to each column's surface, so
-- ripples read as water. Disturbances (center agitation while busy; a click/<CR>
-- anywhere on the line) send waves that propagate, reflect off the ends, and
-- decay to rest. A status label is spliced into the centre, and the whole thing
-- fades colour by state (blue idle → yellow thinking → red generating).
--
-- These pin the PURE halves: the octant fill, the sim step (propagate + decay +
-- settle), the frame render + label splice, and the colour helpers. The
-- component's timer/interaction is exercised via prompt_spec.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")
local water = require("weave.view.water")

local function frame_text(spans)
  local parts = {}
  for _, s in ipairs(spans) do
    parts[#parts + 1] = type(s) == "string" and s or s[1]
  end
  return table.concat(parts)
end

describe("view.water glyphs", function()
  it("maps octant bitmaps to the shared block glyphs", function()
    assert.equal(" ", water.glyph(0))
    assert.equal("█", water.glyph(255))
    assert.equal("▄", water.glyph(204)) -- bottom two rows, both columns
    assert.equal("▐", water.glyph(240)) -- whole right column
    assert.equal("⣿", water.glyph(255, "braille"))
  end)

  it("dot(s) lights a SINGLE surface sub-row at height s (rows from the bottom)", function()
    -- surface line only, like the old wave — nothing is filled below it.
    assert.equal(8, water.dot(0)) -- bottom row
    assert.equal(4, water.dot(1)) -- second from the bottom (the rest baseline)
    assert.equal(2, water.dot(2))
    assert.equal(1, water.dot(3)) -- top row
    -- a cell is left dot + right dot (right = left << 4)
    assert.equal(68, water.dot(1) + water.dot(1) * 16) -- both columns at baseline
  end)
end)

describe("view.water sim", function()
  it("a disturbance decays and settles toward rest", function()
    local st = water.new(12) -- 24 sub-columns
    water.disturb(st, 12, 2.0)
    local e0 = water.energy(st)
    assert.is_true(e0 > 0)
    for _ = 1, 1000 do
      water.step(st)
    end
    assert.is_true(water.energy(st) < e0 * 0.01)
    for i = 1, #st.h do
      assert.is_true(math.abs(st.h[i]) < 0.1)
    end
  end)

  it("a disturbance propagates outward to far columns", function()
    local st = water.new(12)
    water.disturb(st, 12, 2.0)
    -- a column far from the centre starts undisturbed …
    assert.is_true(math.abs(st.h[20]) < 1e-9 and math.abs(st.v[20]) < 1e-9)
    for _ = 1, 40 do
      water.step(st)
    end
    -- … and the ripple has reached it
    assert.is_true(math.abs(st.h[20]) > 1e-6 or math.abs(st.v[20]) > 1e-6)
  end)

  it("stays bounded over many steps (stable integration)", function()
    local st = water.new(12)
    water.disturb(st, 12, 3.0)
    for _ = 1, 3000 do
      water.step(st)
    end
    for i = 1, #st.h do
      assert.is_true(math.abs(st.h[i]) < 100)
    end
  end)
end)

describe("view.water frame", function()
  it("renders a surface line: one dot per column at its level, coloured by height", function()
    local levels = {}
    for i = 1, 24 do
      levels[i] = 1 -- rest baseline (2nd row from the bottom)
    end
    local spans = water.frame(levels, { width = 12 })
    assert.equal(12, #spans)
    assert.equal(water.glyph(water.dot(1) + water.dot(1) * 16), spans[1][1])
    assert.equal(water.HL[2], spans[1].hl) -- baseline height → 2nd group

    levels[1], levels[2] = 3, 3 -- a crest at the top of the first cell
    spans = water.frame(levels, { width = 12 })
    assert.equal(water.glyph(water.dot(3) + water.dot(3) * 16), spans[1][1])
    assert.equal(water.HL[4], spans[1].hl)
  end)

  it("splices a centered label into the row with the label hl", function()
    local levels = {}
    for i = 1, 24 do
      levels[i] = 1
    end
    local spans = water.frame(levels, { width = 12, label = "busy", label_hl = "WeaveWaterLabel" })
    assert.equal(12, #spans)
    local text = frame_text(spans)
    assert.truthy(text:find("busy", 1, true))
    -- the label is centred: 12 cells, 4-char label → starts at cell 5
    assert.equal("b", spans[5][1])
    assert.equal("WeaveWaterLabel", spans[5].hl)
    -- water (a surface dot) still shows on the flanks
    assert.equal(water.glyph(water.dot(1) + water.dot(1) * 16), spans[1][1])
  end)
end)

describe("view.water colour", function()
  it("lerps between two RGB colours", function()
    assert.same({ 128, 128, 128 }, water.lerp_rgb({ 0, 0, 0 }, { 255, 255, 255 }, 0.5))
    assert.same({ 10, 20, 30 }, water.lerp_rgb({ 10, 20, 30 }, { 200, 200, 200 }, 0))
    assert.same({ 200, 200, 200 }, water.lerp_rgb({ 10, 20, 30 }, { 200, 200, 200 }, 1))
  end)

  it("derives a 4-step shade ramp that brightens with height", function()
    local shades = water.shades({ 100, 100, 200 })
    assert.equal(4, #shades)
    assert.same({ 100, 100, 200 }, shades[4]) -- top shade IS the base colour
    for i = 1, 3 do
      assert.is_true(shades[i][3] < shades[i + 1][3]) -- brighter each step
    end
  end)
end)

describe("view.water component", function()
  local function line0(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  end

  it("always renders a width-wide water line (present even when idle)", function()
    local handle = mount.floating(function()
      return { comp = ui.col, props = {}, children = { { comp = water.Water, props = { status = "idle" } } } }
    end, {}, { width = 20, height = 3 })
    assert.is_true(vim.fn.strwidth(vim.trim(line0(handle.bufnr))) >= 12)
    handle.unmount()
  end)

  it("<CR> on the line drops a ripple where the cursor is (via on_press local x)", function()
    local handle = mount.floating(function()
      return { comp = ui.col, props = {}, children = { { comp = water.Water, props = { status = "idle" } } } }
    end, {}, { width = 20, height = 3 })
    local rest = line0(handle.bufnr) -- flat rest line

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 1, 6 }) -- middle of the 12-cell line
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
    -- the sim animates on a timer; let a few frames elapse
    vim.wait(300, function()
      return line0(handle.bufnr) ~= rest
    end)
    assert.is_true(line0(handle.bufnr) ~= rest) -- the water moved

    handle.unmount()
  end)
end)
