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

--- @alias weave.permissions.RequirementMode "or_stricter"|"exact"|"or_looser"

--- @class weave.permissions.SandboxRequirement What confinement a preset's rules assume
--- @field profile "off"|"workspace"|"readonly"|"blackbox"
--- @field mode? weave.permissions.RequirementMode Default "or_stricter"

--- @class weave.permissions.Preset
--- @field name string Unique id; a later source shadows an earlier one of the same name
--- @field label? string Human label for the sidebar/UI (defaults to name)
--- @field rules weave.permissions.Rule[] Evaluated in order, first match wins
--- @field sandbox? weave.permissions.SandboxRequirement Declarative: the engine compares, it never applies a profile
--- @field source? "builtin"|"setup"|"runtime" Assigned by the engine, not the caller

--- @class weave.permissions.Action
--- @field tool string Namespaced action name (see the vocabulary above)
--- @field resource? string The thing acted on (path, command line, buffer ref)

local DECISIONS = { allow = true, deny = true, ask = true }

-- The sandbox profiles ordered by CONFINEMENT, which is what makes "at least
-- this strict" a comparison instead of a table of special cases:
--   off < workspace < readonly < blackbox
-- (no sandbox / project rw / project ro / project absent).
local PROFILE_RANK = { off = 1, workspace = 2, readonly = 3, blackbox = 4 }
local MODES = { or_stricter = true, exact = true, or_looser = true }

