local Registry = require("weave.registry")
local Config = require("weave.config")
local Permissions = require("weave.permissions")
local Subagents = require("weave.subagents")

local function pump()
  vim.wait(60, function() return false end, 2)
end

describe("client-side subagent runs", function()
  local saved_provider, saved_limits, clients
  local function get_instance(_, ready)
    local client = { state = "connected", sandbox_mode = "on", turns = {}, writes = {}, n = 0 }
    function client:create_session(handlers, cb)
      self.handlers = handlers
      cb({ sessionId = tostring(self), configOptions = {
        { id = "effort", name = "Effort", currentValue = "low",
          options = { { value = "low", name = "Low" }, { value = "high", name = "High" } } },
      } })
    end
    function client:set_config_option(_sid, id, value, cb)
      self.writes[#self.writes + 1] = { id = id, value = value, cb = cb }
    end
    function client:send_prompt(_sid, prompt, cb)
      self.n = self.n + 1
      self.turns[#self.turns + 1] = { prompt = prompt, cb = cb }
    end
    function client:cancel_turn() self.cancelled = true end
    function client:cancel_session() self.closed = true end
    clients[#clients + 1] = client
    ready(client)
    return client
  end
  local function root()
    local entry = Registry.add({ provider = "subagent-test", get_instance = get_instance })
    pump()
    return entry
  end
  local function create(parent, opts)
    opts = vim.tbl_extend("force", { prompt = "Review the change", get_instance = get_instance }, opts or {})
    return Subagents.create(parent.session, opts)
  end

  before_each(function()
    Registry.reset()
    Permissions._reset(); Permissions.set_mode("on"); Permissions.set_active("auto")
    clients = {}
    saved_provider, saved_limits = Config.acp_providers["subagent-test"], Config.subagents
    Config.acp_providers["subagent-test"] = { name = "Test", command = "not-spawned" }
    Config.subagents = { provision_timeout_ms = 200, max_running = 8 }
  end)
  after_each(function()
    Registry.reset()
    Config.acp_providers["subagent-test"], Config.subagents = saved_provider, saved_limits
    Permissions._reset()
  end)

  it("creates an ordinary child session and reports completion at the actual turn boundary", function()
    local parent = root()
    local child, run = create(parent)
    pump()
    assert.equal(parent.key, child.parent_key)
    assert.equal("running", run.status)
    child.session:get_store():set_status("idle")
    assert.equal("running", run.status)
    child.session:get_store():append_streaming_text("agent", "The result")
    clients[2].turns[1].cb({ stopReason = "end_turn" })
    pump()
    assert.equal("completed", run.status)
    local out = Subagents.read(parent.session, child.key, { run_id = run.id })
    assert.equal("The result", out.output)
  end)

  it("applies requested config before the initial prompt", function()
    local parent = root()
    local _, run = create(parent, { config_defaults = { effort = "high" } })
    pump()
    assert.equal("provisioning", run.status)
    assert.equal(0, #clients[2].turns)
    assert.equal("high", clients[2].writes[1].value)
    clients[2].writes[1].cb({})
    pump()
    assert.equal("running", run.status)
    assert.equal(1, #clients[2].turns)
  end)

  it("fails provisioning instead of silently running with unsupported configuration", function()
    local parent = root()
    local _, run = create(parent, { config_defaults = { unknown = "high" } })
    vim.wait(350, function() return run.status == "failed" end, 5)
    assert.equal("failed", run.status)
    assert.equal(0, #clients[2].turns)
  end)

  it("serializes reusable-child runs and reads bounded unicode output by cursor", function()
    local parent = root()
    local child, first = create(parent)
    pump()
    local second = Subagents.send(parent.session, child.key, "Next task")
    assert.equal("queued", second.status)
    child.session:get_store():append_streaming_text("agent", "aλ界z")
    local out = Subagents.read(parent.session, child.key, { run_id = first.id, max_chars = 2 })
    assert.equal("aλ", out.output)
    assert.equal(2, out.next_cursor)
    assert.equal("界z", Subagents.read(parent.session, child.key, { run_id = first.id, cursor = 2 }).output)
    clients[2].turns[1].cb({ stopReason = "end_turn" }); pump()
    assert.equal("running", second.status)
    assert.equal(2, #clients[2].turns)
    assert.is_true(first.id ~= second.id)
  end)

  it("wait timeouts leave work running and completion answers waiters once", function()
    local parent = root()
    local child, run = create(parent)
    pump()
    local replies, out = 0
    Subagents.wait(parent.session, child.key, run.id, 10, function(result)
      replies, out = replies + 1, result
    end)
    pump()
    assert.is_true(out.timed_out)
    assert.equal("running", run.status)
    clients[2].turns[1].cb({ stopReason = "end_turn" }); pump()
    assert.equal(1, replies)
  end)

  it("settles pending waits when a child is closed and ignores late turn replies", function()
    local parent = root()
    local child, run = create(parent); pump()
    local replies, out = 0
    Subagents.wait(parent.session, child.key, run.id, 5000, function(result)
      replies, out = replies + 1, result
    end)
    Subagents.close(parent.session, child.key)
    assert.equal(1, replies)
    assert.equal("cancelled", out.status)
    clients[2].turns[1].cb({ stopReason = "end_turn" }); pump()
    assert.equal(1, replies)
    assert.equal("cancelled", run.status)
  end)

  it("rejects sibling, ancestor, self and unrelated session access for every operation", function()
    local parent, other = root(), root()
    local a = create(parent)
    local b = create(parent)
    pump()
    for _, target in ipairs({ parent.key, other.key, a.key }) do
      assert.has_error(function() Subagents.send(a.session, target, "stolen") end)
      assert.has_error(function() Subagents.read(a.session, target, {}) end)
      assert.has_error(function() Subagents.wait(a.session, target, 1, 1, function() end) end)
      assert.has_error(function() Subagents.cancel(a.session, target) end)
      assert.has_error(function() Subagents.close(a.session, target) end)
    end
    assert.has_error(function() Subagents.send(a.session, b.key, "stolen") end)
    assert.equal(0, #Subagents.list(a.session, {}))
    assert.equal(2, #Subagents.list(parent.session, {}))
  end)

  it("ignores unrelated turn completions while a delegated run is active", function()
    local parent = root()
    local child, run = create(parent); pump()
    child.session:_emit("turn_finished", { messages = { { text = "manual prompt" } },
      response = { stopReason = "end_turn" } })
    assert.equal("running", run.status)
    clients[2].turns[1].cb({ stopReason = "end_turn" }); pump()
    assert.equal("completed", run.status)
  end)

  it("cancels descendant runs owned by this run, not unrelated queued work in a reused child", function()
    local parent = root()
    local child, first = create(parent); pump()
    local grandchild, nested = create(child); pump()
    local human = Subagents.send(parent.session, grandchild.key, "Human follow-up")
    Subagents.cancel(parent.session, child.key, first.id)
    assert.equal("cancelled", nested.status)
    assert.equal("queued", human.status)
  end)

  it("treats a user's cancellation of the child session as cancellation of its delegated work", function()
    local parent = root()
    local child, run = create(parent); pump()
    local _, nested = create(child); pump()
    child.session:cancel()
    assert.equal("cancelled", run.status)
    assert.equal("cancelled", nested.status)
  end)

  it("bounds concurrency and cancels work owned by a cancelled delegated run", function()
    Config.subagents.max_running = 1
    local parent = root()
    local child, first = create(parent); pump()
    local grandchild, nested = create(child); pump()
    assert.equal("queued", nested.status)
    Subagents.cancel(parent.session, child.key, first.id)
    pump()
    assert.equal("cancelled", first.status)
    assert.equal("cancelled", nested.status)
    assert.is_not_nil(Registry.get(grandchild.key))
  end)

  it("cancels and closes descendants without killing an unrelated provider conversation", function()
    local parent, other = root(), root()
    local child, run = create(parent); pump()
    Subagents.cancel(parent.session, child.key, run.id)
    assert.equal("cancelled", run.status)
    assert.is_true(clients[3].cancelled)
    Subagents.close(parent.session, child.key)
    assert.equal("cancelled", run.status)
    assert.is_not_nil(Registry.get(other.key))
  end)
end)
