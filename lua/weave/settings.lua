-- weave.settings: the one declarative registry of every user-facing runtime
-- setting, plus the scoped stores that hold their values.
--
-- ── One home per setting ────────────────────────────────────────────────────
--
-- Each setting DECLARES its scope and lives only there — there is no
-- global→session→view resolution chain, because none of these settings
-- plausibly wants different values at several layers at once, and a cascade
-- would force every checkbox to grow an "inherit" third state:
--
--   view     per panel; pure display choices (what registry entries used to
--            hold as weave.view.Prefs — same store contract, same lifetime)
--   session  per conversation: how THIS agent relates to the user's edits
--   global   editor-wide: there is one revision log, so there is one switch
--
-- ── Stores ──────────────────────────────────────────────────────────────────
--
-- Store carries the contract the view's use_store hook already relies on
-- (inherited from Prefs and SessionStore): `.state` is REASSIGNED per
-- mutation, unchanged keys keep identity, subscribe/notify fires once per
-- mutation, synchronously. Values are validated against the spec — a typo'd
-- key or a mistyped value fails loudly instead of silently binding nothing.
--
-- Effects (starting the revision log, announcing a brief) do NOT live here:
-- the owning modules (weave.edit_sync, weave.briefs) subscribe to the stores
-- they care about. This module stays pure so the settings window, the
-- sidebar and the specs can drive it without side effects they didn't ask
-- for.
--
-- ── Presets ─────────────────────────────────────────────────────────────────
--
-- A preset is a PARTIAL {key = value} map plus a name — a button, not a
-- state. Applying one sets exactly the keys it names (in registry order, so
-- dependencies like track_edits-before-auto_send_edits hold) and leaves the
-- rest untouched; hand-editing a setting afterwards puts you in no preset at
-- all, which is why nothing here tries to infer "the current preset" back
-- from the values.

local Config = require("weave.config")

local M = {}

--- @class weave.settings.Spec
--- @field key string
--- @field scope "view"|"session"|"global"
--- @field type "boolean"|"integer"|"enum"
--- @field default boolean|integer|string
--- @field label string Shown next to the control in the sidebar/window
--- @field min? integer Lower bound (integer type)

--- Every runtime setting, in display order. Defaults are overridable per key
--- via Config.settings.defaults.
--- @type weave.settings.Spec[]
M.SPECS = {
  -- view: what this panel shows
  { key = "show_thoughts", scope = "view", type = "boolean", default = true, label = "Show thinking" },
  { key = "show_diffs", scope = "view", type = "boolean", default = true, label = "Show edit diffs" },
  { key = "conceal_markdown", scope = "view", type = "boolean", default = true, label = "Prettify markdown" },
  { key = "follow", scope = "view", type = "boolean", default = true, label = "Follow streaming" },
  -- global: the revision log is editor-wide, so its switch is too
  { key = "track_edits", scope = "global", type = "boolean", default = false, label = "Track user edits" },
  -- session: how this conversation relates to the user's edits
  { key = "auto_send_edits", scope = "session", type = "boolean", default = false, label = "Auto-send edits" },
  { key = "debounce_ms", scope = "session", type = "integer", default = 7000, min = 0, label = "Edit debounce (ms)" },
  { key = "edit_gate", scope = "session", type = "boolean", default = false, label = "Gate writes on unseen edits" },
  { key = "brief", scope = "session", type = "enum", default = "normal", label = "Agent brief" },
}

--- @type table<string, weave.settings.Spec>
local BY_KEY = {}
for _, spec in ipairs(M.SPECS) do
  BY_KEY[spec.key] = spec
end

--- @param key string
--- @return weave.settings.Spec
function M.spec(key)
  local spec = BY_KEY[key]
  if not spec then
    error(("weave.settings: unknown setting %q"):format(tostring(key)), 3)
  end
  return spec
end

