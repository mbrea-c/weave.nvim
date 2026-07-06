-- The "busy" water indicator (shell/UX niceties), replacing the old bouncing
-- wave. A 1-D Hooke's-law height field — a row of columns, each with a height
-- and velocity, coupled to its neighbours by springs and pulled gently back to
-- rest — rendered on ONE row of Unicode-16 block octants (2 sub-columns × 4
-- sub-rows per cell), each column FILLED from the bottom up to its surface so
-- ripples read as water. While busy the centre is agitated; a click / <CR>
-- anywhere on the line drops a ripple where you pressed (the interact layer
-- hands on_press the local column). The status label is spliced into the
-- centre, and the whole thing fades colour by state (blue idle → yellow
-- thinking → red generating), the label included.
--
-- Pure halves + a thin component, WEAVE-LOCAL (props in, vnodes out) like the
-- markdown/diff components:
--   glyph/fill            octant bitmap helpers (bit layout borrowed from the
--                         neominimap tables, same as the old wave).
--   new/disturb/step/     the sim: O(sub-columns) per tick, propagates, reflects
--     energy/levels         off the ends, decays, settles to rest.
--   frame(levels, opts)   levels → a fibrous span list, label spliced centre.
--   lerp_rgb/shades       colour easing + the per-height shade ramp.
--   palette(rgb)          the colour groups for `rgb`, created ONCE and cached —
--                         the fade animates by REFERENCING different palette
--                         groups from the rendered spans (a targeted line
--                         repaint), never by redefining a fixed group with
--                         nvim_set_hl (which invalidates the whole screen).
--   Water(ctx, props)     drives the sim off a self-stopping uv timer (zero CPU
--                         once idle AND settled AND the colour has arrived).

local ui = require("fibrous.inline.components")
local Theme = require("weave.view.theme")

local uv = vim.uv or vim.loop

local M = {}

-- Default height-ramp + label groups: frame() uses them when no palette is
-- passed (standalone / specs). The live component passes palette groups instead
-- (see M.palette) so the colour animates without redefining these.
M.HL = Theme.WATER_HL
M.LABEL_HL = Theme.WATER_LABEL_HL

-- Unicode-16 block-octant glyphs (U+1CD00…), indexed by bitmap+1; left column =
-- bits 0-3 (values 1,2,4,8, TOP→bottom), right column = bits 4-7 (16…128).
-- Borrowed verbatim from neominimap; landmark glyphs pinned in the spec.
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

local TOP = 3 -- highest surface row index (0 = bottom … 3 = top), 4 rows
local REST_S = 1 -- baseline surface: the SECOND row from the bottom
local GAIN = 1.2 -- displacement → surface-row scaling

-- Left-column bit for a SINGLE surface dot at row-from-bottom `s`: the bottom
-- row (s=0) is bit 8, up to the top row (s=3) at bit 1. Surface only — nothing
-- is filled below, exactly like the old wave. Right column is this << 4.
local DOT = { [0] = 8, [1] = 4, [2] = 2, [3] = 1 }

--- @param bitmap integer 0-255
--- @param set? "octant"|"braille"
--- @return string
function M.glyph(bitmap, set)
  local codes = SETS[set or "octant"]
  return vim.fn.list2str({ codes[bitmap + 1] })
end

--- Left-column bit for the surface dot at height `s` (0 = bottom … 3 = top). A
--- cell is `dot(sl) + dot(sr) * 16` (the right column is the left shifted up 4).
--- @param s integer 0..3
--- @return integer
function M.dot(s)
  return DOT[s] or (s < 0 and 8 or 1)
end

-- ── The sim ──────────────────────────────────────────────────────────────────

local K = 0.008 -- restoring spring toward rest (gentle: ripples travel first)
local C = 0.22 -- neighbour coupling (wave speed; < 0.5 keeps explicit Euler stable)
local DRAG = 0.985 -- velocity damping (energy bleed → settles)

