-- The client-side permission engine (design-agent-sandbox.md, phase 1): one
-- generic rule set answering "may the agent do THIS to THAT" for every
-- mediated operation, whatever protocol it arrived over. Editor-global and
-- protocol-agnostic on purpose — it lives BESIDE the ACP client, not inside
-- it (partial preparation for weave one day being an agentic provider rather
-- than only an ACP client).
--
-- ── The model ───────────────────────────────────────────────────────────────
--
-- An ACTION is what the agent is attempting: a namespaced tool name plus an
-- optional resource string. The namespace is the extensibility hook — any
-- plugin with client-side tools resolves through the same engine by picking
-- its own prefix:
--   acp:<kind>      an ACP session/request_permission (kind: edit, execute,
--                   read, delete, ... — mapped in acp_bridge)
--   weave:<tool>    weave's own MCP suite (weave:read, weave:task_start, ...)
--   <plugin>:<tool> any other clankbox tool provider (perijove:run_cell, ...)
-- The resource is the thing acted on: a file path, a command line, a buffer
-- reference — plain text, matched with globs.
--
-- A RULE is (tool glob, optional resource glob, decision allow/deny/ask).
-- A PRESET is a named, ordered rule list. Resolution: first matching rule of
-- the ACTIVE preset wins; a rule carrying a resource glob never matches an
-- action without a resource; when nothing matches the answer is "ask" (the
-- safe default — surfaced where the caller has a user to ask, denied where
-- it does not).
--
-- Presets coexist from three sources, later shadowing earlier BY NAME:
-- builtin (shipped; the legacy permission modes normal/auto/allow_edits
-- re-encoded), setup (config.permissions.presets), runtime (created or
-- edited in the config window; in-memory for now — persistence is an open
-- question in the design doc). ;;p cycles the effective list.

local M = {}

--- @alias weave.permissions.Decision "allow"|"deny"|"ask"

--- @class weave.permissions.Rule
--- @field tool string Glob over the namespaced action name (e.g. "acp:*", "weave:read", "*")
--- @field resource? string Glob over the resource; a rule with one never matches an action without one
--- @field decision weave.permissions.Decision

--- @class weave.permissions.Preset
--- @field name string Unique id; a later source shadows an earlier one of the same name
--- @field label? string Human label for the sidebar/UI (defaults to name)
--- @field rules weave.permissions.Rule[] Evaluated in order, first match wins
--- @field source? "builtin"|"setup"|"runtime" Assigned by the engine, not the caller

--- @class weave.permissions.Action
--- @field tool string Namespaced action name (see the vocabulary above)
--- @field resource? string The thing acted on (path, command line, buffer ref)

local DECISIONS = { allow = true, deny = true, ask = true }

