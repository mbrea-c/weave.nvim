-- The permission gate over weave's MCP tool suite (design-agent-sandbox.md,
-- phase 1): register_into wraps every tool def so the call resolves through
-- the client-side engine as weave:<tool> with the concrete resource (path,
-- buffer ref, command line). allow runs the tool unchanged, deny answers an
-- isError result naming the preset, and ask surfaces a synthetic permission
-- request into the session store's existing queue — the sidebar + ;;1
-- answering work on it exactly like an ACP request.

local Gate = require("weave.tools.gate")
local Permissions = require("weave.permissions")
local SessionStore = require("weave.session_store")
local TaskStore = require("weave.task_store")
local Tools = require("weave.tools")

--- register_into against a capture server; returns the wrapped defs.
local function wrapped_tools()
  local server = { tools = {} }
  function server.register_tool(name, def)
    server.tools[name] = def
  end
  Tools.register_into(server)
  return server.tools
end

--- Call a wrapped (always-async) def and return what respond delivered.
local function call(def, args)
  local result
  def.handler(args, function(ret)
    result = ret
  end)
  return result
end

local function text_of(result)
  if type(result) == "string" then
    return result
  end
  return result.content[1].text
end

local function tmpfile(content)
  local path = vim.fn.tempname() .. "-gate.txt"
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  return path
end

