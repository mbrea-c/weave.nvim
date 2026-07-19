-- Gating tools weave does not own. Gate.wrap only reaches weave's own defs,
-- so clankbox built-ins (exec_lua) and other plugins' tools reached the agent
-- ungated — under a sandbox profile exec_lua is a full escape, since it runs
-- arbitrary Lua in the unsandboxed editor. Gate.middleware() plugs into
-- clankbox's call-time middleware chain and resolves foreign tools through
-- the same engine, as mcp:<tool>, so preset rules are the control surface.

local Gate = require("weave.tools.gate")
local Permissions = require("weave.permissions")
local SessionStore = require("weave.session_store")

--- Drive the middleware like clankbox would.
--- @return table { responded = any, ran = boolean }
local function call(name, args)
  local out = { ran = false }
  local mw = Gate.middleware()
  mw({ name = name, args = args or {}, def = {} }, function(ret)
    out.responded = ret
  end, function()
    out.ran = true
  end)
  return out
end

--- Activate an ad-hoc preset with exactly these rules.
local function rules(list)
  Permissions.save_preset({ name = "spec", rules = list })
  Permissions.set_active("spec")
end

local function text_of(result)
  if type(result) == "string" then
    return result
  end
  return result.content[1].text
end

describe("foreign tool middleware", function()
  local saved_ask_store

  before_each(function()
    saved_ask_store = Gate._ask_store
    Permissions.set_active("normal")
  end)

  after_each(function()
    Gate._ask_store = saved_ask_store
    Permissions._reset()
  end)

  it("passes a foreign tool through when the preset allows it", function()
    -- "normal" ends in a catch-all allow, so an unlisted tool runs.
    local out = call("exec_lua", { code = "return 1" })
    assert.is_true(out.ran)
    assert.is_nil(out.responded)
  end)

  it("resolves foreign tools under the mcp: namespace", function()
    rules({
      { tool = "mcp:exec_lua", decision = "deny" },
      { tool = "*", decision = "allow" },
    })
    local out = call("exec_lua", {})
    assert.is_false(out.ran)
    assert.truthy(text_of(out.responded):find("exec_lua", 1, true))
    assert.is_true(out.responded.isError)
  end)

  it("leaves weave's own tools alone, since Gate.wrap already gated them", function()
    -- Double-gating would prompt twice for one call.
    rules({
      { tool = "mcp:*", decision = "deny" },
      { tool = "*", decision = "allow" },
    })
    local out = call("read", { path = "/tmp/x" })
    assert.is_true(out.ran)
    assert.is_nil(out.responded)
  end)

  it("asks through the session store, holding the call until answered", function()
    local store = SessionStore:new()
    Gate._ask_store = function()
      return store
    end
    rules({
      { tool = "mcp:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    })

    local out = call("exec_lua", {})
    assert.is_false(out.ran)
    assert.is_nil(out.responded)

    local perm = store:get_permission()
    assert.is_not_nil(perm)
    assert.truthy(perm.request.toolCall.title:find("exec_lua", 1, true))
    assert.is_true(perm.client_side)

    perm.respond("allow_once")
    assert.is_true(out.ran)
  end)

  it("refuses the call when the ask is declined", function()
    local store = SessionStore:new()
    Gate._ask_store = function()
      return store
    end
    rules({
      { tool = "mcp:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    })

    local out = call("exec_lua", {})
    store:get_permission().respond("reject_once")
    assert.is_false(out.ran)
    assert.is_true(out.responded.isError)
  end)

  it("records a grant when the answer is an always", function()
    local store = SessionStore:new()
    Gate._ask_store = function()
      return store
    end
    rules({
      { tool = "mcp:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    })

    call("exec_lua", {})
    -- answer the way keys.lua does: respond, then pop the head
    store:get_permission().respond("reject_always")
    store:pop_permission()
    -- the grant answers the next call without asking again
    local out = call("exec_lua", {})
    assert.is_false(out.ran)
    assert.is_true(out.responded.isError)
    assert.is_nil(store:get_permission())
  end)
end)
