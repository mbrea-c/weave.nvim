-- Terminal-draw benchmark for weave's own screens, on fibrous's shared harness
-- (fibrous.bench.termdraw). Where the ms/op benches measure CPU, this measures
-- what nvim's TUI pushes at a real pty per frame — the tmux+ssh cost, highlight
-- repaints included. It's the number behind the water-indicator flicker: a colour
-- flip writes zero buffer cells but repaints the whole row on the wire.
--
-- A separate, self-contained target (NOT a bench/*_bench.lua the default runner
-- discovers) because it spawns child nvim TUIs and is slower than the CPU benches.
--   make bench-term      (nvim --headless -u NONE -i NONE -l bench/term.lua)
--   nix run .#bench-term

local root = vim.fn.getcwd()
local fibrous = vim.env.FIBROUS_PATH or (root .. "/../nui-reactive")
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  fibrous .. "/lua/?.lua",
  fibrous .. "/lua/?/init.lua",
  package.path,
}, ";")

local termdraw = require("fibrous.bench.termdraw")

local COLS = tonumber(vim.env.BENCH_COLS) or 80
local ROWS = tonumber(vim.env.BENCH_ROWS) or 24
local FRAMES = tonumber(vim.env.BENCH_FRAMES) or 60

-- Run one scenario and print its per-frame terminal draw. `init` mounts the view
-- in the child and defines a global FRAME(i) doing one frame's work. The child
-- gets weave + fibrous on its runtimepath so both are requirable there.
local function run(name, init)
  local r = termdraw.measure({
    rtp = { root, fibrous },
    cols = COLS,
    rows = ROWS,
    frames = FRAMES,
    init = init,
  })
  io.write(("%-46s %8.1f bytes/frame  (%d bytes, %d writes)\n"):format(name, r.per_frame, r.bytes, r.writes))
end

-- Shared preamble: mount a full-width water indicator whose sim + colour we drive
-- by hand (the real component runs off a uv timer; the sim, palette render and
-- colour ease are the same code, stepped deterministically here). The fill points
-- at the CURRENT colour's palette groups, exactly like the component — so easing
-- _G.color re-colours the row via the spans, never via a fixed-group set_hl.
local WATER_PRE = [[
  local mount = require("fibrous.inline.mount")
  local ui = require("fibrous.inline.components")
  local water = require("weave.view.water")
  local W = 60
  _G.sim = water.new(W)
  _G.color = { 60, 120, 200 }
  _G.target = { 220, 40, 40 }
  local set
  local function Water(ctx)
    local s = ctx.use_state(0); set = s.set; local _ = s.get()
    return { comp = ui.label, props = { fill = function(w)
      local pal = water.palette(_G.color)
      return water.frame(water.levels(_G.sim), { width = w, label = "thinking…", hl = pal.shades, label_hl = pal.label })
    end } }
  end
  mount.floating(function() return { comp = ui.col, props = {}, children = { { comp = Water } } } end,
    {}, { width = W, height = 1 })
  _G.rerender = set
]]

io.write(("water indicator — %dx%d pty, %d frames each\n\n"):format(COLS, ROWS, FRAMES))

-- The busy indicator as it actually runs (mirrors the component's timer): ripples
-- every frame, colour eased every color_every frames. The palette cache is warmed
-- first (the colours a fade traverses are created ONCE, off the measured window),
-- so this is the amortised steady-session cost — a colour step is a targeted
-- one-row repaint, not a whole-screen set_hl.
run(
  "water thinking (palette fade, warm cache)",
  WATER_PRE .. [[
  local CE = water.color_every(30)
  -- warm-up: create every palette colour the fade will hit (the one-time set_hl
  -- cost, paid here BEFORE the measured frames — as it is after the first fade).
  do local c = { 60, 120, 200 }
     for _ = 1, 400 do c = water.lerp_rgb(c, _G.target, 0.08); water.palette(c) end end
  _G.FRAME = function(i)
    water.disturb(_G.sim, math.floor(#_G.sim.h / 2) + math.random(-2, 2), 1.6)
    water.step(_G.sim)
    if i % CE == 0 then
      local step = 1 - (1 - 0.08) ^ CE
      _G.color = water.lerp_rgb(_G.color, _G.target, step)   -- palette hit → row re-colours, no set_hl
    end
    _G.rerender(i)
  end
]]
)

-- Steady state: the colour has arrived, so the fill keeps referencing the same
-- palette groups and only the rippling glyphs redraw — the floor.
run(
  "water thinking (settled colour, glyphs only)",
  WATER_PRE .. [[
  _G.color = _G.target
  _G.FRAME = function(i)
    water.disturb(_G.sim, math.floor(#_G.sim.h / 2) + math.random(-2, 2), 1.6)
    water.step(_G.sim)
    _G.rerender(i)
  end
]]
)

io.write("\n")
