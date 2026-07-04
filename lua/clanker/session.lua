-- A Session: one conversation with an ACP agent. Owns the store, the live
-- ACP client + session id, and all turn/queue/steer/cancel/config logic —
-- ported from agentic's reactive/session.lua. It does NOT own a view: the
-- panel binds to this session's store and forwards user actions through
-- view_handlers().
--
--   AgentInstance (spawn/reuse client)
--     → create_session(bridge handlers)        -- agent → store
--     → store is the single source of truth    -- store → panel projections
--     → submit/steer/cancel                    -- user (via the panel) → agent
--
-- Session restore (load_session + the discovery picker) is deferred — it
-- needs the session_source port (tracker: R5 leftovers).

local AcpBridge = require("clanker.acp_bridge")
local AgentInstance = require("clanker.acp.agent_instance")
local Config = require("clanker.config")
local Logger = require("clanker.utils.logger")
local SessionStore = require("clanker.session_store")

--- A selectable session option (model or mode), normalised across the Kiro
--- legacy shape (models/modes) and the ACP standard (configOptions).
--- @class clanker.session.Option
--- @field id string Value sent to the agent
--- @field label string Human label for the picker

--- Normalised model/mode config captured at session creation. `set(id)` knows
--- whether to call set_model/set_mode (Kiro) or set_config_option (ACP).
--- @class clanker.session.ConfigKind
--- @field current? string
--- @field available clanker.session.Option[]
--- @field set fun(id: string, cb: fun(ok: boolean)): nil

--- @class clanker.Session
--- @field _store clanker.store.SessionStore
--- @field _client? table ACPClient (or an injected double)
--- @field _session_id? string
--- @field _provider_name string
--- @field _get_instance fun(provider: string, on_ready: fun(client: table)): table|nil
--- @field _turn_active boolean Whether a prompt turn is currently in flight
--- @field _steer_text? string Prompt to resend once a steered turn ends as cancelled
--- @field _config { model?: clanker.session.ConfigKind, mode?: clanker.session.ConfigKind }
local Session = {}
Session.__index = Session

--- @param opts { provider?: string, get_instance?: fun(provider: string, on_ready: fun(client: table)): table|nil }|nil
---   get_instance is injectable so specs can script the client; defaults to
---   AgentInstance.get_instance (spawn or reuse the provider process).
--- @return clanker.Session session
function Session:new(opts)
  opts = opts or {}
  return setmetatable({
    _store = SessionStore:new(),
    _client = nil,
    _session_id = nil,
    _provider_name = opts.provider or Config.provider,
    _get_instance = opts.get_instance or AgentInstance.get_instance,
    _turn_active = false,
    _steer_text = nil,
    _config = {},
  }, Session)
end

--- The store backing this session; the panel binds to it.
--- @return clanker.store.SessionStore
function Session:get_store()
  return self._store
end

--- Whether the ACP session is up (client connected + session created).
--- @return boolean
function Session:is_ready()
  return self._client ~= nil and self._session_id ~= nil
end

--- The callback table wiring a panel's user actions to this session.
--- @return table callbacks panel.open-compatible
function Session:view_handlers()
  return {
    on_submit = function(text)
      self:submit(text)
    end,
    on_steer = function(text)
      self:steer(text)
    end,
    on_cancel = function()
      self:cancel()
    end,
    on_permission = function(index)
      self:respond_permission(index)
    end,
    on_cycle_permission_mode = function()
      self:cycle_permission_mode()
    end,
    on_pick_model = function()
      self:show_config_picker("model")
    end,
    on_pick_mode = function()
      self:show_config_picker("mode")
    end,
  }
end

--- Cycle the permission mode (Normal → Auto → Allow-edits → …) and notify.
function Session:cycle_permission_mode()
  local mode = self._store:cycle_permission_mode()
  Logger.notify("Permission mode: " .. (SessionStore.PERMISSION_MODE_LABEL[mode] or mode), vim.log.levels.INFO)
end

--- Connect to the provider and create the ACP session. Status is "busy"
--- until the session is ready.
function Session:start()
  self._store:set_status("busy")

  local client = self._get_instance(self._provider_name, function(c)
    vim.schedule(function()
      self:_on_client_ready(c)
    end)
  end)

  if not client then
    self._store:set_status("idle")
    self._store:append_entry({
      kind = "agent",
      text = "⚠️ Could not start provider '" .. self._provider_name .. "'.",
    })
    return
  end

  self._client = client
end

--- @private
--- @param client table
function Session:_on_client_ready(client)
  if client.state == "error" or client.state == "disconnected" then
    self._store:set_status("idle")
    self._store:append_entry({
      kind = "agent",
      text = "⚠️ Failed to connect to " .. self._provider_name .. ".",
    })
    return
  end

  client:create_session(self:_build_handlers(), function(response, err)
    vim.schedule(function()
      self._store:set_status("idle")

      if err or not response then
        self._store:append_entry({
          kind = "agent",
          text = "⚠️ Session creation failed: " .. (err and err.message or "unknown"),
        })
        return
      end

      self._session_id = response.sessionId
      Logger.debug("session ready " .. response.sessionId)
      self:_capture_config(response)
      self:_publish_meta()
    end)
  end, self:_resolve_mcp_servers())
