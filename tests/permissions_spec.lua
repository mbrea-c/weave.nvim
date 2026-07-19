-- The client-side permission engine (design-agent-sandbox.md, phase 1): a
-- generic rule set — (tool glob, resource glob, decision allow/deny/ask) —
-- resolved first-match-wins against the ACTIVE preset. Presets come from
-- three coexisting sources (builtin, setup(), runtime UI), later sources
-- shadowing earlier ones by name. Editor-global, protocol-agnostic: both ACP
-- permission requests (acp:<kind>) and client-side MCP tools (weave:<tool>,
-- perijove:<tool>, ...) resolve through the same rules.

local Permissions = require("weave.permissions")

describe("permissions.glob_match", function()
  it("* matches any run, ? one char, the rest is literal", function()
    assert.is_true(Permissions.glob_match("*", "anything at all"))
    assert.is_true(Permissions.glob_match("acp:*", "acp:edit"))
    assert.is_false(Permissions.glob_match("acp:*", "weave:edit"))
    assert.is_true(Permissions.glob_match("git *", "git status"))
    assert.is_false(Permissions.glob_match("git *", "gitk"))
    assert.is_true(Permissions.glob_match("/etc/*", "/etc/ssh/sshd_config"))
    assert.is_true(Permissions.glob_match("?.lua", "a.lua"))
    assert.is_false(Permissions.glob_match("?.lua", "ab.lua"))
    -- magic characters are literal, not lua-pattern syntax
    assert.is_true(Permissions.glob_match("a+b.c", "a+b.c"))
    assert.is_false(Permissions.glob_match("a+b.c", "aab_c"))
    -- the whole text must match, not a substring
    assert.is_false(Permissions.glob_match("etc", "/etc/hosts"))
  end)
end)

