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
-- Session restore is ACP-native only (session/list + session/load), matching
-- upstream agentic's final shape: providers without listing support get a
-- notify from the client's capability check — there is no local persistence
-- fallback to fall back to.

local AcpBridge = require("weave.acp_bridge")
local AgentInstance = require("weave.acp.agent_instance")
local Config = require("weave.config")
local FileSystem = require("weave.utils.file_system")
local Logger = require("weave.utils.logger")
local SessionSource = require("weave.session_source")
local SessionStore = require("weave.session_store")

--- A selectable session option (model or mode), normalised across the Kiro
--- legacy shape (models/modes) and the ACP standard (configOptions).
--- @class weave.session.Option
--- @field id string Value sent to the agent
--- @field label string Human label for the picker

--- One selectable config kind captured at session creation: the Kiro legacy
--- pair (model/mode) or ANY ACP configOption category (model, mode,
--- thought_level, ...). `set(id)` knows whether to call set_model/set_mode
--- (Kiro) or set_config_option (ACP).
--- @class weave.session.ConfigKind
--- @field key string category key ("model", "mode", "thought_level", ...)
--- @field label string human label for the kind ("Model", "Thinking effort")
--- @field current? string
--- @field available weave.session.Option[]
--- @field set fun(id: string, cb: fun(ok: boolean)): nil

--- @class weave.Session
--- @field _store weave.store.SessionStore
--- @field _client? table ACPClient (or an injected double)
--- @field _session_id? string
--- @field _provider_name string
--- @field _get_instance fun(provider: string, on_ready: fun(client: table)): table|nil
--- @field _turn_active boolean Whether a prompt turn is currently in flight
--- @field _steer_queue weave.session.Message[] Messages to send once a steered turn ends as cancelled, in arrival order (never a scalar slot: two interruptions can land on one dying turn)
--- @field _cancelling boolean A cancel is already in flight for the current turn
--- @field _restoring boolean Whether a session/load history replay is in flight
--- @field _steered_session? string ACP session id already given the mode-on steering note
--- @field _config table<string, weave.session.ConfigKind> by category key
--- @field _config_order string[] category keys in capture order
local Session = {}
Session.__index = Session

--- @param opts { provider?: string, get_instance?: fun(provider: string, on_ready: fun(client: table)): table|nil }|nil
---   get_instance is injectable so specs can script the client; defaults to
---   AgentInstance.get_instance (spawn or reuse the provider process).
--- @return weave.Session session
function Session:new(opts)
  opts = opts or {}
  local session = setmetatable({
    _store = SessionStore:new(),
    _client = nil,
    _session_id = nil,
    _provider_name = opts.provider or Config.provider,
    _get_instance = opts.get_instance or AgentInstance.get_instance,
    _turn_active = false,
    _steer_queue = {},
    _cancelling = false,
    _restoring = false,
    _config = {},
    _config_order = {},
  }, Session)
  -- A drain held back by an in-progress edit (dequeue_prompt refuses while
  -- the edited entry is at the head) resumes here: when the box releases (or
  -- moves to another entry), pick the queue back up. Deferred so the drain
  -- never runs inside another mutation's notify.
  local prev_editing
  session._store:subscribe(function(state)
    local now = state.editing_queued
    if now ~= prev_editing then
      prev_editing = now
      vim.schedule(function()
        session:_drain_queue()
      end)
    end
  end)
  return session
end

--- The store backing this session; the panel binds to it.
--- @return weave.store.SessionStore
function Session:get_store()
  return self._store
end

--- Whether the ACP session is up (client connected + session created).
--- @return boolean
function Session:is_ready()
  return self._client ~= nil and self._session_id ~= nil
end

--- The ACP client behind this session, for callers that need to read the
--- provider's capabilities (e.g. loadSession before an agent restart).
--- @return weave.acp.ACPClient|nil
function Session:client()
  return self._client
end

--- The live ACP session id, or nil before session/new has answered.
--- @return string|nil
function Session:session_id()
  return self._session_id
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
    on_restore_picker = function()
      self:show_restore_picker()
    end,
    on_toggle_tutor = function()
      require("weave.tutor").toggle(self)
    end,
  }
end

--- Cycle the active permission preset (editor-global, weave.permissions) and
--- notify. Kept under the historical action name: ;;p used to cycle the
--- session-level permission MODE, which the presets re-encode.
function Session:cycle_permission_mode()
  local preset = require("weave.permissions").cycle()
  Logger.notify("Permission preset: " .. (preset.label or preset.name), vim.log.levels.INFO)