--- A fresh height field of `2*width` sub-columns, all at rest.
--- @param width integer cells
--- @return { h: number[], v: number[], width: integer }
function M.new(width)
  local h, v = {}, {}
  for i = 1, 2 * width do
    h[i], v[i] = 0, 0
  end
  return { h = h, v = v, width = width }
end

--- Drop a raindrop-style dent at sub-column `subcol` (a small gaussian dip that
--- springs back up), which then propagates outward.
--- @param st table sim state
--- @param subcol integer 1-based sub-column
--- @param amount? number dip depth (default 1.5)
function M.disturb(st, subcol, amount)
  amount = amount or 1.5
  local h, n = st.h, #st.h
  local sigma = 1.5
  for d = -3, 3 do
    local i = subcol + d
    if i >= 1 and i <= n then
      h[i] = h[i] - amount * math.exp(-(d * d) / (2 * sigma * sigma))
    end
  end
  return st
end

--- Advance the field one tick (symplectic Euler): each column feels a spring
--- toward rest plus coupling to its neighbours, velocity is damped, then heights
--- integrate. Reflective (Neumann) ends: the edge's missing neighbour mirrors
--- it, so waves bounce back instead of leaking.
--- @param st table sim state
function M.step(st)
  local h, v, n = st.h, st.v, #st.h
  for i = 1, n do
    local left = h[i - 1] or h[1]
    local right = h[i + 1] or h[n]
    local a = C * (left + right - 2 * h[i]) - K * h[i]
    v[i] = (v[i] + a) * DRAG
  end
  for i = 1, n do
    h[i] = h[i] + v[i]
  end
  return st
end

--- Total energy (kinetic + spring potential); ~0 when settled.
--- @param st table sim state
--- @return number
function M.energy(st)
  local e = 0
  for i = 1, #st.h do
    e = e + st.v[i] * st.v[i] + K * st.h[i] * st.h[i]
  end
  return e
end

--- Quantise each sub-column's displacement to a surface row 0..TOP, baseline at
--- REST_S (the 2nd row from the bottom).
--- @param st table sim state
--- @return integer[]
function M.levels(st)
  local out = {}
  for i = 1, #st.h do
    local s = math.floor(REST_S + st.h[i] * GAIN + 0.5)
    out[i] = math.max(0, math.min(TOP, s))
  end
  return out
end

-- ── Render ───────────────────────────────────────────────────────────────────

