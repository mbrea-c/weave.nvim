-- The session controller (roadmap R5): one conversation with an ACP agent —
-- owns the store, the live client + session id, and the turn/queue/steer/
-- cancel logic. Ported from agentic's reactive/session.lua; its semantics are
-- this spec. The client is injected (opts.get_instance) so everything runs
-- against a scripted fake.

local Session = require("weave.session")

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
    -- advertises ACP session listing, so SessionSource routes discovery through
    -- session/list (real listing providers set this; Kiro doesn't — see
    -- session_source_spec for the filesystem fallback)
    agent_capabilities = { sessionCapabilities = { list = true } },
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
  --- session/list: scripted via client.saved_sessions / client.list_err.
  function client:list_sessions(cwd, callback)
    self.calls.list_cwd = cwd
    if self.list_err then
      callback(nil, self.list_err)
    else
      callback({ sessions = self.saved_sessions or {} }, nil)
    end
  end
  --- session/load: replays client.replay through the handlers (the provider
  --- streams history as ordinary session updates DURING the request), then
  --- completes with client.load_err / client.load_result.
  function client:load_session(session_id, _cwd, _mcp, handlers, on_complete)
    self.calls.loads = self.calls.loads or {}
    self.calls.loads[#self.calls.loads + 1] = session_id
    self.handlers = handlers
    for _, update in ipairs(self.replay or {}) do
      handlers.on_session_update(update)
    end
    on_complete(self.load_err, self.load_err == nil and (self.load_result or {}) or nil)
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
    assert.same({ "second" }, store:queued_texts())

    client:end_turn()
    pump()
    assert.same({ "first", "second" }, client.calls.prompts)
    assert.same({}, store:queued_texts())
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

  it("cancel stops the turn but KEEPS the queue; permissions answered cancelled", function()
    local session, client, store = started()
    session:submit("work")
    session:submit("queued")
    local answered = "UNSET"
    store:enqueue_permission({
      request = { toolCall = { toolCallId = "t1" }, options = {} },
      respond = function(option_id)
        answered = option_id
      end,
    })

    session:cancel()
    assert.equal(1, client.calls.cancel_turns)
    -- the queue survives (requests.md: <C-c> cancels the turn, keeps the queue)…
    assert.same({ "queued" }, store:queued_texts())
    -- …but pending permissions are still answered cancelled (ACP requirement)
    assert.is_nil(answered) -- respond(nil) was called
    assert.equal(0, store.state.permission_count)

    -- the cancelled turn ends → the queue drains, moving straight on to the next
    client:end_turn()
    pump()
    assert.same({ "work", "queued" }, client.calls.prompts)
  end)

  it("sent prompts accumulate in the recall history", function()
    local session, client, store = started()
    session:submit("first") -- sent now
    session:submit("second") -- queued (turn in flight)
    assert.same({ "first" }, store.state.history) -- only the sent one so far

    client:end_turn()
    pump() -- "second" drains and is sent
    assert.same({ "first", "second" }, store.state.history)
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

  it("restore replaces the conversation: history replays without status flapping", function()
    local session, client, store = started()
    session:submit("stale prompt")
    client:end_turn()
    pump()

    client.replay = {
      { sessionUpdate = "user_message_chunk", content = { type = "text", text = "old question" } },
      { sessionUpdate = "agent_message_chunk", content = { text = "old answer" } },
    }
    client.load_result = {
      models = {
        currentModelId = "opus",
        availableModels = { { modelId = "opus", name = "Opus" } },
      },
    }
    local statuses = {}
    store:subscribe(function(state)
      statuses[#statuses + 1] = state.status
    end)

    session:restore("old-1")
    pump()

    -- The stale transcript is gone; the replayed history IS the transcript.
    assert.equal(2, #store.state.entries)
    assert.equal("old question", store.state.entries[1].text)
    assert.equal("old answer", store.state.entries[2].text)
    -- The replay never flaps the spinner: no generating/thinking seen.
    for _, s in ipairs(statuses) do
      assert.is_true(s ~= "generating" and s ~= "thinking", "status flapped to " .. s)
    end
    assert.equal("idle", store.state.status)
    -- The restored session is live: id adopted, config recaptured, usable.
    assert.is_true(session:is_ready())
    assert.equal("old-1", store.state.meta.session_id)
    assert.equal("opus", store.state.meta.model)
    session:submit("follow-up")
    assert.same({ "stale prompt", "follow-up" }, client.calls.prompts)
  end)

  it("a failed restore lands in the transcript and leaves the session not-ready", function()
    local session, client, store = started()
    client.load_err = { message = "no such session" }

    session:restore("gone")
    pump()

    local last = store.state.entries[#store.state.entries]
    assert.truthy(last.text:find("no such session", 1, true))
    assert.is_false(session:is_ready())
  end)

  it("start with restore loads the saved session instead of creating one", function()
    local client = fake_client()
    client.replay = {
      { sessionUpdate = "user_message_chunk", content = { type = "text", text = "old question" } },
    }
    local session = Session:new({
      provider = "test-agent",
      get_instance = function(_name, on_ready)
        on_ready(client)
        return client
      end,
    })
    session:start({ restore = "saved-1" })
    pump()

    assert.is_nil(client.calls.create_sessions)
    assert.same({ "saved-1" }, client.calls.loads)
    local store = session:get_store()
    assert.equal("old question", store.state.entries[1].text)
    assert.equal("saved-1", store.state.meta.session_id)
    assert.is_true(session:is_ready())
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

describe("session restore picker", function()
  local real_select

  before_each(function()
    real_select = vim.ui.select
  end)

  after_each(function()
    vim.ui.select = real_select
  end)

  --- Stub vim.ui.select: records each prompt's items and answers from
  --- `answers` in call order (nil = dismiss).
  --- @param answers (integer|nil)[] 1-based index to pick per select call
  --- @return table[] prompts { prompt = string, items = any[] } per call
  local function select_script(answers)
    local prompts = {}
    vim.ui.select = function(items, select_opts, on_choice)
      prompts[#prompts + 1] = { prompt = select_opts.prompt, items = items, format = select_opts.format_item }
      local pick = answers[#prompts]
      on_choice(pick and items[pick] or nil)
    end
    return prompts
  end

  it("lists saved sessions and restores the pick", function()
    local session, client = started()
    client.saved_sessions = {
      { sessionId = "old-1", title = "Fix the bug", updatedAt = "2026-07-04T10:30:00Z" },
      { sessionId = "old-2", title = nil, updatedAt = nil },
    }
    local prompts = select_script({ 1 })

    session:show_restore_picker()
    pump()

    assert.equal(1, #prompts)
    assert.equal(2, #prompts[1].items)
    assert.equal("2026-07-04 10:30 - Fix the bug", prompts[1].format(prompts[1].items[1]))
    assert.equal("unknown date - (no title)", prompts[1].format(prompts[1].items[2]))
    assert.same({ "old-1" }, client.calls.loads)
  end)

  it("a non-empty transcript needs confirmation — Cancel restores nothing", function()
    local session, client = started()
    session:submit("in progress")
    client.saved_sessions = { { sessionId = "old-1", title = "t", updatedAt = "2026-07-04T10:30:00Z" } }
    local prompts = select_script({ 1, 1 }) -- pick the session, then "Cancel"

    session:show_restore_picker()
    pump()

    assert.equal(2, #prompts)
    assert.equal("Cancel", prompts[2].items[1])
    assert.is_nil(client.calls.loads)

    -- Confirming does restore.
    select_script({ 1, 2 })
    session:show_restore_picker()
    pump()
    assert.same({ "old-1" }, client.calls.loads)
  end)

  it("no saved sessions → no picker", function()
    local session, client = started()
    client.saved_sessions = {}
    local prompts = select_script({})

    session:show_restore_picker()
    pump()

    assert.equal(0, #prompts)
    assert.is_nil(client.calls.loads)
  end)

  it("a list error → no picker", function()
    local session, client = started()
    client.list_err = { message = "unsupported" }
    local prompts = select_script({})

    session:show_restore_picker()
    pump()

    assert.equal(0, #prompts)
    assert.is_nil(client.calls.loads)
  end)
end)