end

--- Connect to the provider and create the ACP session — or, with
--- opts.restore, LOAD that saved session instead (activating a saved
--- conversation into a fresh Session: same connect, session/load in place of
--- session/new). Status is "busy" until the session is ready.
--- @param opts { restore?: string }|nil restore = saved ACP session id
function Session:start(opts)
  local restore = opts and opts.restore
  self._store:set_status("busy")

  local client = self._get_instance(self._provider_name, function(c)
    vim.schedule(function()
      self:_on_client_ready(c, restore)
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
--- @param restore string|nil saved session id to load instead of creating
function Session:_on_client_ready(client, restore)
  if client.state == "error" or client.state == "disconnected" then
    self._store:set_status("idle")
    self._store:append_entry({
      kind = "agent",
      text = "⚠️ Failed to connect to " .. self._provider_name .. ".",
    })
    return
  end

  -- Activating a saved session: _client is already set (start() assigned it
  -- before this scheduled callback ran), so restore() has all it needs.
  if restore then
    return self:restore(restore)
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

--- The selectable config kinds captured from the session, in capture order —
--- the details window's editable fields. Live ConfigKind references: `current`
--- tracks set_config successes.
--- @return weave.session.ConfigKind[]
function Session:config_kinds()
  local out = {}
  for _, key in ipairs(self._config_order) do
    out[#out + 1] = self._config[key]
  end
  return out
end

--- Apply a config choice: validate it against the captured options, send it
--- through the kind's `set` closure, and on success track `current` and
--- mirror the option's label into the sidebar meta.
--- @param key string category key ("model", "mode", "thought_level", ...)
--- @param id string option id to select
--- @param cb? fun(ok: boolean)
function Session:set_config(key, id, cb)
  cb = cb or function() end
  local cfg = self._config[key]
  local option
  for _, o in ipairs(cfg and cfg.available or {}) do
    if o.id == id then
      option = o
    end
  end
  if not option then
    cb(false)
    return
  end
  cfg.set(id, function(ok)
    vim.schedule(function()
      if not ok then
        Logger.notify("Failed to set " .. cfg.label .. ".", vim.log.levels.ERROR)
        cb(false)
        return
      end
      cfg.current = id
      self._store:set_meta({ [key] = option.label })
      cb(true)
    end)
  end)
end

--- Show a picker for a config kind ("model" | "mode") and apply the choice
--- via set_config.
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
    self:set_config(kind, choice.id)
  end)
end

--- Capture the selectable config kinds from a session-creation response,
--- normalising the two provider shapes:
---   * Kiro legacy: response.models / response.modes (availableX + currentX),
---     changed via set_model / set_mode.
---   * ACP standard: response.configOptions[] — EVERY category (model, mode,
---     thought_level, ...), changed via set_config_option.
--- Each kind's `set(id, cb)` closure reads self._session_id at CALL time —
--- config is process-level and may outlive the session it was captured from.
--- @private
--- @param response table SessionCreationResponse
function Session:_capture_config(response)
  local config, order = {}, {}

  local function capture(key, kind)
    if not config[key] then
      order[#order + 1] = key
    end
    kind.key = key
    config[key] = kind
  end

  if response.models then
    local available = {}
    for _, m in ipairs(response.models.availableModels or {}) do
      available[#available + 1] = { id = m.modelId, label = m.name }
    end
    capture("model", {
      label = "Model",
      current = response.models.currentModelId,
      available = available,
      set = function(id, cb)
        self._client:set_model(self._session_id, id, function(_r, err)
          cb(not err)
        end)
      end,
    })
  end

  if response.modes then
    local available = {}
    for _, m in ipairs(response.modes.availableModes or {}) do
      available[#available + 1] = { id = m.id, label = m.name }
    end
    capture("mode", {
      label = "Mode",
      current = response.modes.currentModeId,
      available = available,
      set = function(id, cb)
        self._client:set_mode(self._session_id, id, function(_r, err)
          cb(not err)
        end)
      end,
    })
  end

  for _, opt in ipairs(response.configOptions or {}) do
    local config_id = opt.id
    -- Spec-compliant agents send `category` (the config kind: "model", "mode",
    -- "thought_level"); some agents omit it and only send `id`. Key on category
    -- when present so _publish_meta / show_config_picker resolve "model"/"mode",
    -- else fall back to the id. An option with NEITHER can't be applied
    -- (set_config_option needs an id) and would nil-index config[key] — skip it
    -- rather than crash the whole config capture and strand the session.
    local key = opt.category or config_id
    if key == nil then
      Logger.debug("skipping config option with no category or id")
    else
      local available = {}
      for _, o in ipairs(opt.options or {}) do
        available[#available + 1] = { id = o.value, label = o.name }
      end
      -- opt.name is the agent's own label; fall back to a title-cased category
      -- key ("thought_level" → "Thought level"), else the raw key
      local label = opt.name
      if not label and type(opt.category) == "string" then
        label = opt.category:sub(1, 1):upper() .. opt.category:sub(2):gsub("_", " ")
      end
      capture(key, {
        label = label or key,
        current = opt.currentValue,
        available = available,
        set = function(id, cb)
          self._client:set_config_option(self._session_id, config_id, id, function(_r, err)
            cb(not err)
          end)
        end,
      })
    end
  end

  self._config = config
  self._config_order = order
end

--- @private
--- @return table handlers weave.acp.ClientHandlers
function Session:_build_handlers()
  return AcpBridge.build_handlers(self._store, {
    -- Read per-update: during a session/load replay the bridge appends the
    -- historical text but skips the generating/thinking status flaps.
    is_restoring = function()
      return self._restoring
    end,
  })
end

-- What the agent is told, once, when it wakes up inside the mode-on sandbox.
-- Without it the confinement is silently misleading rather than merely
-- restrictive: under bwrap, builtin WRITES fail loudly (EROFS on the
-- read-only project tmpfs) but builtin READS succeed against the empty decoy,
-- so an unsteered agent concludes the project is empty and says so with
-- confidence. Observed against a live opencode session, not hypothesised.
-- Worded to cover the seatbelt backend too, where the same reads are DENIED
-- rather than answered with nothing — a note that promised one shape would be
-- wrong on the other platform.
local STEERING_NOTE = table.concat({
  "[weave] Your process is sandboxed: the working directory you can see is NOT the real",
  "project, and your builtin file/search/shell tools cannot reach it — depending on the",
  "platform they will either come back EMPTY or be denied outright. The real project is",
  "reachable only through the weave MCP tools (read, write, edit, glob, grep,",
  "task_start, ...). Use those for everything. If you need access beyond the project",
  "(another directory, or network for a command), ask with request_access.",
}, "\n")

--- THIS session's frozen spawn confinement — the client's, never the
--- globally selected session's.
--- @private
--- @return "on"|"off"|nil
function Session:_sandbox_mode()
  return self._client and self._client.sandbox_mode or nil
end

--- Resolve the MCP servers to hand the agent at session creation. A
--- provider's own `mcpServers` OVERRIDES the global `config.mcp_servers`
--- (not merged). Each server's env gets $NVIM (this editor's socket)
--- injected — per-server, NOT on the agent's process env (Kiro treats a set
--- $NVIM as "inside a Neovim terminal" and exits). A server already carrying
--- a socket of its own is left alone: weave's clankbox entry rides the
--- broker ($CLANKBOX_SOCKET), and handing it $NVIM too would put the raw
--- RPC socket back within the agent's reach — the exact thing the broker
--- exists to prevent.
--- @private
--- @return table[] servers
function Session:_resolve_mcp_servers()
  local provider_cfg = Config.acp_providers[self._provider_name]
  local servers = (provider_cfg and provider_cfg.mcpServers) or Config.mcp_servers or {}

  -- weave's own tool suite rides along as a clankbox entry (weave.tools),
  -- unless disabled or the user already lists a clankbox server. Appended on
  -- a copy: `servers` may be the live config table.
  if not (Config.tools and Config.tools.enabled == false) then
    local has_clankbox = false
    for _, srv in ipairs(servers) do
      if srv.name == "clankbox" then
        has_clankbox = true
        break
      end
    end
    if not has_clankbox then
      local Tools = require("weave.tools")
      Tools.ensure_registered()
      local entry = Tools.clankbox_server_entry()
      if entry then
        local merged = {}
        for i, srv in ipairs(servers) do
          merged[i] = srv
        end
        merged[#merged + 1] = entry
        servers = merged
      end
    end
  end

  local socket = vim.v.servername

  local resolved = {}
  for _, srv in ipairs(servers) do
    local env = {}
    local has_socket = false
    for _, e in ipairs(srv.env or {}) do
      env[#env + 1] = e
      if e.name == "NVIM" or e.name == "CLANKBOX_SOCKET" then
        has_socket = true
      end
    end
    if has_socket or srv.name == "clankbox" then
      -- already socket-bearing (weave's broker entry, or a user who wired a
      -- socket explicitly) — or the clankbox entry itself, which IS the
      -- tool suite and must never be proxied. Legacy $NVIM injection only
      -- for a socket-less clankbox (broker-less checkout, unsandboxed use).
      if not has_socket and socket and socket ~= "" then
        env[#env + 1] = { name = "NVIM", value = socket }
      end
      resolved[#resolved + 1] = { name = srv.name, command = srv.command, args = srv.args, env = env }
    else
      -- v2 phase G: every other server is WRAPPED — the real process runs
      -- clientside, weave-owned (optionally sandboxed per its own config),
      -- and the agent gets the shim against the proxy socket. The gate then
      -- mediates its tools/call frames as mcp:<tool>. Fallback (no clankbox
      -- shim to run): the legacy in-sandbox spawn with $NVIM injected.
      local wrapped = require("weave.mcp_proxy").entry_for(srv)
      if wrapped then
        resolved[#resolved + 1] = wrapped
      else
        if socket and socket ~= "" then
          env[#env + 1] = { name = "NVIM", value = socket }
        end
        resolved[#resolved + 1] = { name = srv.name, command = srv.command, args = srv.args, env = env }
      end
    end
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
  return self:_steer_messages({ { kind = "user", text = text } })
end

--- Interrupt with a list of messages. The cancel and the resend are separated
--- by a round trip, so a SECOND interruption can arrive while the first turn is
--- still dying — the user hitting <C-x> as a tutor-mode flush fires, say. This
--- is the store's own documented discipline applied to steering: never hold an
--- in-flight obligation in a scalar slot (see the queue-pattern note in
--- weave.session_store), because the second one silently overwrites the first.
--- @private
--- @param msgs weave.session.Message[]
function Session:_steer_messages(msgs)
  if not self._turn_active then
    return self:_send_messages(msgs)
  end
  vim.list_extend(self._steer_queue, msgs)
  -- Cancel once per turn: this turn is already on its way out, and a second
  -- cancel_turn for it is noise on the wire. The flag tracks THAT rather than
  -- an empty queue, so a user steer still interrupts a turn that a
  -- non-interrupting tutor send is merely waiting behind.
  if not self._cancelling then
    self._cancelling = true
    self:_cancel_turn()
  end
end

--- Send something that is NOT the user's words — tutor-mode edit batches, mode
--- announcements. It reaches the agent as an ordinary prompt block, but in the
--- transcript it is its own entry kind carrying `label` (the payload is there
--- to peek at, not to read inline), and it never joins the prompt recall
--- history: `<Up>` is for prompts the user typed, and a diff blob there is
--- unusable.
---
--- ACCEPTED is not DELIVERED: a message parked behind an active turn still
--- dies if the steer queue is wiped (cancel, /new, restore). `on_sent` fires
--- when the message actually goes out on the wire; `on_dropped` when a wipe
--- kills it first. Tutor mode advances its revision cursor only on on_sent —
--- that is what makes a wiped diff resendable instead of silently lost.
--- @param opts { text: string, label?: string, interrupt?: boolean, on_sent?: fun(), on_dropped?: fun() }
--- @return boolean accepted false when the session cannot take it (not ready)
function Session:send_system(opts)
  if not self:is_ready() or type(opts.text) ~= "string" or opts.text == "" then
    return false
  end
  local msg = {
    kind = "tutor",
    text = opts.text,
    label = opts.label or "(system message)",
    on_sent = opts.on_sent,
    on_dropped = opts.on_dropped,
  }
  if opts.interrupt then
    self:_steer_messages({ msg })
    return true
  end
  if self._turn_active then
    self._steer_queue[#self._steer_queue + 1] = msg
    return true
  end
  self:_send_messages({ msg })
  return true
end

--- Wipe the steer queue, telling the owners that care. A queued message is an
--- ACCEPTED send that never made the wire; firing its on_dropped here is what
--- lets tutor mode re-arm and resend the edits it carried instead of losing
--- them (its cursor only advances on on_sent).
--- @private
function Session:_drop_steered()
  local dropped = self._steer_queue
  self._steer_queue = {}
  for _, msg in ipairs(dropped) do
    if msg.on_dropped then
      pcall(msg.on_dropped)
    end
  end
end

--- Cancel the in-flight turn with no resend, KEEPING any queued prompts: the
--- cancelled turn ends, and _on_turn_end drains the next queued prompt so we
--- move straight on to it (requests.md). Clear queued prompts individually (the
--- prompt-box `✕`) to drop them. Resolves pending permissions as cancelled (ACP).
function Session:cancel()
  self:_drop_steered()
  self._cancelling = false
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

--- The content blocks one prompt's attachments contribute, per file:
---
---   * an `image` / `audio` block carrying the bytes, when the provider says
---     it takes them (promptCapabilities) — the direct route, and the only
---     one that works for a model with no filesystem at all;
---   * a `resource_link` to the STAGED path, always. Under mode on that path
---     is real inside the sandbox (weave binds the staging dir read-only), so
---     an agent that would rather open the file with its own read tool can —
---     which is the only thing that works for providers that ignore image
---     blocks. The sandboxed presets allow exactly that read (${attachments}).
---
--- Both together are cheap: the link is a URI, not a copy of the bytes.
--- @private
--- @param attachments weave.Attachment[]
--- @return table[] blocks
function Session:_attachment_blocks(attachments)
  local agent_caps = (self._client and self._client.agent_capabilities) or {}
  local caps = agent_caps.promptCapabilities or {}
  local blocks = {}
  for _, att in ipairs(attachments) do
    local kind = att.mime and (att.mime:match("^image/") and "image" or att.mime:match("^audio/") and "audio") or nil
    if kind and caps[kind] then
      blocks[#blocks + 1] = {
        type = kind,
        mimeType = att.mime,
        uri = att.uri,
        data = FileSystem.read_file_base64(att.path),
      }
    end
    blocks[#blocks + 1] = { type = "resource_link", uri = att.uri, name = att.name, mimeType = att.mime }
  end
  return blocks
end

--- Echo a user message and drive a turn via send_prompt. Marks the turn
--- active; the send_prompt callback (turn end / stopReason) clears it and
--- drains the queue or fires a pending steer.
--- @private
--- @param text string
function Session:_send_now(text)
  return self:_send_messages({ { kind = "user", text = text } })
end

--- @class weave.session.Message One prompt block and how the transcript shows it
--- @field kind "user"|"tutor"
--- @field text string what the agent receives
--- @field label? string what the transcript shows for a non-user message

--- Drive one turn from a list of messages. Usually that list is a single user
--- prompt; it is longer when several interruptions landed on the same dying
--- turn, and they go out TOGETHER rather than as N sequential turns.
--- @private
--- @param msgs weave.session.Message[]
function Session:_send_messages(msgs)
  -- Attachments belong to the user's message, so a send with none in it must
  -- leave them pending for whenever the user does speak.
  local carries_user = false
  for _, msg in ipairs(msgs) do
    carries_user = carries_user or msg.kind ~= "tutor"
  end
  -- Taken (not copied) so the next prompt starts clean, and echoed on the user
  -- entry so the transcript shows what was handed over.
  local attachments = carries_user and self._store:take_attachments() or {}

  local prompt = {}
  local attached = false
  for _, msg in ipairs(msgs) do
    if msg.kind == "tutor" then
      self._store:append_entry({ kind = "tutor", text = msg.label, payload = msg.text })
    else
      self._store:append_entry({
        kind = "user",
        text = msg.text,
        attachments = not attached and attachments or nil,
      })
      self._store:push_history(msg.text) -- a sent prompt joins the recall history
      attached = true
    end
    prompt[#prompt + 1] = { type = "text", text = msg.text }
  end

  self._store:set_status("thinking")
  self._turn_active = true

  local session_id = self._session_id

  -- The steering note rides on the FIRST prompt of a sandboxed conversation,
  -- as a separate content block ahead of the user's text: prepending it to
  -- `text` itself would put words in the user's mouth in the transcript
  -- echo (already appended above) and in the agent's own history.
  vim.list_extend(prompt, self:_attachment_blocks(attachments))
  if self:_sandbox_mode() == "on" and self._steered_session ~= session_id then
    self._steered_session = session_id
    table.insert(prompt, 1, { type = "text", text = STEERING_NOTE })
  end

  self._client:send_prompt(session_id, prompt, function(_response, err)
    vim.schedule(function()
      -- Ignore stale turns from a previous session (e.g. after /new).
      if self._session_id ~= session_id then
        return
      end
      self:_on_turn_end(err)
    end)
  end)

  -- The prompt is on the wire: fire the delivery signal for owners that track
  -- it (tutor mode's revision cursor rides on this).
  for _, msg in ipairs(msgs) do
    if msg.on_sent then
      pcall(msg.on_sent)
    end
  end
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

  -- Steered messages take priority over the queue: something interrupted to
  -- send THESE now. They go out as one turn, in arrival order, so a user steer
  -- and a tutor-mode flush racing for the same dying turn both land. Then fall
  -- through to draining queued prompts in order.
  local steered = self._steer_queue
  self._steer_queue = {}
  self._cancelling = false
  if #steered > 0 then
    self:_send_messages(steered)
    return
  end

  self:_drain_queue()
end

--- Send the next queued prompt, if there is one and nothing holds it back:
--- no turn in flight, no steer pending, the head not under edit
--- (dequeue_prompt returns nil for a held head). Called at turn end and when
--- an edit releases a held queue.
--- @private
function Session:_drain_queue()
  if self._turn_active or #self._steer_queue > 0 or not self:is_ready() then
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
  self:_drop_steered()
  self._cancelling = false
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

--- Replace the conversation with a saved ACP session (session/load). The
--- provider replays the whole history through the ordinary update handlers
--- DURING the request; `_restoring` keeps the replay from flapping the
--- spinner (see acp_bridge). Like /new: the previous ACP session is
--- cancelled and the store reset first, meta persists.
--- @param session_id string
function Session:restore(session_id)
  if not self._client then
    Logger.notify("Provider not ready yet — try again in a moment.", vim.log.levels.WARN)
    return
  end

  if self._session_id then
    self._client:cancel_session(self._session_id)
  end
  self._session_id = nil
  self._turn_active = false
  self:_drop_steered()
  self._cancelling = false
  self._store:reset()
  self._store:set_status("busy")
  self._restoring = true

  self._client:load_session(
    session_id,
    vim.fn.getcwd(),
    self:_resolve_mcp_servers(),
    self:_build_handlers(),
    function(err, result)
      vim.schedule(function()
        self._restoring = false
        self._store:set_status("idle")

        if err then
          self._store:append_entry({
            kind = "agent",
            text = "⚠️ Session restore failed: " .. (err.message or vim.inspect(err)),
          })
          return
        end

        -- session/load may return session config (models/modes) like
        -- session/new does — recapture so the pickers track the restored
        -- session, and republish the sidebar meta.
        self._session_id = session_id
        self:_capture_config(result or {})
        self:_publish_meta()
      end)
    end
  )
end

--- List the provider's saved sessions for this cwd (session/list) and
--- restore the pick. A non-empty transcript asks before being clobbered.
--- Discovery is provider-aware — ACP session/list, or a filesystem fallback for
--- providers (Kiro) that support loadSession but NOT listing — via
--- SessionSource, which normalises both and never errors (an empty result just
--- means nothing is restorable for this cwd).
function Session:show_restore_picker()
  if not self._client then
    Logger.notify("Provider not ready yet — try again in a moment.", vim.log.levels.WARN)
    return
  end

  SessionSource.list(self._client, self._provider_name, vim.fn.getcwd(), function(sessions)
    vim.schedule(function()
      if #sessions == 0 then
        Logger.notify("No restorable sessions found for this directory.", vim.log.levels.INFO)
        return
      end

      local items = {}
      for _, s in ipairs(sessions) do
        local date = s.updatedAt and s.updatedAt:sub(1, 16):gsub("T", " ") or "unknown date"
        items[#items + 1] = {
          session_id = s.sessionId,
          display = string.format("%s - %s", date, s.title or "(no title)"),
        }
      end

      vim.ui.select(items, {
        prompt = "Restore session:",
        format_item = function(item)
          return item.display
        end,
      }, function(choice)
        if not choice then
          return
        end
        self:_confirm_clobber(function()
          self:restore(choice.session_id)
        end)
      end)
    end)
  end)
end

--- Run `on_confirmed` immediately when the transcript is empty; otherwise
--- ask first — restore resets the store, discarding the conversation.
--- @private
--- @param on_confirmed fun()
function Session:_confirm_clobber(on_confirmed)
  if #self._store.state.entries == 0 then
    return on_confirmed()
  end

  local discard = "Discard current conversation and restore"
  vim.ui.select({ "Cancel", discard }, {
    prompt = "The current conversation is not empty. Restore anyway?",
  }, function(choice)
    if choice == discard then
      on_confirmed()
    end
  end)
end

return Session