end

--- Surface session metadata in the sidebar: provider display name from
--- config, agent name+version from the client, model/mode from the captured
--- config.
--- @private
function Session:_publish_meta()
  local provider_cfg = Config.acp_providers[self._provider_name]
  local agent_info = self._client.agent_info
  local agent = agent_info and agent_info.name or self._provider_name
  if agent_info and agent_info.version then
    agent = agent .. " v" .. agent_info.version
  end
  self._store:set_meta({
    provider = provider_cfg and provider_cfg.name or self._provider_name,
    agent = agent,
    model = self._config.model and self._config.model.current,
    mode = self._config.mode and self._config.mode.current,
    session_id = self._session_id,
  })
end

--- Show a picker for a config kind ("model" | "mode") and apply the choice
--- via its captured `set` closure, updating the sidebar meta on success.
--- @param kind "model" | "mode"
function Session:show_config_picker(kind)
  local cfg = self._config[kind]
  if not cfg or #cfg.available == 0 then
    Logger.notify("No selectable " .. kind .. " for this provider/session.", vim.log.levels.INFO)
    return
  end

  vim.ui.select(cfg.available, {
    prompt = "Select " .. kind .. ":",
    format_item = function(item)
      local marker = item.id == cfg.current and "● " or "  "
      return marker .. item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    cfg.set(choice.id, function(ok)
      vim.schedule(function()
        if not ok then
          Logger.notify("Failed to set " .. kind .. ".", vim.log.levels.ERROR)
          return
        end
        cfg.current = choice.id
        self._store:set_meta({ [kind] = choice.label })
      end)
    end)
  end)
end

--- Capture selectable model/mode options from a session-creation response,
--- normalising the two provider shapes:
---   * Kiro legacy: response.models / response.modes (availableX + currentX),
---     changed via set_model / set_mode.
---   * ACP standard: response.configOptions[] with category model|mode,
---     changed via set_config_option.
--- Each kind's `set(id, cb)` closure reads self._session_id at CALL time —
--- config is process-level and may outlive the session it was captured from.
--- @private
--- @param response table SessionCreationResponse
function Session:_capture_config(response)
  local config = {}

  if response.models then
    local available = {}
    for _, m in ipairs(response.models.availableModels or {}) do
      available[#available + 1] = { id = m.modelId, label = m.name }
    end
    config.model = {
      current = response.models.currentModelId,
      available = available,
      set = function(id, cb)
        self._client:set_model(self._session_id, id, function(_r, err)
          cb(not err)
        end)
      end,
    }
  end

  if response.modes then
    local available = {}
    for _, m in ipairs(response.modes.availableModes or {}) do
      available[#available + 1] = { id = m.id, label = m.name }
    end
    config.mode = {
      current = response.modes.currentModeId,
      available = available,
      set = function(id, cb)
        self._client:set_mode(self._session_id, id, function(_r, err)
          cb(not err)
        end)
      end,
    }
  end

  for _, opt in ipairs(response.configOptions or {}) do
    local category = opt.category
    if category == "model" or category == "mode" then
      local available = {}
      for _, o in ipairs(opt.options or {}) do
        available[#available + 1] = { id = o.value, label = o.name }
      end
      local config_id = opt.id
      config[category] = {
        current = opt.currentValue,
        available = available,
        set = function(id, cb)
          self._client:set_config_option(self._session_id, config_id, id, function(_r, err)
            cb(not err)
          end)
        end,
      }
    end
  end

  self._config = config
end

--- @private
--- @return table handlers clanker.acp.ClientHandlers
function Session:_build_handlers()
  return AcpBridge.build_handlers(self._store, {})
end

--- Resolve the MCP servers to hand the agent at session creation. A
--- provider's own `mcpServers` OVERRIDES the global `config.mcp_servers`
--- (not merged). Each server's env gets $NVIM (this editor's socket)
--- injected — per-server, NOT on the agent's process env (Kiro treats a set
--- $NVIM as "inside a Neovim terminal" and exits).
--- @private
--- @return table[] servers
function Session:_resolve_mcp_servers()
  local provider_cfg = Config.acp_providers[self._provider_name]
  local servers = (provider_cfg and provider_cfg.mcpServers) or Config.mcp_servers or {}

  local socket = vim.v.servername
  if not socket or socket == "" then
    return servers
  end

  local resolved = {}
  for _, srv in ipairs(servers) do
    local env = {}
    local has_nvim = false
    for _, e in ipairs(srv.env or {}) do
      env[#env + 1] = e
      if e.name == "NVIM" then
        has_nvim = true
      end
    end
    if not has_nvim then
      env[#env + 1] = { name = "NVIM", value = socket }
    end
    resolved[#resolved + 1] = { name = srv.name, command = srv.command, args = srv.args, env = env }
  end
  return resolved
end

--- Submit prompt text. ACP turns are sequential per session, so a prompt sent
--- while a turn is in flight is QUEUED (shown in the transcript) and sent
--- automatically when the current turn ends. To interrupt instead, steer().
--- @param text string
function Session:submit(text)
  -- Intercept /new BEFORE the readiness/turn guards so the user can always
  -- start fresh, even mid-generation.
  if text:match("^/new%s*$") then
    self:new_conversation()
    return
  end

  if not self:is_ready() then
    Logger.notify("Session not ready yet — wait for the agent to connect.", vim.log.levels.WARN)
    return
  end

  if self._turn_active then
    self._store:enqueue_prompt(text)
    return
  end

  self:_send_now(text)
end

--- Interrupt the in-flight turn and send `text` instead. Over ACP this is
--- cancel-then-resend: there is no mid-turn injection. With no turn active,
--- this is just a submit.
--- @param text string
function Session:steer(text)
  if not self:is_ready() then
    return self:submit(text)
  end
  if not self._turn_active then
    return self:_send_now(text)
  end

  self._steer_text = text
  self:_cancel_turn()
end

--- Explicitly cancel the in-flight turn with no resend, and drop any queued
--- prompts. Resolves pending permissions as cancelled (ACP requirement).
function Session:cancel()
  self._steer_text = nil
  self._store:clear_queue()
  if self._turn_active then
    self:_cancel_turn()
  end
end

--- Respond to the HEAD permission by 1-based option index (as numbered in
--- the sidebar). Pops the head, promoting the next queued request.
--- @param index integer
function Session:respond_permission(index)
  local pending = self._store:get_permission()
  if not pending then
    return
  end
  local option = pending.request.options[index]
  if not option then
    Logger.notify("No permission option #" .. index .. ".", vim.log.levels.WARN)
    return
  end
  self._store:pop_permission()
  pending.respond(option.optionId)
end

--- Cancel the current turn while keeping the session subscribed. Per the ACP
--- spec, ALL pending permission requests must be answered `cancelled` on
--- cancel — drain the whole queue, not just the head.
--- @private
function Session:_cancel_turn()
  self._store:drain_permissions()
  self._client:cancel_turn(self._session_id)
  self._store:set_status("idle")
end

--- Echo a user message and drive a turn via send_prompt. Marks the turn
--- active; the send_prompt callback (turn end / stopReason) clears it and
--- drains the queue or fires a pending steer.
--- @private
--- @param text string
function Session:_send_now(text)
  self._store:append_entry({ kind = "user", text = text })
  self._store:set_status("thinking")
  self._turn_active = true

  local prompt = { { type = "text", text = text } }
  local session_id = self._session_id

  self._client:send_prompt(session_id, prompt, function(_response, err)
    vim.schedule(function()
      -- Ignore stale turns from a previous session (e.g. after /new).
      if self._session_id ~= session_id then
        return
      end
      self:_on_turn_end(err)
    end)
  end)
end

--- Turn-end handler: clears the active flag, reports errors, rotates the
--- sidebar hint, then either resends a steered prompt or drains the queue.
--- @private
--- @param err table|nil ACPError
function Session:_on_turn_end(err)
  self._turn_active = false
  self._store:set_status("idle")
  self._store:rotate_hint()

  if err then
    self._store:append_entry({
      kind = "agent",
      text = "🐞 Turn failed: " .. (err.message or vim.inspect(err)),
    })
  end

  -- A steered prompt takes priority over the queue: the user interrupted to
  -- send THIS now. Then fall through to draining queued prompts in order.
  local steer_text = self._steer_text
  self._steer_text = nil
  if steer_text then
    self:_send_now(steer_text)
    return
  end

  local next_prompt = self._store:dequeue_prompt()
  if next_prompt then
    self:_send_now(next_prompt)
  end
end

--- Stop the conversation: cancel the ACP session. Does NOT touch views.
function Session:stop()
  if self._client and self._session_id then
    self._client:cancel_session(self._session_id)
  end
  self._session_id = nil
end

--- Start a fresh conversation in place (the `/new` command): cancel the
--- current ACP session, clear the transcript (meta persists — it belongs to
--- the client), and create a new ACP session on the same client.
function Session:new_conversation()
  if not self._client then
    Logger.notify("Provider not ready yet — try again in a moment.", vim.log.levels.WARN)
    return
  end

  if self._session_id then
    self._client:cancel_session(self._session_id)
  end
  self._session_id = nil
  self._turn_active = false
  self._steer_text = nil
  self._store:reset()
  self._store:set_status("busy")

  self._client:create_session(self:_build_handlers(), function(response, err)
    vim.schedule(function()
      self._store:set_status("idle")
      if err or not response then
        self._store:append_entry({
          kind = "agent",
          text = "⚠️ New session failed: " .. (err and err.message or "unknown"),
        })
        return
      end
      self._session_id = response.sessionId
      self:_capture_config(response)
      self._store:set_meta({ session_id = response.sessionId })
    end)
  end, self:_resolve_mcp_servers())
end

return Session
