-- The ACP bridge (roadmap R3): builds the weave.acp.ClientHandlers table
-- that ACPClient expects, routing every protocol callback into SessionStore
-- mutations. Ported from agentic's reactive/acp_bridge.lua — its routing
-- logic is this spec.

local AcpBridge = require("weave.acp_bridge")
local SessionStore = require("weave.session_store")

local function setup(opts)
  local store = SessionStore:new()
  local handlers = AcpBridge.build_handlers(store, opts)
  return store, handlers
end

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
    handlers.on_request_permission({ toolCall = { toolCallId = "t1" }, options = {} }, cb("t1"))
    handlers.on_request_permission({ toolCall = { toolCallId = "t2" }, options = {} }, cb("t2"))

    handlers.on_tool_call_update({ tool_call_id = "t2", status = "failed" })

    -- t2's request was answered cancelled (nil); t1 still surfaced
    assert.same({ option_id = nil }, answered.t2)
    assert.is_nil(answered.t1)
    assert.equal("t1", store.state.permission.request.toolCall.toolCallId)
    assert.equal(1, store.state.permission_count)
    -- queue non-empty, so status stays idle (a prompt is showing)
    assert.equal("idle", store.state.status)

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

  it("normal mode enqueues, sets idle, and respond routes to the agent callback", function()
    local store, handlers = setup()
    local answered
    handlers.on_request_permission({ toolCall = { toolCallId = "t1" }, options = ALLOW }, function(option_id)
      answered = option_id
    end)
    assert.equal("idle", store.state.status)
    assert.equal(1, store.state.permission_count)
    store.state.permission.respond("once")
    assert.equal("once", answered)
    -- respond answers ONLY the agent; queue management is the caller's job
    assert.equal(1, store.state.permission_count)
  end)

  it("auto mode answers with the agent's own allow option, enqueuing nothing", function()
    local store, handlers = setup()
    store:set_permission_mode("auto")
    local answered
    handlers.on_request_permission({ toolCall = { toolCallId = "t1" }, options = ALLOW }, function(option_id)
      answered = option_id
    end)
    assert.equal("once", answered)
    assert.equal(0, store.state.permission_count)
    assert.is_nil(store.state.permission)
  end)

  it("auto mode still surfaces requests carrying no allow option", function()
    local store, handlers = setup()
    store:set_permission_mode("auto")
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
