-- The sidebar: the panel's metadata column, a pure projection of
-- SessionStore + Prefs. Ported from agentic's
-- reactive/view/components/sidebar.lua + render.lua (session_lines,
-- hint_lines, plan_lines, permission_lines), rebuilt as fibrous components.
--
-- Each section is a SELF-CONTAINED component: it owns its header, its rows
-- and its use_store subscription, so it renders (and updates) standalone —
-- Sidebar is pure composition. Section headers are Title labels (fibrous has
-- no border labels); the pref checkboxes are ui.checkbox.

local ui = require("fibrous.inline.components")
local SessionStore = require("weave.session_store")
local TerminalTasks = require("weave.view.terminal_tasks")
local Theme = require("weave.view.theme")
local octant = require("weave.view.octant")
local use_permissions = require("weave.view.use_permissions")
local use_store = require("weave.view.use_store")

local M = {}

local function header(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "Title" } } }
end

local function dim(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "@comment" } } }
end

--- Group an integer with thousands separators: 200000 → "200,000".
--- @param n number
--- @return string
local function commas(n)
  local s = tostring(math.floor(n + 0.5))
  local k
  repeat
    s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
  until k == 0
  return s
end

--- Format a session cost, USD as "$x.xx" (up to 4 decimals, trailing zeros
--- trimmed to ≥2), other currencies as "x.xxxx CUR".
--- @param cost { amount: number, currency?: string }
--- @return string
local function fmt_cost(cost)
  local amount = (string.format("%.4f", cost.amount):gsub("(%.%d%d)0+$", "%1"))
  if (cost.currency or "USD") == "USD" then
    return "Cost: $" .. amount
  end
  return "Cost: " .. amount .. " " .. cost.currency
end

