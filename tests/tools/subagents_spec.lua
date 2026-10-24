local Registry = require("weave.registry")
local Config = require("weave.config")
local Permissions = require("weave.permissions")
local Context = require("weave.tool_context")
local Tools = require("weave.tools.subagents")
local Subagents = require("weave.subagents")
local Introspect = require("weave.tools.session")

describe("subagent tool authority", function()
  local saved_provider, create, clients
  local function instance(_, cb)
    local client = { state = "connected", sandbox_mode = "on" }
    function client:create_session(_handlers, reply) reply({ sessionId = tostring(self) }) end
    function client:send_prompt() end
    function client:cancel_session() end
    function client:cancel_turn() end
    clients[#clients + 1] = client
    cb(client)
    return client
  end
  local function parent()
    local entry = Registry.add({ provider = "tool-subagent-test", get_instance = instance })
    vim.wait(30, function() return entry.session:is_ready() end, 2)
    local ctx = { caller = Context.authenticate(Context.bind(entry.session)) }
    return entry, ctx
  end

  before_each(function()
    Registry.reset(); Permissions._reset(); Permissions.set_mode("on"); Permissions.set_active("auto")
    saved_provider = Config.acp_providers["tool-subagent-test"]
    Config.acp_providers["tool-subagent-test"] = { name = "Test", command = "unused" }
    clients, create = {}, Tools._create
    Tools._create = function(session, opts)
      opts.get_instance = instance
      return Subagents.create(session, opts)
    end
  end)
  after_each(function()
    Registry.reset(); Permissions._reset()
    Tools._create = create
    Config.acp_providers["tool-subagent-test"] = saved_provider
  end)

  it("requires transport identity and cannot be redirected using parent arguments", function()
    local entry, ctx = parent()
    assert.has_error(function() Tools.create.handler({ prompt = "work", parent_key = entry.key }, function() end) end)
    assert.has_error(function() Tools.create.handler({ prompt = "work", parent_key = entry.key }, function() end, ctx) end)
    assert.has_error(function() Tools.list.handler({ caller = { session_id = entry.session:session_id() } }) end)
    local response
    Tools.create.handler({ prompt = "work" }, function(ret) response = vim.json.decode(ret) end, ctx)
    assert.equal(entry.key, Registry.get(response.subagent_id).parent_key)
    assert.equal(2, #Registry.list())
  end)

  it("does not auto-approve a requested child permission profile even under auto", function()
    local entry, ctx = parent()
    local response
    Tools.create.handler({ prompt = "work", permissions = { preset = "yolo" } }, function(ret) response = ret end, ctx)
    assert.equal(1, #Registry.list())
    assert.is_nil(response)
    local request = entry.session:get_store():pop_permission()
    assert.is_not_nil(request)
    request.respond("reject_once")
    assert.is_true(response.isError)
    assert.equal(1, #Registry.list())
  end)

  it("applies an explicitly user-approved profile only to the child", function()
    local entry, ctx = parent()
    local response
    Tools.create.handler({ prompt = "work", permissions = { preset = "read_only", sandbox = { network = false } } },
      function(ret) response = vim.json.decode(ret) end, ctx)
    entry.session:get_store():pop_permission().respond("allow_once")
    local child = Registry.get(response.subagent_id)
    assert.equal("read_only", child.session:permissions().active().name)
    assert.equal("auto", entry.session:permissions().active().name)
    assert.equal("auto", Permissions.active().name)
  end)

  it("cannot create a child using stale approval or inject a provider command", function()
    local entry, ctx = parent()
    assert.has_error(function() Tools.create.handler({ prompt = "work", command = "evil" }, function() end, ctx) end)
    local response
    Tools.create.handler({ prompt = "work", permissions = { preset = "yolo" } }, function(ret) response = ret end, ctx)
    local pending = entry.session:get_store():pop_permission()
    entry.session:_reset_config_session(true)
    pending.respond("allow_once")
    assert.is_true(response.isError)
    assert.equal(1, #Registry.list())
  end)

  it("uses caller identity for introspection and refuses unrelated sessions", function()
    local entry, ctx = parent()
    local unrelated = parent()
    Registry.select(unrelated.key)
    local result = vim.json.decode(Introspect.introspect.handler({}, ctx))
    assert.equal(entry.key, result.session_key)
    assert.equal("auto", result.permissions.preset)
    assert.has_error(function() Introspect.introspect.handler({ session_key = unrelated.key }, ctx) end)
    assert.has_error(function() Tools.read.handler({ subagent_id = unrelated.key }, ctx) end)
    assert.has_error(function() Tools.close.handler({ subagent_id = unrelated.key }, ctx) end)
  end)
end)