-- Rules are static tables in Lua and in config, so they cannot name the
-- project root literally. `${project}` in a resource glob expands to it at
-- resolve time — without this, "inside the project" is inexpressible and the
-- sandboxed presets below collapse to tool-name-only rules.
local PROJECT_TOKEN = "${project}"

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
  -- ── The sandboxed variants ────────────────────────────────────────────────
  --
  -- Same three shapes, same cycle order, with the client-side exemption
  -- removed: once a profile confines the agent PROCESS, weave's own tools stop
  -- being a free channel around it. Note what they deliberately do NOT do —
  -- they never tighten acp:*, so the agent-side flow is unchanged.
  --
  -- The task query tools are listed one by one above the weave:* catch-all on
  -- purpose. tools/init.lua registers them with no resource extractor, and a
  -- resource-bearing rule never matches a resourceless action, so a
  -- `{ tool = "weave:*", resource = "${project}/**" }` line would sail past
  -- them into the ask below and make the agent ask permission to read a task's
  -- exit code.
  {
    name = "sandboxed_normal",
    label = "Sandboxed (ask)",
    source = "builtin",
    sandbox = { profile = "workspace", mode = "or_stricter" },
    rules = {
      { tool = "acp:*", decision = "ask" },
      { tool = "weave:read", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:glob", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:grep", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:task_status", decision = "allow" },
      { tool = "weave:task_wait", decision = "allow" },
      { tool = "weave:task_kill", decision = "allow" },
      { tool = "weave:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
  },
  {
    name = "sandboxed_auto",
    label = "Sandboxed (auto)",
    source = "builtin",
    sandbox = { profile = "workspace", mode = "or_stricter" },
    rules = {
      { tool = "weave:task_status", decision = "allow" },
      { tool = "weave:task_wait", decision = "allow" },
      { tool = "weave:task_kill", decision = "allow" },
      { tool = "weave:*", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
  },
  {
    name = "sandboxed_allow_edits",
    label = "Sandboxed (allow edits)",
    source = "builtin",
    sandbox = { profile = "workspace", mode = "or_stricter" },
    rules = {
      { tool = "acp:edit", decision = "allow" },
      { tool = "acp:*", decision = "ask" },
      { tool = "weave:read", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:glob", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:grep", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:write", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:edit", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:task_status", decision = "allow" },
      { tool = "weave:task_wait", decision = "allow" },
      { tool = "weave:task_kill", decision = "allow" },
      { tool = "weave:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
  },
}

--- @type weave.permissions.Preset[] from setup(); shadows builtin by name
local setup_presets = {}
--- @type weave.permissions.Preset[] from save_preset(); shadows both
local runtime_presets = {}
local active_name = "normal"
--- @type weave.permissions.Rule[] the grant overlay; consulted BEFORE the active preset
local overlay = {}
--- @type string|nil project root for ${project}; nil = ask the editor
local project_root = nil
--- @type string|nil the RUNNING session's profile; nil = ask the config
local current_profile = nil
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

--- The project root `${project}` expands to. Defaults to the editor's cwd;
--- the session layer sets it explicitly so a rule means the same thing
--- whatever the user has :cd'd to since.
--- @return string
function M.project_root()
  return project_root or vim.fn.getcwd()
end

--- @param root string|nil nil restores the cwd default
function M.set_project_root(root)
  project_root = root
end

--- Expand `${project}` in a resource glob. Cheap enough to do per resolve,
--- and doing it lazily is what keeps presets serialisable.
--- @param resource string
--- @return string
local function expand(resource)
  if not resource:find(PROJECT_TOKEN, 1, true) then
    return resource
  end
  return (resource:gsub("%${project}", (M.project_root():gsub("%%", "%%%%"))))
end

--- Match a rule's resource pattern against an action's resource.
---
--- `dir/**` means the directory AND everything under it. Plain glob matching
--- gives only the latter, which reads fine until a tool's resource IS a
--- directory: `grep` with no `path` resources at the project root, so
--- `${project}/**` would miss the single most common search there is and drop
--- it to "ask". Nobody writing that rule meant "everything except the
--- directory itself".
--- @param pattern string already expanded
--- @param resource string
--- @return boolean
local function resource_matches(pattern, resource)
  if M.glob_match(pattern, resource) then
    return true
  end
  local dir = pattern:match("^(.*)/%*%*$")
  return dir ~= nil and dir == resource
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
  return action.resource ~= nil and resource_matches(expand(rule.resource), action.resource)
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
  local sandbox = preset.sandbox and { profile = preset.sandbox.profile, mode = preset.sandbox.mode } or nil
  return { name = preset.name, label = preset.label, rules = rules, sandbox = sandbox, source = source }
end

--- Validate one rule in isolation (shared by presets and grants).
--- @param rule table
--- @param where string prefix for the error message
local function validate_rule(rule, where)
  if type(rule.tool) ~= "string" or rule.tool == "" then
    error(("weave.permissions: %s: `tool` must be a glob string"):format(where), 0)
  end
  if rule.resource ~= nil and type(rule.resource) ~= "string" then
    error(("weave.permissions: %s: `resource` must be a glob string"):format(where), 0)
  end
  if not DECISIONS[rule.decision] then
    error(
      ("weave.permissions: %s: `decision` must be allow/deny/ask, got %s"):format(where, vim.inspect(rule.decision)),
      0
    )
  end
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
    validate_rule(rule, ("preset %q rule %d"):format(preset.name, i))
  end
  local sandbox = preset.sandbox
  if sandbox ~= nil then
    if type(sandbox) ~= "table" or not PROFILE_RANK[sandbox.profile] then
      error(
        ("weave.permissions: preset %q: `sandbox.profile` must be off/workspace/readonly/blackbox, got %s"):format(
          preset.name,
          vim.inspect(type(sandbox) == "table" and sandbox.profile or sandbox)
        ),
        0
      )
    end
    if sandbox.mode ~= nil and not MODES[sandbox.mode] then
      error(
        ("weave.permissions: preset %q: `sandbox.mode` must be or_stricter/exact/or_looser, got %s"):format(
          preset.name,
          vim.inspect(sandbox.mode)
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

--- ── Sandbox profiles ────────────────────────────────────────────────────────

--- Confinement rank; higher is stricter. Unknown profiles rank as `off`, so a
--- typo loosens visibly rather than silently claiming confinement.
--- @param profile string|nil
--- @return integer
function M.profile_rank(profile)
  return PROFILE_RANK[profile] or PROFILE_RANK.off
end

--- The profile in force RIGHT NOW: the one the session you are looking at
--- was actually spawned under.
---
--- Agent processes are keyed (provider, profile), so two sessions can be
--- running at different confinements at the same time and "the current
--- profile" is only meaningful relative to one of them. The selected session
--- is the one the permissions UI describes and the one a ;;p selection acts
--- on, so it is the one that answers here. Falling back, in order: the last
--- spawn (set_profile, for the window between spawn and a registered
--- session) and the configured default (before anything spawns at all).
--- @return string
function M.current_profile()
  local ok, Registry = pcall(require, "weave.registry")
  if ok then
    local entry = Registry.selected() or Registry.list()[1]
    local session = entry and entry.session
    local client = session and session.client and session:client()
    if client and client.sandbox_profile then
      return client.sandbox_profile
    end
  end
  if current_profile then
    return current_profile
  end
  local sok, sandbox = pcall(require, "weave.sandbox")
  return (sok and sandbox.resolve().profile) or "off"
end

--- @param profile string|nil nil restores the config default
function M.set_profile(profile)
  if current_profile == profile then
    return
  end
  current_profile = profile
  notify()
end

--- Does this preset's declared requirement accept `profile`? Presets with no
--- requirement accept everything, so every builtin stays reachable.
--- @param preset weave.permissions.Preset
--- @param profile? string defaults to the current profile
--- @return boolean ok, string|nil reason
function M.preset_compatible(preset, profile)
  local req = preset and preset.sandbox
  if not req then
    return true, nil
  end
  profile = profile or M.current_profile()
  local mode = req.mode or "or_stricter"
  local want, have = M.profile_rank(req.profile), M.profile_rank(profile)
  local ok
  if mode == "exact" then
    ok = have == want
  elseif mode == "or_looser" then
    ok = have <= want
  else
    ok = have >= want
  end
  if ok then
    return true, nil
  end
  local phrasing = ({ or_stricter = " or stricter", or_looser = " or looser", exact = " exactly" })[mode]
  return false, ("requires sandbox %s%s; current: %s"):format(req.profile, phrasing, profile)
end

--- The presets `;;p` may land on: the effective list minus the ones the
--- current profile does not satisfy. Guard: never filter to empty — a cycle
--- that lands nowhere reads as a broken keybind, so a fully-incompatible list
--- is returned whole and the UI explains itself instead.
--- @param profile? string
--- @return weave.permissions.Preset[]
function M.compatible_presets(profile)
  local all = M.presets()
  local out = {}
  for _, p in ipairs(all) do
    if M.preset_compatible(p, profile) then
      out[#out + 1] = p
    end
  end
  return #out > 0 and out or all
end

--- Advance to the next COMPATIBLE preset in the effective order (the ;;p
--- cycle) and return it. Cycling is cheap, frequent and non-destructive: it
--- never restarts an agent and never prompts, so incompatible presets are
--- skipped silently here and surfaced (greyed, with a reason) in the
--- permissions window instead.
--- @return weave.permissions.Preset
function M.cycle()
  local list = M.compatible_presets()
  local idx = 0
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

--- Resolve an action: the grant overlay first, then the active preset, then
--- the engine-wide "ask". First matching rule's decision wins.
--- @param action weave.permissions.Action
--- @return weave.permissions.Decision decision, weave.permissions.Rule|nil rule
function M.resolve(action)
  for _, list in ipairs({ overlay, M.active().rules or {} }) do
    for _, rule in ipairs(list) do
      if rule_matches(rule, action) then
        return rule.decision, rule
      end
    end
  end
  return "ask", nil
end

--- ── The grant overlay ───────────────────────────────────────────────────────
---
--- Answering "allow for project" on a gate prompt writes here, NOT into the
--- active preset. Redefining `normal` as a side effect of one keystroke would
--- mean `normal` no longer means what it means in the docs or on anyone
--- else's machine, and cycling away and back would not clear it. A separate
--- overlay keeps preset semantics exactly as shipped and keeps grants visibly
--- a thing sitting on top, with somewhere to list and revoke them.
---
--- Session-scoped: discarded on exit, promoted to a named preset by an
--- explicit action. A durable filesystem grant created by pressing `;;2` is
--- how people end up with a permission set whose origin they cannot account
--- for.

--- @return weave.permissions.Rule[] a copy; mutate through add/revoke
function M.grants()
  local out = {}
  for i, r in ipairs(overlay) do
    out[i] = { tool = r.tool, resource = r.resource, decision = r.decision }
  end
  return out
end

--- Append a grant. Newest last, so an older grant keeps winning — a grant is
--- an answer to a question, and re-answering it the same way is a no-op.
--- @param rule weave.permissions.Rule
function M.add_grant(rule)
  validate_rule(rule, "grant")
  overlay[#overlay + 1] = { tool = rule.tool, resource = rule.resource, decision = rule.decision }
  notify()
end

--- @param index integer 1-based, as listed by grants()
function M.revoke_grant(index)
  if not overlay[index] then
    error(("weave.permissions: no grant at index %d"):format(index), 0)
  end
  table.remove(overlay, index)
  notify()
end

function M.clear_overlay()
  if #overlay == 0 then
    return
  end
  overlay = {}
  notify()
end

--- The rule an "always" answer to `action` should produce. Granting exactly
--- what was asked is close to worthless for fs and search tools — an agent
--- rarely reads the same path twice, so the user is asked again on the next
--- file. The useful unit is the one the sandbox already reasons in: the
--- project. Outside it we fall back to the exact resource, so a grant over
--- ~/.config does not silently generalise to all of ~.
--- @param action weave.permissions.Action
--- @param decision weave.permissions.Decision
--- @return weave.permissions.Rule
function M.grant_rule(action, decision)
  if action.resource == nil then
    return { tool = action.tool, decision = decision }
  end
  local root = M.project_root()
  local inside = action.resource:sub(1, #root + 1) == root .. "/"
  return {
    tool = action.tool,
    resource = inside and (PROJECT_TOKEN .. "/**") or action.resource,
    decision = decision,
  }
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
  elseif M.current_profile() ~= "off" and M.get("sandboxed_" .. active_name) then
    -- A profile is on and the user expressed no preference: default to the
    -- matching sandboxed variant, since the plain ones exempt weave's own
    -- tools from the confinement the profile was turned on for.
    active_name = "sandboxed_" .. active_name
  end
  notify()
end

-- test hook: back to the shipped state
function M._reset()
  setup_presets = {}
  runtime_presets = {}
  overlay = {}
  active_name = "normal"
  project_root = nil
  current_profile = nil
  subscribers = {}
end

return M
