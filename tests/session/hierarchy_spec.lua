local Registry = require("weave.registry")
local Permissions = require("weave.permissions")
local Config = require("weave.config")

local function instance(_, cb)
  local client = { state = "connected" }
  function client:create_session(_handlers, reply) reply({ sessionId = tostring({}) }) end
  function client:cancel_session() self.stopped = true end
  function client:cancel_turn() end
  cb(client)
  return client
end

local function add(parent, opts)
  opts = opts or {}
  opts.parent_key = parent and parent.key
  opts.get_instance = instance
  return Registry.add(opts)
end

describe("session hierarchy", function()
  before_each(function() Registry.reset(); Permissions._reset(); Permissions.set_mode("on") end)
  after_each(function() Registry.reset(); Permissions._reset() end)

  it("indexes a forest by stable keys and distinguishes strict descendants", function()
    local root, unrelated = add(), add()
    local a = add(root)
    local b = add(a)
    assert.equal(root.key, a.parent_key)
    assert.equal(a.key, b.parent_key)
    assert.same({ a }, Registry.children(root.key))
    assert.same({ a, b }, Registry.children(root.key, true))
    assert.is_true(Registry.is_descendant(b.key, root.key))
    assert.is_false(Registry.is_descendant(root.key, root.key))
    assert.is_false(Registry.is_descendant(root.key, a.key))
    assert.is_false(Registry.is_descendant(unrelated.key, root.key))
    assert.has_error(function() Registry.add({ parent_key = 999999, get_instance = instance }) end)
  end)

  it("inherits a detached parent policy and accepts explicit child policy overrides", function()
    local root = add(nil, { permissions = { preset = "auto" } })
    local a = add(root, { permissions = { preset = "read_only" } })
    local b = add(root)
    assert.equal("read_only", a.session:permissions().active().name)
    assert.equal("auto", b.session:permissions().active().name)
    root.session:permissions().set_active("yolo")
    assert.equal("auto", b.session:permissions().active().name)
  end)

  it("closes descendants deepest-first without touching other roots", function()
    local root, other = add(), add()
    local a = add(root)
    local b = add(a)
    local closed = {}
    local unsubscribe = Registry.on_close(function(entry) closed[#closed + 1] = entry.key end)
    Registry.close(root.key)
    unsubscribe()
    assert.same({ b.key, a.key, root.key }, closed)
    assert.same({ other }, Registry.list())
  end)

  it("notifies live observers of background additions and removals", function()
    local changes = 0
    local unsubscribe = Registry.subscribe(function() changes = changes + 1 end)
    local root = add()
    add(root)
    Registry.close(root.key)
    unsubscribe()
    assert.truthy(changes >= 4)
  end)

  it("bounds recursive creation before spawning a provider", function()
    local saved = Config.subagents
    Config.subagents = { max_depth = 1, max_children = 1, max_sessions = 2 }
    local root = add()
    local a = add(root)
    local ok_deep = pcall(add, a)
    local ok_wide = pcall(add, root)
    Config.subagents = saved
    assert.is_false(ok_deep)
    assert.is_false(ok_wide)
    assert.equal(2, #Registry.list())
  end)
end)
