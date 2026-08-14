-- The ACP bridge (roadmap R3): builds the weave.acp.ClientHandlers table
-- that ACPClient expects, routing every protocol callback into SessionStore
-- mutations. Ported from agentic's reactive/acp_bridge.lua — its routing
-- logic is this spec.

local AcpBridge = require("weave.acp_bridge")
local Permissions = require("weave.permissions")
local SessionStore = require("weave.session_store")

local function setup(opts)
  local store = SessionStore:new()
  local handlers = AcpBridge.build_handlers(store, opts)
  return store, handlers
end

-- Under sandbox mode on, agent-side permission requests are DENIED by the
-- preset rather than bypassed. The bridge itself knows nothing about modes:
-- it resolves every request through the engine, in both modes, and a
-- sandboxed preset's `acp:* deny` is what turns the agent's builtin tools
-- back toward the client-side ones.
describe("acp_bridge sandboxed acp denial", function()
  before_each(function()
    Permissions._reset()
    Permissions.set_mode("on")
    Permissions.set_active("ask")
  end)
  after_each(function()
    Permissions._reset()
  end)

  local function request(options)
    return {
      toolCall = { kind = "execute", rawInput = { command = "make test" } },
      options = options or {
        { optionId = "a1", kind = "allow_once" },
        { optionId = "r1", kind = "reject_once" },
      },
    }
  end

  it("answers the agent's own reject option, queueing nothing", function()
    local store, handlers = setup()
    local answered
    handlers.on_request_permission(request(), function(option_id)
      answered = option_id
    end)
    assert.equal("r1", answered)
    assert.is_nil(store:get_permission())
  end)

  it("tells the user why, once per session", function()
    local store, handlers = setup()
    local function ask()
      handlers.on_request_permission(request(), function() end)
    end
    ask()
    local entries = store.state.entries
    assert.equal(1, #entries)
    assert.truthy(entries[1].text:find("weave", 1, true))
    ask()
    ask()
    assert.equal(1, #store.state.entries) -- explained once, not per call
  end)

  -- Providers ask permission for MCP tool calls too, naming the tool in the
  -- title. Those are the agent reaching for the CLIENT-side tools — already
  -- gated at the broker — so the acp:* deny must not catch them, or weave
  -- blocks the only way out of the sandbox it just steered the agent toward.
  -- (Live opencode: title "clankbox_read", kind "other", no locations.)
  it("lets through the agent's request to call a tool weave brokers", function()
    local store, handlers = setup()
    local answered
    handlers.on_request_permission({
      toolCall = { kind = "other", title = "clankbox_read", locations = {} },
      options = {
        { optionId = "once", kind = "allow_once" },
        { optionId = "reject", kind = "reject_once" },
      },
    }, function(option_id)
      answered = option_id
    end)
    assert.equal("once", answered)
    assert.is_nil(store:get_permission())
  end)

  it("recognises the double-underscore spelling too", function()
    local _, handlers = setup()
    local answered
    handlers.on_request_permission({
      toolCall = { kind = "other", title = "mcp__clankbox__task_start" },
      options = { { optionId = "once", kind = "allow_once" }, { optionId = "r", kind = "reject_once" } },
    }, function(option_id)
      answered = option_id
    end)
    assert.equal("once", answered)
  end)

  -- Codex names the tool in an ENVELOPE, not the title. The renderer learned
  -- that shape; this path had not, so every clankbox call codex made resolved
  -- as acp:execute, hit the acp:* deny, and came back to the model as "user
  -- rejected MCP tool call" — weave refusing the agent the only tools it can
  -- reach. Both sides read weave.acp.mcp_ident now, so they cannot drift.
  it("lets through a call the provider named in an envelope, not the title", function()
    local _, handlers = setup()
    local answered
    handlers.on_request_permission({
      toolCall = {
        toolCallId = "exec-1",
        kind = "execute",
        rawInput = { server = "clankbox", tool = "read", arguments = { path = "src/main.rs" } },
      },
      options = { { optionId = "once", kind = "allow_once" }, { optionId = "r", kind = "reject_once" } },
    }, function(option_id)
      answered = option_id
    end)
    assert.equal("once", answered)
  end)

  -- A provider may announce the call in full and then ask permission with
  -- little more than its id. The frame in hand names nothing; the one before
  -- it did, and the store is where every normalized frame has landed.
  it("remembers what an earlier frame named when the request carries only an id", function()
    local _, handlers = setup()
    handlers.on_tool_call({
      tool_call_id = "exec-2",
      kind = "execute",
      mcp = { server = "clankbox", tool = "read" },
    })
    local answered
    handlers.on_request_permission({
      toolCall = { toolCallId = "exec-2", status = "pending" },
      options = { { optionId = "once", kind = "allow_once" }, { optionId = "r", kind = "reject_once" } },
    }, function(option_id)
      answered = option_id
    end)
    assert.equal("once", answered)
  end)

  -- The let-through is for tools WEAVE brokers, which are gated at the broker.
  -- A server the agent brought itself is gated nowhere else, so it stays the
  -- sandboxed preset's business.
  it("does not let through an MCP server weave does not broker", function()
    local _, handlers = setup()
    local answered
    handlers.on_request_permission({
      toolCall = {
        toolCallId = "exec-3",
        kind = "execute",
        rawInput = { server = "postgres", tool = "query", arguments = { sql = "select 1" } },
      },
      options = { { optionId = "once", kind = "allow_once" }, { optionId = "r", kind = "reject_once" } },
    }, function(option_id)
      answered = option_id
    end)
    assert.equal("r", answered)
  end)

  it("still denies a builtin tool whose title merely looks tool-ish", function()
    local _, handlers = setup()
    local answered
    handlers.on_request_permission({
      toolCall = { kind = "read", title = "Read", locations = { { path = "/x" } } },
      options = { { optionId = "once", kind = "allow_once" }, { optionId = "r", kind = "reject_once" } },
    }, function(option_id)
      answered = option_id
    end)
    assert.equal("r", answered)
  end)

  it("an unsandboxed session keeps the ask flow", function()
    Permissions.set_mode("off")
    Permissions.set_active("unsandboxed_ask")
    local store, handlers = setup()
    local answered = "unset"
    handlers.on_request_permission(request(), function(option_id)
      answered = option_id
    end)
    assert.equal("unset", answered)
    assert.is_not_nil(store:get_permission())
  end)
end)

describe("acp_bridge session updates", function()
  it("streams agent message chunks with generating status", function()
    local store, handlers = setup()
    handlers.on_session_update({ sessionUpdate = "agent_message_chunk", content = { text = "hel" } })
    handlers.on_session_update({ sessionUpdate = "agent_message_chunk", content = { text = "lo" } })
    assert.equal("generating", store.state.status)
    assert.same({ { kind = "agent", text = "hello" } }, store.state.entries)
  end)

  it("streams thought chunks with thinking status", function()
    local store, handlers = setup()
    handlers.on_session_update({ sessionUpdate = "agent_thought_chunk", content = { text = "hmm" } })
    assert.equal("thinking", store.state.status)
    assert.same({ { kind = "thought", text = "hmm" } }, store.state.entries)
  end)

  it("appends user message chunks as whole entries, skipping empties", function()
    local store, handlers = setup()
    handlers.on_session_update({ sessionUpdate = "user_message_chunk", content = { type = "text", text = "hi" } })
    handlers.on_session_update({ sessionUpdate = "user_message_chunk", content = { type = "text", text = "" } })
    assert.same({ { kind = "user", text = "hi" } }, store.state.entries)
  end)

  it("routes the standard plan channel as the authoritative source", function()
    local store, handlers = setup()
    handlers.on_session_update({ sessionUpdate = "plan", entries = { { content = "a" } } })
    assert.same({ { content = "a" } }, store.state.plan)
    -- authoritative: a later tool-sourced plan must not clobber it
    assert.is_false(store:set_plan({ { content = "b" } }, "tool"))
  end)

  it("suppresses status (but not text) while restoring", function()
    local restoring = true
    local store, handlers = setup({
      is_restoring = function()
        return restoring
      end,
    })
    handlers.on_session_update({ sessionUpdate = "agent_message_chunk", content = { text = "old" } })
    assert.equal("idle", store.state.status)
    assert.same({ { kind = "agent", text = "old" } }, store.state.entries)

    restoring = false
    handlers.on_session_update({ sessionUpdate = "agent_message_chunk", content = { text = "!" } })
    assert.equal("generating", store.state.status)
  end)

  it("routes available_commands_update into the store's command list", function()
    local store, handlers = setup()
    handlers.on_session_update({
      sessionUpdate = "available_commands_update",
      availableCommands = { { name = "plan", description = "Make a plan" } },
    })
    local words = vim.tbl_map(function(item)
      return item.word
    end, store.state.commands)
    assert.same({ "plan", "new" }, words)
  end)

  it("routes usage_update into the store's usage snapshot", function()
    local store, handlers = setup()
    handlers.on_session_update({
      sessionUpdate = "usage_update",
      used = 7837,
      size = 200000,
      cost = { amount = 0, currency = "USD" },
    })
    assert.equal(7837, store.state.usage.used)
    assert.equal(200000, store.state.usage.size)
    assert.equal("USD", store.state.usage.cost.currency)
    -- config-plane, not transcript
    assert.same({}, store.state.entries)
  end)

  it("ignores unknown update kinds without error", function()
    local store, handlers = setup()
    assert.has_no_error(function()
      handlers.on_session_update({ sessionUpdate = "current_mode_update", modeId = "dev" })
    end)
    assert.same({}, store.state.entries)
  end)
end)

describe("acp_bridge tool calls", function()
  before_each(function()
    -- the queue assertions need agent-side requests to actually QUEUE, which
    -- is the unsandboxed world; the sandboxed presets deny them outright
    Permissions.set_mode("off")
    Permissions.set_active("unsandboxed_ask")
  end)
  after_each(function()
    Permissions._reset()
  end)

  it("upserts the call and mirrors kiro task commands into the plan", function()
    local store, handlers = setup()
    handlers.on_tool_call({
      tool_call_id = "t1",
      title = "tasks",
      input = { command = "create", tasks = { { task_description = "one" } } },
    })
    assert.equal("tasks", store.state.tool_calls.t1.title)
    assert.same({ kind = "tool_call", tool_call_id = "t1" }, store.state.entries[1])
    assert.same({ { content = "one", status = "pending", priority = "medium" } }, store.state.plan)
  end)

  it("re-applies the MERGED input on updates (complete against remembered state)", function()
    local store, handlers = setup()
    handlers.on_tool_call({
      tool_call_id = "t1",
      input = { command = "create", tasks = { { task_description = "one" }, { task_description = "two" } } },
    })
    -- the update alone carries only the delta; the merged block must land it
    handlers.on_tool_call_update({
      tool_call_id = "t1",
      input = { command = "complete", completed_task_ids = { "2" } },
    })
    assert.same({
      { content = "one", status = "pending", priority = "medium" },
      { content = "two", status = "completed", priority = "medium" },
    }, store.state.plan)
  end)

  it("a terminal status cancels that tool's pending permission, anywhere in the queue", function()
    local store, handlers = setup()
    local answered = {}
    local function cb(id)
      return function(option_id)
        answered[id] = { option_id = option_id }
      end
    end
    store:set_status("generating") -- mid-turn: the agent hit tools needing approval
    handlers.on_request_permission({ toolCall = { toolCallId = "t1" }, options = {} }, cb("t1"))
    handlers.on_request_permission({ toolCall = { toolCallId = "t2" }, options = {} }, cb("t2"))

    handlers.on_tool_call_update({ tool_call_id = "t2", status = "failed" })

    -- t2's request was answered cancelled (nil); t1 still surfaced
    assert.same({ option_id = nil }, answered.t2)
    assert.is_nil(answered.t1)
    assert.equal("t1", store.state.permission.request.toolCall.toolCallId)
    assert.equal(1, store.state.permission_count)
    -- a pending permission no longer masquerades as idle: the turn is still
    -- active (the "awaiting your approval" cue is derived from the queue, view-side)
    assert.equal("generating", store.state.status)

    handlers.on_tool_call_update({ tool_call_id = "t1", status = "completed" })
    assert.same({ option_id = nil }, answered.t1)
    assert.equal(0, store.state.permission_count)
    -- queue drained by terminal statuses: back to generating
    assert.equal("generating", store.state.status)
  end)
end)

describe("acp_bridge permissions", function()
  local ALLOW = {
    { optionId = "once", kind = "allow_once" },
    { optionId = "always", kind = "allow_always" },
  }

  before_each(function()
    -- this whole block is about the AGENT-side flow (acp:*), which only has
    -- something to answer with the sandbox off
    Permissions.set_mode("off")
    Permissions.set_active("unsandboxed_ask")
  end)
  after_each(function()
    Permissions._reset()
  end)

  it("the ask preset enqueues (preserving the active status) and respond routes to the agent callback", function()
    local store, handlers = setup()
    store:set_status("generating") -- the turn is live when the approval is asked for
    local answered
    handlers.on_request_permission({ toolCall = { toolCallId = "t1" }, options = ALLOW }, function(option_id)
      answered = option_id
    end)
    -- the request no longer idles the water; the turn stays active
    assert.equal("generating", store.state.status)
    assert.equal(1, store.state.permission_count)
    store.state.permission.respond("once")
    assert.equal("once", answered)
    -- respond answers ONLY the agent; queue management is the caller's job
    assert.equal(1, store.state.permission_count)
  end)

  it("an allow resolution answers with the agent's own allow option, enqueuing nothing", function()
    local store, handlers = setup()
    Permissions.set_active("unsandboxed_auto")
    local answered
    handlers.on_request_permission({ toolCall = { toolCallId = "t1" }, options = ALLOW }, function(option_id)
      answered = option_id
    end)
    assert.equal("once", answered)
    assert.equal(0, store.state.permission_count)
    assert.is_nil(store.state.permission)
  end)

  it("allow still surfaces requests carrying no allow option", function()
    local store, handlers = setup()
    Permissions.set_active("unsandboxed_auto")
    local answered
    handlers.on_request_permission(
      { toolCall = { toolCallId = "t1" }, options = { { optionId = "no", kind = "reject_once" } } },
      function(option_id)
        answered = option_id
      end
    )
    assert.is_nil(answered)
    assert.equal(1, store.state.permission_count)
  end)

  it("the edit preset auto-allows edit tool calls and surfaces the rest", function()
    local store, handlers = setup()
    Permissions.set_active("unsandboxed_edit")
    local answered
    handlers.on_request_permission(
      { toolCall = { toolCallId = "t1", kind = "edit" }, options = ALLOW },
      function(option_id)
        answered = option_id
      end
    )
    assert.equal("once", answered)
    handlers.on_request_permission(
      { toolCall = { toolCallId = "t2", kind = "execute" }, options = ALLOW },
      function() end
    )
    assert.equal(1, store.state.permission_count)
  end)

  it("a deny resolution answers with the agent's reject option, or cancels without one", function()
    local store, handlers = setup()
    Permissions.save_preset({
      name = "no-exec",
      rules = {
        { tool = "acp:execute", decision = "deny" },
        { tool = "*", decision = "ask" },
      },
    })
    Permissions.set_active("no-exec")
    local answered = "unset"
    handlers.on_request_permission({
      toolCall = { toolCallId = "t1", kind = "execute" },
      options = {
        { optionId = "yes", kind = "allow_once" },
        { optionId = "no", kind = "reject_once" },
      },
    }, function(option_id)
      answered = option_id
    end)
    assert.equal("no", answered)
    assert.equal(0, store.state.permission_count)

    -- no reject option offered → cancelled (respond nil), never a guessed id
    answered = "unset"
    handlers.on_request_permission(
      { toolCall = { toolCallId = "t2", kind = "execute" }, options = { ALLOW[1] } },
      function(option_id)
        answered = option_id
      end
    )
    assert.is_nil(answered)
    assert.equal(0, store.state.permission_count)
  end)

  it("rules see the request's resource: the command line or the first location path", function()
    local store, handlers = setup()
    Permissions.save_preset({
      name = "guarded",
      rules = {
        { tool = "acp:execute", resource = "rm *", decision = "deny" },
        { tool = "acp:*", decision = "allow" },
      },
    })
    Permissions.set_active("guarded")
    local answered = "unset"
    handlers.on_request_permission({
      toolCall = { toolCallId = "t1", kind = "execute", rawInput = { command = "rm -rf build" } },
      options = {
        { optionId = "yes", kind = "allow_once" },
        { optionId = "no", kind = "reject_once" },
      },
    }, function(option_id)
      answered = option_id
    end)
    assert.equal("no", answered)

    handlers.on_request_permission({
      toolCall = { toolCallId = "t2", kind = "edit", locations = { { path = "/tmp/notes.md" } } },
      options = ALLOW,
    }, function(option_id)
      answered = option_id
    end)
    assert.equal("once", answered)
    assert.equal(0, store.state.permission_count)
  end)
end)

describe("acp_bridge errors", function()
  it("on_error resets status and surfaces the error in the transcript", function()
    local store, handlers = setup()
    store:set_status("generating")
    handlers.on_error({ message = "boom" })
    assert.equal("idle", store.state.status)
    assert.equal(1, #store.state.entries)
    assert.equal("agent", store.state.entries[1].kind)
    assert.truthy(store.state.entries[1].text:find("Agent Error"))
  end)
end)
