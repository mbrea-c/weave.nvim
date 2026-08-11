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

--- @class weave.permissions.SandboxBind One directory (or file) bound into tool sandboxes
--- @field path string `${project}` expands at spawn time; `~` at mount time
--- @field mode? "rw"|"ro" Default "rw"

--- @class weave.permissions.SandboxSection The preset's confinement section
--- (design-agent-sandbox-v2.md): `binds`/`network` are the kernel hull
--- every TOOL invocation runs under — deliberately ORTHOGONAL to the rules:
--- rules speak globs (fine-grained, per-call, can ask), binds speak
--- directories (the coarse outer hull bounding whatever the gate allows,
--- and bugs in the tools themselves). Neither is derived from the other;
--- lint_preset flags the one confusing combination (a rule no bind reaches).
--- @field binds? weave.permissions.SandboxBind[] Tool-sandbox binds (default: the project, rw)
--- @field network? boolean Tool sandboxes get network (default false)

--- @class weave.permissions.Preset
--- @field name string Unique id; a later source shadows an earlier one of the same name
--- @field label? string Human label for the sidebar/UI (defaults to name)
--- @field rules weave.permissions.Rule[] Evaluated in order, first match wins
--- @field sandbox? weave.permissions.SandboxSection Declarative: the engine compares/derives, it never applies anything itself
--- @field source? "builtin"|"setup"|"runtime" Assigned by the engine, not the caller

--- @class weave.permissions.Action
--- @field tool string Namespaced action name (see the vocabulary above)
--- @field resource? string The thing acted on (path, command line, buffer ref)

