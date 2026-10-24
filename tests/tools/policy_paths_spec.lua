local Permissions = require("weave.permissions")
local Session = require("weave.session")
local Sandbox = require("weave.sandbox")
local Access = require("weave.tools.access")

local function context(session)
  return { caller = { session = session, valid = function() return true end } }
end

describe("session-scoped policy enforcement paths", function()
  local available, wrap
  before_each(function()
    Permissions._reset()
    Permissions.set_mode("on")
    Permissions.set_active("yolo")
    available, wrap = Sandbox._available, Sandbox.wrap_tool
    Sandbox._available = function() return true end
  end)
  after_each(function()
    Sandbox._available, Sandbox.wrap_tool = available, wrap
    Permissions._reset()
  end)

  it("uses the caller's hull even while the global preset disables sandboxing", function()
    local session = Session:new({ permissions = { preset = "read_only" } })
    local hull
    Sandbox.wrap_tool = function(command, args, policy) hull = policy; return command, args end
    Sandbox.wrap_for_tool("weave:task_start", "sh", { "-c", "true" }, context(session))
    assert.is_not_nil(hull)
    assert.is_true(hull.enabled)
    assert.is_false(hull.network)
    assert.equal("ro", hull.binds[1].mode)
  end)

  it("carries the caller through fetch callbacks into the subprocess spawn", function()
    local Web = require("weave.tools.web_fetch")
    local run, curl = Web._run, Web.curl_path
    local seen
    Web._run = function(_argv, cb, ctx)
      seen = ctx
      cb({ code = 0, stdout = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhello", stderr = "" })
    end
    Web.curl_path = function() return "curl" end
    local ctx = context(Session:new())
    Web.def.handler({ url = "https://session-policy-test.invalid/" }, function() end, ctx)
    Web._run, Web.curl_path = run, curl
    Web._reset_cache()
    assert.rawequal(ctx, seen)
  end)

  it("keeps elevation and pending approvals on the caller rather than global state", function()
    local session = Session:new({ permissions = { preset = "read_only" } })
    local result
    Access.def.handler({ network = true }, function(ret) result = ret end, context(session))
    local pending = session:get_store():pop_permission()
    assert.is_not_nil(pending)
    pending.respond("allow_once")
    assert.is_true(session:permissions().network_granted())
    assert.is_false(Permissions.network_granted())
    assert.truthy(result:find("granted", 1, true))
  end)

  it("does not grant elevation through an approval retained after conversation expiry", function()
    local session, live = Session:new(), true
    local ctx = { caller = { session = session, valid = function() return live end } }
    local result
    Access.def.handler({ network = true }, function(ret) result = ret end, ctx)
    local pending = session:get_store():pop_permission()
    assert.is_not_nil(pending)
    live = false
    pending.respond("allow_once")
    assert.is_false(session:permissions().network_granted())
    assert.is_true(result.isError)
  end)
end)
