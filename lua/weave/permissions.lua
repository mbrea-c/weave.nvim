-- Permission definitions are reusable templates. Runtime policy and grants
-- belong to an engine instance, never to the currently selected editor tab.
local Engine = require("weave.permissions.engine")
local M = Engine.new(false)
local stores = setmetatable({}, { __mode = "k" })

function M.for_session(session)
  if session and session.permissions then return session:permissions() end
  return M
end

function M.for_store(store)
  return stores[store] or M
end

function M.bind(store, policy)
  stores[store] = policy
end

--- A detached permission instance, inheriting a snapshot of the base policy.
--- Explicit rules precede the preset's rules; sandbox keys replace selectively.
function M.new(opts, base)
  opts, base = opts or {}, base or M
  local engine = Engine.new(true, M)
  local mode, inherited = base.current_mode(), base.active().name
  engine.set_mode(mode)
  engine.set_project_root(base.project_root())
  if not base.preset_allowed(base.active(), mode) then
    inherited = mode == "off" and ("unsandboxed_" .. inherited) or inherited:match("^unsandboxed_(.+)$")
    if not inherited or not base.get(inherited) then inherited = nil end
  end
  if opts.preset ~= nil then
    engine.set_active(opts.preset)
  elseif base.preset_allowed(base.active(), mode) then
    engine.use_snapshot(base.active())
  elseif inherited then
    engine.set_active(inherited)
  end
  local preset = vim.deepcopy(engine.active())
  if opts.rules ~= nil then
    if type(opts.rules) ~= "table" then error("permissions.rules must be a list", 0) end
    preset.rules = vim.list_extend(vim.deepcopy(opts.rules), preset.rules or {})
  end
  if opts.sandbox ~= nil then
    if type(opts.sandbox) ~= "table" then error("permissions.sandbox must be a table", 0) end
    preset.sandbox = preset.sandbox or {}
    for key, value in pairs(opts.sandbox) do
      if key == "tools" and type(value) == "table" then
        preset.sandbox.tools = preset.sandbox.tools or {}
        for tool, override in pairs(value) do
          preset.sandbox.tools[tool] = vim.tbl_extend("force", preset.sandbox.tools[tool] or {}, vim.deepcopy(override))
        end
      else
        preset.sandbox[key] = vim.deepcopy(value)
      end
    end
  end
  if opts.rules ~= nil or opts.sandbox ~= nil then
    preset.source = "session"
    engine.use_snapshot(preset)
  end
  -- Selecting a different profile starts from that profile, not old grants.
  if opts.preset == nil then
    for _, rule in ipairs(base.grants()) do engine.add_grant(rule) end
    for _, bind in ipairs(base.bind_grants()) do engine.add_bind_grant(bind) end
    engine.set_network_granted(base.network_granted())
    engine.set_tool_sandbox_disabled(base.tool_sandbox_disabled())
  end
  function engine.snapshot()
    return {
      preset = engine.active().name, effective = vim.deepcopy(engine.active()),
      grants = engine.grants(), bind_grants = engine.bind_grants(),
      network_granted = engine.network_granted(), tool_sandbox_disabled = engine.tool_sandbox_disabled(),
      mode = engine.current_mode(), project_root = engine.project_root(),
    }
  end
  return engine
end

return M