describe("permissions engine", function()
  after_each(function()
    Permissions._reset()
  end)

  it("ships the builtin presets in the legacy mode order", function()
    local names = {}
    for _, p in ipairs(Permissions.presets()) do
      names[#names + 1] = p.name
    end
    assert.same({
      "normal",
      "auto",
      "allow_edits",
      "sandboxed_normal",
      "sandboxed_auto",
      "sandboxed_allow_edits",
    }, names)
    assert.equal("normal", Permissions.active().name)
    assert.equal("Normal (ask)", Permissions.active().label)
  end)

  it("builtin normal asks for ACP requests and allows client-side tools", function()
    assert.equal("ask", Permissions.resolve({ tool = "acp:edit" }))
    assert.equal("ask", Permissions.resolve({ tool = "acp:execute", resource = "rm -rf /" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:read", resource = "/tmp/x" }))
    assert.equal("allow", Permissions.resolve({ tool = "perijove:run_cell" }))
  end)

  it("builtin auto allows everything; allow_edits allows only ACP edits", function()
    Permissions.set_active("auto")
    assert.equal("allow", Permissions.resolve({ tool = "acp:execute" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = "/etc/hosts" }))

    Permissions.set_active("allow_edits")
    assert.equal("allow", Permissions.resolve({ tool = "acp:edit" }))
    assert.equal("ask", Permissions.resolve({ tool = "acp:execute" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:read" }))
  end)

  it("resolves first-match-wins and falls back to ask when nothing matches", function()
    Permissions.save_preset({
      name = "locked",
      rules = {
        { tool = "weave:read", resource = "/safe/*", decision = "allow" },
        { tool = "weave:read", decision = "deny" },
      },
    })
    Permissions.set_active("locked")
    assert.equal("allow", Permissions.resolve({ tool = "weave:read", resource = "/safe/notes.md" }))
    assert.equal("deny", Permissions.resolve({ tool = "weave:read", resource = "/etc/passwd" }))
    -- nothing matches weave:write → the engine-wide safe default
    assert.equal("ask", Permissions.resolve({ tool = "weave:write", resource = "/safe/notes.md" }))
  end)

  it("a rule with a resource pattern never matches an action without one", function()
    Permissions.save_preset({
      name = "resourceful",
      rules = { { tool = "*", resource = "/tmp/*", decision = "deny" } },
    })
    Permissions.set_active("resourceful")
    assert.equal("deny", Permissions.resolve({ tool = "weave:write", resource = "/tmp/x" }))
    assert.equal("ask", Permissions.resolve({ tool = "weave:task_kill" }))
  end)

  it("resolve also returns the matched rule", function()
    local decision, rule = Permissions.resolve({ tool = "acp:edit" })
    assert.equal("ask", decision)
    assert.equal("acp:*", rule.tool)
    local d2, r2 = Permissions.resolve({ tool = "weave:read" })
    assert.equal("allow", d2)
    assert.equal("*", r2.tool)
  end)

  it("setup() appends setup presets after the builtins and can pick the active one", function()
    Permissions.setup({
      preset = "team",
      presets = {
        { name = "team", label = "Team policy", rules = { { tool = "*", decision = "allow" } } },
      },
    })
    local names = {}
    for _, p in ipairs(Permissions.presets()) do
      names[#names + 1] = p.name
    end
    assert.same({
      "normal",
      "auto",
      "allow_edits",
      "sandboxed_normal",
      "sandboxed_auto",
      "sandboxed_allow_edits",
      "team",
    }, names)
    assert.equal("team", Permissions.active().name)
    assert.equal("setup", Permissions.get("team").source)
    assert.equal("allow", Permissions.resolve({ tool = "acp:execute" }))
  end)

  it("runtime presets shadow builtins by name; deleting reveals the shadowed def", function()
    Permissions.save_preset({
      name = "auto",
      label = "Auto (but no deletes)",
      rules = {
        { tool = "acp:delete", decision = "ask" },
        { tool = "*", decision = "allow" },
      },
    })
    -- still ONE preset called auto, at its builtin position, now runtime-owned
    local names = {}
    for _, p in ipairs(Permissions.presets()) do
      names[#names + 1] = p.name
    end
    assert.same({
      "normal",
      "auto",
      "allow_edits",
      "sandboxed_normal",
      "sandboxed_auto",
      "sandboxed_allow_edits",
    }, names)
    assert.equal("runtime", Permissions.get("auto").source)

    Permissions.set_active("auto")
    assert.equal("ask", Permissions.resolve({ tool = "acp:delete" }))

    Permissions.delete_preset("auto")
    assert.equal("builtin", Permissions.get("auto").source)
    assert.equal("allow", Permissions.resolve({ tool = "acp:delete" }))
  end)

  it("deleting a runtime-only preset drops it and re-points active at normal", function()
    Permissions.save_preset({ name = "temp", rules = { { tool = "*", decision = "deny" } } })
    Permissions.set_active("temp")
    Permissions.delete_preset("temp")
    assert.is_nil(Permissions.get("temp"))
    assert.equal("normal", Permissions.active().name)
  end)

  it("cycle() walks the effective preset order and notifies subscribers", function()
    local fired = 0
    local unsub = Permissions.subscribe(function()
      fired = fired + 1
    end)
    assert.equal("auto", Permissions.cycle().name)
    assert.equal("allow_edits", Permissions.cycle().name)
    assert.equal("normal", Permissions.cycle().name)
    assert.equal(3, fired)
    unsub()
    Permissions.cycle()
    assert.equal(3, fired)
  end)

  it("save_preset validates loudly", function()
    assert.has_error(function()
      Permissions.save_preset({ rules = {} })
    end, "name")
    assert.has_error(function()
      Permissions.save_preset({ name = "x", rules = { { tool = "*", decision = "maybe" } } })
    end, "decision")
    assert.has_error(function()
      Permissions.save_preset({ name = "x", rules = { { decision = "allow" } } })
    end, "tool")
    assert.has_error(function()
      Permissions.delete_preset("normal") -- no runtime def to delete
    end, "runtime")
  end)

  it("set_active rejects unknown presets loudly", function()
    assert.has_error(function()
      Permissions.set_active("yolo")
    end, "yolo")
    assert.equal("normal", Permissions.active().name)
  end)
end)

describe("permissions ${project} expansion", function()
  before_each(function()
    Permissions.set_project_root("/home/me/proj")
  end)
  after_each(function()
    Permissions._reset()
  end)

  it("expands ${project} in a resource glob to the project root", function()
    Permissions.save_preset({
      name = "scoped",
      rules = {
        { tool = "weave:read", resource = "${project}/**", decision = "allow" },
        { tool = "weave:read", decision = "deny" },
      },
    })
    Permissions.set_active("scoped")
    assert.equal("allow", Permissions.resolve({ tool = "weave:read", resource = "/home/me/proj/lua/x.lua" }))
    assert.equal("deny", Permissions.resolve({ tool = "weave:read", resource = "/etc/passwd" }))
  end)

  it("a ${project} rule still never matches a resourceless action", function()
    Permissions.save_preset({
      name = "scoped",
      rules = { { tool = "weave:*", resource = "${project}/**", decision = "allow" } },
    })
    Permissions.set_active("scoped")
    assert.equal("ask", Permissions.resolve({ tool = "weave:task_status" }))
  end)

  it("falls back to the cwd when no root was set", function()
    Permissions._reset()
    Permissions.save_preset({
      name = "scoped",
      rules = { { tool = "weave:read", resource = "${project}/**", decision = "allow" } },
    })
    Permissions.set_active("scoped")
    assert.equal("allow", Permissions.resolve({ tool = "weave:read", resource = vim.fn.getcwd() .. "/init.lua" }))
  end)
end)

describe("permissions sandboxed builtins", function()
  before_each(function()
    Permissions.set_project_root("/home/me/proj")
  end)
  after_each(function()
    Permissions._reset()
  end)

  it("ships three sandboxed variants after the legacy three", function()
    local names = {}
    for _, p in ipairs(Permissions.presets()) do
      names[#names + 1] = p.name
    end
    assert.same({
      "normal",
      "auto",
      "allow_edits",
      "sandboxed_normal",
      "sandboxed_auto",
      "sandboxed_allow_edits",
    }, names)
  end)

  it("sandboxed_normal allows reads inside the project and asks outside it", function()
    Permissions.set_active("sandboxed_normal")
    assert.equal("allow", Permissions.resolve({ tool = "weave:read", resource = "/home/me/proj/a.lua" }))
    assert.equal("ask", Permissions.resolve({ tool = "weave:read", resource = "/etc/passwd" }))
    assert.equal("ask", Permissions.resolve({ tool = "weave:write", resource = "/home/me/proj/a.lua" }))
    assert.equal("ask", Permissions.resolve({ tool = "acp:edit" }))
  end)

  it("the resourceless task query tools are allowed, not caught by the catch-all ask", function()
    for _, preset in ipairs({ "sandboxed_normal", "sandboxed_auto", "sandboxed_allow_edits" }) do
      Permissions.set_active(preset)
      assert.equal("allow", Permissions.resolve({ tool = "weave:task_status" }))
      assert.equal("allow", Permissions.resolve({ tool = "weave:task_wait" }))
      assert.equal("allow", Permissions.resolve({ tool = "weave:task_kill" }))
    end
  end)

  it("sandboxed_allow_edits allows writes inside the project only", function()
    Permissions.set_active("sandboxed_allow_edits")
    assert.equal("allow", Permissions.resolve({ tool = "acp:edit" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = "/home/me/proj/a.lua" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:edit", resource = "/home/me/proj/a.lua" }))
    assert.equal("ask", Permissions.resolve({ tool = "weave:write", resource = "/etc/hosts" }))
  end)

  it("sandboxed_auto allows any weave tool inside the project, asks outside", function()
    Permissions.set_active("sandboxed_auto")
    assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = "/home/me/proj/a.lua" }))
    assert.equal("allow", Permissions.resolve({ tool = "acp:execute" }))
    assert.equal("ask", Permissions.resolve({ tool = "weave:read", resource = "/etc/passwd" }))
  end)
end)

describe("permissions sandbox requirements", function()
  after_each(function()
    Permissions._reset()
  end)

  it("orders the profiles by confinement", function()
    assert.is_true(Permissions.profile_rank("off") < Permissions.profile_rank("workspace"))
    assert.is_true(Permissions.profile_rank("workspace") < Permissions.profile_rank("readonly"))
    assert.is_true(Permissions.profile_rank("readonly") < Permissions.profile_rank("blackbox"))
  end)

  it("a preset with no sandbox field is compatible with every profile", function()
    for _, profile in ipairs({ "off", "workspace", "readonly", "blackbox" }) do
      assert.is_true(Permissions.preset_compatible(Permissions.get("normal"), profile))
    end
  end)

  it("or_stricter is satisfied by the named profile or anything stricter", function()
    Permissions.save_preset({
      name = "p",
      sandbox = { profile = "readonly", mode = "or_stricter" },
      rules = { { tool = "*", decision = "allow" } },
    })
    local p = Permissions.get("p")
    assert.is_false(Permissions.preset_compatible(p, "off"))
    assert.is_false(Permissions.preset_compatible(p, "workspace"))
    assert.is_true(Permissions.preset_compatible(p, "readonly"))
    assert.is_true(Permissions.preset_compatible(p, "blackbox"))
  end)

  it("or_stricter is the default when mode is omitted", function()
    Permissions.save_preset({
      name = "p",
      sandbox = { profile = "readonly" },
      rules = { { tool = "*", decision = "allow" } },
    })
    assert.is_false(Permissions.preset_compatible(Permissions.get("p"), "workspace"))
    assert.is_true(Permissions.preset_compatible(Permissions.get("p"), "blackbox"))
  end)

  it("exact is satisfied only by that profile", function()
    Permissions.save_preset({
      name = "p",
      sandbox = { profile = "readonly", mode = "exact" },
      rules = { { tool = "*", decision = "allow" } },
    })
    local p = Permissions.get("p")
    assert.is_false(Permissions.preset_compatible(p, "workspace"))
    assert.is_true(Permissions.preset_compatible(p, "readonly"))
    assert.is_false(Permissions.preset_compatible(p, "blackbox"))
  end)

  it("or_looser is satisfied by the named profile or anything looser", function()
    Permissions.save_preset({
      name = "p",
      sandbox = { profile = "readonly", mode = "or_looser" },
      rules = { { tool = "*", decision = "allow" } },
    })
    local p = Permissions.get("p")
    assert.is_true(Permissions.preset_compatible(p, "off"))
    assert.is_true(Permissions.preset_compatible(p, "readonly"))
    assert.is_false(Permissions.preset_compatible(p, "blackbox"))
  end)

  it("reports a reason naming the requirement and the current profile", function()
    Permissions.save_preset({
      name = "p",
      sandbox = { profile = "readonly", mode = "or_stricter" },
      rules = { { tool = "*", decision = "allow" } },
    })
    local ok, reason = Permissions.preset_compatible(Permissions.get("p"), "off")
    assert.is_false(ok)
    assert.truthy(reason:match("readonly"))
    assert.truthy(reason:match("off"))
  end)

  it("validates the sandbox field loudly", function()
    assert.has_error(function()
      Permissions.save_preset({ name = "p", sandbox = { profile = "yolo" }, rules = {} })
    end, "profile")
    assert.has_error(function()
      Permissions.save_preset({ name = "p", sandbox = { profile = "off", mode = "maybe" }, rules = {} })
    end, "mode")
  end)

  it("survives the round trip through save_preset", function()
    Permissions.save_preset({
      name = "p",
      sandbox = { profile = "blackbox", mode = "exact" },
      rules = { { tool = "*", decision = "allow" } },
    })
    assert.same({ profile = "blackbox", mode = "exact" }, Permissions.get("p").sandbox)
  end)
end)

describe("permissions cycle under a profile", function()
  after_each(function()
    Permissions._reset()
  end)

  it("skips presets incompatible with the current profile", function()
    Permissions.set_profile("off")
    local names = {}
    for _, p in ipairs(Permissions.compatible_presets()) do
      names[#names + 1] = p.name
    end
    assert.same({ "normal", "auto", "allow_edits" }, names)

    Permissions.set_profile("workspace")
    names = {}
    for _, p in ipairs(Permissions.compatible_presets()) do
      names[#names + 1] = p.name
    end
    assert.same({
      "normal",
      "auto",
      "allow_edits",
      "sandboxed_normal",
      "sandboxed_auto",
      "sandboxed_allow_edits",
    }, names)
  end)

  it("cycle() never lands on an incompatible preset", function()
    Permissions.set_profile("off")
    for _ = 1, 6 do
      local p = Permissions.cycle()
      assert.is_true(Permissions.preset_compatible(p, "off"))
    end
  end)

  it("does not filter to empty when nothing is compatible", function()
    Permissions.setup({
      presets = { { name = "only", sandbox = { profile = "blackbox" }, rules = { { tool = "*", decision = "allow" } } } },
    })
    Permissions.set_profile("off")
    -- the builtins are unconstrained, so force the pathological case directly
    assert.is_true(#Permissions.compatible_presets("off") > 0)
    assert.is_true(#Permissions.compatible_presets("blackbox") > 0)
  end)
end)

describe("permissions grant overlay", function()
  before_each(function()
    Permissions.set_project_root("/home/me/proj")
  end)
  after_each(function()
    Permissions._reset()
  end)

  it("starts empty and resolves through the active preset", function()
    Permissions.set_active("sandboxed_normal")
    assert.same({}, Permissions.grants())
    assert.equal("ask", Permissions.resolve({ tool = "weave:write", resource = "/home/me/proj/a.lua" }))
  end)

  it("an overlay rule beats a conflicting preset rule", function()
    Permissions.set_active("sandboxed_normal")
    Permissions.add_grant({ tool = "weave:write", resource = "${project}/**", decision = "allow" })
    assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = "/home/me/proj/a.lua" }))
    assert.equal("ask", Permissions.resolve({ tool = "weave:write", resource = "/etc/hosts" }))
  end)

  it("survives a preset switch and is cleared by clear_overlay", function()
    Permissions.add_grant({ tool = "weave:write", resource = "${project}/**", decision = "allow" })
    Permissions.set_active("sandboxed_normal")
    assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = "/home/me/proj/a.lua" }))
    Permissions.clear_overlay()
    assert.equal("ask", Permissions.resolve({ tool = "weave:write", resource = "/home/me/proj/a.lua" }))
  end)

  it("revoke_grant drops one rule and notifies", function()
    local fired = 0
    Permissions.subscribe(function()
      fired = fired + 1
    end)
    Permissions.add_grant({ tool = "weave:write", resource = "${project}/**", decision = "allow" })
    Permissions.add_grant({ tool = "weave:read", resource = "/etc/hosts", decision = "deny" })
    assert.equal(2, #Permissions.grants())
    Permissions.revoke_grant(1)
    assert.equal(1, #Permissions.grants())
    assert.equal("weave:read", Permissions.grants()[1].tool)
    assert.equal(3, fired)
  end)

  it("validates a grant like any other rule", function()
    assert.has_error(function()
      Permissions.add_grant({ tool = "weave:write", decision = "maybe" })
    end, "decision")
  end)

  it("grant_rule scopes to the project inside it and to the exact resource outside", function()
    assert.same(
      { tool = "weave:read", resource = "${project}/**", decision = "allow" },
      Permissions.grant_rule({ tool = "weave:read", resource = "/home/me/proj/a.lua" }, "allow")
    )
    assert.same(
      { tool = "weave:read", resource = "/home/other/.config/x", decision = "deny" },
      Permissions.grant_rule({ tool = "weave:read", resource = "/home/other/.config/x" }, "deny")
    )
    -- a resourceless action grants by tool name alone
    assert.same(
      { tool = "weave:task_start", decision = "allow" },
      Permissions.grant_rule({ tool = "weave:task_start" }, "allow")
    )
  end)
end)