--- The specs of one scope, in registry (display) order.
--- @param scope "view"|"session"|"global"
--- @return weave.settings.Spec[]
function M.specs(scope)
  local out = {}
  for _, spec in ipairs(M.SPECS) do
    if spec.scope == scope then
      out[#out + 1] = spec
    end
  end
  return out
end

--- The specs the sidebar renders directly, from Config.settings.sidebar —
--- which settings deserve a permanent checkbox is the user's call, made once
--- at setup. Unknown names are skipped loudly (a typo should not vanish a
--- toggle without a trace).
--- @return weave.settings.Spec[]
function M.sidebar_specs()
  local out = {}
  local conf = Config.settings or {}
  for _, key in ipairs(conf.sidebar or {}) do
    if BY_KEY[key] then
      out[#out + 1] = BY_KEY[key]
    else
      vim.notify(("weave: settings.sidebar names unknown setting %q"):format(key), vim.log.levels.WARN)
    end
  end
  return out
end

--- Valid values for an enum setting. `brief` is the only one today: the
--- configured brief names, sorted, with the default first so pickers read
--- naturally.
--- @param key string
--- @return string[]
function M.enum_options(key)
  local spec = M.spec(key)
  if spec.type ~= "enum" then
    return {}
  end
  local names = {}
  if key == "brief" then
    for name in pairs((Config.settings or {}).briefs or {}) do
      names[#names + 1] = name
    end
  end
  table.sort(names, function(a, b)
    if a == spec.default then
      return b ~= spec.default
    end
    if b == spec.default then
      return false
    end
    return a < b
  end)
  return names
end

--- Validate + normalise a value for `spec`. Integers arrive as strings from
--- input prompts; enums must name a configured option.
--- @param spec weave.settings.Spec
--- @param value any
--- @return any|nil value nil when invalid
--- @return string|nil err
function M.coerce(spec, value)
  if spec.type == "boolean" then
    if type(value) ~= "boolean" then
      return nil, ("%s expects true/false"):format(spec.key)
    end
    return value
  end
  if spec.type == "integer" then
    local n = tonumber(value)
    if not n then
      return nil, ("%s expects a number"):format(spec.key)
    end
    n = math.floor(n)
    if spec.min and n < spec.min then
      return nil, ("%s must be at least %d"):format(spec.key, spec.min)
    end
    return n
  end
  if spec.type == "enum" then
    for _, opt in ipairs(M.enum_options(spec.key)) do
      if opt == value then
        return value
      end
    end
    return nil, ("%s must be one of: %s"):format(spec.key, table.concat(M.enum_options(spec.key), ", "))
  end
  return nil, ("unknown setting type %q"):format(tostring(spec.type))
end

--- @param spec weave.settings.Spec
--- @return any
local function default_of(spec)
  local overrides = (Config.settings or {}).defaults or {}
  local override = overrides[spec.key]
  if override ~= nil then
    local v = M.coerce(spec, override)
    if v ~= nil then
      return v
    end
    vim.notify(
      ("weave: settings.defaults.%s is invalid; using the builtin default"):format(spec.key),
      vim.log.levels.WARN
    )
  end
  return spec.default
end

---------------------------------------------------------------------------
-- Store
---------------------------------------------------------------------------

--- @class weave.settings.Store
--- @field scope "view"|"session"|"global"
--- @field state table<string, any>
--- @field _subscribers fun(state: table<string, any>)[]
local Store = {}
Store.__index = Store
M.Store = Store

--- @param scope "view"|"session"|"global"
--- @return weave.settings.Store
function Store:new(scope)
  local state = {}
  for _, spec in ipairs(M.SPECS) do
    if spec.scope == scope then
      state[spec.key] = default_of(spec)
    end
  end
  return setmetatable({ scope = scope, state = state, _subscribers = {} }, self)
end

--- Subscribe to changes; fn(state) fires synchronously after every mutation.
--- @param fn fun(state: table<string, any>)
--- @return fun() unsubscribe
function Store:subscribe(fn)
  local subs = self._subscribers
  subs[#subs + 1] = fn
  return function()
    for i, f in ipairs(subs) do
      if f == fn then
        table.remove(subs, i)
        return
      end
    end
  end
end

--- The spec of `key`, verified to live in THIS store's scope.
--- @param key string
--- @return weave.settings.Spec
function Store:_spec(key)
  local spec = M.spec(key)
  if spec.scope ~= self.scope then
    error(("weave.settings: %q is %s-scoped, not %s"):format(key, spec.scope, self.scope), 3)
  end
  return spec
end

--- @param key string
--- @return any
function Store:get(key)
  return self.state[self:_spec(key).key]
end

--- Assign one setting (reassigning state) and notify. Invalid values error:
--- every caller is either code (a bug to surface) or the settings window
--- (which coerces first and reports to the user itself).
--- @param key string
--- @param value any
function Store:set(key, value)
  local spec = self:_spec(key)
  local v, err = M.coerce(spec, value)
  if v == nil then
    error("weave.settings: " .. (err or "invalid value"), 2)
  end
  if self.state[key] == v then
    return
  end
  local draft = {}
  for k, val in pairs(self.state) do
    draft[k] = val
  end
  draft[key] = v
  self.state = draft
  for _, fn in ipairs({ unpack(self._subscribers) }) do
    fn(draft)
  end
end

--- Flip one boolean setting.
--- @param key string
function Store:toggle(key)
  local spec = self:_spec(key)
  if spec.type ~= "boolean" then
    error(("weave.settings: cannot toggle %s setting %q"):format(spec.type, key), 2)
  end
  self:set(key, not self.state[key])
end

---------------------------------------------------------------------------
-- The scoped instances
---------------------------------------------------------------------------

local global_store = nil

--- The editor-global store (one per nvim).
--- @return weave.settings.Store
function M.global()
  if not global_store then
    global_store = Store:new("global")
  end
  return global_store
end

--- Per-session stores, weak-keyed: a session that goes away takes its
--- settings with it. Created on first ask, so specs can hand in bare
--- session-shaped doubles.
--- @type table<table, weave.settings.Store>
local session_stores = setmetatable({}, { __mode = "k" })

--- @param session table
--- @return weave.settings.Store
function M.for_session(session)
  local store = session_stores[session]
  if not store then
    store = Store:new("session")
    session_stores[session] = store
  end
  return store
end

--- A fresh view-scoped store — what a registry entry owns per panel (the
--- successor of weave.view.Prefs).
--- @return weave.settings.Store
function M.new_view()
  return Store:new("view")
end

---------------------------------------------------------------------------
-- Presets
---------------------------------------------------------------------------

--- @class weave.settings.Preset
--- @field name string
--- @field settings table<string, any> Partial: keys not named stay untouched

--- The configured presets, in config order.
--- @return weave.settings.Preset[]
function M.presets()
  return (Config.settings or {}).presets or {}
end

--- Apply a preset to the given stores, keys in REGISTRY order (so
--- track_edits lands before auto_send_edits, and brief last — effect
--- subscribers see dependencies before dependents). Keys whose scope has no
--- store here are skipped: a preset naming a view setting still applies its
--- session half when only a session store is at hand.
--- @param preset weave.settings.Preset
--- @param stores { view?: weave.settings.Store, session?: weave.settings.Store, global?: weave.settings.Store }
function M.apply_preset(preset, stores)
  for _, spec in ipairs(M.SPECS) do
    local value = preset.settings[spec.key]
    if value ~= nil then
      local store = stores[spec.scope]
      if store then
        store:set(spec.key, value)
      end
    end
  end
  M._last_preset = preset.name
end

--- The name of the last preset applied this session — a display hint for the
--- settings window, never authoritative (hand-editing any setting afterwards
--- puts you in no preset, and nothing detects that).
--- @return string|nil
function M.last_preset()
  return M._last_preset
end

-- test hook
function M._reset()
  global_store = nil
  session_stores = setmetatable({}, { __mode = "k" })
  M._last_preset = nil
end

return M
