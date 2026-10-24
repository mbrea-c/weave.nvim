local Permissions = require("weave.permissions")
local Session = require("weave.session")
local Gate = require("weave.tools.gate")

local function context(session)
  return { caller = { session = session, valid = function() return true end } }
end

describe("caller-bound permissions", function()
  before_each(function() Permissions._reset(); Permissions.set_mode("on"); Permissions.set_active("auto") end)
  after_each(function() Permissions._reset() end)

  it("rejects unbound MCP requests instead of borrowing the selected policy", function()
    Permissions.set_active("yolo")
    local called, result = false
    local def = Gate.wrap("read", { handler = function() called = true; return "private" end })
    def.handler({ caller = { session = "forged" } }, function(out) result = out end,
      { name = "weave_read", args = {} })
    assert.is_false(called)
    assert.is_true(result.isError)
  end)

  it("resolves against the caller rather than the selected/global session", function()
    local child = Session:new({ permissions = { preset = "read_only" } })
    local called, result = false
    local def = Gate.wrap("write", { handler = function() called = true; return "wrote" end },
      { resource = function() return Permissions.project_root() .. "/new.lua" end })
    def.handler({ caller = "somebody-else" }, function(ret) result = ret end, context(child))
    assert.is_false(called)
    assert.is_true(result.isError)
  end)

  it("queues approvals and grants on the caller across interleaved completions", function()
    local a, b = Session:new({ permissions = { preset = "ask" } }), Session:new({ permissions = { preset = "ask" } })
    local def = Gate.wrap("read", { handler = function() return "done" end },
      { resource = function() return Permissions.project_root() .. "/main.lua" end })
    local ca, cb, calls = context(a), context(b), 0
    local function answer() calls = calls + 1 end
    def.handler({}, answer, ca)
    def.handler({}, answer, cb)
    assert.equal(1, a:get_store().state.permission_count)
    assert.equal(1, b:get_store().state.permission_count)
    b:get_store():pop_permission().respond("allow_always")
    assert.equal(1, calls)
    assert.equal(1, #b:permissions().grants())
    assert.equal(0, #a:permissions().grants())
    assert.equal(0, #Permissions.grants())
    a:get_store():pop_permission().respond("reject_once")
    assert.equal(2, calls)
  end)

  it("does not disclose late asynchronous results to a revoked caller", function()
    local session, live = Session:new(), true
    local ctx = { caller = { session = session, valid = function() return live end } }
    local finish, result
    local def = Gate.wrap("task_wait", { async = true, handler = function(_args, respond) finish = respond end })
    def.handler({}, function(ret) result = ret end, ctx)
    assert.is_not_nil(finish)
    live = false
    finish("private-late-output")
    assert.is_true(result.isError)
    assert.is_nil(result.content[1].text:find("private-late-output", 1, true))
  end)

  it("rejects stale contexts after a pending approval", function()
    local a = Session:new({ permissions = { preset = "ask" } })
    local live, called, result = true, false, nil
    local ctx = { caller = { session = a, valid = function() return live end } }
    Gate.wrap("read", { handler = function() called = true end },
      { resource = function() return Permissions.project_root() .. "/main.lua" end }).handler({}, function(ret) result = ret end, ctx)
    local pending = a:get_store():pop_permission()
    assert.is_not_nil(pending)
    live = false
    pending.respond("allow_always")
    assert.is_false(called)
    assert.is_true(result.isError)
    assert.equal(0, #a:permissions().grants())
  end)
end)
