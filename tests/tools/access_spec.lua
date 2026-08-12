-- w:request_access, the elevation tool (design-agent-sandbox-v2.md phase H):
-- an accepted grant lands in the permission engine's overlays — a bind for
-- the kernel hull AND allow rules for the gate (folder), or the network
-- flag (tasks) — and applies to the next tool spawn with no restart.

local Access = require("weave.tools.access")
local Gate = require("weave.tools.gate")
local Permissions = require("weave.permissions")

describe("request_access", function()
  local real_ask_store = Gate._ask_store
  local queued

  --- a store double capturing the prompt; answer(id) plays the user
  local function fake_store()
    return {
      enqueue_permission = function(_, p)
        queued = p
      end,
    }
  end

  before_each(function()
    queued = nil
    Permissions._reset()
    Permissions.set_project_root("/proj/demo")
    -- elevations are a mode-on concept, and the sandboxed_* presets the
    -- assertions below select belong to that mode
    Permissions.set_mode("on")
    Gate._ask_store = function()
      return fake_store()
    end
  end)

  after_each(function()
    Gate._ask_store = real_ask_store
    Permissions._reset()
  end)

  local function request(args)
    local result
    Access.def.handler(args, function(ret)
      result = ret
    end)
    return function(option_id)
      queued.respond(option_id)
      return result
    end, function()
      return result
    end
  end

  it("a granted rw folder widens BOTH the hull and the rules", function()
    local answer = request({ path = "/data/corpus", mode = "rw", reason = "index the corpus" })
    assert.is_not_nil(queued)
    assert.truthy(queued.request.toolCall.title:find("read%-write access to /data/corpus"))
    assert.truthy(queued.request.toolCall.title:find("index the corpus"))
    assert.is_true(queued.client_side)

    local result = answer("allow_once")
    assert.truthy(tostring(result):find("access granted", 1, true))

    -- the hull reaches it on the next spawn
    local hull = Permissions.tool_sandbox()
    local found
    for _, b in ipairs(hull.binds) do
      if b.path == "/data/corpus" then
        found = b
      end
    end
    assert.is_not_nil(found)
    assert.equal("rw", found.mode)
    -- and the gate agrees, even under a restrictive preset
    Permissions.set_active("sandboxed_normal")
    assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = "/data/corpus/x.txt" }))
  end)

  it("a granted ro folder allows only the read-shaped tools", function()
    local answer = request({ path = "/data/refs", mode = "ro" })
    answer("allow_once")
    Permissions.set_active("sandboxed_normal")
    assert.equal("allow", Permissions.resolve({ tool = "weave:read", resource = "/data/refs/a" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:grep", resource = "/data/refs" }))
    assert.equal("ask", Permissions.resolve({ tool = "weave:write", resource = "/data/refs/a" }))
    local hull = Permissions.tool_sandbox()
    assert.equal("ro", hull.binds[#hull.binds].mode)
  end)

  it("a granted network flips the tool-sandbox flag", function()
    assert.is_false(Permissions.tool_sandbox().network)
    local answer = request({ network = true, reason = "npm install" })
    assert.truthy(queued.request.toolCall.title:find("network access"))
    answer("allow_once")
    assert.is_true(Permissions.tool_sandbox().network)
  end)

  it("declining grants nothing", function()
    local answer = request({ path = "/data", network = true })
    local result = answer("reject_once")
    assert.is_true(result.isError)
    assert.same({}, Permissions.bind_grants())
    assert.is_false(Permissions.network_granted())
  end)

  it("asks for nothing = an error, no prompt", function()
    local _, result_of = request({ reason = "hmm" })
    assert.is_nil(queued)
    assert.is_true(result_of().isError)
  end)

  it("clear_overlay revokes elevation grants too", function()
    local answer = request({ path = "/data", network = true })
    answer("allow_once")
    assert.is_true(#Permissions.bind_grants() > 0)
    Permissions.clear_overlay()
    assert.same({}, Permissions.bind_grants())
    assert.is_false(Permissions.network_granted())
    assert.is_false(Permissions.tool_sandbox().network)
  end)

  it("no active session to ask: an honest refusal", function()
    Gate._ask_store = function()
      return nil
    end
    local _, result_of = request({ path = "/data" })
    assert.is_true(result_of().isError)
    assert.truthy(result_of().content[1].text:find("no active weave session", 1, true))
  end)
end)
