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
    assert.same({ "normal", "auto", "allow_edits" }, names)
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
    assert.same({ "normal", "auto", "allow_edits", "team" }, names)
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
    assert.same({ "normal", "auto", "allow_edits" }, names)
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