--- Render a levels array (2*width sub-columns, each 0..ROWS) as a fibrous span
--- list of `width` cells: each cell filled to its two sub-columns' levels and
--- coloured by the taller one. `opts.label` is spliced, centred, over the water.
--- `opts.hl` (4 height-shade group names) + `opts.label_hl` override the default
--- groups — the component passes a palette here so the colour rides the span refs.
--- @param levels integer[]
--- @param opts? { width?: integer, set?: string, label?: string, hl?: string[], label_hl?: string }
--- @return table spans
function M.frame(levels, opts)
  opts = opts or {}
  local width = opts.width or 12
  local set = opts.set or "octant"
  local hl = opts.hl or M.HL
  local label_hl = opts.label_hl or M.LABEL_HL
  local spans = {}
  for i = 0, width - 1 do
    local sl = levels[2 * i + 1] or REST_S
    local sr = levels[2 * i + 2] or REST_S
    -- colour by the taller surface: row 0..3 → height group 1..4.
    local level = math.max(sl, sr) + 1
    spans[#spans + 1] = { M.glyph(M.dot(sl) + M.dot(sr) * 16, set), hl = hl[level] }
  end

  if opts.label and opts.label ~= "" then
    local chars = vim.fn.str2list(opts.label)
    while #chars > width do -- never overflow the row
      chars[#chars] = nil
    end
    local start = math.floor((width - #chars) / 2) -- 0-based cell
    for j = 1, #chars do
      local cell = start + j
      if cell >= 1 and cell <= width then
        spans[cell] = { vim.fn.list2str({ chars[j] }), hl = label_hl }
      end
    end
  end
  return spans
end

-- ── Colour ───────────────────────────────────────────────────────────────────

local function clamp255(x)
  return math.max(0, math.min(255, math.floor(x + 0.5)))
end

--- Linear interpolate between two {r,g,b} (0-255) colours.
--- @param a integer[]
--- @param b integer[]
--- @param t number 0..1
--- @return integer[]
function M.lerp_rgb(a, b, t)
  return {
    clamp255(a[1] + (b[1] - a[1]) * t),
    clamp255(a[2] + (b[2] - a[2]) * t),
    clamp255(a[3] + (b[3] - a[3]) * t),
  }
end

--- The 4-height shade ramp of a base colour: dim (0.5×) at height 1 → the base
--- itself at height 4.
--- @param rgb integer[]
--- @return integer[][]
function M.shades(rgb)
  local out = {}
  for i = 1, 4 do
    local f = 0.5 + 0.5 * (i - 1) / 3
    out[i] = { clamp255(rgb[1] * f), clamp255(rgb[2] * f), clamp255(rgb[3] * f) }
  end
  return out
end

local function hexstr(c)
  return string.format("#%02x%02x%02x", c[1], c[2], c[3])
end

-- RGB quantisation for the palette key. Redefining a highlight group costs a
-- whole-screen redraw, so the fade must NOT do it per frame. Instead each colour
-- gets its own groups, created ONCE and cached; the fade animates by pointing the
-- rendered spans at a different colour's groups (a targeted one-line repaint).
-- Quantising bounds the cache and makes colours recur across fades — after a few
-- transitions every step is a cache hit, so no set_hl happens at all. 8 is fine
-- for a one-row indicator (≈32 levels/channel; the ease already steps discretely).
local PALETTE_STEP = 8

local palette_cache = {}

local function quantize(c)
  local q = math.floor(c / PALETTE_STEP + 0.5) * PALETTE_STEP
  return math.max(0, math.min(255, q))
end

--- The highlight groups for colour `rgb`: a 4-entry height-shade ramp plus the
--- label group, created once (the only set_hl this module does) and cached by the
--- quantised colour. Referencing these from frame() is how the colour animates —
--- no fixed group is ever redefined, so no frame triggers a whole-screen redraw.
--- @param rgb integer[]
--- @return { shades: string[], label: string }
function M.palette(rgb)
  local key = ("%02x%02x%02x"):format(quantize(rgb[1]), quantize(rgb[2]), quantize(rgb[3]))
  local entry = palette_cache[key]
  if entry then
    return entry
  end
  local base = { tonumber(key:sub(1, 2), 16), tonumber(key:sub(3, 4), 16), tonumber(key:sub(5, 6), 16) }
  local sh = M.shades(base)
  local shades = {}
  for i = 1, 4 do
    local g = "WeaveWaterP_" .. key .. "_" .. i
    vim.api.nvim_set_hl(0, g, { fg = hexstr(sh[i]) })
    shades[i] = g
  end
  local label = "WeaveWaterPL_" .. key
  vim.api.nvim_set_hl(0, label, { fg = "#" .. key, bold = true })
  entry = { shades = shades, label = label }
  palette_cache[key] = entry
  return entry
end

-- ── Component ────────────────────────────────────────────────────────────────

local STATE_FG = Theme.WATER_STATE_FG
local EPS = 1e-3 -- energy below which the water counts as settled
local COLOR_EASE = 0.08 -- per-frame-equivalent lerp toward the target colour
local COLOR_FPS = 8 -- the fade's own update rate (see color_every)
local INJECT_EVERY = 4 -- frames between centre agitations while busy
local IMPULSE = 1.6

--- Frames between colour updates so the fade runs at ~COLOR_FPS whatever the
--- sim's fps is. Even with the palette (a colour step is a targeted one-row
--- repaint, not a set_hl), re-colouring the whole row every frame is wasted wire
--- traffic: the ripples need 30fps, the fade doesn't, and easing it in a handful
--- of steps looks identical while cutting how often the row re-colours by
--- fps/COLOR_FPS. Never 0 (it's a modulo divisor).
--- @param fps integer
--- @return integer
function M.color_every(fps)
  return math.max(1, math.floor((fps or 30) / COLOR_FPS + 0.5))
end

local function color_of(status)
  return STATE_FG[status] or STATE_FG.busy
end

local function near_color(a, b)
  return math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3]) < 3
end

--- The water indicator. `status` (idle|thinking|generating|busy) drives the
--- agitation + target colour; `label` is spliced centre. Always rendered (a
--- clickable button — ripple even when idle); the timer stops when idle AND
--- settled AND the colour has arrived, so at rest it costs nothing. Renders via
--- fibrous `fill`, so it spans its full column width and re-sizes on resize
--- (the sim grows/shrinks to match) with no re-render.
--- @param ctx table fibrous hook context
--- @param props { status: string, label?: string, set?: string, fps?: integer }
function M.Water(ctx, props)
  local st = ctx.use_ref()
  local tick = ctx.use_state(0)
  local status = props.status or "idle"
  local fps = props.fps or 30

  if not st.sim then
    st.sim = M.new(24) -- an initial guess; `fill` re-sizes to the real width
    st.color = vim.deepcopy(color_of("idle"))
    st.frame = 0
  end
  st.status = status
  st.target = color_of(status)
  st.label = props.label

  local function stop_timer()
    if st.timer then
      st.timer:stop()
      if not st.timer:is_closing() then
        st.timer:close()
      end
      st.timer = nil
    end
  end
  local function ensure_running()
    if st.timer then
      return
    end
    st.timer = uv.new_timer()
    st.timer:start(
      0,
      math.floor(1000 / fps),
      vim.schedule_wrap(function()
        if not st.timer then
          return
        end
        st.frame = st.frame + 1
        local busy = st.status ~= "idle"
        if busy and st.frame % INJECT_EVERY == 0 then
          local c = math.floor(#st.sim.h / 2) + math.random(-2, 2)
          M.disturb(st.sim, c, IMPULSE * (0.6 + math.random() * 0.6))
        end
        M.step(st.sim)
        -- Ease the colour at ~COLOR_FPS, not every sim frame. Nothing is set_hl'd
        -- here: st.color feeds M.palette in the render below, so a colour change is
        -- a targeted one-line repaint (new palette groups referenced), not a
        -- whole-screen redraw. Pacing still helps — it's how often that one line
        -- re-colours. The per-update step is compounded to keep the fade duration.
        local color_every = M.color_every(fps)
        if st.frame % color_every == 0 then
          local step = 1 - (1 - COLOR_EASE) ^ color_every
          st.color = M.lerp_rgb(st.color, st.target, step)
        end
        if not busy and M.energy(st.sim) < EPS and near_color(st.color, st.target) then
          st.color = vim.deepcopy(st.target) -- land the exact target on the final frame
          tick.set(st.frame)
          stop_timer()
        else
          tick.set(st.frame) -- render re-reads st.color → palette → colour rides the spans
        end
      end)
    )
  end
  st.ensure_running = ensure_running

  ctx.use_effect(function()
    ensure_running() -- wake on any status change; run through the idle settle
    return stop_timer -- unmount / deps-change cleanup
  end, { status, width, fps })

  return {
    comp = ui.label,
    props = {
      role = "button",
      on_press = function(x)
        -- ripple where the line was pressed (display cell → left sub-column)
        local subcol = (x or math.floor(st.sim.width / 2)) * 2 + 1
        M.disturb(st.sim, subcol, IMPULSE * 1.3)
        st.ensure_running()
      end,
      -- fill: generated from the FINAL column width — spans the full prompt and
      -- re-sizes on resize. The sim grows/shrinks to match (ripples reset on a
      -- resize, which is fine). The current colour's palette groups are referenced
      -- here, so easing st.color re-colours the row via the spans — no set_hl.
      fill = function(w)
        w = math.max(w, 1)
        if st.sim.width ~= w then
          st.sim = M.new(w)
        end
        local pal = M.palette(st.color)
        return M.frame(M.levels(st.sim), {
          width = w,
          set = props.set,
          label = st.label,
          hl = pal.shades,
          label_hl = pal.label,
        })
      end,
    },
  }
end

return M
