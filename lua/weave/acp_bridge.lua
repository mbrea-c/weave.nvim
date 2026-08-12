-- Bridges the ACP layer to the session store.
-- Builds the weave.acp.ClientHandlers table that ACPClient:create_session
-- expects, routing every protocol callback into SessionStore mutations. The
-- fibrous view never sees the protocol; it renders `store.state`.
-- Ported from agentic's reactive/acp_bridge.lua.

local Logger = require("weave.utils.logger")
local Permissions = require("weave.permissions")

--- @class weave.AcpBridge
local AcpBridge = {}

-- Stores whose user has already been told why agent-side requests are being
-- refused (see the deny path below). Weak keys: a closed session's store
-- must not be kept alive by a bookkeeping flag.
local denial_explained = setmetatable({}, { __mode = "k" })

-- ── Permission resolution ───────────────────────────────────────────────────
--
-- Every session/request_permission resolves through the client-side
-- permission engine (weave.permissions): the request maps to a generic
-- action (acp:<kind> plus a resource string) and the ACTIVE preset decides
-- allow/deny/ask. Crucially, allow and deny never fabricate an outcome:
-- they select one of the request's OWN options.
--
-- This holds under BOTH sandbox modes. Mode on used to bypass the engine
-- and auto-approve everything here, on the theory that a fully confined
-- agent's own tools cannot land anything real anyway. True, but the
-- interesting half is what the agent concludes from being let through: a
-- live run approved its way into the empty read-only project decoy and
-- reported the project as empty. The sandboxed presets now DENY acp:*
-- instead (with a `message`), so the first builtin call turns the agent
-- toward the clientside tools that actually work.
--
-- WHY allow_ONCE, not allow_always: "allow_always" tells the AGENT to
-- persist a standing grant for that tool. If a preset auto-selected it,
-- switching presets would NOT restore prompting — the agent keeps the
-- permanent grant forever. "allow_once" grants exactly this invocation, so
-- the preset is the only thing keeping tools auto-allowed: switch it and the
-- next request prompts again. Presets must be fully reversible. The same
-- holds for reject_once over reject_always on the deny side.