--- Session metadata (provider/agent/model/mode), or a connecting placeholder
--- before the first set_meta. With `on_details` the whole meta block is ONE
--- bare-button interactable (requests.md: activating the section opens the
--- session details modal) — hover marks it, <CR> anywhere on it activates.
--- @param ctx table
--- @param props { store: weave.store.SessionStore, on_details?: fun() }
function M.SessionSection(ctx, props)
  local state = use_store(ctx, props.store)
  local lines = {}
  local labels = { { "provider", "Provider" }, { "agent", "Agent" }, { "model", "Model" }, { "mode", "Mode" } }
  for _, pair in ipairs(labels) do
    local value = state.meta[pair[1]]
    if value then
      lines[#lines + 1] = pair[2] .. ": " .. value
    end
  end
  local body
  if #lines == 0 then
    body = dim("(connecting…)")
  else
    body = { comp = ui.label, props = { text = table.concat(lines, "\n") } }
  end
  if props.on_details then
    body.comp = ui.button
    body.props.label = body.props.text
    body.props.text = nil
    body.props.theme = false -- no chip chrome: the block reads as plain rows
    body.props.style = vim.tbl_extend("force", body.props.style or {}, { _hover = { hl = "FibrousHover" } })
    body.props.on_press = props.on_details
  end
  return { comp = ui.col, props = {}, children = { header("Session"), body } }
end

-- A cell is an octant sub-canvas (2 cols x 4 rows = 8 sub-cells), so the
-- boundary cell of the bar carries EIGHT sub-levels: fill the left column
-- bottom-up to a half-lit ▌ (levels 1-4), then the right column bottom-up to a
-- full █ (levels 5-8). Column-major so the fill reads left-to-right, one octant
-- resolving what a whole cell would — an 8× finer bar than a cell-granular one.
local FULL = "█"

--- The boundary glyph for `level` sub-cells lit (1..7), column-major: the left
--- column fills first (levels 1-4 → up to ▌), then the right (levels 5-7).
--- @param level integer 1..7
--- @return integer bitmap
local function boundary_bits(level)
  if level <= 4 then
    return octant.col_fill(level) -- left column, bottom `level` rows
  end
  return octant.col_fill(4) + octant.col_fill(level - 4) * 16 -- left full + right rows
end

--- A horizontal context-usage bar `width` cells wide. Full cells render █; when
--- the fill lands mid-cell the boundary column is an octant filled to the
--- nearest eighth (left column bottom-up, then right), so a W-cell bar resolves
--- 8W steps. The rest is spaces — the row's background tint (UsageSection's
--- style.hl) shows through as the track, so there is no "empty" glyph. Returned
--- as a fibrous span list for a `fill = ` label that re-sizes to the section
--- width (no width threading, like the water widget).
--- @param fraction number 0..1 (used / window)
--- @param width integer cells
--- @param fill_hl string highlight for the lit portion
--- @return table spans
function M.context_bar(fraction, width, fill_hl)
  width = math.max(width, 1)
  fraction = math.min(math.max(fraction, 0), 1)
  local sub = math.floor(fraction * width * 8 + 0.5) -- eighth-cell steps (8 per cell)
  if fraction > 0 and sub == 0 then
    sub = 1 -- a live context never reads as an empty bar
  end
  sub = math.min(sub, width * 8)
  local full = math.floor(sub / 8)
  local rem = sub % 8
  local spans = {}
  if full > 0 then
    spans[#spans + 1] = { FULL:rep(full), hl = fill_hl }
  end
  if rem > 0 then
    spans[#spans + 1] = { octant.glyph(boundary_bits(rem)), hl = fill_hl }
  end
  local lit = full + (rem > 0 and 1 or 0)
  if lit < width then
    -- the unfilled track: bare spaces carrying the same bg tint the fill groups
    -- do, so lit and unlit cells share one background
    spans[#spans + 1] = { (" "):rep(width - lit), hl = Theme.USAGE_TRACK_HL }
  end
  return spans
end

--- Fill colour by fullness: green while there is headroom, amber past two
--- thirds, red near the cap — so context pressure reads without doing the math.
--- @param pct integer 0..100
--- @return string
local function bar_hl(pct)
  if pct >= 90 then
    return Theme.USAGE_BAR_HL.high
  elseif pct >= 66 then
    return Theme.USAGE_BAR_HL.mid
  end
  return Theme.USAGE_BAR_HL.low
end

--- Session usage: a context-fill bar over the exact figure (used / window with a
--- percent), and the running cost when the agent charges for the turn (ACP
--- usage_update). A free or subscription model reports cost 0, so the cost line
--- is omitted then; a raw token count with no window size stays a plain line.
--- @param ctx table
--- @param props { store: weave.store.SessionStore }
function M.UsageSection(ctx, props)
  local state = use_store(ctx, props.store)
  local usage = state.usage
  local rows = { header("Usage") }
  if usage then
    if usage.used and usage.size and usage.size > 0 then
      local fraction = usage.used / usage.size
      local pct = math.floor(fraction * 100 + 0.5)
      local fill_hl = bar_hl(pct)
      -- the fill bar, stretched to the section width by `fill` (re-sized on
      -- resize with no re-render, like the water indicator). Every cell — lit,
      -- partially lit, or track — carries the same background tint from its span,
      -- so a partial octant's unlit sub-cells read as the track, not a hole...
      rows[#rows + 1] = {
        comp = ui.label,
        props = {
          fill = function(w)
            return M.context_bar(fraction, w, fill_hl)
          end,
        },
      }
      -- ...with the exact figure centred beneath it
      rows[#rows + 1] = {
        comp = ui.label,
        props = {
          text = string.format("%s / %s (%d%%)", commas(usage.used), commas(usage.size), pct),
          align_self = "center",
        },
      }
    elseif usage.used then
      rows[#rows + 1] = { comp = ui.label, props = { text = "Tokens: " .. commas(usage.used) } }
    end
    local cost = usage.cost
    if type(cost) == "table" and type(cost.amount) == "number" and cost.amount > 0 then
      rows[#rows + 1] = { comp = ui.label, props = { text = fmt_cost(cost) } }
    end
  end
  if #rows == 1 then
    rows[2] = dim("(no usage yet)")
  end
  return { comp = ui.col, props = {}, children = rows }
end

--- The view-pref checkboxes, wired straight to Prefs:toggle.
--- @param ctx table
--- @param props { prefs: weave.view.Prefs }
function M.PrefsSection(ctx, props)
  local prefs = use_store(ctx, props.prefs)
  local function pref_checkbox(key, label)
    return {
      comp = ui.checkbox,
      props = {
        label = label,
        checked = prefs[key],
        on_toggle = function()
          props.prefs:toggle(key)
        end,
      },
    }
  end
  return {
    comp = ui.col,
    props = {},
    children = {
      pref_checkbox("show_thoughts", "Show thinking"),
      pref_checkbox("show_diffs", "Show edit diffs"),
      pref_checkbox("conceal_markdown", "Prettify markdown"),
      pref_checkbox("follow", "Follow streaming"),
    },
  }
end

--- The rotating hint line.
--- @param ctx table
--- @param props { store: weave.store.SessionStore }
function M.HintSection(ctx, props)
  local state = use_store(ctx, props.store)
  return {
    comp = ui.col,
    props = {},
    children = {
      header("Hint"),
      { comp = ui.paragraph, props = { text = state.hint, style = { text_hl = "@comment" } } },
    },
  }
end

-- The sidebar task list caps (requests.md): at most this many items inline,
-- each clamped to this many wrapped lines; the rest lives behind the
-- "…see full list" button.
local MAX_TASKS = 8
local MAX_TASK_LINES = 3

--- Which tasks stay on the sidebar when the plan exceeds `max` (requests.md):
--- hide the oldest COMPLETED items first — they're the least interesting —
--- then the oldest of any other state, until `max` remain. Plan order is
--- preserved. Pure, so the hide policy is spec'd directly.
--- @param plan { content: string, status?: string }[]
--- @param max integer
--- @return table shown, integer hidden
function M.visible_tasks(plan, max)
  if #plan <= max then
    return vim.list_slice(plan, 1, #plan), 0
  end
  local hide = #plan - max
  local hidden = {}
  for i, e in ipairs(plan) do
    if hide == 0 then
      break
    end
    if (e.status or "pending") == "completed" then
      hidden[i], hide = true, hide - 1
    end
  end
  for i in ipairs(plan) do
    if hide == 0 then
      break
    end
    if not hidden[i] then
      hidden[i], hide = true, hide - 1
    end
  end
  local shown = {}
  for i, e in ipairs(plan) do
    if not hidden[i] then
      shown[#shown + 1] = e
    end
  end
  return shown, #plan - max
end

--- Greedy word-wrap of `text` into display lines of width <= w cells (the
--- same policy as fibrous's paragraph wrap: whitespace collapses, words wider
--- than the line are hard-broken).
--- @param text string
--- @param w integer
--- @return string[]
local function wrap_words(text, w)
  local lines = {}
  local line, lw = "", 0
  for word in text:gmatch("%S+") do
    local ww = vim.api.nvim_strwidth(word)
    if ww > w then
      if line ~= "" then
        lines[#lines + 1] = line
      end
      -- hard-break: peel w-cell chunks off the front
      while vim.api.nvim_strwidth(word) > w do
        local chunk, cells = "", 0
        for ch in word:gmatch("[%z\1-\127\194-\253][\128-\191]*") do
          local cw = vim.api.nvim_strwidth(ch)
          if cells + cw > w then
            break
          end
          chunk, cells = chunk .. ch, cells + cw
        end
        lines[#lines + 1] = chunk
        word = word:sub(#chunk + 1)
      end
      line, lw = word, vim.api.nvim_strwidth(word)
    elseif line == "" then
      line, lw = word, ww
    elseif lw + 1 + ww <= w then
      line, lw = line .. " " .. word, lw + 1 + ww
    else
      lines[#lines + 1] = line
      line, lw = word, ww
    end
  end
  if line ~= "" or #lines == 0 then
    lines[#lines + 1] = line
  end
  return lines
end

--- Wrap `text` to `w` cells and keep at most `max_lines` lines; a clamped
--- tail carries a trailing ellipsis (requests.md: "truncate each item at 3
--- lines"). Pure, spec'd directly.
--- @param text string
--- @param w integer
--- @param max_lines integer
--- @return string[] lines, boolean truncated
function M.clamp_lines(text, w, max_lines)
  w = math.max(w, 4)
  local lines = wrap_words(text, w)
  if #lines <= max_lines then
    return lines, false
  end
  local out = vim.list_slice(lines, 1, max_lines)
  local tail = out[max_lines]
  while tail ~= "" and vim.api.nvim_strwidth(tail) + 1 > w do
    tail = vim.fn.strcharpart(tail, 0, vim.fn.strchars(tail) - 1)
  end
  out[max_lines] = tail .. "…"
  return out, true
end

--- One task row: a status glyph in its status colour, then the task text,
--- which dims + strikes through once the task is done or failed (the icon is
--- never struck: colour marks the outcome, the strike the text). `text` may
--- be pre-clamped lines (sidebar) or the raw content (full list).
local function task_row(e, text, wrap)
  local status = e.status or "pending"
  local icon = Theme.TASK_ICON[status] or Theme.TASK_ICON.pending
  local icon_hl = Theme.TASK_ICON_HL[status]
  local text_hl = (status == "completed" or status == "failed") and Theme.TASK_DONE_HL or nil
  return {
    comp = ui.row,
    props = { gap = 1 },
    children = {
      { comp = ui.label, props = { text = icon, style = icon_hl and { text_hl = icon_hl } or nil } },
      {
        comp = wrap and ui.paragraph or ui.label,
        props = { text = text, style = text_hl and { text_hl = text_hl } or nil },
      },
    },
  }
end

--- The FULL plan in its own floating mount (the "…see full list" button):
--- every item, untruncated, live off the store; q/<Esc> closes.
--- @param store weave.store.SessionStore
function M.open_tasks_list(store)
  local mount = require("fibrous.inline.mount")
  local function FullList(ctx)
    local state = use_store(ctx, store)
    local rows = { header(("Tasks (%d)"):format(#state.plan)) }
    if #state.plan == 0 then
      rows[2] = dim("(no tasks)")
    end
    for _, e in ipairs(state.plan) do
      rows[#rows + 1] = task_row(e, e.content or "", true)
    end
    return { comp = ui.col, props = {}, children = rows }
  end
  local app = mount.floating(FullList, {}, {
    width = 60,
    height = math.min(math.max(#store.state.plan + 2, 4), math.max(vim.o.lines - 6, 8)),
    mode = "scroll",
    border = "rounded",
    backdrop = true,
  })
  require("weave.keys").map(app.bufnr, "close_float", function()
    app.unmount()
  end, { nowait = true, desc = "weave: close task list" })
  app.focus()
  return app
end

--- The plan (requests.md shape): at most MAX_TASKS rows, each clamped to
--- MAX_TASK_LINES wrapped lines (ellipsis when cut); overflow hides oldest
--- completed items first, then oldest of any state; anything hidden or
--- truncated adds a "…see full list" button opening the whole plan in a
--- floating mount. Clamped lines hang under the text, not under the icon.
--- @param ctx table
--- @param props { store: weave.store.SessionStore, width?: integer }
function M.TasksSection(ctx, props)
  local state = use_store(ctx, props.store)
  local rows = { header("Tasks") }
  if #state.plan == 0 then
    rows[2] = dim("(no tasks)")
  else
    local shown, hidden = M.visible_tasks(state.plan, MAX_TASKS)
    -- text width inside the sidebar: its col chrome (left border + x-padding
    -- = 3) plus the icon column and gap (2)
    local text_w = math.max((props.width or 30) - 5, 4)
    local truncated = false
    for _, e in ipairs(shown) do
      local lines, clamped = M.clamp_lines(e.content or "", text_w, MAX_TASK_LINES)
      truncated = truncated or clamped
      rows[#rows + 1] = task_row(e, table.concat(lines, "\n"), false)
    end
    if hidden > 0 or truncated then
      rows[#rows + 1] = {
        comp = ui.button,
        props = {
          label = "…see full list",
          style = { text_hl = "@comment" },
          on_press = function()
            M.open_tasks_list(props.store)
          end,
        },
      }
    end
  end
  return { comp = ui.col, props = {}, children = rows }
end

--- The active permission PRESET (engine-global, cycled with ;;p); plus the
--- head request's title + numbered options when one is pending (answered
--- with ;;1..;;9 — the numbers here are that keymap's legend). The header
--- opens the preset configuration window.
--- @param ctx table
--- @param props { store: weave.store.SessionStore }
function M.PermissionsSection(ctx, props)
  local state = use_store(ctx, props.store)
  local active = use_permissions(ctx)
  local rows = {
    {
      comp = ui.button,
      props = {
        label = "Permissions",
        theme = false,
        style = { text_hl = "Title", _hover = { hl = "FibrousHover" } },
        on_press = function()
          require("weave.view.permissions_window").open()
        end,
      },
    },
    { comp = ui.label, props = { text = "Preset: " .. (active.label or active.name) .. "  (;;p)" } },
  }
  local Permissions = require("weave.permissions")
  local profile = Permissions.current_profile()
  if profile ~= "off" then
    rows[#rows + 1] = dim("Sandbox: " .. profile)
  end
  -- A grant the user cannot see is a grant they cannot revoke; the list and
  -- the revoke live one click away in the permissions window.
  local grants = #Permissions.grants()
  if grants > 0 then
    rows[#rows + 1] = dim(("Grants: %d this session"):format(grants))
  end
  local perm = state.permission
  if perm then
    if (state.permission_count or 1) > 1 then
      rows[#rows + 1] = dim(string.format("(1 of %d pending)", state.permission_count))
    end
    local tc = perm.request.toolCall or {}
    rows[#rows + 1] = {
      comp = ui.paragraph,
      props = { text = tc.title or ("tool call " .. tostring(tc.toolCallId or "?")) },
    }
    for i, opt in ipairs(perm.request.options or {}) do
      rows[#rows + 1] = { comp = ui.label, props = { text = string.format("[%d] %s", i, opt.name or opt.optionId) } }
    end
  end
  return { comp = ui.col, props = {}, children = rows }
end

--- Pure composition — every section subscribes to its own store slice.
--- @param props { sidebar_width: integer, store: weave.store.SessionStore, prefs: weave.view.Prefs, on_details?: fun() }
function M.Sidebar(_, props)
  return {
    comp = ui.col,
    props = {
      gap = 1,
      width = props.sidebar_width,
      style = {
        padding = { x = 1 },
        border = {
          left = true,
        },
      },
    },
    children = {
      { comp = M.SessionSection, props = { store = props.store, on_details = props.on_details } },
      { comp = M.UsageSection, props = { store = props.store } },
      { comp = M.PrefsSection, props = { prefs = props.prefs } },
      { comp = M.HintSection, props = { store = props.store } },
      { comp = M.TasksSection, props = { store = props.store, width = props.sidebar_width } },
      -- terminal tasks sit ABOVE permissions (design-agent-sandbox.md, 0c)
      { comp = TerminalTasks.Section, props = { width = props.sidebar_width } },
      { comp = M.PermissionsSection, props = { store = props.store } },
    },
  }
end

return M
