-- The session controller (roadmap R5): one conversation with an ACP agent —
-- owns the store, the live client + session id, and the turn/queue/steer/
-- cancel logic. Ported from agentic's reactive/session.lua; its semantics are
-- this spec. The client is injected (opts.get_instance) so everything runs
-- against a scripted fake.

local Session = require("clanker.session")

--- Pump the main loop so vim.schedule'd continuations run.
local function pump()
  vim.wait(50, function()
    return false
  end, 5)
end

--- A scripted ACP client double: records calls, lets the spec fire turn ends.
local function fake_client(session_response)
  local client = {
    state = "connected",
    agent_info = { name = "fake-agent", version = "1.0" },
    calls = { prompts = {}, cancel_turns = 0, cancel_sessions = 0, set_model = {}, set_mode = {} },
    _prompt_cbs = {},
  }
  function client:create_session(handlers, callback, _mcp)
    self.handlers = handlers
    self.calls.create_sessions = (self.calls.create_sessions or 0) + 1
    callback(session_response or { sessionId = "s1" }, nil)
  end
  function client:send_prompt(_session_id, prompt, callback)
    self.calls.prompts[#self.calls.prompts + 1] = prompt[1].text
    self._prompt_cbs[#self._prompt_cbs + 1] = callback
  end
  --- Complete the OLDEST in-flight turn (like the agent's stopReason arriving).
  function client:end_turn(err)
    local cb = table.remove(self._prompt_cbs, 1)
    assert(cb, "no turn in flight")
    cb(nil, err)
  end
  function client:cancel_turn(_session_id)
    self.calls.cancel_turns = self.calls.cancel_turns + 1
  end
  function client:cancel_session(_session_id)
    self.calls.cancel_sessions = self.calls.cancel_sessions + 1
  end
  function client:set_model(_session_id, id, cb)
    self.calls.set_model[#self.calls.set_model + 1] = id
    cb({}, nil)
  end
  function client:set_mode(_session_id, id, cb)
    self.calls.set_mode[#self.calls.set_mode + 1] = id
    cb({}, nil)
  end
  return client
end

local function started(session_response)
  local client = fake_client(session_response)
  local session = Session:new({
    provider = "test-agent",
    get_instance = function(_name, on_ready)
      on_ready(client)
      return client
    end,
  })
  session:start()
  pump()
  return session, client, session:get_store()
end

describe("session start", function()
  it("creates the ACP session and publishes meta", function()
    local session, _, store = started({
      sessionId = "s1",
      models = {
        currentModelId = "sonnet",
        availableModels = { { modelId = "sonnet", name = "Sonnet" }, { modelId = "opus", name = "Opus" } },
      },
      modes = {
        currentModeId = "dev",
        availableModes = { { id = "dev", name = "Dev" } },
      },
    })
    assert.equal("idle", store.state.status)
    assert.equal("test-agent", store.state.meta.provider)
    assert.equal("fake-agent v1.0", store.state.meta.agent)
    assert.equal("sonnet", store.state.meta.model)
    assert.equal("dev", store.state.meta.mode)
    assert.equal("s1", store.state.meta.session_id)
    assert.is_true(session:is_ready())
  end)

  it("captures ACP-standard configOptions too", function()
    local session = started({
      sessionId = "s1",
      configOptions = {
        {
          id = "model-opt",
          category = "model",
          currentValue = "m1",
          options = { { value = "m1", name = "One" } },
        },
      },
    })
    assert.equal("m1", session:get_store().state.meta.model)
  end)

  it("reports a failed connection in the transcript", function()
    local client = fake_client()
    client.state = "error"
    local session = Session:new({
      provider = "test-agent",
      get_instance = function(_name, on_ready)
        on_ready(client)
        return client
      end,
    })
    session:start()
    pump()
    local store = session:get_store()
    assert.equal("idle", store.state.status)
    assert.truthy(store.state.entries[1].text:find("Failed to connect", 1, true))
    assert.is_false(session:is_ready())
  end)
end)

describe("session turns", function()
  it("submit echoes the user entry and drives a turn", function()
    local session, client, store = started()
    session:submit("run the tests")
    assert.same({ "run the tests" }, client.calls.prompts)
    assert.equal("user", store.state.entries[1].kind)
    assert.equal("thinking", store.state.status)

    client:end_turn()
    pump()
    assert.equal("idle", store.state.status)
  end)

  it("a prompt sent mid-turn is queued and drained on turn end", function()
    local session, client, store = started()
    session:submit("first")
    session:submit("second")
    assert.same({ "first" }, client.calls.prompts)
    assert.same({ "second" }, store.state.queued)

    client:end_turn()
    pump()
    assert.same({ "first", "second" }, client.calls.prompts)
    assert.same({}, store.state.queued)
  end)

  it("a turn error lands in the transcript", function()
    local session, client, store = started()
    session:submit("boom")
    client:end_turn({ message = "exploded" })
    pump()
    local last = store.state.entries[#store.state.entries]
    assert.truthy(last.text:find("Turn failed: exploded", 1, true))
  end)

  it("steer cancels the turn and resends once it ends", function()
    local session, client = started()
    session:submit("original")
    session:steer("do this instead")
    assert.equal(1, client.calls.cancel_turns)
    assert.same({ "original" }, client.calls.prompts)

    client:end_turn() -- the cancelled turn's stop arrives
    pump()
    assert.same({ "original", "do this instead" }, client.calls.prompts)
  end)

  it("steer with no turn in flight is a plain submit", function()
    local session, client = started()
    session:steer("just send it")
    assert.same({ "just send it" }, client.calls.prompts)
    assert.equal(0, client.calls.cancel_turns)
  end)

  it("cancel stops the turn, drops the queue, answers permissions cancelled", function()
    local session, client, store = started()
    session:submit("work")
    session:submit("queued")
    local answered
    store:enqueue_permission({
      request = { toolCall = { toolCallId = "t1" }, options = {} },
      respond = function(option_id)
        answered = option_id
      end,
    })

    session:cancel()
    assert.equal(1, client.calls.cancel_turns)
    assert.same({}, store.state.queued)
    assert.is_nil(answered)
    assert.equal(0, store.state.permission_count)

    client:end_turn()
    pump()
    -- nothing is resent after an explicit cancel
    assert.same({ "work" }, client.calls.prompts)
  end)
end)

describe("session permissions and /new", function()
  it("respond_permission answers the head by index and pops it", function()
    local session, _, store = started()
    local answered
    store:enqueue_permission({
      request = {
        toolCall = { toolCallId = "t1" },
        options = { { optionId = "allow", name = "Allow" }, { optionId = "reject", name = "Reject" } },
      },
      respond = function(option_id)
        answered = option_id
      end,
    })
    session:respond_permission(2)
    assert.equal("reject", answered)
    assert.equal(0, store.state.permission_count)
  end)

  it("/new resets the store and creates a fresh session", function()
    local session, client, store = started()
    session:submit("hello")
    store:set_meta({ provider = "kept" })

    session:submit("/new")
    pump()
    assert.equal(1, client.calls.cancel_sessions)
    assert.equal(2, client.calls.create_sessions)
    assert.same({}, store.state.entries)
    assert.equal("kept", store.state.meta.provider)
    assert.is_true(session:is_ready())
  end)
end)