--- The MCP servers weave itself wires into the agent: its own tool suite
--- (clankbox) plus every configured server, all of which weave brokers and
--- gates CLIENT-side. Names, for recognising the agent's requests to call
--- them (see brokered_call below).
--- @return string[]
local function brokered_names()
  local names = { "clankbox" }
  local ok, Config = pcall(require, "weave.config")
  if not ok then
    return names
  end
  local lists = { Config.mcp_servers }
  for _, provider in pairs(Config.acp_providers or {}) do
    lists[#lists + 1] = provider.mcpServers
  end
  for _, list in ipairs(lists) do
    for _, srv in ipairs(list or {}) do
      if type(srv.name) == "string" and srv.name ~= "" then
        names[#names + 1] = srv.name
      end
    end
  end
  return names
end

--- Is this request the agent asking to call a tool WEAVE brokers, rather
--- than to run one of its own builtins?
---
--- Providers ask permission for MCP tool calls too, naming the tool in the
--- title (opencode: "clankbox_read", kind "other"; Claude Code:
--- "mcp__clankbox__read"). Those calls are already mediated where it counts
--- — every frame crosses the broker or the MCP proxy, where the real gate
--- sits — so re-deciding them here is at best a double prompt and at worst
--- (a sandboxed preset's acp:* deny) weave blocking the agent from the very
--- tools it just told it to use. Matching on the server name is loose on
--- purpose: a false positive costs a redundant approval of an already-gated
--- call, a false negative breaks the sandbox's only way out.
--- @param tc table toolCall
--- @return boolean
local function brokered_call(tc)
  local title = type(tc.title) == "string" and tc.title or nil
  if not title then
    return false
  end
  for _, name in ipairs(brokered_names()) do
    if title ~= name and title:find(name, 1, true) then
      return true
    end
  end
  return false
end

--- The engine action for an ACP permission request: the tool-call kind under
--- the acp: namespace, and the most concrete resource the request carries —
--- the first location path (edits/reads), else the command line from
--- rawInput (execute), else its file path fields.
---
--- One exception: a request to call a tool weave brokers resolves as
--- `acp:mcp` with the tool name as its resource, keeping it addressable by
--- rules while separating it from the agent's own tools, which are what the
--- sandboxed presets exist to turn back.
--- @param request table The ACP RequestPermission params
--- @return weave.permissions.Action
local function acp_action(request)
  local tc = (request and request.toolCall) or {}
  if brokered_call(tc) then
    return { tool = "acp:mcp", resource = tc.title }
  end
  local resource
  local loc = type(tc.locations) == "table" and tc.locations[1] or nil
  if type(loc) == "table" and type(loc.path) == "string" then
    resource = loc.path
  end
  local ri = tc.rawInput
  if not resource and type(ri) == "table" then
    for _, key in ipairs({ "command", "file_path", "path", "abs_path" }) do
      if type(ri[key]) == "string" then
        resource = ri[key]
        break
      end
    end
  end
  return { tool = "acp:" .. (tc.kind or "other"), resource = resource }
end

--- The agent-offered option to answer `decision` with: allow prefers
--- allow_once then allow_always; deny prefers reject_once then
--- reject_always. The spec calls `kind` a "hint", so a provider COULD omit
--- or mis-set it — nil when no matching kind is offered (allow then falls
--- through to the user; deny falls back to the cancelled outcome). We never
--- guess an optionId the agent didn't mark.
--- @param options table[]|nil ACP PermissionOption[]
--- @param decision "allow"|"deny"
--- @return string|nil option_id
local function option_for(options, decision)
  local once = decision == "allow" and "allow_once" or "reject_once"
  local always = decision == "allow" and "allow_always" or "reject_always"
  local fallback
  for _, opt in ipairs(options or {}) do
    if opt.kind == once then
      return opt.optionId -- reversible answer, prefer it (see WHY note)
    elseif opt.kind == always and not fallback then
      fallback = opt.optionId
    end
  end
  return fallback
end

-- ── Kiro task-list adapter ──────────────────────────────────────────────────
--
-- ACP HAS a standard plan channel (sessionUpdate="plan" → PlanEntry[]), which
-- we handle in apply_session_update and surface in the Tasks sidebar. But
-- Kiro does NOT emit plan updates — it drives a STATEFUL task-list TOOL
-- (commands: create, complete, update) as regular tool calls. Plans are
-- optional in ACP, so this is a legitimate-but-non-standard choice; a generic
-- ACP client sees nothing in the plan channel. We mirror Kiro's task tool
-- into the plan store so the Tasks sidebar populates (the tool call also
-- still renders inline in the transcript).
--
-- The intelligence lives in SessionStore:apply_kiro_task_command — it must be
-- STATEFUL because `complete` sends only completed_task_ids with an EMPTY
-- output, so completion can't be read from a single call; it's applied
-- against the remembered task list. The bridge just forwards each tool
-- call's input there.

--- Map an ACP session/update message onto store mutations.
--- Tool calls and permissions arrive via dedicated handlers, so this only
--- handles message/thought chunks, plans, and activity status.
---
--- During restore (load_session) the provider REPLAYS the whole history
--- through these same updates. `restoring` suppresses the activity-status
--- mutations so the spinner doesn't flap "generating/thinking" for a finished
--- conversation; the transcript text is still appended so history renders.
--- @param store weave.store.SessionStore
--- @param update weave.acp.SessionUpdateMessage
--- @param restoring boolean
local function apply_session_update(store, update, restoring)
  local kind = update.sessionUpdate

  if kind == "agent_message_chunk" then
    if not restoring then
      store:set_status("generating")
    end
    if update.content and update.content.text then
      store:append_streaming_text("agent", update.content.text)
    end
  elseif kind == "agent_thought_chunk" then
    if not restoring then
      store:set_status("thinking")
    end
    if update.content and update.content.text then
      store:append_streaming_text("thought", update.content.text)
    end
  elseif kind == "user_message_chunk" then
    local content = update.content
    if content and content.type == "text" and content.text ~= "" then
      store:append_entry({ kind = "user", text = content.text })
    end
  elseif kind == "plan" then
    -- Standard ACP plan channel — authoritative (see set_plan source rules).
    store:set_plan(update.entries, "acp")
  elseif kind == "available_commands_update" then
    -- Feeds the prompt's slash-command completion (normalised in the store).
    store:set_commands(update.availableCommands)
  elseif kind == "usage_update" then
    -- Context tokens used / window size + cost — config-plane (the sidebar's
    -- Usage section), not transcript. tonumber tolerates vim.NIL/absent fields.
    store:set_usage({
      used = tonumber(update.used),
      size = tonumber(update.size),
      cost = type(update.cost) == "table" and update.cost or nil,
    })
  else
    -- mode/model/info updates are config-plane, not transcript.
    Logger.debug("acp_bridge: unhandled session update '" .. tostring(kind) .. "'")
  end
end

--- Build the ACP client handlers backed by a session store.
--- @param store weave.store.SessionStore
--- @param opts? { is_restoring?: fun(): boolean }
---  is_restoring: predicate read per-update; when it returns true
---  (load_session replay in flight) status mutations are skipped.
--- @return weave.acp.ClientHandlers handlers
function AcpBridge.build_handlers(store, opts)
  opts = opts or {}
  local is_restoring = opts.is_restoring or function()
    return false
  end

  --- @type weave.acp.ClientHandlers
  local handlers = {
    on_session_update = function(update)
      apply_session_update(store, update, is_restoring())
    end,

    on_tool_call = function(tool_call)
      store:upsert_tool_call(tool_call)
      -- Mirror Kiro's stateful task-list tool into the plan store (Kiro
      -- doesn't use ACP's plan channel). create/complete/update are applied
      -- against remembered state — crucially the `complete` command carries
      -- only completed_task_ids with an EMPTY output, so it must be applied
      -- from input. See SessionStore:apply_kiro_task_command.
      store:apply_kiro_task_command(tool_call.input)
    end,

    on_tool_call_update = function(tool_call_update)
      store:upsert_tool_call(tool_call_update)
      -- The merged tool call carries the full input (upsert deep-merges);
      -- re-apply so a task command seen across call/update still lands.
      local merged = store.state.tool_calls[tool_call_update.tool_call_id]
      store:apply_kiro_task_command((merged or tool_call_update).input)

      local status = tool_call_update.status
      if status == "completed" or status == "failed" then
        -- A terminal tool status means its permission request (anywhere
        -- in the queue, not just the head) is moot. Remove it from the
        -- queue and answer it `cancelled` so the agent's request id isn't
        -- left waiting. remove_* takes it out of the queue; respond only
        -- answers the agent (it does NOT touch the queue), so there's no
        -- double-pop.
        local removed = store:remove_permission_for_tool_call(tool_call_update.tool_call_id)
        if removed then
          removed.respond(nil)
        end
        if not store:get_permission() then
          store:set_status("generating")
        end
      end
    end,

    on_request_permission = function(request, callback)
      -- The active preset may answer this request without the user (see the
      -- permission-resolution note above). The tool call still renders (the
      -- user should see what was auto-answered) — that arrives via
      -- on_tool_call/on_tool_call_update, not here, so answering simply
      -- skips the enqueue + surfacing. An allow with no allow option falls
      -- through to the queue (never guess); a deny with no reject option
      -- answers the cancelled outcome (respond nil).
      local decision, rule = Permissions.resolve(acp_action(request))
      if decision == "deny" then
        -- ACP's permission response carries an optionId and nothing else, so
        -- a rule's `message` cannot reach the agent here (the mode-on
        -- steering note is what tells it where to go instead). Say it to the
        -- USER, once per session: a preset that turns the agent's own tools
        -- back without explanation reads as the agent malfunctioning.
        if rule and rule.message and not denial_explained[store] then
          denial_explained[store] = true
          store:append_entry({ kind = "agent", text = "⚠️ " .. rule.message })
        end
        callback(option_for(request.options, "deny"))
        return
      end
      if decision == "allow" then
        local option_id = option_for(request.options, "allow")
        if option_id then
          callback(option_id)
          return
        end
      end

      -- Deliberately DON'T touch the status: the turn is still active (the agent
      -- is blocked on YOU), so it must not masquerade as idle — idle is reserved
      -- for a genuinely ended turn ("you have the mic"). The "awaiting your
      -- approval" cue is derived view-side from the presence of a queued
      -- permission (see weave.view.prompt), a state distinct from both idle and
      -- the streaming thinking/generating tones.
      -- Enqueue (never overwrite): the agent may have several requests in
      -- flight at once. Each keeps its own respond closure that answers
      -- ONLY the agent. Queue removal is the caller's job (pop on a user
      -- answer; remove_* on a terminal status) so respond can't double-pop.
      -- See the queue-pattern note in session_store.lua.
      store:enqueue_permission({
        request = request,
        respond = function(option_id)
          callback(option_id)
        end,
      })
    end,

    on_error = function(err)
      Logger.debug("acp_bridge: agent error ", err)
      store:set_status("idle")
      store:append_entry({
        kind = "agent",
        text = "🐞 Agent Error: " .. vim.inspect(err),
      })
    end,
  }

  return handlers
end

return AcpBridge
