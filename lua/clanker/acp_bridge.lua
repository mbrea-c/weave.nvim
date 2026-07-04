-- Bridges the ACP layer to the session store.
-- Builds the clanker.acp.ClientHandlers table that ACPClient:create_session
-- expects, routing every protocol callback into SessionStore mutations. The
-- fibrous view never sees the protocol; it renders `store.state`.
-- Ported from agentic's reactive/acp_bridge.lua.

local Logger = require("clanker.utils.logger")
local SessionStore = require("clanker.session_store")

--- @class clanker.AcpBridge
local AcpBridge = {}

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
--- @param store clanker.store.SessionStore
--- @param update clanker.acp.SessionUpdateMessage
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
  else
    -- mode/model/usage/info updates are config-plane, not transcript.
    Logger.debug("acp_bridge: unhandled session update '" .. tostring(kind) .. "'")
  end
end

--- Build the ACP client handlers backed by a session store.
--- @param store clanker.store.SessionStore
--- @param opts? { is_restoring?: fun(): boolean } predicate read per-update; when
---  it returns true (load_session replay in flight) status mutations are skipped
--- @return clanker.acp.ClientHandlers handlers
function AcpBridge.build_handlers(store, opts)
  opts = opts or {}
  local is_restoring = opts.is_restoring or function()
    return false
  end

  --- @type clanker.acp.ClientHandlers
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
      -- Permission mode may auto-answer this request (Auto / Allow-edits)
      -- by selecting one of the agent's OWN allow options. We still want the
      -- tool call to render (the user should see what was auto-allowed) —
      -- but that arrives via on_tool_call/on_tool_call_update, not here, so
      -- auto-answering simply skips the enqueue + surfacing. If no option is
      -- chosen (Normal, or no allow option offered), fall through to the
      -- queue as before. See PERMISSION_MODES in session_store.lua.
      local auto_id = SessionStore.auto_option_for(request, store:get_permission_mode())
      if auto_id then
        callback(auto_id)
        return
      end

      store:set_status("idle")
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
