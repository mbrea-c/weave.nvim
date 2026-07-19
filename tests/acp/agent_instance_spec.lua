-- Process reuse. ACP is explicit that one agent process serves many sessions,
-- so the registry key matters: too coarse and a session runs at a confinement
-- it did not ask for, too fine and every session pays a process.
--
-- The key here is (provider, resolved sandbox profile). Everything below is a
-- statement about that pair.

local AgentInstance = require("weave.acp.agent_instance")
local Config = require("weave.config")

local function fake_client(config)
  return {
    config = config,
    stopped = false,
    stop = function(self)
      self.stopped = true
    end,
  }
end

describe("AgentInstance instance keying", function()
  local spawned
  local real_available

  before_each(function()
    real_available = require("weave.sandbox")._available
    AgentInstance:cleanup_all()
    AgentInstance._profile_overrides = {}
    spawned = {}
    AgentInstance._spawn = function(config, on_ready)
      local client = fake_client(config)
      spawned[#spawned + 1] = client
      if on_ready then
        on_ready(client)
      end
      return client
    end
    Config.acp_providers = Config.acp_providers or {}
    Config.acp_providers["prov"] = { command = "fake-agent", args = {} }
    Config.sandbox = { profile = "off", state_paths = {}, ro_paths = {} }
    require("weave.sandbox")._available = function()
      return true
    end
  end)

  after_each(function()
    AgentInstance:cleanup_all()
    AgentInstance._profile_overrides = {}
    AgentInstance._reset()
    require("weave.sandbox")._available = real_available
    require("weave.sandbox")._reset()
  end)

  it("reuses one process for the same provider and profile", function()
    local a = AgentInstance.get_instance("prov")
    local b = AgentInstance.get_instance("prov")
    assert.equal(a, b)
    assert.equal(1, #spawned)
  end)

  it("spawns a separate process per profile of the same provider", function()
    local off = AgentInstance.get_instance("prov")
    AgentInstance.set_profile_override("prov", "readonly")
    local ro = AgentInstance.get_instance("prov")

    assert.truthy(off ~= ro)
    assert.equal(2, #spawned)
    assert.equal("readonly", ro.config.sandbox.profile)
    -- and the first one is still alive, serving whoever already had it
    assert.is_false(off.stopped)
    assert.equal(off, AgentInstance.instance("prov", "off"))
  end)

  it("returns to the original process when the profile comes back", function()
    local off = AgentInstance.get_instance("prov")
    AgentInstance.set_profile_override("prov", "readonly")
    AgentInstance.get_instance("prov")
    AgentInstance.set_profile_override("prov", nil)

    assert.equal(off, AgentInstance.get_instance("prov"))
    assert.equal(2, #spawned)
  end)

  it("keys on the RESOLVED profile, so a degraded sandbox shares one process", function()
    require("weave.sandbox")._available = function()
      return false -- no bwrap: every profile degrades to off
    end
    local a = AgentInstance.get_instance("prov")
    AgentInstance.set_profile_override("prov", "blackbox")
    local b = AgentInstance.get_instance("prov")

    assert.equal(a, b)
    assert.equal(1, #spawned)
  end)

  it("stop() drops every profile of a provider by default", function()
    local off = AgentInstance.get_instance("prov")
    AgentInstance.set_profile_override("prov", "readonly")
    local ro = AgentInstance.get_instance("prov")

    AgentInstance.stop("prov")
    assert.is_true(off.stopped)
    assert.is_true(ro.stopped)
    assert.is_nil(AgentInstance.instance("prov", "off"))
  end)

  it("stop() with a profile drops only that one", function()
    local off = AgentInstance.get_instance("prov")
    AgentInstance.set_profile_override("prov", "readonly")
    local ro = AgentInstance.get_instance("prov")

    AgentInstance.stop("prov", "readonly")
    assert.is_false(off.stopped)
    assert.is_true(ro.stopped)
    assert.equal(off, AgentInstance.instance("prov", "off"))
  end)
end)

describe("AgentInstance.reap", function()
  local spawned

  before_each(function()
    AgentInstance:cleanup_all()
    AgentInstance._profile_overrides = {}
    spawned = {}
    AgentInstance._spawn = function(config)
      local client = fake_client(config)
      spawned[#spawned + 1] = client
      return client
    end
    Config.acp_providers = Config.acp_providers or {}
    Config.acp_providers["prov"] = { command = "fake-agent", args = {} }
    Config.sandbox = { profile = "off", state_paths = {}, ro_paths = {} }
  end)

  after_each(function()
    AgentInstance:cleanup_all()
    AgentInstance._profile_overrides = {}
    AgentInstance._reset()
  end)

  it("stops instances no live session is using", function()
    local orphan = AgentInstance.get_instance("prov")
    local keeper = {
      stopped = false,
      stop = function(s)
        s.stopped = true
      end,
    }
    AgentInstance._instances["prov"]["readonly"] = keeper

    AgentInstance._live_clients = function()
      return { [keeper] = true }
    end
    AgentInstance.reap()

    assert.is_true(orphan.stopped)
    assert.is_false(keeper.stopped)
    assert.is_nil(AgentInstance.instance("prov", "off"))
    assert.equal(keeper, AgentInstance.instance("prov", "readonly"))
  end)
end)
