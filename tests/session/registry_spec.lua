-- The session registry (providers & sessions): the editor-GLOBAL list of
-- active sessions plus the per-tabpage pointer to the one the panel shows
-- there. Entries outlive panels and tabs; closing an entry is the only thing
-- that stops its conversation. Each entry owns the Session AND its view
-- Prefs. Sessions may use DIFFERENT providers — the process-per-provider
-- reuse lives below, in AgentInstance.

local Registry = require("weave.registry")

--- Pump the main loop so vim.schedule'd continuations run.
local function pump()
  vim.wait(50, function()
    return false
  end, 5)
end

--- Minimal scripted client (see session_spec for the full double).
local function fake_client()
  local client = {
    state = "connected",
    agent_info = { name = "fake-agent" },
    calls = { cancel_sessions = 0, loads = {} },
    _n = 0,
  }
  function client:create_session(_handlers, callback, _mcp)
    self._n = self._n + 1
    callback({ sessionId = "s" .. self._n }, nil)
  end
  function client:cancel_session(_sid)
    self.calls.cancel_sessions = self.calls.cancel_sessions + 1
  end
  function client:cancel_turn() end
  function client:load_session(session_id, _cwd, _mcp, handlers, on_complete)
    self.calls.loads[#self.calls.loads + 1] = session_id
    for _, update in ipairs(self.replay or {}) do
      handlers.on_session_update(update)
    end
    on_complete(nil, {})
  end
  return client
end

--- A get_instance double: one fake client per provider name (mirroring
--- AgentInstance's process-per-provider reuse), recording the names asked.
local function fake_instances()
  local clients, asked = {}, {}
  local function get_instance(name, on_ready)
    asked[#asked + 1] = name
    local client = clients[name] or fake_client()
    clients[name] = client
    on_ready(client)
    return client
  end
  return get_instance, clients, asked
end

describe("session registry", function()
  after_each(function()
    Registry.reset()
    pump()
  end)

  it("add starts one session per entry; different providers coexist", function()
    local get_instance, _, asked = fake_instances()
    local a = Registry.add({ provider = "prov-a", get_instance = get_instance })
    local b = Registry.add({ provider = "prov-b", get_instance = get_instance })
    pump()

    assert.same({ "prov-a", "prov-b" }, asked)
    local list = Registry.list()
    assert.equal(2, #list)
    assert.rawequal(a, list[1])
    assert.rawequal(b, list[2])
    assert.is_true(a.key ~= b.key)
    assert.equal("prov-a", a.provider)
    assert.equal("prov-b", b.provider)
    assert.is_true(a.session:is_ready())
    assert.is_true(b.session:is_ready())
    -- fully independent conversations: own store, own view prefs
    assert.is_true(a.session:get_store() ~= b.session:get_store())
    assert.is_true(a.prefs ~= b.prefs)
  end)

  it("selection is per tabpage", function()
    local get_instance = fake_instances()
    local a = Registry.add({ get_instance = get_instance })
    local b = Registry.add({ get_instance = get_instance })
    pump()

    Registry.select(a.key)
    assert.rawequal(a, Registry.selected())

    vim.cmd.tabnew()
    assert.is_nil(Registry.selected())
    Registry.select(b.key)
    assert.rawequal(b, Registry.selected())

    vim.cmd.tabclose()
    assert.rawequal(a, Registry.selected())
  end)

  it("close stops the session and clears selections pointing at it", function()
    local get_instance, clients = fake_instances()
    local a = Registry.add({ provider = "prov-a", get_instance = get_instance })
    pump()
    Registry.select(a.key)

    local closed = {}
    Registry.on_close(function(entry)
      closed[#closed + 1] = entry.key
    end)

    Registry.close(a.key)
    pump()
    assert.equal(1, clients["prov-a"].calls.cancel_sessions)
    assert.same({}, Registry.list())
    assert.is_nil(Registry.get(a.key))
    assert.is_nil(Registry.selected())
    assert.same({ a.key }, closed)
  end)

  it("add with restore activates a saved session in a fresh entry", function()
    local get_instance, clients = fake_instances()
    local entry = Registry.add({ provider = "prov-a", get_instance = get_instance, restore = "saved-7" })
    clients["prov-a"].replay = {
      { sessionUpdate = "user_message_chunk", content = { type = "text", text = "old question" } },
    }
    pump()

    assert.same({ "saved-7" }, clients["prov-a"].calls.loads)
    local store = entry.session:get_store()
    assert.equal("old question", store.state.entries[1].text)
    assert.equal("saved-7", store.state.meta.session_id)
    assert.is_true(entry.session:is_ready())
  end)

  it("reset closes every entry", function()
    local get_instance, clients = fake_instances()
    Registry.add({ provider = "prov-a", get_instance = get_instance })
    Registry.add({ provider = "prov-a", get_instance = get_instance })
    pump()

    Registry.reset()
    assert.same({}, Registry.list())
    assert.equal(2, clients["prov-a"].calls.cancel_sessions)
  end)
end)
