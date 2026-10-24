local Session = require("weave.session")
local Config = require("weave.config")

local function pump()
  vim.wait(40, function() return false end, 2)
end

local function field(id, category, current, values)
  local options = {}
  for _, value in ipairs(values or {}) do options[#options + 1] = { value = value, name = value:upper() } end
  return { id = id, category = category, name = id, currentValue = current, options = options }
end

local function model(current, values)
  return field("model-opt", "model", current or "m1", values or { "m1", "m2", "m3" })
end

local function effort(current, values)
  return field("effort-opt", "thought_level", current or "low", values or { "low", "high" })
end

local function client_for(options)
  local client = { state = "connected", agent_info = { name = "defaults-test" },
    requests = {}, handlers = {}, created = 0, options = options or {} }
  function client:create_session(handlers, cb)
    self.created = self.created + 1
    local id = "s" .. self.created
    self.handlers[id] = handlers
    local response = vim.deepcopy(self.response or { configOptions = self.options })
    response.sessionId = id
    cb(response)
    if self.early then self:notify(id, self.early) end
  end
  local function request(self, method, id, key, value, cb)
    self.requests[#self.requests + 1] = { method = method, session = id, key = key, value = value, cb = cb }
  end
  function client:set_config_option(id, key, value, cb) request(self, "config", id, key, value, cb) end
  function client:set_model(id, value, cb) request(self, "model", id, "model", value, cb) end
  function client:set_mode(id, value, cb) request(self, "mode", id, "mode", value, cb) end
  function client:notify(id, options)
    self.handlers[id].on_session_update({ sessionUpdate = "config_option_update", configOptions = options })
  end
  function client:finish(index, response, err)
    self.requests[index].cb(response or {}, err)
    pump()
  end
  function client:cancel_session() end
  function client:load_session(id, _cwd, _mcp, handlers, cb)
    self.handlers[id] = handlers
    cb(nil, vim.deepcopy(self.response or { configOptions = self.options }))
  end
  return client
end

local function current(session, id)
  for _, kind in ipairs(session:config_kinds()) do
    if kind.id == id or kind.key == id then return kind.current end
  end
end

describe("provider session defaults", function()
  local saved, sessions
  before_each(function()
    saved, sessions = Config.acp_providers["defaults-test"], {}
  end)
  after_each(function()
    for _, session in ipairs(sessions) do session:stop() end
    Config.acp_providers["defaults-test"] = saved
  end)

  local function start(defaults, client, restore)
    Config.acp_providers["defaults-test"] = { name = "Defaults test", session_defaults = defaults }
    client = client or client_for({ model(), effort() })
    local session = Session:new({ provider = "defaults-test", get_instance = function(_, ready)
      ready(client)
      return client
    end })
    sessions[#sessions + 1] = session
    session:start(restore and { restore = restore } or nil)
    pump()
    return session, client
  end

  it("applies model defaults first and revalidates dependent defaults from the response", function()
    local session, client = start({ ["model-opt"] = "m2", ["effort-opt"] = "high" },
      client_for({ effort(), model() }))
    assert.equal(1, #client.requests)
    assert.equal("model-opt", client.requests[1].key)
    client:finish(1, { configOptions = { model("m2"), effort("low", { "low" }) } })
    assert.equal(1, #client.requests) -- high stopped being valid after the model change
    client:notify("s1", { model("m2"), effort() })
    pump()
    assert.equal(2, #client.requests)
    assert.equal("effort-opt", client.requests[2].key)
    assert.equal("high", client.requests[2].value)
    client:finish(2)
    assert.equal("high", current(session, "thought_level"))
  end)

  it("waits for missing fields and invalid values to become available", function()
    local _, client = start({ ["effort-opt"] = "high" }, client_for({ model() }))
    assert.equal(0, #client.requests)
    client:notify("s1", { model(), effort("low", { "low" }) })
    pump()
    assert.equal(0, #client.requests)
    client:notify("s1", { model(), effort() })
    pump()
    assert.equal(1, #client.requests)
    assert.equal("high", client.requests[1].value)
  end)

  it("treats explicitly reselecting the current value as manual intent", function()
    local session, client = start({ ["model-opt"] = "m2" }, client_for({ model("m2") }))
    assert.equal(0, #client.requests)
    local applied
    session:set_config("model", "m2", function(ok) applied = ok end)
    pump()
    assert.is_true(applied)
    assert.equal(0, #client.requests)
    client:notify("s1", { model("m1") })
    pump()
    assert.equal(0, #client.requests)
  end)

  it("does not count automatic defaults as manual choices", function()
    local _, client = start({ ["model-opt"] = "m2" }, client_for({ model() }))
    client:finish(1)
    client:notify("s1", { model("m2") }) -- actual confirmation, not just an optimistic acknowledgement
    client:notify("s1", { model("m1") })
    pump()
    assert.equal(2, #client.requests)
    assert.equal("m2", client.requests[2].value)
  end)

  it("does not retry rejected defaults on identical notifications", function()
    local _, client = start({ ["model-opt"] = "m2" }, client_for({ model() }))
    client:finish(1, nil, { message = "temporarily rejected" })
    for _ = 1, 3 do client:notify("s1", { model() }); pump() end
    assert.equal(1, #client.requests)
    client:notify("s1", { model("m1", { "m1", "m2", "m3", "m4" }) })
    pump()
    assert.equal(2, #client.requests)
  end)

  it("does not loop when a successful response keeps the old value", function()
    local _, client = start({ ["model-opt"] = "m2" }, client_for({ model() }))
    client:finish(1, { configOptions = { model() } })
    for _ = 1, 3 do client:notify("s1", { model() }); pump() end
    assert.equal(1, #client.requests)
  end)

  it("prioritizes a manual choice over defaults after an in-flight default finishes", function()
    local session, client = start({ ["model-opt"] = "m2", ["effort-opt"] = "high" })
    assert.equal(1, #client.requests)
    local applied
    session:set_config("model", "m1", function(ok) applied = ok end)
    assert.equal(1, #client.requests)
    client:finish(1)
    assert.equal(2, #client.requests)
    assert.equal("model-opt", client.requests[2].key)
    assert.equal("m1", client.requests[2].value)
    client:finish(2)
    assert.is_true(applied)
    assert.equal("m1", current(session, "model"))
    assert.equal("effort-opt", client.requests[3].key)
  end)

  it("serializes manual changes too and revalidates queued choices", function()
    local session, client = start({})
    local applied
    session:set_config("model", "m2")
    session:set_config("thought_level", "high", function(ok) applied = ok end)
    assert.equal(1, #client.requests)
    client:finish(1, { configOptions = { model("m2"), effort("low", { "low" }) } })
    assert.equal(1, #client.requests)
    assert.is_false(applied)
  end)

  it("keeps manual intent when a field disappears and later returns", function()
    local session, client = start({ ["model-opt"] = "m2" }, client_for({ model("m2") }))
    session:set_config("model", "m1")
    client:finish(1)
    client:notify("s1", {})
    client:notify("s1", { model("m1") })
    pump()
    assert.equal(1, #client.requests)
  end)

  it("tracks distinct field IDs even when categories are shared", function()
    local session, client = start({ alpha = "b", beta = "y" }, client_for({
      field("alpha", "other", "a", { "a", "b" }), field("beta", "other", "x", { "x", "y" }),
    }))
    assert.equal(2, #session:config_kinds())
    assert.equal(1, #client.requests)
    client:finish(1)
    assert.equal(2, #client.requests)
    local chosen = { [client.requests[1].key] = client.requests[1].value, [client.requests[2].key] = client.requests[2].value }
    assert.same({ alpha = "b", beta = "y" }, chosen)
  end)

  it("supports legacy model/mode defaults through their legacy endpoints", function()
    local client = client_for()
    client.response = {
      models = { currentModelId = "m1", availableModels = { { modelId = "m1", name = "One" }, { modelId = "m2", name = "Two" } } },
      modes = { currentModeId = "ask", availableModes = { { id = "ask", name = "Ask" }, { id = "code", name = "Code" } } },
    }
    start({ model = "m2", mode = "code" }, client)
    assert.equal("model", client.requests[1].method)
    client:finish(1)
    assert.equal("mode", client.requests[2].method)
    assert.equal("code", client.requests[2].value)
  end)

  it("applies defaults after restore and to fields discovered later", function()
    local session, client = start({ ["model-opt"] = "m2", ["effort-opt"] = "high" },
      client_for({ model() }), "saved")
    assert.equal(0, client.created)
    assert.equal(1, #client.requests)
    assert.equal("saved", client.requests[1].session)
    assert.equal("model-opt", client.requests[1].key)
    client:finish(1)
    client:notify("saved", { model("m2"), effort() })
    pump()
    assert.equal(2, #client.requests)
    assert.equal("effort-opt", client.requests[2].key)
    client:finish(2)
    assert.equal("m2", current(session, "model"))
    assert.equal("high", current(session, "thought_level"))
  end)

  it("resets defaults and manual intent for /new and ignores old acknowledgements", function()
    local session, client = start({ ["model-opt"] = "m2" }, client_for({ model() }))
    local cancelled
    session:set_config("model", "m1", function(ok) cancelled = ok end)
    session:new_conversation()
    pump()
    assert.is_false(cancelled)
    assert.equal(2, #client.requests)
    assert.equal("s2", client.requests[2].session)
    client:finish(1, { configOptions = { model("m3") } })
    assert.equal("m1", current(session, "model"))
    client:finish(2)
    assert.equal("m2", current(session, "model"))
    client:notify("s1", { model("m3") })
    pump()
    assert.equal("m2", current(session, "model"))
  end)

  it("uses config notifications that arrive before the scheduled creation callback", function()
    local client = client_for({ model() })
    client.early = { model("m2") }
    local session = start({ ["model-opt"] = "m2" }, client)
    assert.equal(0, #client.requests)
    assert.equal("m2", current(session, "model"))
  end)

  it("does not let a stale response replace a newer notification and manual choice", function()
    local session, client = start({ ["model-opt"] = "m2" }, client_for({ model() }))
    local applied
    session:set_config("model", "m3", function(ok) applied = ok end)
    client.requests[1].cb({ configOptions = { model("m2") } }, nil)
    client:notify("s1", { model("m3") })
    pump()
    assert.equal("m3", current(session, "model"))
    assert.equal(1, #client.requests)
    assert.is_true(applied)
  end)

  it("preserves acknowledged legacy values across a later partial config response", function()
    local client = client_for()
    client.response = {
      models = { currentModelId = "m1", availableModels = { { modelId = "m1", name = "One" }, { modelId = "m2", name = "Two" } } },
      modes = { currentModeId = "ask", availableModes = { { id = "ask", name = "Ask" }, { id = "code", name = "Code" } } },
    }
    local session = start({ model = "m2", mode = "code" }, client)
    client:finish(1)
    client:finish(2, { modes = vim.tbl_extend("force", client.response.modes, { currentModeId = "code" }) })
    assert.equal("m2", current(session, "model"))
    assert.equal("code", current(session, "mode"))
    assert.equal(2, #client.requests)
  end)

  it("keeps manual intent separate for sessions sharing one provider process", function()
    local client = client_for({ model("m2") })
    local first = start({ ["model-opt"] = "m2" }, client)
    local second = start({ ["model-opt"] = "m2" }, client)
    first:set_config("model", "m2")
    client:notify("s1", { model() })
    client:notify("s2", { model() })
    pump()
    assert.equal(1, #client.requests)
    assert.equal("s2", client.requests[1].session)
    client:finish(1)
    assert.equal("m1", current(first, "model"))
    assert.equal("m2", current(second, "model"))
  end)

  it("drops pending manual callbacks and late acknowledgements on stop", function()
    local session, client = start({})
    local calls, applied = 0, nil
    session:set_config("model", "m2", function(ok) calls, applied = calls + 1, ok end)
    session:stop()
    assert.is_false(applied)
    assert.equal(1, calls)
    client:finish(1, { configOptions = { model("m2") } })
    client:notify("s1", { model("m3") })
    pump()
    assert.equal(1, calls)
    assert.equal("m1", current(session, "model"))
  end)

  it("orders model defaults first even for providers that omit config categories", function()
    local _, client = start({ model = "m2", effort = "high" }, client_for({
      field("effort", nil, "low", { "low", "high" }),
      field("model", nil, "m1", { "m1", "m2" }),
    }))
    assert.equal("model", client.requests[1].key)
    client:finish(1)
    assert.equal("effort", client.requests[2].key)
  end)

  it("does not lose a field whose id matches another field's category", function()
    local session, client = start({ thought_level = "on", effort = "high" }, client_for({
      field("thought_level", "other", "off", { "off", "on" }),
      field("effort", "thought_level", "low", { "low", "high" }),
    }))
    assert.equal(2, #session:config_kinds())
    assert.equal("thought_level", client.requests[1].key)
    client:finish(1)
    assert.equal("effort", client.requests[2].key)
  end)

  it("explicitly writes matching restored defaults once without repeating on notifications", function()
    local session, client = start({ ["model-opt"] = "m2" }, client_for({ model("m2"), effort() }), "saved")
    assert.equal(1, #client.requests)
    assert.equal("m2", client.requests[1].value)
    for _ = 1, 3 do client:notify("saved", { model("m2"), effort() }); pump() end
    assert.equal(1, #client.requests)
    client:finish(1, { configOptions = { model("m2"), effort() } })
    for _ = 1, 3 do client:notify("saved", { model("m2"), effort() }); pump() end
    client:notify("saved", {})
    client:notify("saved", { model("m2"), effort() })
    pump()
    assert.equal(1, #client.requests)
    assert.equal("low", current(session, "thought_level")) -- no default for this field
  end)

  it("does not repeat a rejected forced write when the reported value already matches", function()
    local _, client = start({ ["model-opt"] = "m2" }, client_for({ model("m2") }), "saved")
    assert.equal(1, #client.requests)
    client:finish(1, nil, { message = "rejected" })
    for _ = 1, 3 do client:notify("saved", { model("m2") }); pump() end
    assert.equal(1, #client.requests)
  end)

  it("forces restored model defaults before revalidating matching dependent defaults", function()
    local _, client = start({ ["model-opt"] = "m2", ["effort-opt"] = "high" },
      client_for({ effort("high"), model("m2") }), "saved")
    assert.equal(1, #client.requests)
    assert.equal("model-opt", client.requests[1].key)
    client:finish(1, { configOptions = { model("m2"), effort("low", { "low" }) } })
    assert.equal(1, #client.requests)
    client:notify("saved", { model("m2"), effort("high") })
    pump()
    assert.equal(2, #client.requests)
    assert.equal("effort-opt", client.requests[2].key)
    assert.equal("high", client.requests[2].value)
    client:finish(2)
    assert.equal(2, #client.requests)
  end)

  it("lets a manual choice made after loading win over an in-flight forced default", function()
    local session, client = start({ ["model-opt"] = "m2" }, client_for({ model("m2") }), "saved")
    assert.equal(1, #client.requests)
    local applied
    session:set_config("model", "m1", function(ok) applied = ok end)
    assert.equal(1, #client.requests)
    client:finish(1)
    assert.equal(2, #client.requests)
    assert.equal("m1", client.requests[2].value)
    client:finish(2)
    assert.is_true(applied)
    client:notify("saved", { model("m1") })
    pump()
    assert.equal(2, #client.requests)
    assert.equal("m1", current(session, "model"))
  end)

  it("does not force a pending field after its current value was manually reselected", function()
    local session, client = start({ ["model-opt"] = "m2", ["effort-opt"] = "high" },
      client_for({ model("m2"), effort("high") }), "saved")
    assert.equal(1, #client.requests)
    local applied
    session:set_config("thought_level", "high", function(ok) applied = ok end)
    client:finish(1)
    assert.is_true(applied)
    assert.equal(1, #client.requests) -- manual no-op must cancel the pending forced effort write
    client:notify("saved", { model("m2"), effort("low") })
    pump()
    assert.equal(1, #client.requests)
  end)

  it("waits until load completes before forcing defaults, using the latest replayed options", function()
    local client = client_for()
    function client:load_session(id, _cwd, _mcp, handlers, cb)
      self.handlers[id], self.loaded = handlers, cb
      self:notify(id, { model("m2") })
    end
    local session = start({ ["model-opt"] = "m2" }, client, "saved")
    assert.is_false(session:is_ready())
    assert.equal(0, #client.requests)
    client.loaded(nil, { configOptions = { model() } })
    pump()
    assert.equal("m2", current(session, "model"))
    assert.equal(1, #client.requests)
    assert.equal("saved", client.requests[1].session)
  end)

  it("replaces manual choices from the previous conversation with defaults on restore", function()
    local session, client = start({ ["model-opt"] = "m2" }, client_for({ model("m2") }))
    session:set_config("model", "m1")
    client:finish(1)
    client.options = { model("m1") }
    session:restore("saved")
    pump()
    assert.equal(2, #client.requests)
    assert.equal("saved", client.requests[2].session)
    assert.equal("m2", client.requests[2].value)
    client:finish(2)
    assert.equal("m2", current(session, "model"))
  end)

  it("resets forced writes on each restore but does not force matching defaults on /new", function()
    local session, client = start({ ["model-opt"] = "m2" }, client_for({ model("m2") }), "saved")
    assert.equal(1, #client.requests)
    client:finish(1)
    session:restore("saved")
    pump()
    assert.equal(2, #client.requests)
    client:finish(2)
    session:new_conversation()
    pump()
    assert.equal(2, #client.requests)
    assert.equal(1, client.created)
  end)

  it("explicitly writes matching legacy model and mode defaults after restore", function()
    local client = client_for()
    client.response = {
      models = { currentModelId = "m2", availableModels = { { modelId = "m2", name = "Two" } } },
      modes = { currentModeId = "code", availableModes = { { id = "code", name = "Code" } } },
    }
    start({ model = "m2", mode = "code" }, client, "saved")
    assert.equal(1, #client.requests)
    assert.equal("model", client.requests[1].method)
    client:finish(1)
    assert.equal("mode", client.requests[2].method)
    client:finish(2)
    assert.equal(2, #client.requests)
  end)
end)
