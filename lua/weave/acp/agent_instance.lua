-- According to the ACP protocol, a single agent process can handle multiple sessions.
-- A session is an isolated conversation with its own state and and context.
-- This file maintain one Agent process per provider.
-- We should NOT spawn multiple agent processes, but create new sessions instead.
-- Documentation for reference: https://agentclientprotocol.com/protocol/session-setup.md

local Config = require("weave.config")
local Logger = require("weave.utils.logger")
local ACPClient = require("weave.acp.acp_client")

--- @class weave.acp.AgentInstance
--- @field chat_widget weave.ui.ChatWidget
--- @field agent_client weave.acp.ACPClient

--- @class weave.acp.AgentInstance
local AgentInstance = {}

--- A Keyed list of agent instances by name
--- @private
--- @type table<weave.UserConfig.ProviderName, weave.acp.ACPClient|nil>
AgentInstance._instances = {}

--- Sandbox profiles chosen for a session rather than configured: the bwrap
--- argv is built once at spawn, so a profile change can only take effect on
--- the NEXT process. Keyed by provider; a nil key is the default applied to
--- every provider without one of its own.
--- @private
--- @type table<string|boolean, string>
AgentInstance._profile_overrides = {}

--- Override the sandbox profile the next spawn of `provider_name` uses (nil
--- provider = all of them). See weave.profile_transition, which pairs this
--- with a stop() and a fresh session.
--- @param provider_name string|nil
--- @param profile string|nil nil clears the override
function AgentInstance.set_profile_override(provider_name, profile)
  AgentInstance._profile_overrides[provider_name or true] = profile
end

--- @param provider_name string
--- @return string|nil
local function profile_override(provider_name)
  local o = AgentInstance._profile_overrides
  return o[provider_name] or o[true]
end

--- Stop and forget one provider's process, so the next get_instance spawns
--- fresh (and therefore picks up a new sandbox profile).
--- @param provider_name string
function AgentInstance.stop(provider_name)
  local client = AgentInstance._instances[provider_name]
  if not client then
    return
  end
  AgentInstance._instances[provider_name] = nil
  pcall(function()
    client:stop()
  end)
end

--- @param provider_name weave.UserConfig.ProviderName
--- @param on_ready fun(client: weave.acp.ACPClient)
function AgentInstance.get_instance(provider_name, on_ready)
  local client = AgentInstance._instances[provider_name]

  if client then
    -- One process per provider, so a session joining a RUNNING agent gets
    -- that agent's profile, not the one just requested. Say so rather than
    -- letting the UI imply a confinement the process does not have.
    local want = profile_override(provider_name)
    if want and client.sandbox_profile and want ~= client.sandbox_profile then
      Logger.notify(
        ("weave: %s is already running under sandbox profile %q; the new session joins it (close the other sessions first to respawn)"):format(
          provider_name,
          client.sandbox_profile
        ),
        vim.log.levels.WARN
      )
    end
    if on_ready then
      on_ready(client)
    end
    return client
  end

  local config = Config.acp_providers[provider_name]

  if not config then
    error("No ACP provider configuration found for: " .. provider_name)
    return nil
  end

  Logger.debug("Creating new ACP agent instance for provider: " .. provider_name)

  local override = profile_override(provider_name)
  if override then
    config = vim.tbl_extend("force", config, {
      sandbox = vim.tbl_extend("force", config.sandbox or {}, { profile = override }),
    })
  end

  client = ACPClient:new(config, on_ready)
  AgentInstance._instances[provider_name] = client

  return client
end

--- Cleanup all active instances and processes
--- This is called automatically on VimLeavePre and signal handlers
--- Can also be called manually if needed
function AgentInstance:cleanup_all()
  for _name, instance in pairs(self._instances) do
    if instance then
      pcall(function()
        instance:stop()
      end)
    end
  end

  self._instances = {}
end

return AgentInstance
