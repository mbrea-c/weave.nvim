-- The animated "thinking" wave (shell/UX niceties): a 12-char bouncing sine
-- wave drawn with Unicode-16 block-octant glyphs (2x4 sub-cell resolution, 24
-- horizontal samples), each char coloured by its height in the wave. The pure
-- halves — `glyph` (bitmap -> octant/braille char) and `frame` (phase -> per-
-- char coloured spans) — are deterministic and pinned here; the component just
-- drives `frame` off a timer.

local mount = require("fibrous.inline.mount")
local wave = require("clanker.view.wave")

-- Concatenated text of a frame's spans (each span is a string or {text, hl}).
local function frame_text(spans)
  local parts = {}
  for _, s in ipairs(spans) do
    parts[#parts + 1] = type(s) == "string" and s or s[1]
  end
  return table.concat(parts)
end

-- Per-char hl list of a frame (nil for a plain/empty cell).
local function frame_hls(spans)
  local out = {}
  for i, s in ipairs(spans) do
    out[i] = type(s) == "table" and s.hl or false
  end
  return out
end

describe("view.wave glyphs", function()
  it("maps octant bitmaps to the right block glyphs (landmarks)", function()
    -- bit layout: left column = bits 0-3 (values 1,2,4,8, top->bottom),
    -- right column = bits 4-7 (16,32,64,128).
    assert.equal(" ", wave.glyph(0))
    assert.equal("█", wave.glyph(255))
    assert.equal("▄", wave.glyph(204)) -- bottom two rows, both cols
    assert.equal("▌", wave.glyph(15)) -- whole left column
    assert.equal("▐", wave.glyph(240)) -- whole right column
    assert.equal("▀", wave.glyph(51)) -- top two rows, both cols
  end)

  it("renders a THIN single-row dot rising, not a filled bar", function()
    -- the wave is a thin crest line: one lit cell per column at the wave's
    -- height, never filled below it. Equal L/R at row q (0=bottom..3=top):
    -- left dot = 8,4,2,1 ; right dot = 128,64,32,16.
    local Ldot = { [0] = 8, [1] = 4, [2] = 2, [3] = 1 }
    local Rdot = { [0] = 128, [1] = 64, [2] = 32, [3] = 16 }
    local ramp = {}
    for q = 0, 3 do
      ramp[#ramp + 1] = wave.glyph(Ldot[q] + Rdot[q])
    end
    assert.equal("▂𜴧𜴆🮂", table.concat(ramp))
  end)

  it("also offers a universal braille glyph set", function()
    assert.equal("⠀", wave.glyph(0, "braille")) -- U+2800 blank braille
    assert.equal("⣿", wave.glyph(255, "braille")) -- all eight dots
  end)
end)

describe("view.wave frame", function()
  it("draws a single crest at the left end at phase 0", function()
    local spans = wave.frame(0, { width = 12 })
    assert.equal(12, #spans)
    -- one thin hump (🮂𜴆𜶀) at the far left, a baseline (▂ = bottom-row dots)
    -- everywhere else — a single crest, not a repeating wave.
    assert.equal("🮂𜴆𜶀▂▂▂▂▂▂▂▂▂", frame_text(spans))
  end)

  it("bounces: the single crest travels between the two ends", function()
    local at0 = frame_text(wave.frame(0, { width = 12 }))
    local at_quarter = frame_text(wave.frame(math.pi / 2, { width = 12 }))
    local at_half = frame_text(wave.frame(math.pi, { width = 12 }))
    local at_three = frame_text(wave.frame(3 * math.pi / 2, { width = 12 }))
    -- phase drives the crest POSITION (cosine-eased): left → middle → right,
    -- then back to the middle — a ping-pong bounce.
    assert.equal("▂▂▂▂𜴐🮂🮂𜴜▂▂▂▂", at_quarter) -- crest in the middle
    assert.equal("▂▂▂▂▂▂▂▂▂𜵑𜴆🮂", at_half) -- crest at the right end
    assert.is_true(at0 ~= at_quarter)
    assert.is_true(at0 ~= at_half)
    assert.equal(at_quarter, at_three) -- symmetric return (bounce)
  end)

  it("colours each char by its height (taller = later ramp group)", function()
    local spans = wave.frame(0, { width = 12 })
    local hls = frame_hls(spans)
    -- phase-0 heights are {3,2,1,0,0,...}: the crest's peak takes the top ramp
    -- group, the baseline the bottom one.
    assert.equal(wave.HL[4], hls[1]) -- height 3 crest peak -> top group
    assert.equal(wave.HL[3], hls[2]) -- height 2
    assert.equal(wave.HL[2], hls[3]) -- height 1
    assert.equal(wave.HL[1], hls[5]) -- height 0 baseline -> bottom group
  end)
end)

describe("view.wave component", function()
  it("renders nothing while inactive", function()
    local function App()
      return { comp = wave.Wave, props = { active = false, width = 12 } }
    end
    local handle = mount.floating(App, {}, { width = 14, height = 1 })
    assert.equal("", vim.trim(vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1] or ""))
    handle.unmount()
  end)

  it("renders a width-wide wave while active", function()
    local function App()
      return { comp = wave.Wave, props = { active = true, width = 12 } }
    end
    local handle = mount.floating(App, {}, { width = 14, height = 1 })
    local line = vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1] or ""
    assert.equal(12, vim.fn.strwidth(vim.trim(line)))
    handle.unmount()
  end)

  it("animates: the frame advances on its own over time", function()
    local function App()
      return { comp = wave.Wave, props = { active = true, width = 12, fps = 60 } }
    end
    local handle = mount.floating(App, {}, { width = 14, height = 1 })
    local first = vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1]
    -- let a few timer ticks land (real uv timer)
    vim.wait(300, function()
      return vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1] ~= first
    end)
    local later = vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1]
    assert.is_true(first ~= later)
    handle.unmount()
  end)

  it("stops the timer on unmount (no re-render after teardown)", function()
    local function App()
      return { comp = wave.Wave, props = { active = true, width = 12, fps = 60 } }
    end
    local handle = mount.floating(App, {}, { width = 14, height = 1 })
    handle.unmount()
    -- if the timer kept firing into a dead fiber it would error; give it room
    assert.has_no_error(function()
      vim.wait(120, function()
        return false
      end)
    end)
  end)
end)
