-- Moving a RUNNING agent to a different sandbox profile. The profile is
-- frozen into the bwrap argv at spawn, so this is always a restart, and the
-- confirmation text is built from the direction plus the provider's
-- loadSession capability rather than from a template — "the session will be
-- restored" is otherwise a false promise whose cost is the conversation.

local Transition = require("weave.profile_transition")

describe("profile_transition.direction", function()
  it("reads the direction off the confinement order, not off the mode", function()
    assert.equal("tighten", Transition.direction("off", "blackbox"))
    assert.equal("tighten", Transition.direction("workspace", "readonly"))
    assert.equal("loosen", Transition.direction("blackbox", "workspace"))
    assert.equal("none", Transition.direction("readonly", "readonly"))
  end)
end)

describe("profile_transition.target_for", function()
  it("is nil when the preset already accepts the current profile", function()
    local preset = { name = "p", sandbox = { profile = "workspace", mode = "or_stricter" } }
    assert.is_nil(Transition.target_for(preset, "readonly"))
    assert.is_nil(Transition.target_for({ name = "plain" }, "off"))
  end)

  it("is the named profile when the requirement is unmet", function()
    assert.equal(
      "workspace",
      Transition.target_for({ sandbox = { profile = "workspace", mode = "or_stricter" } }, "off")
    )
    assert.equal("readonly", Transition.target_for({ sandbox = { profile = "readonly", mode = "exact" } }, "blackbox"))
    assert.equal(
      "workspace",
      Transition.target_for({ sandbox = { profile = "workspace", mode = "or_looser" } }, "blackbox")
    )
  end)
end)

describe("profile_transition.confirmation", function()
  it("tightening with loadSession leads with the cost and promises a restore", function()
    local c = Transition.confirmation({ from = "off", to = "readonly", load_session = true })
    assert.truthy(c.prompt:find("restart", 1, true))
    assert.truthy(c.prompt:find("restored", 1, true))
    assert.is_nil(c.prompt:find("will be lost", 1, true))
  end)

  it("tightening without loadSession says the conversation is lost, in bold", function()
    local c = Transition.confirmation({ from = "off", to = "readonly", load_session = false })
    assert.truthy(c.prompt:find("**", 1, true))
    assert.truthy(c.prompt:find("will be lost", 1, true))
    assert.is_nil(c.prompt:find("restored", 1, true))
  end)

  it("loosening leads with the consequence, then the restart", function()
    local c = Transition.confirmation({ from = "blackbox", to = "workspace", load_session = true })
    local reduce = c.prompt:find("REDUCE", 1, true)
    local restart = c.prompt:find("restart", 1, true)
    assert.truthy(reduce)
    assert.truthy(restart)
    assert.is_true(reduce < restart)
    assert.truthy(c.prompt:find("blackbox", 1, true))
    assert.truthy(c.prompt:find("workspace", 1, true))
  end)

  it("names what each target profile actually grants", function()
    assert.truthy(
      Transition.confirmation({ from = "blackbox", to = "workspace", load_session = true }).prompt:find("write")
    )
    assert.truthy(
      Transition.confirmation({ from = "blackbox", to = "off", load_session = true }).prompt:find("unsandboxed")
    )
  end)
end)

describe("profile_transition.select_preset", function()
  local Permissions = require("weave.permissions")
  local calls

  before_each(function()
    calls = { confirms = {}, restarts = {} }
    Transition._confirm = function(opts, cb)
      calls.confirms[#calls.confirms + 1] = opts
      cb(calls.answer)
    end
    Transition._restart = function(profile, cb)
      calls.restarts[#calls.restarts + 1] = profile
      cb(true)
    end
    Permissions.set_profile("off")
  end)

  after_each(function()
    Permissions._reset()
    Transition._reset()
  end)

  it("applies a compatible preset directly, with no prompt", function()
    Transition.select_preset("auto")
    assert.equal("auto", Permissions.active().name)
    assert.equal(0, #calls.confirms)
    assert.equal(0, #calls.restarts)
  end)

  it("stages an incompatible one: declining leaves the active preset untouched", function()
    calls.answer = false
    Transition.select_preset("sandboxed_normal")
    assert.equal(1, #calls.confirms)
    assert.equal(0, #calls.restarts)
    assert.equal("normal", Permissions.active().name)
  end)

  it("accepting restarts under the required profile and then applies the preset", function()
    calls.answer = true
    Transition.select_preset("sandboxed_normal")
    assert.same({ "workspace" }, calls.restarts)
    assert.equal("sandboxed_normal", Permissions.active().name)
  end)

  it("request_profile confirms in the loosening direction and is the only way down", function()
    Permissions.set_profile("blackbox")
    calls.answer = false
    Transition.request_profile("off")
    assert.truthy(calls.confirms[1].prompt:find("REDUCE", 1, true))
    assert.equal(0, #calls.restarts)

    calls.answer = true
    Transition.request_profile("off")
    assert.same({ "off" }, calls.restarts)
  end)

  it("request_profile on the current profile is a no-op", function()
    Permissions.set_profile("readonly")
    Transition.request_profile("readonly")
    assert.equal(0, #calls.confirms)
  end)

  it("a failed restart does not apply the preset", function()
    calls.answer = true
    Transition._restart = function(_, cb)
      cb(false)
    end
    Transition.select_preset("sandboxed_normal")
    assert.equal("normal", Permissions.active().name)
  end)
end)
