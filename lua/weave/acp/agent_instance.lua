-- According to the ACP protocol, a single agent process can handle multiple
-- sessions. A session is an isolated conversation with its own state and
-- context. We should NOT spawn a process per session, but create new sessions
-- against an existing one.
-- Documentation for reference: https://agentclientprotocol.com/protocol/session-setup.md
--
-- The unit of reuse is therefore (provider, sandbox mode), not provider
-- alone. The bwrap argv is frozen at spawn, so a process cannot change
-- confinement: two sessions of the same provider at different modes are
-- two genuinely different runtime environments and must not share. Keying
-- on the pair is what makes "start a sandboxed session while another runs
-- unsandboxed" mean what it says, instead of silently joining the loose
-- process. A mode that DEGRADES (no bwrap on this platform) resolves to
-- `off` before keying, so the degraded case still shares one process.

local Config = require("weave.config")
local Logger = require("weave.utils.logger")
local ACPClient = require("weave.acp.acp_client")

--- @class weave.acp.AgentInstance
--- @field chat_widget weave.ui.ChatWidget
--- @field agent_client weave.acp.ACPClient

--- @class weave.acp.AgentInstance
local AgentInstance = {}

--- Agent processes, keyed provider -> resolved mode -> client.
--- @private
--- @type table<weave.UserConfig.ProviderName, table<string, weave.acp.ACPClient>>
AgentInstance._instances = {}

--- Sandbox modes chosen for a session rather than configured: the bwrap
--- argv is built once at spawn, so a mode change can only take effect on
--- the NEXT process. Keyed by provider; a nil key is the default applied to
--- every provider without one of its own.
--- @private
--- @type table<string|boolean, string>
AgentInstance._mode_overrides = {}

--- Spawn seam (specs script it; the default is the real transport).
--- @param config table
--- @param on_ready fun(client: weave.acp.ACPClient)|nil
--- @return weave.acp.ACPClient
local function default_spawn(config, on_ready)
  return ACPClient:new(config, on_ready)
end
AgentInstance._spawn = default_spawn

--- Override the sandbox mode the next spawn of `provider_name` uses (nil
--- provider = all of them). See weave.mode_transition, which pairs this
--- with a fresh session.
--- @param provider_name string|nil
--- @param mode string|nil nil clears the override
function AgentInstance.set_mode_override(provider_name, mode)
  AgentInstance._mode_overrides[provider_name or true] = mode
end

--- @param provider_name string
--- @return string|nil
local function mode_override(provider_name)
  local o = AgentInstance._mode_overrides
  return o[provider_name] or o[true]
end

--- The provider config a spawn would use, with any mode override folded in.
--- @param provider_name string
--- @return table|nil
local function spawn_config(provider_name)
  local config = Config.acp_providers[provider_name]
  if not config then
    return nil
  end
  local override = mode_override(provider_name)
  if override then
    config = vim.tbl_extend("force", config, {
      sandbox = vim.tbl_extend("force", config.sandbox or {}, { mode = override }),
    })
  end
  return config
end

--- The mode a spawn of `provider_name` would actually RUN at: resolved
--- through weave.sandbox, so a configured mode that degrades on this
--- platform keys as `off` rather than pretending to be its own environment.
--- @param provider_name string
--- @return string
function AgentInstance.resolved_mode(provider_name)
  local config = spawn_config(provider_name)
  local ok, Sandbox = pcall(require, "weave.sandbox")
  if not ok then
    return "off"
  end
  local resolved = Sandbox.resolve(config and config.sandbox or nil)
  return resolved and resolved.mode or "off"
end

--- The live process for a (provider, mode) pair, if there is one.
--- @param provider_name string
--- @param mode string
--- @return weave.acp.ACPClient|nil
function AgentInstance.instance(provider_name, mode)
  local by_mode = AgentInstance._instances[provider_name]
  return by_mode and by_mode[mode] or nil
end

--- Stop and forget a provider's process(es): one mode's when `mode` is
--- given, all of them otherwise.
--- @param provider_name string
--- @param mode string|nil
function AgentInstance.stop(provider_name, mode)
  local by_mode = AgentInstance._instances[provider_name]
  if not by_mode then
    return
  end
  for m, client in pairs(by_mode) do
    if mode == nil or m == mode then
      by_mode[m] = nil
      pcall(function()
        client:stop()
      end)
    end
  end
  if next(by_mode) == nil then
    AgentInstance._instances[provider_name] = nil
  end
end

--- Every client some live session still talks to. Overridable seam: the
--- registry is a soft dependency here (specs drive AgentInstance alone).
--- @return table<any, boolean>
local function default_live_clients()
  local live = {}
  local ok, Registry = pcall(require, "weave.registry")
  if not ok then
    return live
  end
  for _, entry in ipairs(Registry.list()) do
    local client = entry.session and entry.session.client and entry.session:client()
    if client then
      live[client] = true
    end
  end
  return live
end
AgentInstance._live_clients = default_live_clients

--- Stop any process no live session is using. Keying by mode means a
--- transition leaves the old process behind rather than killing it out from
--- under sessions that are still happily using it; this is what eventually
--- collects it, once they are gone.
function AgentInstance.reap()
  local live = AgentInstance._live_clients()
  for provider, by_mode in pairs(AgentInstance._instances) do
    for mode, client in pairs(by_mode) do
      if not live[client] then
        by_mode[mode] = nil
        pcall(function()
          client:stop()
        end)
      end
    end
    if next(by_mode) == nil then
      AgentInstance._instances[provider] = nil
    end
  end
end

--- @param provider_name weave.UserConfig.ProviderName
--- @param on_ready fun(client: weave.acp.ACPClient)|nil
function AgentInstance.get_instance(provider_name, on_ready)
  local mode = AgentInstance.resolved_mode(provider_name)
  local client = AgentInstance.instance(provider_name, mode)

  if client then
    if on_ready then
      on_ready(client)
    end
    return client
  end

  local config = spawn_config(provider_name)

  if not config then
    error("No ACP provider configuration found for: " .. provider_name)
    return nil
  end

  Logger.debug(("Creating new ACP agent instance for provider %s (sandbox %s)"):format(provider_name, mode))

  client = AgentInstance._spawn(config, on_ready)
  AgentInstance._instances[provider_name] = AgentInstance._instances[provider_name] or {}
  AgentInstance._instances[provider_name][mode] = client

  return client
end

--- Cleanup all active instances and processes
--- This is called automatically on VimLeavePre and signal handlers
--- Can also be called manually if needed
function AgentInstance:cleanup_all()
  for _name, by_mode in pairs(self._instances) do
    for _mode, instance in pairs(by_mode) do
      if instance then
        pcall(function()
          instance:stop()
        end)
      end
    end
  end

  self._instances = {}
end

-- test hook: back to the real seams
function AgentInstance._reset()
  AgentInstance._spawn = default_spawn
  AgentInstance._live_clients = default_live_clients
end

return AgentInstance
