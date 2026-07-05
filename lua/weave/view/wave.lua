-- The animated "thinking" wave (shell/UX niceties). A SINGLE thin crest that
-- bounces back and forth between the two ends of a 12-char bar, rendered with
-- Unicode-16 block-octant glyphs — 2 columns × 4 rows per cell, so 24
-- horizontal sub-columns and 4 vertical levels — each dot coloured by its
-- height (dim-blue baseline → bright-cyan crest). Braille is offered as a
-- universal fallback for terminals without a Unicode-16 font.
--
-- Two pure halves plus a thin component:
--   glyph(bitmap[, set])  bitmap (0-255) → the octant/braille char. Bit layout
--                         (shared with the neominimap tables this borrows):
--                         left column = bits 0-3 (values 1,2,4,8, top→bottom),
--                         right column = bits 4-7 (16,32,64,128).
--   frame(phase, opts)    phase (radians) → a fibrous span list: one coloured
--                         char per cell, height sampled from the sine.
--   Wave(ctx, props)      drives `frame` off a uv timer while `active`.
--
-- WEAVE-LOCAL like the markdown/diff components: store/theme-free (props in,
-- vnodes out) so it never widens the pinned-fibrous gap.

local ui = require("fibrous.inline.components")
local Theme = require("weave.view.theme")

local uv = vim.uv or vim.loop

local M = {}

-- Height ramp groups, re-exported so callers/specs address them by height.
M.HL = Theme.WAVE_HL

-- Unicode-16 block-octant glyphs (Symbols for Legacy Computing Supplement,
-- U+1CD00…), indexed by bitmap+1. Table borrowed verbatim from neominimap
-- (~/src/neominimap.nvim), whose `map_point_to_flag` fixes the bit layout
-- documented above; the landmark glyphs are pinned in the spec.
local OCTANT = ""
  .. " 𜺨𜴀▘𜴉𜴊🯦𜴍𜺣𜴶𜴹𜴺▖𜵅𜵈▌𜺫🮂𜴁𜴂𜴋𜴌𜴎𜴏𜴷𜴸𜴻𜴼𜵆𜵇𜵉𜵊"
  .. "𜴃𜴄𜴆𜴇𜴐𜴑𜴔𜴕𜴽𜴾𜵁𜵂𜵋𜵌𜵎𜵏▝𜴅𜴈▀𜴒𜴓𜴖𜴗𜴿𜵀𜵃𜵄▞𜵍𜵐▛"
  .. "𜴘𜴙𜴜𜴝𜴧𜴨𜴫𜴬𜵑𜵒𜵕𜵖𜵡𜵢𜵥𜵦𜴚𜴛𜴞𜴟𜴩𜴪𜴭𜴮𜵓𜵔𜵗𜵘𜵣𜵤𜵧𜵨"
  .. "🯧𜴠𜴣𜴤𜴯𜴰𜴳𜴴𜵙𜵚𜵝𜵞𜵩𜵪𜵭𜵮𜴡𜴢𜴥𜴦𜴱𜴲𜴵🮅𜵛𜵜𜵟𜵠𜵫𜵬𜵯𜵰"
  .. "𜺠𜵱𜵴𜵵𜶀𜶁𜶄𜶅▂𜶬𜶯𜶰𜶻𜶼𜶿𜷀𜵲𜵳𜵶𜵷𜶂𜶃𜶆𜶇𜶭𜶮𜶱𜶲𜶽𜶾𜷁𜷂"
  .. "𜵸𜵹𜵼𜵽𜶈𜶉𜶌𜶍𜶳𜶴𜶷𜶸𜷃𜷄𜷇𜷈𜵺𜵻𜵾𜵿𜶊𜶋𜶎𜶏𜶵𜶶𜶹𜶺𜷅𜷆𜷉𜷊"
  .. "▗𜶐𜶓▚𜶜𜶝𜶠𜶡𜷋𜷌𜷏𜷐▄𜷛𜷞▙𜶑𜶒𜶔𜶕𜶞𜶟𜶢𜶣𜷍𜷎𜷑𜷒𜷜𜷝𜷟𜷠"
  .. "𜶖𜶗𜶙𜶚𜶤𜶥𜶨𜶩𜷓𜷔𜷗𜷘𜷡𜷢▆𜷤▐𜶘𜶛▜𜶦𜶧𜶪𜶫𜷕𜷖𜷙𜷚▟𜷣𜷥█"