local DECISIONS = { allow = true, deny = true, ask = true }

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
  -- removed: under sandbox mode on, weave's tools are the agent's ONLY
  -- route to the world, so they cannot be a free channel around the gate.
  -- Note what they deliberately do NOT do — they never tighten acp:*, so
  -- the agent-side flow is unchanged (and auto-approved under mode on).
  -- Any preset remains selectable under any mode: the hull bounds blast
  -- radius either way, and setup() defaults to a sandboxed_* variant when
  -- mode is on and the user expressed no preference.
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
    rules = {
      { tool = "acp:*", decision = "ask" },
      { tool = "weave:read", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:glob", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:grep", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:task_status", decision = "allow" },
      { tool = "weave:task_wait", decision = "allow" },
      { tool = "weave:task_kill", decision = "allow" },
      { tool = "weave:*", decision = "ask" },
      -- Tools weave does not own (clankbox's exec_lua, other plugins'):
      -- unmediated they undo the confinement this preset exists for.
      { tool = "mcp:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
  },
  {
    name = "sandboxed_auto",
    label = "Sandboxed (auto)",
    source = "builtin",
    rules = {
      { tool = "weave:task_status", decision = "allow" },
      { tool = "weave:task_wait", decision = "allow" },
      { tool = "weave:task_kill", decision = "allow" },
      { tool = "weave:*", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:*", decision = "ask" },
      -- Tools weave does not own (clankbox's exec_lua, other plugins'):
      -- unmediated they undo the confinement this preset exists for.
      { tool = "mcp:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
  },
  {
    name = "sandboxed_allow_edits",
    label = "Sandboxed (allow edits)",
    source = "builtin",
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
      -- Tools weave does not own (clankbox's exec_lua, other plugins'):
      -- unmediated they undo the confinement this preset exists for.
      { tool = "mcp:*", decision = "ask" },
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
--- @type weave.permissions.SandboxBind[] elevation grants: binds ADDED to the
--- active preset's hull for every subsequent tool spawn (weave.tools.access)
local bind_overlay = {}
--- @type boolean elevation grant: tool sandboxes get network this session
local network_granted = false
--- @type string|nil project root for ${project}; nil = ask the editor
local project_root = nil
--- @type string|nil the RUNNING session's sandbox mode; nil = ask the config
local current_mode = nil
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
  local sandbox = nil
  if preset.sandbox then
    local binds = nil
    if preset.sandbox.binds then
      binds = {}
      for i, b in ipairs(preset.sandbox.binds) do
        binds[i] = { path = b.path, mode = b.mode }
      end
    end
    sandbox = { binds = binds, network = preset.sandbox.network }
  end
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
    if type(sandbox) ~= "table" then
      error(("weave.permissions: preset %q: `sandbox` must be a table, got %s"):format(preset.name, type(sandbox)), 0)
    end
    -- The v1 requirement fields died with the profile machinery. Loud, not
    -- ignored: a preset that names a confinement requirement weave no
    -- longer honours must not silently load as if it were honoured.
    if sandbox.profile ~= nil or sandbox.mode ~= nil then
      error(
        ("weave.permissions: preset %q: sandbox `profile`/`mode` requirements were removed (sandbox v2); the section now carries `binds`/`network`"):format(
          preset.name
        ),
        0
      )
    end
    if sandbox.binds ~= nil then
      if type(sandbox.binds) ~= "table" then
        error(("weave.permissions: preset %q: `sandbox.binds` must be a list"):format(preset.name), 0)
      end
      for i, b in ipairs(sandbox.binds) do
        if type(b) ~= "table" or type(b.path) ~= "string" or b.path == "" then
          error(("weave.permissions: preset %q: `sandbox.binds[%d].path` must be a string"):format(preset.name, i), 0)
        end
        if b.mode ~= nil and b.mode ~= "rw" and b.mode ~= "ro" then
          error(
            ("weave.permissions: preset %q: `sandbox.binds[%d].mode` must be rw/ro, got %s"):format(
              preset.name,
              i,
              vim.inspect(b.mode)
            ),
            0
          )
        end
      end
    end
    if sandbox.network ~= nil and type(sandbox.network) ~= "boolean" then
      error(("weave.permissions: preset %q: `sandbox.network` must be a boolean"):format(preset.name), 0)
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

--- ── Sandbox mode ────────────────────────────────────────────────────────────

--- The mode in force RIGHT NOW: the one the session you are looking at was
--- actually spawned under.
---
--- Agent processes are keyed (provider, mode), so two sessions can be
--- running at different confinements at the same time and "the current
--- mode" is only meaningful relative to one of them. The selected session
--- is the one the permissions UI describes, so it is the one that answers
--- here. Falling back, in order: the last spawn (set_mode, for the window
--- between spawn and a registered session) and the configured default
--- (before anything spawns at all).
--- @return "on"|"off"
function M.current_mode()
  local ok, Registry = pcall(require, "weave.registry")
  if ok then
    local entry = Registry.selected() or Registry.list()[1]
    local session = entry and entry.session
    local client = session and session.client and session:client()
    if client and client.sandbox_mode then
      return client.sandbox_mode
    end
  end
  if current_mode then
    return current_mode
  end
  local sok, sandbox = pcall(require, "weave.sandbox")
  return (sok and sandbox.resolve().mode) or "off"
end

--- @param mode string|nil nil restores the config default
function M.set_mode(mode)
  if current_mode == mode then
    return
  end
  current_mode = mode
  notify()
end

--- Advance to the next preset in the effective order (the ;;p cycle) and
--- return it. Cycling is cheap, frequent and non-destructive: it never
--- restarts an agent and never prompts. Every preset is reachable under
--- every mode — the hull bounds blast radius regardless, so preset choice
--- is policy, not a confinement claim.
--- @return weave.permissions.Preset
function M.cycle()
  local list = M.presets()
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

--- ── The tool-sandbox hull ───────────────────────────────────────────────────

-- What a preset without a sandbox section means: the project, read-write,
-- no network. Explicit binds REPLACE this (they do not extend it), so a
-- preset binding only /data genuinely excludes the project.
local DEFAULT_BINDS = { { path = PROJECT_TOKEN, mode = "rw" } }

--- The kernel hull TOOL invocations run under (design-agent-sandbox-v2):
--- binds with `${project}` expanded now, modes defaulted, plus the network
--- flag. Consumed by the task/tool spawn path on EVERY invocation, so an
--- active-preset switch or (later) an elevation grant applies to the next
--- spawn with no restart anywhere.
--- @param preset? weave.permissions.Preset default: the active one
--- @return { binds: weave.permissions.SandboxBind[], network: boolean }
function M.tool_sandbox(preset)
  preset = preset or M.active()
  local section = preset.sandbox or {}
  local binds = {}
  for i, b in ipairs(section.binds or DEFAULT_BINDS) do
    binds[i] = { path = expand(b.path), mode = b.mode or "rw" }
  end
  -- Elevation grants sit ON TOP of the preset's hull, exactly like the rule
  -- overlay sits on top of its rules: session-scoped, revocable, never
  -- rewriting the preset.
  for _, b in ipairs(bind_overlay) do
    binds[#binds + 1] = { path = expand(b.path), mode = b.mode or "rw" }
  end
  return { binds = binds, network = section.network == true or network_granted }
end

--- Does a bind's path plausibly reach a resource glob's static prefix?
--- Prefix containment with a path-boundary guard: /a/b covers /a/b/c and
--- /a/b, never /a/bc.
local function bind_covers(bind, prefix)
  local function contains(outer, inner)
    if inner:sub(1, #outer) ~= outer then
      return false
    end
    local nxt = inner:sub(#outer + 1, #outer + 1)
    return nxt == "" or nxt == "/" or outer:sub(-1) == "/"
  end
  return contains(bind, prefix) or contains(prefix, bind)
end

--- Rules and binds are orthogonal by design, which leaves one confusing
--- combination: a non-deny rule whose resource no bind can reach — the gate
--- says yes, the tool then dies at the kernel wall. Flag it at definition
--- time instead of letting it read as a tool bug at call time. A heuristic
--- (static glob prefixes, path-shaped resources only — command strings and
--- buffer refs are not filesystem places), so it WARNS, never errors.
--- @param preset weave.permissions.Preset
--- @return string[] warnings
function M.lint_preset(preset)
  local warnings = {}
  local hull = M.tool_sandbox(preset)
  local home = vim.uv.os_homedir() or ""
  local function norm(p)
    return (home ~= "" and p:gsub("^~", home)) or p
  end
  for i, rule in ipairs(preset.rules or {}) do
    if rule.resource ~= nil and rule.decision ~= "deny" then
      local res = norm(expand(rule.resource))
      if res:sub(1, 1) == "/" then
        local prefix = res:match("^([^*?]*)")
        local reachable = false
        for _, b in ipairs(hull.binds) do
          if bind_covers(norm(b.path), prefix) then
            reachable = true
            break
          end
        end
        if not reachable then
          warnings[#warnings + 1] = ("rule %d (%s %s): resource %q lies outside every sandbox bind"):format(
            i,
            rule.decision,
            rule.tool,
            rule.resource
          )
        end
      end
    end
  end
  return warnings
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
  if #overlay == 0 and #bind_overlay == 0 and not network_granted then
    return
  end
  overlay = {}
  bind_overlay = {}
  network_granted = false
  notify()
end

--- ── Elevation grants (design-agent-sandbox-v2.md, phase H) ──────────────────
---
--- The bind-shaped counterpart of the rule overlay: session-scoped widenings
--- of the TOOL sandboxes, granted through w:request_access. They apply on
--- the very next tool spawn (hulls are re-derived per invocation) — no
--- restart anywhere, which is the entire point of confining tools instead
--- of the agent process.

--- @return weave.permissions.SandboxBind[] a copy; mutate through add/revoke
function M.bind_grants()
  local out = {}
  for i, b in ipairs(bind_overlay) do
    out[i] = { path = b.path, mode = b.mode }
  end
  return out
end

--- @param bind weave.permissions.SandboxBind
function M.add_bind_grant(bind)
  if type(bind) ~= "table" or type(bind.path) ~= "string" or bind.path == "" then
    error("weave.permissions: a bind grant needs a `path`", 0)
  end
  if bind.mode ~= nil and bind.mode ~= "rw" and bind.mode ~= "ro" then
    error("weave.permissions: bind grant `mode` must be rw/ro", 0)
  end
  bind_overlay[#bind_overlay + 1] = { path = bind.path, mode = bind.mode or "rw" }
  notify()
end

--- @param index integer 1-based, as listed by bind_grants()
function M.revoke_bind_grant(index)
  if not bind_overlay[index] then
    error(("weave.permissions: no bind grant at index %d"):format(index), 0)
  end
  table.remove(bind_overlay, index)
  notify()
end

--- @return boolean
function M.network_granted()
  return network_granted
end

--- @param granted boolean
function M.set_network_granted(granted)
  if network_granted == granted then
    return
  end
  network_granted = granted
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
--- Surface lint findings for a preset entering the engine. Advisory only
--- (design-agent-sandbox-v2 open question 6 resolved as warn-not-error): the
--- preset still lands, the user learns why a gate-allowed tool would fail.
--- @param preset weave.permissions.Preset
local function warn_lint(preset)
  for _, w in ipairs(M.lint_preset(preset)) do
    vim.notify(("weave: preset %q: %s"):format(preset.name, w), vim.log.levels.WARN)
  end
end

function M.save_preset(preset)
  validate(preset)
  warn_lint(preset)
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
    warn_lint(p)
    setup_presets[#setup_presets + 1] = own(p, "setup")
  end
  if cfg.preset then
    if not M.get(cfg.preset) then
      error(("weave.permissions: unknown active preset %q in setup"):format(cfg.preset), 0)
    end
    active_name = cfg.preset
  elseif M.current_mode() == "on" and M.get("sandboxed_" .. active_name) then
    -- The sandbox is on and the user expressed no preference: default to the
    -- matching sandboxed variant, since the plain ones exempt weave's own
    -- tools from the confinement the sandbox was turned on for.
    active_name = "sandboxed_" .. active_name
  end
  notify()
end

-- test hook: back to the shipped state
function M._reset()
  setup_presets = {}
  runtime_presets = {}
  overlay = {}
  bind_overlay = {}
  network_granted = false
  active_name = "normal"
  project_root = nil
  current_mode = nil
  subscribers = {}
end

return M
