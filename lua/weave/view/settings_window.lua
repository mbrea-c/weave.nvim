-- The settings window: every runtime setting weave has (weave.settings),
-- grouped by scope, plus the preset buttons. Reached from the sidebar's
-- Settings header (or the open_settings chord); the sidebar itself shows
-- only the setup-configured subset — this window is the whole surface.
--
-- Controls follow the setting's TYPE, straight from the registry, and they
-- are fibrous natives: booleans are ui.checkbox, integers a singleline
-- ui.text_input, enums a ui.dropdown (strict select). The two field
-- controls are KEYED on the committed value: an external change — a preset
-- button, another surface — remounts them re-seeded, which is how an
-- uncontrolled subwindow buffer tracks the store without ever being
-- rewritten under the user's cursor (while they type, the value has not
-- changed, so the key has not either). A preset button applies its partial
-- {key = value} map to the right stores (weave.settings.apply_preset) —
-- the announcement to the agent is not this window's business: weave.briefs
-- follows the session store and speaks when the `brief` value actually
-- changes.

local ui = require("fibrous.inline.components")
local Logger = require("weave.utils.logger")
local Settings = require("weave.settings")
local use_store = require("weave.view.use_store")

local M = {}

local SCOPE_ORDER = { "session", "view", "global" }
local SCOPE_TITLES = {
  session = "Session — this conversation",
  view = "View — this panel",
  global = "Global — this editor",
}

local function header(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "Title" } } }
end

local function dim(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "@comment" } } }
end

local function blank()
  return { comp = ui.label, props = { text = "" } }
end

local function bare_button(label, on_press)
  return {
    comp = ui.button,
    props = {
      label = label,
      theme = false,
      style = { _hover = { hl = "FibrousHover" } },
      on_press = on_press,
    },
  }
end

--- One setting row, shaped by its type.
--- @param spec weave.settings.Spec
--- @param store weave.settings.Store
--- @param state table<string, any> the store's use_store snapshot
local function setting_row(spec, store, state)
  if spec.type == "boolean" then
    return {
      comp = ui.checkbox,
      props = {
        label = spec.label,
        checked = state[spec.key] == true,
        on_toggle = function()
          store:toggle(spec.key)
        end,
      },
    }
  end
  local value = tostring(state[spec.key])
  local control
  if spec.type == "integer" then
    -- Commit on normal-mode <CR> or on leaving the field; per-keystroke
    -- on_change is deliberately unused — a half-typed number is not a value.
    -- An invalid commit warns and leaves the typed text in place to fix; the
    -- store is never touched, so the key (and the seeded value) stand still.
    local function commit(v)
      v = vim.trim(v or "")
      if v == "" or v == value then
        return
      end
      local n, err = Settings.coerce(spec, v)
      if n == nil then
        Logger.notify("weave: " .. (err or "invalid value"), vim.log.levels.WARN)
        return
      end
      store:set(spec.key, n)
    end
    control = {
      comp = ui.text_input,
      key = spec.key .. "=" .. value,
      props = {
        value = value,
        singleline = true,
        width = 8,
        height = 1,
        on_submit = commit,
        on_blur = commit,
      },
    }
  else
    -- enum: strict select — typing filters, blur without a match reverts.
    -- Width is border-box: the longest option plus the field's [▾ and ]
    -- edge cells.
    local options = Settings.enum_options(spec.key)
    local width = 10
    for _, o in ipairs(options) do
      width = math.max(width, #o + 3)
    end
    control = {
      comp = ui.dropdown,
      key = spec.key .. "=" .. value,
      props = {
        options = options,
        value = value,
        width = width,
        on_select = function(v)
          store:set(spec.key, v)
        end,
      },
    }
  end
  return {
    comp = ui.row,
    props = { gap = 1 },
    children = { { comp = ui.label, props = { text = spec.label .. ":" } }, control },
  }
end
-- Shared with the sidebar's inline settings rows, so both surfaces render a
-- setting the same way.
M.setting_row = setting_row

--- @param props { stores: { view?: weave.settings.Store, session?: weave.settings.Store, global?: weave.settings.Store } }
local function Window(ctx, props)
  local stores = props.stores
  -- one subscription per store present, so any change re-renders
  local snapshots = {}
  for scope, store in pairs(stores) do
    snapshots[scope] = use_store(ctx, store)
  end

  local rows = {}

  -- Presets first: the buttons users came for. A preset is a button, not a
  -- state — nothing here claims to know "the current preset", only which one
  -- was last APPLIED (hand-editing any setting afterwards leaves that stale
  -- on purpose; it is a hint, not a mode).
  local presets = Settings.presets()
  if #presets > 0 then
    rows[#rows + 1] = header("Presets")
    local buttons = {}
    for _, preset in ipairs(presets) do
      buttons[#buttons + 1] = bare_button("[" .. preset.name .. "]", function()
        Settings.apply_preset(preset, stores)
        Logger.notify(("weave: applied preset %q"):format(preset.name), vim.log.levels.INFO)
      end)
    end
    local last = Settings.last_preset()
    if last then
      buttons[#buttons + 1] = dim("last applied: " .. last)
    end
    rows[#rows + 1] = { comp = ui.row, props = { gap = 2 }, children = buttons }
    rows[#rows + 1] = blank()
  end

  for _, scope in ipairs(SCOPE_ORDER) do
    rows[#rows + 1] = header(SCOPE_TITLES[scope])
    local store = stores[scope]
    if not store then
      rows[#rows + 1] = dim(scope == "session" and "  (no active session)" or "  (no open panel)")
    else
      for _, spec in ipairs(Settings.specs(scope)) do
        rows[#rows + 1] = setting_row(spec, store, snapshots[scope])
      end
    end
    rows[#rows + 1] = blank()
  end

  rows[#rows + 1] = dim("<CR> toggles/edits · q closes")
  return { comp = ui.col, props = {}, children = rows }
end
M.Window = Window

--- The stores this window edits. view/session default to the acting entry
--- (selected, else first — matching the tool layer's convention); global is
--- always the editor's.
--- @param opts { view?: weave.settings.Store, session?: weave.settings.Store }|nil
--- @return { view?: weave.settings.Store, session?: weave.settings.Store, global: weave.settings.Store }
function M.resolve_stores(opts)
  opts = opts or {}
  local stores = { view = opts.view, session = opts.session, global = Settings.global() }
  if not stores.view or not stores.session then
    local ok, Registry = pcall(require, "weave.registry")
    local entry = ok and (Registry.selected() or Registry.list()[1]) or nil
    if entry then
      stores.view = stores.view or entry.prefs
      stores.session = stores.session or Settings.for_session(entry.session)
    end
  end
  return stores
end

--- Open the settings window. Returns the fibrous app handle.
--- @param opts { view?: weave.settings.Store, session?: weave.settings.Store }|nil
function M.open(opts)
  local mount = require("fibrous.inline.mount")
  local stores = M.resolve_stores(opts)
  local size = #Settings.SPECS + #Settings.presets() + 12
  local app = mount.floating(Window, { stores = stores }, {
    width = 52,
    height = math.min(size, math.max(vim.o.lines - 6, 8)),
    mode = "scroll",
    border = "rounded",
    backdrop = true,
  })
  require("weave.keys").map(app.bufnr, "close_float", function()
    app.unmount()
  end, { nowait = true, desc = "weave: close settings" })
  app.focus()
  return app
end

return M
