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
local Theme = require("weave.view.theme")
local use_store = require("weave.view.use_store")

local M = {}

local function header(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "Title" } } }
end

local function dim(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "@comment" } } }
end

--- Session metadata (provider/agent/model/mode), or a connecting placeholder
--- before the first set_meta.
--- @param ctx table
--- @param props { store: weave.store.SessionStore }
function M.SessionSection(ctx, props)
  local state = use_store(ctx, props.store)
  local rows = { header("Session") }
  local labels = { { "provider", "Provider" }, { "agent", "Agent" }, { "model", "Model" }, { "mode", "Mode" } }
  for _, pair in ipairs(labels) do
    local value = state.meta[pair[1]]
    if value then
      rows[#rows + 1] = { comp = ui.label, props = { text = pair[2] .. ": " .. value } }
    end
  end
  if #rows == 1 then
    rows[2] = dim("(connecting…)")
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
    children = { header("Hint"), { comp = ui.paragraph, props = { text = state.hint, style = { text_hl = "@comment" } } } },
  }
end

--- The plan: one row per task — a status glyph in its status colour, then the
--- task text, which dims + strikes through once the task is done or failed
--- (the icon is never struck: colour marks the outcome, the strike the text).
--- Wrapped task text hangs under itself, not under the icon.
--- @param ctx table
--- @param props { store: weave.store.SessionStore }
function M.TasksSection(ctx, props)
  local state = use_store(ctx, props.store)
  local rows = { header("Tasks") }
  if #state.plan == 0 then
    rows[2] = dim("(no tasks)")
  else
    for _, e in ipairs(state.plan) do
      local status = e.status or "pending"
      local icon = Theme.TASK_ICON[status] or Theme.TASK_ICON.pending
      local icon_hl = Theme.TASK_ICON_HL[status]
      local text_hl = (status == "completed" or status == "failed") and Theme.TASK_DONE_HL or nil
      rows[#rows + 1] = {
        comp = ui.row,
        props = { gap = 1 },
        children = {
          { comp = ui.label, props = { text = icon, style = icon_hl and { text_hl = icon_hl } or nil } },
          { comp = ui.paragraph, props = { text = e.content or "", style = text_hl and { text_hl = text_hl } or nil } },
        },
      }
    end
  end
  return { comp = ui.col, props = {}, children = rows }
end

--- The active permission MODE (cycled with ;;p); plus the head request's
--- title + numbered options when one is pending (answered with ;;1..;;9 —
--- the numbers here are that keymap's legend).
--- @param ctx table
--- @param props { store: weave.store.SessionStore }
function M.PermissionsSection(ctx, props)
  local state = use_store(ctx, props.store)
  local mode_label = SessionStore.PERMISSION_MODE_LABEL[state.permission_mode] or state.permission_mode
  local rows = {
    header("Permissions"),
    { comp = ui.label, props = { text = "Mode: " .. mode_label .. "  (;;p)" } },
  }
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
--- @param props { store: weave.store.SessionStore, prefs: weave.view.Prefs }
function M.Sidebar(_, props)
  return {
    comp = ui.col,
    props = { gap = 1, style = { padding = { x = 1 } } },
    children = {
      { comp = M.SessionSection, props = { store = props.store } },
      { comp = M.PrefsSection, props = { prefs = props.prefs } },
      { comp = M.HintSection, props = { store = props.store } },
      { comp = M.TasksSection, props = { store = props.store } },
      { comp = M.PermissionsSection, props = { store = props.store } },
    },
  }
end

return M
