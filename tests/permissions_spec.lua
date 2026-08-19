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

  it("ships four shapes per sandbox mode, sandboxed first, plus yolo", function()
    local names = {}
    for _, p in ipairs(Permissions.presets()) do
      names[#names + 1] = p.name
    end
    -- the sandboxed four hold the PLAIN names: the sandbox is the default, so
    -- a half-remembered name lands on the confined preset, not the open one.
    -- `yolo` is sandbox-on only — with the sandbox off, unsandboxed_auto is
    -- already everything yolo could offer.
    assert.same({
      "ask",
      "read_only",
      "edit",
      "auto",
      "yolo",
      "unsandboxed_ask",
      "unsandboxed_read_only",
      "unsandboxed_edit",
      "unsandboxed_auto",
    }, names)
    assert.equal("ask", Permissions.active().name)
    assert.equal("Ask", Permissions.active().label)
  end)

  it("unsandboxed_ask asks for ACP requests and allows client-side tools", function()
    Permissions.set_mode("off")
    Permissions.set_active("unsandboxed_ask")
    assert.equal("ask", Permissions.resolve({ tool = "acp:edit" }))
    assert.equal("ask", Permissions.resolve({ tool = "acp:execute", resource = "rm -rf /" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:read", resource = "/tmp/x" }))
    assert.equal("allow", Permissions.resolve({ tool = "perijove:run_cell" }))
  end)

  it("unsandboxed auto allows everything; edit allows only ACP reads and edits", function()
    Permissions.set_mode("off")
    Permissions.set_active("unsandboxed_auto")
    assert.equal("allow", Permissions.resolve({ tool = "acp:execute" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = "/etc/hosts" }))

    Permissions.set_active("unsandboxed_edit")
    assert.equal("allow", Permissions.resolve({ tool = "acp:edit" }))
    assert.equal("allow", Permissions.resolve({ tool = "acp:read" }))
    assert.equal("ask", Permissions.resolve({ tool = "acp:execute" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:read" }))
  end)

  it("unsandboxed read-only turns back writes on BOTH sides", function()
    Permissions.set_mode("off")
    Permissions.set_active("unsandboxed_read_only")
    assert.equal("allow", Permissions.resolve({ tool = "acp:read" }))
    assert.equal("deny", Permissions.resolve({ tool = "acp:edit" }))
    assert.equal("deny", Permissions.resolve({ tool = "acp:execute" }))
    -- denying only the agent's tools would just make it switch to weave's
    assert.equal("deny", Permissions.resolve({ tool = "weave:write", resource = "/tmp/x" }))
    assert.equal("deny", Permissions.resolve({ tool = "weave:task_start", resource = "ls" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:read", resource = "/tmp/x" }))
  end)

  -- Annotations are the agent's whole output channel in tutor mode, and they
  -- change nothing: a virtual-text overlay, no file touched. Making the user
  -- approve twenty of them during one review would make the mode unusable, so
  -- every builtin allows them — including read_only, which is the preset tutor
  -- mode will normally run under.
  it("allows annotating under every builtin, read_only included", function()
    Permissions.set_project_root("/home/me/proj")
    for _, name in ipairs({ "ask", "read_only", "edit", "auto", "yolo" }) do
      Permissions.set_mode("on")
      Permissions.set_active(name)
      assert.equal("allow", Permissions.resolve({ tool = "weave:annotate", resource = "/home/me/proj/a.lua" }), name)
      assert.equal("allow", Permissions.resolve({ tool = "weave:annotate_list" }), name)
      assert.equal("allow", Permissions.resolve({ tool = "weave:annotate_update" }), name)
      assert.equal("allow", Permissions.resolve({ tool = "weave:annotate_dismiss" }), name)
    end
    for _, name in ipairs({ "unsandboxed_ask", "unsandboxed_read_only", "unsandboxed_edit", "unsandboxed_auto" }) do
      Permissions.set_mode("off")
      Permissions.set_active(name)
      assert.equal("allow", Permissions.resolve({ tool = "weave:annotate", resource = "/tmp/a.lua" }), name)
    end
  end)

  -- ...but they are still workspace-scoped under the sandbox, like every other
  -- weave tool: a note on a file outside the project is a path the agent has
  -- to ask for.
  it("still refuses to annotate outside the workspace when sandboxed", function()
    Permissions.set_project_root("/home/me/proj")
    Permissions.set_mode("on")
    Permissions.set_active("read_only")
    assert.equal("deny", Permissions.resolve({ tool = "weave:annotate", resource = "/etc/hosts" }))
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
    Permissions.set_mode("off")
    Permissions.set_active("unsandboxed_ask")
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
      "ask",
      "read_only",
      "edit",
      "auto",
      "yolo",
      "unsandboxed_ask",
      "unsandboxed_read_only",
      "unsandboxed_edit",
      "unsandboxed_auto",
      "team",
    }, names)
    assert.equal("team", Permissions.active().name)
    assert.equal("setup", Permissions.get("team").source)
    assert.equal("allow", Permissions.resolve({ tool = "acp:execute" }))
  end)

  it("runtime presets shadow builtins by name; deleting reveals the shadowed def", function()
    Permissions.set_mode("off")
    Permissions.save_preset({
      name = "unsandboxed_auto",
      label = "Auto (but no deletes)",
      for_mode = "off",
      rules = {
        { tool = "acp:delete", decision = "ask" },
        { tool = "*", decision = "allow" },
      },
    })
    -- still ONE preset by that name, at its builtin position, now runtime-owned
    local names = {}
    for _, p in ipairs(Permissions.presets()) do
      names[#names + 1] = p.name
    end
    assert.same({
      "ask",
      "read_only",
      "edit",
      "auto",
      "yolo",
      "unsandboxed_ask",
      "unsandboxed_read_only",
      "unsandboxed_edit",
      "unsandboxed_auto",
    }, names)
    assert.equal("runtime", Permissions.get("unsandboxed_auto").source)

    Permissions.set_active("unsandboxed_auto")
    assert.equal("ask", Permissions.resolve({ tool = "acp:delete" }))

    Permissions.delete_preset("unsandboxed_auto")
    assert.equal("builtin", Permissions.get("unsandboxed_auto").source)
    assert.equal("allow", Permissions.resolve({ tool = "acp:delete" }))
  end)

  it("deleting a runtime-only preset drops it and re-points active inside the mode", function()
    Permissions.set_mode("on")
    Permissions.save_preset({ name = "temp", rules = { { tool = "*", decision = "deny" } } })
    Permissions.set_active("temp")
    Permissions.delete_preset("temp")
    assert.is_nil(Permissions.get("temp"))
    assert.equal("ask", Permissions.active().name)
  end)

  it("cycle() walks the effective preset order and notifies subscribers", function()
    Permissions.set_mode("on")
    local fired = 0
    local unsub = Permissions.subscribe(function()
      fired = fired + 1
    end)
    -- the sandboxed shapes, in shipped order, starting from `ask` — yolo last,
    -- so the cycle passes through every scoped preset before the open one
    assert.equal("read_only", Permissions.cycle().name)
    assert.equal("edit", Permissions.cycle().name)
    assert.equal("auto", Permissions.cycle().name)
    assert.equal("yolo", Permissions.cycle().name)
    assert.equal("ask", Permissions.cycle().name)
    assert.equal(5, fired)
    unsub()
    Permissions.cycle()
    assert.equal(5, fired)
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
      Permissions.delete_preset("ask") -- no runtime def to delete
    end, "runtime")
  end)

  it("set_active rejects unknown presets loudly", function()
    assert.has_error(function()
      Permissions.set_active("nonesuch")
    end, "nonesuch")
    assert.equal("ask", Permissions.active().name)
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

  it("`dir/**` covers the directory itself, so a cwd-rooted grep is not an ask", function()
    Permissions.save_preset({
      name = "scoped",
      rules = {
        { tool = "weave:grep", resource = "${project}/**", decision = "allow" },
        { tool = "weave:grep", decision = "ask" },
      },
    })
    Permissions.set_active("scoped")
    assert.equal("allow", Permissions.resolve({ tool = "weave:grep", resource = "/home/me/proj" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:grep", resource = "/home/me/proj/lua" }))
    -- but a sibling that merely shares the prefix is still outside
    assert.equal("ask", Permissions.resolve({ tool = "weave:grep", resource = "/home/me/projector" }))
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
    -- they are tagged for_mode = "on" and refused anywhere else
    Permissions.set_mode("on")
  end)
  after_each(function()
    Permissions._reset()
  end)

  local SANDBOXED = { "ask", "read_only", "edit", "auto", "yolo" }
  -- The four that treat the workspace as the world. `yolo` scopes nothing, so
  -- every assertion about scoping is about these and not about it.
  local SCOPED = { "ask", "read_only", "edit", "auto" }

  it("ships the sandboxed shapes ahead of the unsandboxed ones", function()
    local names = {}
    for _, p in ipairs(Permissions.available("on")) do
      names[#names + 1] = p.name
    end
    assert.same(SANDBOXED, names)
  end)

  it("ask asks inside the workspace and denies outside it", function()
    Permissions.set_active("ask")
    assert.equal("ask", Permissions.resolve({ tool = "weave:read", resource = "/home/me/proj/a.lua" }))
    assert.equal("ask", Permissions.resolve({ tool = "weave:write", resource = "/home/me/proj/a.lua" }))
    -- the agent's OWN tools are turned back: in mode on they only reach the
    -- empty read-only decoy, and letting them through taught a live agent
    -- that the project was empty
    assert.equal("deny", Permissions.resolve({ tool = "acp:edit" }))
  end)

  it("every scoped sandboxed preset denies outside the workspace, pointing at request_access", function()
    for _, preset in ipairs(SCOPED) do
      Permissions.set_active(preset)
      local decision, rule = Permissions.resolve({ tool = "weave:read", resource = "/etc/passwd" })
      assert.equal("deny", decision, preset .. " reads outside the workspace")
      assert.truthy(rule.message:find("request_access", 1, true), preset .. " says how to ask")
    end
  end)

  it("acp:mcp — the agent calling OUR tools — is allowed, not denied", function()
    for _, preset in ipairs(SANDBOXED) do
      Permissions.set_active(preset)
      assert.equal("allow", Permissions.resolve({ tool = "acp:mcp", resource = "clankbox_read" }))
    end
  end)

  it("lets the agent read what the USER attached, and nothing else of its own", function()
    local Attachments = require("weave.attachments")
    local staging = Attachments.root()
    for _, preset in ipairs(SANDBOXED) do
      Permissions.set_active(preset)
      -- the staged file is bound into the hull, so the agent's own read tool
      -- is the right way to look at an image — w:read returns text
      assert.equal("allow", Permissions.resolve({ tool = "acp:read", resource = staging .. "/shot.png" }), preset)
      -- everywhere else its builtin read is still a dead end
      assert.equal("deny", Permissions.resolve({ tool = "acp:read", resource = "/home/me/proj/a.lua" }), preset)
    end
  end)

  it("the attachments allowance does not read as an unreachable bind", function()
    -- the hull governs the TOOL layer; an acp:* rule speaks about the agent
    -- sandbox, whose binds are not the tool binds
    for _, preset in ipairs(SANDBOXED) do
      assert.same({}, Permissions.lint_preset(Permissions.get(preset)), preset)
    end
  end)

  it("the acp:* deny carries a message pointing at the client-side tools", function()
    Permissions.set_active("ask")
    local decision, rule = Permissions.resolve({ tool = "acp:read", resource = "/home/me/proj/a.lua" })
    assert.equal("deny", decision)
    assert.truthy(rule.message:find("weave", 1, true))
  end)

  it("the resourceless task query tools are allowed, not caught by a catch-all", function()
    for _, preset in ipairs(SANDBOXED) do
      Permissions.set_active(preset)
      assert.equal("allow", Permissions.resolve({ tool = "weave:task_status" }), preset)
      assert.equal("allow", Permissions.resolve({ tool = "weave:task_wait" }), preset)
      assert.equal("allow", Permissions.resolve({ tool = "weave:task_kill" }), preset)
    end
  end)

  it("read_only allows the read-shaped tools and denies the rest, hull included", function()
    Permissions.set_active("read_only")
    assert.equal("allow", Permissions.resolve({ tool = "weave:read", resource = "/home/me/proj/a.lua" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:grep", resource = "/home/me/proj" }))
    for _, tool in ipairs({ "weave:write", "weave:edit", "weave:task_start" }) do
      local decision, rule = Permissions.resolve({ tool = tool, resource = "/home/me/proj/a.lua" })
      assert.equal("deny", decision, tool)
      assert.truthy(rule.message:find("read-only", 1, true), tool)
    end
    -- and the kernel agrees: tools spawned under it get the project ro
    assert.same(
      { path = "/home/me/proj", mode = "ro" },
      Permissions.tool_sandbox(Permissions.get("read_only")).binds[1]
    )
  end)

  it("edit writes inside the workspace unprompted but still asks to run commands", function()
    Permissions.set_active("edit")
    assert.equal("deny", Permissions.resolve({ tool = "acp:edit" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = "/home/me/proj/a.lua" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:edit", resource = "/home/me/proj/a.lua" }))
    assert.equal("ask", Permissions.resolve({ tool = "weave:task_start", resource = "rm -rf /" }))
    assert.equal("deny", Permissions.resolve({ tool = "weave:write", resource = "/etc/hosts" }))
  end)

  it("auto allows any weave tool inside the workspace — except widening the sandbox", function()
    Permissions.set_active("auto")
    assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = "/home/me/proj/a.lua" }))
    assert.equal("allow", Permissions.resolve({ tool = "weave:task_start", resource = "make" }))
    assert.equal("deny", Permissions.resolve({ tool = "acp:execute" }))
    -- grants are the user's call in every preset
    assert.equal("ask", Permissions.resolve({ tool = "weave:request_access" }))
    -- ...but the workspace boundary still holds: auto is about prompting, not
    -- about reach
    assert.equal("deny", Permissions.resolve({ tool = "weave:write", resource = "/etc/hosts" }))
  end)

  -- "auto" is the user saying do not ask me, and a foreign MCP call is a tool
  -- call like any other. These used to ask while `unsandboxed_auto` allowed
  -- exactly the same calls, which made the sandboxed shape the odd one out —
  -- and made every proxied third-party server prompt per call.
  it("auto runs foreign MCP tools unprompted; the scoped three still ask", function()
    Permissions.set_active("auto")
    assert.equal("allow", Permissions.resolve({ tool = "mcp:exec_lua" }))
    assert.equal("allow", Permissions.resolve({ tool = "mcp:some_server_tool" }))
    for _, preset in ipairs({ "ask", "read_only", "edit" }) do
      Permissions.set_active(preset)
      assert.equal("ask", Permissions.resolve({ tool = "mcp:exec_lua" }), preset)
    end
  end)

  describe("yolo", function()
    before_each(function()
      Permissions.set_active("yolo")
    end)

    it("asks nothing and scopes nothing", function()
      assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = "/etc/hosts" }))
      assert.equal("allow", Permissions.resolve({ tool = "weave:task_start", resource = "rm -rf /" }))
      assert.equal("allow", Permissions.resolve({ tool = "weave:web_fetch", resource = "https://x/" }))
      assert.equal("allow", Permissions.resolve({ tool = "mcp:exec_lua" }))
      assert.equal("allow", Permissions.resolve({ tool = "perijove:run_cell" }))
    end)

    -- The one thing a preset cannot hand back: mode on confines the AGENT
    -- process invariantly, so its builtin tools still meet the empty project
    -- stand-in. Allowing them would trade a redirection the agent acts on for
    -- a confident wrong answer read off an empty directory.
    it("still turns the agent's OWN tools back at the sandbox wall", function()
      local decision, rule = Permissions.resolve({ tool = "acp:read", resource = "/home/me/proj/a.lua" })
      assert.equal("deny", decision)
      assert.truthy(rule.message:find("weave", 1, true))
      -- ...while the tools weave brokers stay reachable, as everywhere else
      assert.equal("allow", Permissions.resolve({ tool = "acp:mcp", resource = "clankbox_read" }))
    end)

    it("hands its tools the whole filesystem, writable, with the network", function()
      local hull = Permissions.tool_sandbox(Permissions.get("yolo"))
      assert.is_true(hull.network)
      assert.same({ path = "/", mode = "rw" }, hull.binds[1])
      -- $HOME is a tmpfs in the floor, so the writable root alone does not
      -- bring it back — only a bind over it does
      assert.same({ path = vim.uv.os_homedir(), mode = "rw" }, hull.binds[2])
    end)

    it("is sandbox-on only, and is not what the sandbox turning off falls back to", function()
      assert.equal("on", Permissions.get("yolo").for_mode)
      -- there is no `unsandboxed_yolo`: going to mode off falls back to the
      -- first preset that mode allows rather than silently handing over an
      -- allow-everything preset with no sandbox under it at all
      Permissions.set_mode("off")
      assert.equal("unsandboxed_ask", Permissions.active().name)
    end)
  end)
end)

describe("permissions sandbox mode", function()
  after_each(function()
    Permissions._reset()
  end)

  it("set_mode/current_mode reflect the last spawn", function()
    Permissions.set_mode("off")
    assert.equal("off", Permissions.current_mode())
    Permissions.set_mode("on")
    assert.equal("on", Permissions.current_mode())
    -- nil = no spawn to speak for; fall back to what the config resolves to
    Permissions.set_mode(nil)
    assert.equal(require("weave.sandbox").resolve().mode, Permissions.current_mode())
  end)

  it("the removed v1 requirement fields error loudly", function()
    -- a preset naming a confinement requirement weave no longer honours
    -- must not silently load as if it were honoured
    assert.has_error(function()
      Permissions.save_preset({ name = "p", sandbox = { profile = "workspace" }, rules = {} })
    end, "removed")
    assert.has_error(function()
      Permissions.save_preset({ name = "p", sandbox = { mode = "or_stricter" }, rules = {} })
    end, "removed")
  end)

  it("available() offers only the presets the mode allows", function()
    local function names(mode)
      local out = {}
      for _, p in ipairs(Permissions.available(mode)) do
        out[#out + 1] = p.name
      end
      return out
    end
    assert.same({
      "unsandboxed_ask",
      "unsandboxed_read_only",
      "unsandboxed_edit",
      "unsandboxed_auto",
    }, names("off"))
    assert.same({ "ask", "read_only", "edit", "auto", "yolo" }, names("on"))
  end)

  it("an untagged preset is available under both modes", function()
    Permissions.save_preset({ name = "either", rules = { { tool = "*", decision = "allow" } } })
    local function has(mode)
      for _, p in ipairs(Permissions.available(mode)) do
        if p.name == "either" then
          return true
        end
      end
      return false
    end
    assert.is_true(has("off"))
    assert.is_true(has("on"))
  end)

  it("set_active refuses a preset belonging to the other mode", function()
    Permissions.set_mode("off")
    assert.has_error(function()
      Permissions.set_active("edit") -- sandboxed, and the sandbox is off
    end, "sandbox mode")
    assert.equal("unsandboxed_ask", Permissions.active().name)
    Permissions.set_mode("on")
    assert.has_error(function()
      Permissions.set_active("unsandboxed_auto")
    end, "sandbox mode")
  end)

  it("cycle() stays inside the presets the mode allows", function()
    Permissions.set_mode("on")
    local seen = {}
    for _ = 1, 5 do
      seen[#seen + 1] = Permissions.cycle().name
    end
    table.sort(seen)
    assert.same({ "ask", "auto", "edit", "read_only", "yolo" }, seen)
  end)

  it("set_mode moves the active preset to its counterpart in the new mode", function()
    Permissions.set_mode("on")
    Permissions.set_active("edit")
    Permissions.set_mode("off")
    assert.equal("unsandboxed_edit", Permissions.active().name)
    Permissions.set_mode("on")
    assert.equal("edit", Permissions.active().name)
  end)

  it("set_mode leaves an untagged preset alone", function()
    Permissions.save_preset({ name = "either", rules = { { tool = "*", decision = "allow" } } })
    Permissions.set_active("either")
    Permissions.set_mode("on")
    assert.equal("either", Permissions.active().name)
  end)

  it("setup with no preference keeps the sandboxed default under mode on", function()
    Permissions.set_mode("on")
    Permissions.setup({})
    assert.equal("ask", Permissions.active().name)
  end)

  it("setup takes the unsandboxed counterpart when mode is off, and honours a compatible pin", function()
    Permissions.set_mode("off")
    Permissions.setup({})
    assert.equal("unsandboxed_ask", Permissions.active().name)
    Permissions.set_mode("on")
    Permissions.setup({ preset = "auto" })
    assert.equal("auto", Permissions.active().name)
  end)

  it("setup rejects a pinned preset from the other mode", function()
    Permissions.set_mode("on")
    assert.has_error(function()
      Permissions.setup({ preset = "unsandboxed_auto" })
    end, "sandbox mode")
  end)

  it("for_mode is validated", function()
    assert.has_error(function()
      Permissions.save_preset({ name = "p", for_mode = "sandboxed", rules = {} })
    end, "for_mode")
  end)
end)

describe("permissions grant overlay", function()
  before_each(function()
    Permissions.set_project_root("/home/me/proj")
    Permissions.set_mode("on") -- the sandboxed presets below are mode-on only
  end)
  after_each(function()
    Permissions._reset()
  end)

  it("starts empty and resolves through the active preset", function()
    Permissions.set_active("ask")
    assert.same({}, Permissions.grants())
    assert.equal("ask", Permissions.resolve({ tool = "weave:write", resource = "/home/me/proj/a.lua" }))
  end)

  it("an overlay rule beats a conflicting preset rule", function()
    Permissions.set_active("ask")
    Permissions.add_grant({ tool = "weave:write", resource = "${project}/**", decision = "allow" })
    assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = "/home/me/proj/a.lua" }))
    -- outside the workspace the preset's closing deny still stands
    assert.equal("deny", Permissions.resolve({ tool = "weave:write", resource = "/etc/hosts" }))
  end)

  it("a grant out-votes the outside-the-workspace deny", function()
    Permissions.set_active("ask")
    assert.equal("deny", Permissions.resolve({ tool = "weave:read", resource = "/data/x" }))
    Permissions.add_grant({ tool = "weave:read", resource = "/data/**", decision = "allow" })
    assert.equal("allow", Permissions.resolve({ tool = "weave:read", resource = "/data/x" }))
  end)

  it("survives a preset switch and is cleared by clear_overlay", function()
    Permissions.add_grant({ tool = "weave:write", resource = "${project}/**", decision = "allow" })
    Permissions.set_active("ask")
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
