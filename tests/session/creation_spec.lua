local Config = require("weave.config")
local Registry = require("weave.registry")
local Session = require("weave.session")
local weave = require("weave")
local SessionModal = require("weave.view.session_modal")

local function pump()
  vim.wait(50, function() return false end, 2)
end

local function model(value)
  return { id = "model-opt", category = "model", name = "Model", currentValue = value or "m1",
    options = { { value = "m1", name = "One" }, { value = "m2", name = "Two" }, { value = "m3", name = "Three" } } }
end

local function effort(values)
  local options = {}
  for _, value in ipairs(values or { "low", "high" }) do options[#options + 1] = { value = value, name = value } end
  return { id = "effort-opt", category = "thought_level", name = "Effort", currentValue = "low", options = options }
end

local function fake_client(options)
  local client = { state = "connected", requests = {}, handlers = {}, created = 0, loads = {},
    options = options or { model(), effort() } }
  function client:create_session(handlers, cb)
    self.created = self.created + 1
    local id = "s" .. self.created
    self.handlers[id] = handlers
    cb({ sessionId = id, configOptions = vim.deepcopy(self.options) })
  end
  function client:set_config_option(sid, key, value, cb)
    self.requests[#self.requests + 1] = { sid, key, value }
    cb({})
  end
  function client:load_session(id, _cwd, _mcp, handlers, cb)
    self.loads[#self.loads + 1] = id
    self.handlers[id] = handlers
    cb(nil, { configOptions = vim.deepcopy(self.options) })
  end
  function client:notify(id, config_options)
    self.handlers[id].on_session_update({ sessionUpdate = "config_option_update", configOptions = config_options })
  end
  function client:cancel_session() end
  function client:cancel_turn() end
  return client, function(_, ready) ready(client); return client end
end

local function current(session, id)
  for _, kind in ipairs(session:config_kinds()) do
    if kind.id == id then return kind.current end
  end
end

describe("session creation API", function()
  local saved_provider, saved_config, unmanaged, saved_select, saved_modal_open
  before_each(function()
    saved_provider, saved_config = Config.provider, Config.acp_providers["creation-test"]
    saved_select, saved_modal_open = vim.ui.select, SessionModal.open
    Config.provider = "creation-test"
    Config.acp_providers["creation-test"] = {
      name = "Creation test", session_defaults = { ["model-opt"] = "m2", ["effort-opt"] = "high" },
    }
    unmanaged = {}
  end)
  after_each(function()
    weave.stop()
    for _, session in ipairs(unmanaged) do session:stop() end
    Config.provider, Config.acp_providers["creation-test"] = saved_provider, saved_config
    vim.ui.select, SessionModal.open = saved_select, saved_modal_open
    vim.cmd("stopinsert")
    pump()
  end)

  it("creates and starts a managed Session without opening or selecting it", function()
    local _, get = fake_client()
    local wins = #vim.api.nvim_list_wins()
    local session = weave.new_session({ get_instance = get })
    assert.is_false(session:is_ready()) -- creation is asynchronous
    assert.is_nil(weave.get_session())
    assert.is_false(weave.is_open())
    pump()
    assert.is_true(session:is_ready())
    assert.equal(1, #Registry.list())
    assert.rawequal(session, Registry.list()[1].session)
    assert.equal("creation-test", Registry.list()[1].provider)
    assert.equal(wins, #vim.api.nvim_list_wins())
  end)

  it("leaves an existing selection and panel alone for background creation", function()
    local _, get = fake_client()
    weave.open({ get_instance = get, width = 45 })
    local first = weave.get_session()
    local session = weave.new_session({ provider = "creation-test", get_instance = get })
    pump()
    assert.is_true(first ~= session)
    assert.rawequal(first, weave.get_session())
    assert.is_true(weave.is_open())
    assert.equal(2, #Registry.list())
  end)

  it("can explicitly select and open the newly created session", function()
    local _, get = fake_client()
    local session = weave.new_session({ provider = "creation-test", get_instance = get, open = true })
    pump()
    assert.rawequal(session, weave.get_session())
    assert.is_true(weave.is_open())
    assert.equal(1, #Registry.list())
  end)

  it("retargets an existing panel when the new session requests open", function()
    local _, get = fake_client()
    weave.open({ get_instance = get, width = 45 })
    local first = weave.get_session()
    local session = weave.new_session({ get_instance = get, open = true })
    pump()
    assert.rawequal(session, weave.get_session())
    assert.is_true(weave.is_open())
    assert.is_true(first:is_ready())
    assert.equal(2, #Registry.list())
    weave.close()
    weave.open()
    assert.rawequal(session, weave.get_session())
  end)

  it("merges public constructor overrides over provider defaults per field", function()
    local client, get = fake_client()
    local session = weave.new_session({ get_instance = get, config_defaults = { ["model-opt"] = "m3" } })
    pump()
    assert.same({ { "s1", "model-opt", "m3" }, { "s1", "effort-opt", "high" } }, client.requests)
    assert.equal("m3", current(session, "model-opt"))
    assert.same({ ["model-opt"] = "m2", ["effort-opt"] = "high" },
      Config.acp_providers["creation-test"].session_defaults)
  end)

  it("accepts config defaults through registry.add", function()
    local client, get = fake_client()
    local entry = Registry.add({ provider = "creation-test", get_instance = get,
      config_defaults = { ["model-opt"] = "m3" } })
    pump()
    assert.same({ "s1", "model-opt", "m3" }, client.requests[1])
    assert.equal("high", current(entry.session, "effort-opt")) -- unrelated provider default inherited
  end)

  it("copies Session constructor overrides before the caller can mutate them", function()
    local client, get = fake_client()
    local defaults = { ["model-opt"] = "m3" }
    local session = Session:new({ provider = "creation-test", get_instance = get, config_defaults = defaults })
    unmanaged[#unmanaged + 1] = session
    defaults["model-opt"] = "m1"
    session:start()
    pump()
    assert.same({ "s1", "model-opt", "m3" }, client.requests[1])
    assert.same({ ["model-opt"] = "m1" }, defaults)
  end)

  for _, method in ipairs({ "open", "toggle" }) do
    it("passes config defaults through weave." .. method .. " when creating a session", function()
      local client, get = fake_client()
      weave[method]({ get_instance = get, width = 45, config_defaults = { ["model-opt"] = "m3" } })
      pump()
      assert.same({ "s1", "model-opt", "m3" }, client.requests[1])
      assert.equal("high", current(weave.get_session(), "effort-opt"))
      assert.is_true(weave.is_open())
    end)
  end

  it("does not apply new open options to an existing selected session", function()
    local client, get = fake_client()
    weave.open({ get_instance = get, width = 45, config_defaults = { ["model-opt"] = "m3" } })
    pump()
    local session = weave.get_session()
    weave.close()
    weave.open({ config_defaults = { ["model-opt"] = "m1" } })
    pump()
    assert.rawequal(session, weave.get_session())
    assert.equal(1, client.created)
    assert.equal("m3", current(session, "model-opt"))
  end)

  it("keeps overrides independent for sessions sharing the same provider process", function()
    local client, get = fake_client()
    local first = Registry.add({ get_instance = get, config_defaults = { ["model-opt"] = "m3" } }).session
    local second = Registry.add({ get_instance = get, config_defaults = { ["model-opt"] = "m1" } }).session
    pump()
    assert.equal("m3", current(first, "model-opt"))
    assert.equal("m1", current(second, "model-opt"))
    assert.equal("m2", Config.acp_providers["creation-test"].session_defaults["model-opt"])
    assert.equal(2, client.created)
  end)

  it("keeps an invalid override pending instead of falling back to the provider default", function()
    local client, get = fake_client()
    local session = Registry.add({ get_instance = get, config_defaults = { ["model-opt"] = "future" } }).session
    pump()
    assert.equal("m1", current(session, "model-opt"))
    local updated = model()
    updated.options[#updated.options + 1] = { value = "future", name = "Future" }
    client:notify("s1", { updated, effort() })
    pump()
    assert.equal("future", current(session, "model-opt"))
  end)

  it("applies an override to a field advertised later", function()
    local client, get = fake_client({ model() })
    local session = Registry.add({ get_instance = get, config_defaults = { ["effort-opt"] = "medium" } }).session
    pump()
    assert.equal(1, #client.requests)
    client:notify("s1", { model("m2"), effort({ "low", "medium", "high" }) })
    pump()
    assert.equal("medium", current(session, "effort-opt"))
  end)

  it("lets manual choices win and reapplies the copied defaults on /new", function()
    local client, get = fake_client()
    local defaults = { ["model-opt"] = "m3" }
    local session = Registry.add({ get_instance = get, config_defaults = defaults }).session
    defaults["model-opt"] = "m1"
    pump()
    assert.equal("m3", current(session, "model-opt"))
    session:set_config("model", "m1")
    pump()
    local before = #client.requests
    client:notify("s1", { model("m1"), effort() })
    pump()
    assert.equal("m1", current(session, "model-opt"))
    -- Only the unrelated effort default may be reapplied.
    for index = before + 1, #client.requests do assert.equal("effort-opt", client.requests[index][2]) end
    session:new_conversation()
    pump()
    assert.equal("m3", current(session, "model-opt"))
  end)

  it("preserves restored config and keeps the overrides for a subsequent /new", function()
    local client, get = fake_client()
    local session = weave.new_session({ get_instance = get, restore = "saved",
      config_defaults = { ["model-opt"] = "m3" } })
    pump()
    assert.same({ "saved" }, client.loads)
    assert.equal(0, client.created)
    assert.equal(0, #client.requests)
    client:notify("saved", { model(), effort() })
    pump()
    assert.equal(0, #client.requests)
    session:new_conversation()
    pump()
    assert.equal("m3", current(session, "model-opt"))
  end)

  for _, flow in ipairs({ "on_new", "on_load_saved" }) do
    it("passes modal creation defaults through " .. flow, function()
      local client, get = fake_client()
      client.agent_capabilities = { sessionCapabilities = { list = true } }
      function client:list_sessions(_cwd, cb) cb({ sessions = { { sessionId = "saved" } } }) end
      -- Test the entrypoint's flow wiring; the modal and native picker have
      -- their own interaction specs.
      SessionModal.open = function(opts) return opts end
      vim.ui.select = function(items, opts, cb)
        if opts.prompt == "Provider:" then cb("creation-test")
        elseif opts.prompt == "Sandbox:" then cb(nil)
        else cb(items[1]) end
      end
      local callbacks = weave.sessions({ get_instance = get, config_defaults = { ["model-opt"] = "m3" } })
      callbacks[flow]()
      pump()
      local session = weave.get_session()
      assert.is_not_nil(session)
      if flow == "on_load_saved" then
        assert.same({ "saved" }, client.loads)
        assert.equal(0, #client.requests)
        session:new_conversation()
        pump()
      end
      assert.equal("m3", current(session, "model-opt"))
    end)
  end
end)
