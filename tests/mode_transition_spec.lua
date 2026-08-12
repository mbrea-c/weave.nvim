-- Toggling a RUNNING agent between sandbox modes. The mode is frozen into
-- the bwrap argv at spawn, so this is always a restart — the ONE remaining
-- restart in the v2 design — and the confirmation text is built from the
-- direction plus the provider's loadSession capability rather than from a
-- template: "the session will be restored" is otherwise a false promise
-- whose cost is the conversation.

local Transition = require("weave.mode_transition")

describe("mode_transition.direction", function()
  it("on is tighter than off; same is none", function()
    assert.equal("tighten", Transition.direction("off", "on"))
    assert.equal("loosen", Transition.direction("on", "off"))
    assert.equal("none", Transition.direction("on", "on"))
    assert.equal("none", Transition.direction("off", "off"))
  end)
end)

describe("mode_transition.confirmation", function()
  it("tightening with loadSession leads with the cost and promises a restore", function()
    local c = Transition.confirmation({ from = "off", to = "on", load_session = true })
    assert.truthy(c.prompt:find("restart", 1, true))
    assert.truthy(c.prompt:find("restored", 1, true))
    assert.is_nil(c.prompt:find("will be lost", 1, true))
  end)

  it("tightening without loadSession says the conversation is lost, in bold", function()
    local c = Transition.confirmation({ from = "off", to = "on", load_session = false })
    assert.truthy(c.prompt:find("**", 1, true))
    assert.truthy(c.prompt:find("will be lost", 1, true))
    assert.is_nil(c.prompt:find("restored", 1, true))
  end)

  it("loosening leads with the consequence, then the restart", function()
    local c = Transition.confirmation({ from = "on", to = "off", load_session = true })
    local reduce = c.prompt:find("REDUCE", 1, true)
    local restart = c.prompt:find("restart", 1, true)
    assert.truthy(reduce)
    assert.truthy(restart)
    assert.is_true(reduce < restart)
    -- the consequence is concrete, not a category
    assert.truthy(c.prompt:find("whole filesystem", 1, true))
  end)
end)

describe("mode_transition.request_mode", function()
  local Permissions = require("weave.permissions")
  local calls

  before_each(function()
    calls = { confirms = {}, restarts = {} }
    Transition._confirm = function(opts, cb)
      calls.confirms[#calls.confirms + 1] = opts
      cb(calls.answer)
    end
    Transition._restart = function(mode, cb)
      calls.restarts[#calls.restarts + 1] = mode
      cb(true)
    end
    Permissions.set_mode("off")
  end)

  after_each(function()
    Permissions._reset()
    Transition._reset()
  end)

  it("confirms in the loosening direction and is the only way down", function()
    Permissions.set_mode("on")
    calls.answer = false
    Transition.request_mode("off")
    assert.truthy(calls.confirms[1].prompt:find("REDUCE", 1, true))
    assert.equal(0, #calls.restarts)

    calls.answer = true
    Transition.request_mode("off")
    assert.same({ "off" }, calls.restarts)
  end)

  it("tightening restarts under mode on once accepted", function()
    calls.answer = true
    Transition.request_mode("on")
    assert.same({ "on" }, calls.restarts)
  end)

  it("the current mode is a no-op", function()
    Transition.request_mode("off")
    assert.equal(0, #calls.confirms)
    assert.equal(0, #calls.restarts)
  end)

  it("declining applies nothing", function()
    calls.answer = false
    local result
    Transition.request_mode("on", function(ok)
      result = ok
    end)
    assert.is_false(result)
    assert.equal(0, #calls.restarts)
  end)
end)

describe("preset selection needs no transition", function()
  local Permissions = require("weave.permissions")

  after_each(function()
    Permissions._reset()
  end)

  -- Selecting a preset the CURRENT mode allows is free: no confirmation, no
  -- restart. Only the mode toggle itself restarts, which is what makes the
  -- mode tags safe to enforce strictly — the presets for the mode you are in
  -- are always reachable without one.
  it("any preset for the current mode activates directly", function()
    Permissions.set_mode("off")
    Permissions.set_active("unsandboxed_auto")
    assert.equal("unsandboxed_auto", Permissions.active().name)
    Permissions.set_mode("on")
    Permissions.set_active("auto")
    assert.equal("auto", Permissions.active().name)
  end)

  it("a preset from the other mode needs the transition, not set_active", function()
    Permissions.set_mode("off")
    assert.has_error(function()
      Permissions.set_active("ask")
    end, "sandbox mode")
  end)
end)