-- Braille dot cells (U+2800…), same bit layout, universal fallback.
local BRAILLE = ""
  .. "⠀⠁⠂⠃⠄⠅⠆⠇⡀⡁⡂⡃⡄⡅⡆⡇⠈⠉⠊⠋⠌⠍⠎⠏⡈⡉⡊⡋⡌⡍⡎⡏"
  .. "⠐⠑⠒⠓⠔⠕⠖⠗⡐⡑⡒⡓⡔⡕⡖⡗⠘⠙⠚⠛⠜⠝⠞⠟⡘⡙⡚⡛⡜⡝⡞⡟"
  .. "⠠⠡⠢⠣⠤⠥⠦⠧⡠⡡⡢⡣⡤⡥⡦⡧⠨⠩⠪⠫⠬⠭⠮⠯⡨⡩⡪⡫⡬⡭⡮⡯"
  .. "⠰⠱⠲⠳⠴⠵⠶⠷⡰⡱⡲⡳⡴⡵⡶⡷⠸⠹⠺⠻⠼⠽⠾⠿⡸⡹⡺⡻⡼⡽⡾⡿"
  .. "⢀⢁⢂⢃⢄⢅⢆⢇⣀⣁⣂⣃⣄⣅⣆⣇⢈⢉⢊⢋⢌⢍⢎⢏⣈⣉⣊⣋⣌⣍⣎⣏"
  .. "⢐⢑⢒⢓⢔⢕⢖⢗⣐⣑⣒⣓⣔⣕⣖⣗⢘⢙⢚⢛⢜⢝⢞⢟⣘⣙⣚⣛⣜⣝⣞⣟"
  .. "⢠⢡⢢⢣⢤⢥⢦⢧⣠⣡⣢⣣⣤⣥⣦⣧⢨⢩⢪⢫⢬⢭⢮⢯⣨⣩⣪⣫⣬⣭⣮⣯"
  .. "⢰⢱⢲⢳⢴⢵⢶⢷⣰⣱⣲⣳⣴⣵⣶⣷⢸⢹⢺⢻⢼⢽⢾⢿⣸⣹⣺⣻⣼⣽⣾⣿"

local SETS = {
  octant = vim.fn.str2list(OCTANT),
  braille = vim.fn.str2list(BRAILLE),
}

-- Thin wave: a SINGLE lit cell per column at the wave's height (a crest line,
-- never filled below). Row q (0=bottom … 3=top) → the one bit for that row.
-- Left = 8,4,2,1 (row3→row0), right = 128,64,32,16.
local LEFT = { [0] = 8, [1] = 4, [2] = 2, [3] = 1 }
local RIGHT = { [0] = 128, [1] = 64, [2] = 32, [3] = 16 }

local ROWS = 4 -- vertical octant resolution (rows 0..3)
local SPREAD = 6 -- crest half-width in sub-columns (the hump's reach)
local PHASE_STEP = 0.3 -- radians advanced per animation frame

--- @param bitmap integer 0-255
--- @param set? "octant"|"braille" default "octant"
--- @return string
function M.glyph(bitmap, set)
  local codes = SETS[set or "octant"]
  return vim.fn.list2str({ codes[bitmap + 1] })
end

-- The single crest's height (row 0..ROWS-1) at sub-column `x`, given the
-- crest centre: a raised-cosine bump peaking at the centre and tapering to the
-- baseline (row 0) SPREAD sub-columns away.
local function bump_row(x, centre)
  local d = math.abs(x - centre)
  if d >= SPREAD then
    return 0
  end
  local h01 = 0.5 * (1 + math.cos(math.pi * d / SPREAD))
  return math.floor(h01 * (ROWS - 1) + 0.5)
end

--- The wave frame at `phase` as a fibrous span list — a SINGLE crest (raised-
--- cosine hump) whose centre bounces between the two ends as the phase
--- advances (cosine-eased, so it slows at the walls). Every column carries a
--- lit dot (baseline row 0 away from the crest), coloured by its row via the
--- height ramp (row 0 = bottom group … ROWS-1 = top).
--- @param phase number radians (0 = crest at the left end, π = the right)
--- @param opts? { width?: integer, set?: "octant"|"braille" }
--- @return table spans  fibrous label text ({char, hl=group} per cell)
function M.frame(phase, opts)
  opts = opts or {}
  local width = opts.width or 12
  local set = opts.set or "octant"
  local subcols = 2 * width
  -- centre eases 0 → (subcols-1) → 0 over one 2π period (a smooth bounce).
  local centre = 0.5 * (1 - math.cos(phase)) * (subcols - 1)
  local spans = {}
  for i = 0, width - 1 do
    local ql = bump_row(2 * i, centre)
    local qr = bump_row(2 * i + 1, centre)
    local char = M.glyph(LEFT[ql] + RIGHT[qr], set)
    local height = math.max(ql, qr)
    spans[#spans + 1] = { char, hl = M.HL[height + 1] }
  end
  return spans
end

--- The animated wave. `active` drives a uv timer that advances the phase;
--- inactive renders nothing (an empty label — its slot in the layout stays so
--- the row doesn't jump when thinking starts/stops).
--- @param ctx table fibrous hook context
--- @param props { active: boolean, width?: integer, set?: "octant"|"braille", fps?: integer }
function M.Wave(ctx, props)
  local frame = ctx.use_state(0)
  local active = props.active
  local fps = props.fps or 12

  ctx.use_effect(function()
    if not active then
      return
    end
    local timer = uv.new_timer()
    timer:start(
      0,
      math.floor(1000 / fps),
      vim.schedule_wrap(function()
        frame.set(frame.get() + 1)
      end)
    )
    return function()
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end
  end, { active, fps })

  if not active then
    return { comp = ui.label, props = { text = "" } }
  end
  return {
    comp = ui.label,
    props = { text = M.frame(frame.get() * PHASE_STEP, { width = props.width, set = props.set }) },
  }
end

return M