describe("tools permission gate", function()
  local saved_ask_store

  before_each(function()
    saved_ask_store = Gate._ask_store
  end)

  after_each(function()
    Gate._ask_store = saved_ask_store
    Permissions._reset()
    TaskStore._kill_all()
    TaskStore._reset()
  end)

  it("wraps every tool async while keeping its schema and description", function()
    local raw = require("weave.tools.fs").read
    local tools = wrapped_tools()
    for _, def in pairs(tools) do
      assert.is_true(def.async)
    end
    assert.equal(raw.description, tools.read.description)
    assert.equal(raw.inputSchema, tools.read.inputSchema)
  end)

  it("the default preset lets the suite run unchanged", function()
    local path = tmpfile("hello gate\n")
    local result = call(wrapped_tools().read, { path = path })
    assert.truthy(text_of(result):find("hello gate", 1, true))
  end)

  it("a deny rule answers isError naming the preset, and the tool never runs", function()
    local path = vim.fn.tempname() .. "-denied.txt"
    Permissions.save_preset({
      name = "locked",
      rules = {
        { tool = "weave:write", resource = "*-denied.txt", decision = "deny" },
        { tool = "*", decision = "allow" },
      },
    })
    Permissions.set_active("locked")
    local result = call(wrapped_tools().write, { path = path, content = "nope" })
    assert.is_true(result.isError)
    assert.truthy(text_of(result):find("locked", 1, true))
    assert.truthy(text_of(result):find("weave:write", 1, true))
    assert.equal(0, vim.fn.filereadable(path))
  end)

  it("resource rules match the ABSOLUTE path, whatever the agent passed", function()
    Permissions.save_preset({
      name = "cwd-jail",
      rules = {
        { tool = "weave:read", resource = vim.fn.getcwd() .. "/*", decision = "deny" },
        { tool = "*", decision = "allow" },
      },
    })
    Permissions.set_active("cwd-jail")
    local result = call(wrapped_tools().read, { path = "README.md" })
    assert.is_true(result.isError)
  end)

  it("task_start resolves with the command line as the resource", function()
    Permissions.save_preset({
      name = "no-rm",
      rules = {
        { tool = "weave:task_start", resource = "rm *", decision = "deny" },
        { tool = "*", decision = "allow" },
      },
    })
    Permissions.set_active("no-rm")
    local tools = wrapped_tools()
    local denied = call(tools.task_start, { command = "rm -rf /tmp/x" })
    assert.is_true(denied.isError)
    local ok = call(tools.task_start, { command = "echo fine" })
    assert.truthy(text_of(ok):find("task 1 started", 1, true))
  end)

  it("ask surfaces a synthetic request in the ask store; allowing runs the tool", function()
    local store = SessionStore:new()
    Gate._ask_store = function()
      return store
    end
    Permissions.save_preset({
      name = "confirm-exec",
      rules = {
        { tool = "weave:task_start", decision = "ask" },
        { tool = "*", decision = "allow" },
      },
    })
    Permissions.set_active("confirm-exec")

    local result
    wrapped_tools().task_start.handler({ command = "echo asked" }, function(ret)
      result = ret
    end)
    -- nothing ran yet: the request waits in the queue like an ACP one
    assert.is_nil(result)
    local perm = store:get_permission()
    assert.is_not_nil(perm)
    assert.truthy(perm.request.toolCall.title:find("task_start", 1, true))
    assert.truthy(perm.request.toolCall.title:find("echo asked", 1, true))
    -- options are ACP-shaped so the sidebar's ;;1 legend applies unchanged
    assert.equal("allow_once", perm.request.options[1].kind)

    store:pop_permission()
    perm.respond("allow_once")
    assert.truthy(text_of(result):find("task 1 started", 1, true))
  end)

  it("ask rejected answers isError and the tool never runs", function()
    local store = SessionStore:new()
    Gate._ask_store = function()
      return store
    end
    Permissions.save_preset({
      name = "confirm-writes",
      rules = {
        { tool = "weave:write", decision = "ask" },
        { tool = "*", decision = "allow" },
      },
    })
    Permissions.set_active("confirm-writes")

    local path = vim.fn.tempname() .. "-asked.txt"
    local result
    wrapped_tools().write.handler({ path = path, content = "nope" }, function(ret)
      result = ret
    end)
    local perm = store:get_permission()
    store:pop_permission()
    perm.respond(nil) -- reject / cancelled (a store drain answers nil too)
    assert.is_true(result.isError)
    assert.truthy(text_of(result):find("not granted", 1, true))
    assert.equal(0, vim.fn.filereadable(path))
  end)

  it("ask with no session store to ask falls back to deny", function()
    Gate._ask_store = function()
      return nil
    end
    Permissions.save_preset({
      name = "ask-everything",
      rules = { { tool = "*", decision = "ask" } },
    })
    Permissions.set_active("ask-everything")
    local result = call(wrapped_tools().task_status, { id = 1 })
    assert.is_true(result.isError)
    assert.truthy(text_of(result):find("no active weave session", 1, true))
  end)

  it("a tool error after an ask-allow still answers the call (isError)", function()
    local store = SessionStore:new()
    Gate._ask_store = function()
      return store
    end
    Permissions.save_preset({
      name = "confirm-reads",
      rules = {
        { tool = "weave:read", decision = "ask" },
        { tool = "*", decision = "allow" },
      },
    })
    Permissions.set_active("confirm-reads")

    local result
    wrapped_tools().read.handler({ path = vim.fn.tempname() .. "-absent.txt" }, function(ret)
      result = ret
    end)
    local perm = store:get_permission()
    store:pop_permission()
    perm.respond("allow_once")
    assert.is_true(result.isError)
    assert.truthy(text_of(result):find("file not found", 1, true))
  end)

  describe("always answers", function()
    local root

    before_each(function()
      root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")
      Permissions.set_project_root(root)
    end)

    local function ask_write(path)
      local store = SessionStore:new()
      Gate._ask_store = function()
        return store
      end
      Permissions.save_preset({
        name = "confirm-writes",
        rules = {
          { tool = "weave:write", decision = "ask" },
          { tool = "*", decision = "allow" },
        },
      })
      Permissions.set_active("confirm-writes")
      local result
      wrapped_tools().write.handler({ path = path, content = "x" }, function(ret)
        result = ret
      end)
      local perm = store:get_permission()
      store:pop_permission()
      return perm, function()
        return result
      end
    end

    it("offers four options and labels the always pair by the scope it grants", function()
      local perm = ask_write(root .. "/a.txt")
      local kinds = {}
      for i, opt in ipairs(perm.request.options) do
        kinds[i] = opt.kind
      end
      assert.same({ "allow_once", "allow_always", "reject_once", "reject_always" }, kinds)
      assert.equal("Allow for project", perm.request.options[2].name)
      assert.equal("Reject for project", perm.request.options[4].name)
    end)

    it("allow_always grants the project and stops the asking", function()
      ask_write(root .. "/a.txt").respond("allow_always")
      assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = root .. "/b.txt" }))
      assert.equal("ask", Permissions.resolve({ tool = "weave:write", resource = "/etc/hosts" }))
    end)

    it("reject_always refuses this call and denies the next one outright", function()
      local perm, result = ask_write(root .. "/a.txt")
      perm.respond("reject_always")
      assert.is_true(result().isError)
      assert.equal("deny", Permissions.resolve({ tool = "weave:write", resource = root .. "/b.txt" }))
    end)

    it("an always answer outside the project does not generalise", function()
      local outside = vim.fn.tempname() .. "-elsewhere/x.txt"
      local perm = ask_write(outside)
      assert.truthy(perm.request.options[2].name:find("Allow for ", 1, true))
      assert.is_nil(perm.request.options[2].name:find("project", 1, true))
      perm.respond("allow_always")
      assert.equal("allow", Permissions.resolve({ tool = "weave:write", resource = outside }))
      assert.equal(
        "ask",
        Permissions.resolve({ tool = "weave:write", resource = vim.fs.dirname(outside) .. "/sibling.txt" })
      )
    end)
  end)
end)
