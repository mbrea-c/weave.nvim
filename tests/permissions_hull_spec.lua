-- The preset sandbox section, v2 (design-agent-sandbox-v2.md, phase C): the
-- kernel hull tool invocations run under. Orthogonal to the rules — both are
-- specified, neither derived — with lint_preset flagging the one confusing
-- combination (a non-deny rule no bind reaches).

local Permissions = require("weave.permissions")

--- assert an error whose message contains `needle` (plain find, no patterns)
local function assert_errors_with(fn, needle)
  local ok, err = pcall(fn)
  assert.is_false(ok)
  assert.truthy(tostring(err):find(needle, 1, true), ("error %q does not contain %q"):format(tostring(err), needle))
end

describe("preset sandbox hull", function()
  before_each(function()
    Permissions._reset()
    Permissions.set_project_root("/proj/demo")
  end)
  after_each(function()
    Permissions._reset()
  end)

  describe("validation", function()
    it("accepts a v2-only section (binds + network, no profile)", function()
      Permissions.save_preset({
        name = "hull_only",
        rules = { { tool = "*", decision = "allow" } },
        sandbox = { binds = { { path = "${project}" }, { path = "/data", mode = "ro" } }, network = true },
      })
      local p = Permissions.get("hull_only")
      assert.equal("/data", p.sandbox.binds[2].path)
      assert.equal("ro", p.sandbox.binds[2].mode)
      assert.is_true(p.sandbox.network)
    end)

    it("rejects the removed v1 requirement fields loudly", function()
      assert_errors_with(function()
        Permissions.save_preset({
          name = "both",
          rules = {},
          sandbox = { profile = "workspace", binds = { { path = "${project}" } } },
        })
      end, "removed")
    end)

    it("rejects malformed binds and network", function()
      assert_errors_with(function()
        Permissions.save_preset({ name = "b1", rules = {}, sandbox = { binds = { { mode = "rw" } } } })
      end, "binds[1].path")
      assert_errors_with(function()
        Permissions.save_preset({ name = "b2", rules = {}, sandbox = { binds = { { path = "/x", mode = "rx" } } } })
      end, "binds[1].mode")
      assert_errors_with(function()
        Permissions.save_preset({ name = "b3", rules = {}, sandbox = { network = "yes" } })
      end, "`sandbox.network` must be a boolean")
    end)

    it("copies the section: caller mutations never reach the engine", function()
      local binds = { { path = "/data" } }
      Permissions.save_preset({ name = "own", rules = {}, sandbox = { binds = binds } })
      binds[1].path = "/mutated"
      assert.equal("/data", Permissions.get("own").sandbox.binds[1].path)
    end)
  end)

  describe("tool_sandbox", function()
    it("defaults to project-rw, network off", function()
      local hull = Permissions.tool_sandbox()
      assert.same({ binds = { { path = "/proj/demo", mode = "rw" } }, network = false }, hull)
    end)

    it("expands ${project} and defaults bind mode to rw", function()
      Permissions.save_preset({
        name = "custom",
        rules = {},
        sandbox = { binds = { { path = "${project}/sub" }, { path = "/data", mode = "ro" } }, network = true },
      })
      local hull = Permissions.tool_sandbox(Permissions.get("custom"))
      assert.same({
        binds = { { path = "/proj/demo/sub", mode = "rw" }, { path = "/data", mode = "ro" } },
        network = true,
      }, hull)
    end)

    it("explicit binds REPLACE the project default", function()
      Permissions.save_preset({ name = "narrow", rules = {}, sandbox = { binds = { { path = "/data" } } } })
      local hull = Permissions.tool_sandbox(Permissions.get("narrow"))
      assert.equal(1, #hull.binds)
      assert.equal("/data", hull.binds[1].path)
    end)
  end)

  describe("per-tool overrides", function()
    before_each(function()
      Permissions.save_preset({
        name = "pertool",
        rules = {},
        sandbox = {
          binds = { { path = "${project}" } },
          network = false,
          tools = {
            ["weave:task_start"] = { network = true },
            ["weave:grep"] = { binds = { { path = "/data", mode = "ro" } } },
          },
        },
      })
    end)

    it("an override replaces only the keys it sets", function()
      local preset = Permissions.get("pertool")
      -- network override: binds still the global ones
      local tasks = Permissions.tool_sandbox(preset, "weave:task_start")
      assert.is_true(tasks.network)
      assert.same({ { path = "/proj/demo", mode = "rw" } }, tasks.binds)
      -- binds override: network still the global one
      local grep = Permissions.tool_sandbox(preset, "weave:grep")
      assert.is_false(grep.network)
      assert.same({ { path = "/data", mode = "ro" } }, grep.binds)
    end)

    it("a tool with no override, and the toolless call, get the global hull", function()
      local preset = Permissions.get("pertool")
      local expected = { binds = { { path = "/proj/demo", mode = "rw" } }, network = false }
      assert.same(expected, Permissions.tool_sandbox(preset, "weave:read"))
      assert.same(expected, Permissions.tool_sandbox(preset))
    end)

    it("elevation grants apply GLOBALLY, overridden tools included", function()
      Permissions.add_bind_grant({ path = "/granted", mode = "rw" })
      Permissions.set_network_granted(true)
      local preset = Permissions.get("pertool")
      for _, tool in ipairs({ "weave:grep", "weave:task_start", "weave:read" }) do
        local hull = Permissions.tool_sandbox(preset, tool)
        assert.is_true(hull.network)
        assert.equal("/granted", hull.binds[#hull.binds].path)
      end
    end)

    it("validates overrides like the global section", function()
      assert_errors_with(function()
        Permissions.save_preset({
          name = "bad",
          rules = {},
          sandbox = { tools = { ["weave:read"] = { binds = { { mode = "rw" } } } } },
        })
      end, 'sandbox.tools["weave:read"].binds[1].path')
      assert_errors_with(function()
        Permissions.save_preset({
          name = "bad2",
          rules = {},
          sandbox = { tools = { ["weave:read"] = { network = 1 } } },
        })
      end, "network must be a boolean")
    end)

    it("lint counts a per-tool bind as reachable", function()
      local warnings = Permissions.lint_preset({
        name = "override_reach",
        sandbox = {
          binds = { { path = "${project}" } },
          tools = { ["weave:grep"] = { binds = { { path = "/data" } } } },
        },
        rules = { { tool = "weave:grep", resource = "/data/**", decision = "allow" } },
      })
      assert.same({}, warnings)
    end)
  end)

  describe("lint_preset", function()
    it("passes a preset whose path rules live inside the hull", function()
      local warnings = Permissions.lint_preset({
        name = "ok",
        rules = {
          { tool = "weave:read", resource = "${project}/**", decision = "allow" },
          { tool = "weave:task_start", resource = "git *", decision = "allow" }, -- command, not a path
          { tool = "weave:read", resource = "/etc/**", decision = "deny" }, -- deny needs no bind
        },
      })
      assert.same({}, warnings)
    end)

    it("flags a non-deny path rule outside every bind", function()
      local warnings = Permissions.lint_preset({
        name = "leaky",
        rules = { { tool = "weave:read", resource = "/etc/ssh/**", decision = "allow" } },
      })
      assert.equal(1, #warnings)
      assert.truthy(warnings[1]:find("/etc/ssh/**", 1, true))
    end)

    it("respects path boundaries: /a/b does not cover /a/bc", function()
      local preset = {
        name = "boundary",
        sandbox = { binds = { { path = "/a/b" } } },
        rules = { { tool = "weave:read", resource = "/a/bc/**", decision = "allow" } },
      }
      assert.equal(1, #Permissions.lint_preset(preset))
      preset.rules[1].resource = "/a/b/c/**"
      assert.same({}, Permissions.lint_preset(preset))
    end)

    it("a bind under the rule's static prefix counts as reachable", function()
      -- rule /** with bind /data: the gate may allow wider than the hull;
      -- some of the allowed space is reachable, so this is not the confusing
      -- case the lint exists for
      local warnings = Permissions.lint_preset({
        name = "wide_rule",
        sandbox = { binds = { { path = "/data" } } },
        rules = { { tool = "weave:read", resource = "/**", decision = "allow" } },
      })
      assert.same({}, warnings)
    end)

    it("warns when explicit binds exclude the project the rules assume", function()
      local warnings = Permissions.lint_preset({
        name = "no_project",
        sandbox = { binds = { { path = "/data" } } },
        rules = { { tool = "weave:*", resource = "${project}/**", decision = "allow" } },
      })
      assert.equal(1, #warnings)
    end)
  end)
end)