-- The legacy permission modes, re-encoded (same names, labels and cycle
-- order, so ;;p muscle memory and the prompt-border palette carry over).
-- "Client-side tools allow by default" preserves phase-0 behavior: the
-- agent-side permission flow already mediates MCP calls over acp:*; rules
-- targeting weave:*/plugin tools are the new, opt-in tightening.
--- @type weave.permissions.Preset[]
local BUILTIN = {
  {
    name = "normal",
    label = "Normal (ask)",
    source = "builtin",
    rules = {
      { tool = "acp:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
  },
  {
    name = "auto",
    label = "Auto (allow all)",
    source = "builtin",
    rules = {
      { tool = "*", decision = "allow" },
    },
  },
  {
    name = "allow_edits",
    label = "Allow edits",
    source = "builtin",
    rules = {
      { tool = "acp:edit", decision = "allow" },
      { tool = "acp:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
  },
}

--- @type weave.permissions.Preset[] from setup(); shadows builtin by name
local setup_presets = {}
--- @type weave.permissions.Preset[] from save_preset(); shadows both
local runtime_presets = {}
local active_name = "normal"
--- @type fun()[]
local subscribers = {}

local function notify()
  for _, fn in ipairs({ unpack(subscribers) }) do
    fn()
  end
end

--- Subscribe to engine changes (active preset, preset definitions). Fires
--- synchronously, payload-free — read the engine back. Returns unsubscribe.
--- @param fn fun()
--- @return fun() unsubscribe
function M.subscribe(fn)
  subscribers[#subscribers + 1] = fn
  return function()
    for i, f in ipairs(subscribers) do
      if f == fn then
        table.remove(subscribers, i)
        return
      end
    end
  end
end

--- Whole-string glob match: `*` any run (including none), `?` exactly one
--- char, everything else literal. Deliberately tiny and predictable — `*`
--- crosses `/`, so "/etc/*" covers the whole subtree and "git *" is a
--- command prefix.
--- @param glob string
--- @param text string
--- @return boolean
function M.glob_match(glob, text)
  local pat = glob:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".")
  return text:match("^" .. pat .. "$") ~= nil
end

--- @param rule weave.permissions.Rule
--- @param action weave.permissions.Action
--- @return boolean
local function rule_matches(rule, action)
  if not M.glob_match(rule.tool, action.tool) then
    return false
  end
  if rule.resource == nil then
    return true
  end
  return action.resource ~= nil and M.glob_match(rule.resource, action.resource)
end

--- Deep-copy a preset so engine state never aliases caller tables.
--- @param preset weave.permissions.Preset
--- @param source "builtin"|"setup"|"runtime"
--- @return weave.permissions.Preset
local function own(preset, source)
  local rules = {}
  for i, r in ipairs(preset.rules or {}) do
    rules[i] = { tool = r.tool, resource = r.resource, decision = r.decision }
  end
  return { name = preset.name, label = preset.label, rules = rules, source = source }
end

--- Validate a caller-supplied preset, loudly (a typo'd decision must not
--- silently become "no rule").
--- @param preset table
local function validate(preset)
  if type(preset) ~= "table" or type(preset.name) ~= "string" or preset.name == "" then
    error("weave.permissions: a preset needs a non-empty `name`", 0)
  end
  if preset.rules ~= nil and type(preset.rules) ~= "table" then
    error(("weave.permissions: preset %q: `rules` must be a list"):format(preset.name), 0)
  end
  for i, rule in ipairs(preset.rules or {}) do
    if type(rule.tool) ~= "string" or rule.tool == "" then
      error(("weave.permissions: preset %q rule %d: `tool` must be a glob string"):format(preset.name, i), 0)
    end
    if rule.resource ~= nil and type(rule.resource) ~= "string" then
      error(("weave.permissions: preset %q rule %d: `resource` must be a glob string"):format(preset.name, i), 0)
    end
    if not DECISIONS[rule.decision] then
      error(
        ("weave.permissions: preset %q rule %d: `decision` must be allow/deny/ask, got %s"):format(
          preset.name,
          i,
          vim.inspect(rule.decision)
        ),
        0
      )
    end
  end
end

--- @param list weave.permissions.Preset[]
--- @param name string
--- @return weave.permissions.Preset|nil, integer|nil
local function find(list, name)
  for i, p in ipairs(list) do
    if p.name == name then
      return p, i
    end
  end
  return nil, nil
end

--- The effective preset list: builtins in shipped order, then setup, then
--- runtime — each name appearing ONCE, at its first-source position, defined
--- by its last source (runtime > setup > builtin).
--- @return weave.permissions.Preset[]
function M.presets()
  local out, seen = {}, {}
  for _, list in ipairs({ BUILTIN, setup_presets, runtime_presets }) do
    for _, p in ipairs(list) do
      if not seen[p.name] then
        seen[p.name] = #out + 1
        out[#out + 1] = p
      else
        out[seen[p.name]] = p -- a later source shadows in place
      end
    end
  end
  return out
end

--- The effective definition of `name`, or nil.
--- @param name string
--- @return weave.permissions.Preset|nil
function M.get(name)
  return find(runtime_presets, name) or find(setup_presets, name) or find(BUILTIN, name)
end

--- The active preset (never nil; falls back to builtin normal if the active
--- name stops existing).
--- @return weave.permissions.Preset
function M.active()
  return M.get(active_name) or (find(BUILTIN, "normal"))
end

--- Make `name` the active preset. Unknown names fail loudly.
--- @param name string
function M.set_active(name)
  if not M.get(name) then
    error(("weave.permissions: unknown preset %q"):format(name), 0)
  end
  if active_name == name then
    return
  end
  active_name = name
  notify()
end

--- Advance to the next preset in the effective order (the ;;p cycle) and
--- return it.
--- @return weave.permissions.Preset
function M.cycle()
  local list = M.presets()
  local idx = 1
  for i, p in ipairs(list) do
    if p.name == active_name then
      idx = i
      break
    end
  end
  local next_preset = list[(idx % #list) + 1]
  M.set_active(next_preset.name)
  return next_preset
end

--- Resolve an action against the active preset: the first matching rule's
--- decision, or "ask" when none matches.
--- @param action weave.permissions.Action
--- @return weave.permissions.Decision decision, weave.permissions.Rule|nil rule
function M.resolve(action)
  for _, rule in ipairs(M.active().rules or {}) do
    if rule_matches(rule, action) then
      return rule.decision, rule
    end
  end
  return "ask", nil
end

--- Create or replace a RUNTIME preset (the config window's save path). A
--- runtime preset with a builtin/setup name shadows it — deleting the
--- runtime def restores the original, so "editing" a shipped preset is
--- always reversible.
--- @param preset weave.permissions.Preset
function M.save_preset(preset)
  validate(preset)
  local owned = own(preset, "runtime")
  local _, i = find(runtime_presets, preset.name)
  if i then
    runtime_presets[i] = owned
  else
    runtime_presets[#runtime_presets + 1] = owned
  end
  notify()
end

--- Delete the RUNTIME definition of `name` (only runtime defs are deletable;
--- shipped and setup presets are permanent). If that name still exists in an
--- earlier source, the shadowed definition takes over; if not and it was
--- active, the active preset falls back to normal.
--- @param name string
function M.delete_preset(name)
  local _, i = find(runtime_presets, name)
  if not i then
    error(("weave.permissions: %q has no runtime definition to delete"):format(name), 0)
  end
  table.remove(runtime_presets, i)
  if active_name == name and not M.get(name) then
    active_name = "normal"
  end
  notify()
end

--- Ingest the setup() config: `presets` become the setup source (validated
--- loudly), `preset` picks the active one.
--- @param cfg { preset?: string, presets?: weave.permissions.Preset[] }|nil
function M.setup(cfg)
  cfg = cfg or {}
  setup_presets = {}
  for _, p in ipairs(cfg.presets or {}) do
    validate(p)
    setup_presets[#setup_presets + 1] = own(p, "setup")
  end
  if cfg.preset then
    if not M.get(cfg.preset) then
      error(("weave.permissions: unknown active preset %q in setup"):format(cfg.preset), 0)
    end
    active_name = cfg.preset
  end
  notify()
end

-- test hook: back to the shipped state
function M._reset()
  setup_presets = {}
  runtime_presets = {}
  active_name = "normal"
  subscribers = {}
end

return M
