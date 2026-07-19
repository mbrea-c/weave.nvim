-- Wiring of weave's MCP tool suite (design-agent-sandbox.md, phase 0):
-- weave is a tool PROVIDER into the shared clankbox host (soft dependency,
-- like perijove), and every ACP session automatically hands the agent a
-- clankbox server entry (the stdio shim run by THIS nvim) so the tools reach
-- agents with zero user configuration.

local Config = require("weave.config")
local Session = require("weave.session")
local Tools = require("weave.tools")

local function pump()
  vim.wait(50, function()
    return false
  end, 5)
end

--- A checkout-shaped dir containing a stub shim.lua, so entry building can
--- point at a "clankbox root" without the real plugin installed.
local function stub_checkout()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local f = assert(io.open(root .. "/shim.lua", "w"))
  f:write("-- stub shim\n")
  f:close()
  return root
end

--- A clankbox double exposing just the provider API.
local function fake_clankbox()
  local server = { tools = {} }
  function server.register_tool(name, def)
    server.tools[name] = def
  end
  return server
end

--- Minimal scripted client capturing the mcpServers create_session receives.
local function capture_client()
  local client = {
    state = "connected",
    agent_info = { name = "fake", version = "0" },
    agent_capabilities = {},
  }
  function client:create_session(handlers, callback, mcp)
    self.handlers = handlers
    self.mcp = mcp
    callback({ sessionId = "s1" }, nil)
  end
  return client
end

local function started()
  local client = capture_client()
  local session = Session:new({
    provider = "test-agent",
    get_instance = function(_name, on_ready)
      on_ready(client)
      return client
    end,
  })
  session:start()
  pump()
  return client
end

describe("tools wiring", function()
  local saved_tools, saved_servers

  before_each(function()
    saved_tools = vim.deepcopy(Config.tools)
    saved_servers = Config.mcp_servers
    Tools._reset()
  end)

  after_each(function()
    Config.tools = saved_tools
    Config.mcp_servers = saved_servers
    Tools._reset()
    package.preload["clankbox"] = nil
    package.loaded["clankbox"] = nil
  end)

  it("register_into plants the fs and task tools", function()
    local server = fake_clankbox()
    Tools.register_into(server)
    for _, name in ipairs({ "read", "write", "edit", "task_start", "task_status", "task_wait", "task_kill" }) do
      local def = server.tools[name]
      assert.is_not_nil(def)
      assert.equal("function", type(def.handler))
      assert.truthy(def.description)
      assert.is_not_nil(def.inputSchema)
    end
  end)

  it("builds a clankbox server entry from the configured checkout", function()
    Config.tools.clankbox_path = stub_checkout()
    local entry = Tools.clankbox_server_entry()
    assert.is_not_nil(entry)
    assert.equal("clankbox", entry.name)
    assert.equal(vim.v.progpath, entry.command)
    assert.same({ "-l", Config.tools.clankbox_path .. "/shim.lua" }, entry.args)
  end)

  it("returns no entry when clankbox cannot be located", function()
    Config.tools.clankbox_path = vim.fn.tempname() -- nonexistent: no shim.lua
    assert.is_nil(Tools.clankbox_server_entry())
  end)

  it("sessions hand the agent the clankbox server alongside configured ones", function()
    Config.tools.clankbox_path = stub_checkout()
    Config.mcp_servers = { { name = "other", command = "other-cmd", args = {} } }
    local client = started()
    local names = {}
    for _, srv in ipairs(client.mcp or {}) do
      names[srv.name] = srv
    end
    assert.is_not_nil(names.other)
    assert.is_not_nil(names.clankbox)
    assert.equal(vim.v.progpath, names.clankbox.command)
  end)

  it("tools.enabled = false keeps sessions clankbox-free", function()
    Config.tools.clankbox_path = stub_checkout()
    Config.tools.enabled = false
    Config.mcp_servers = {}
    local client = started()
    assert.same({}, client.mcp or {})
  end)

  it("a user-configured clankbox entry is not duplicated", function()
    Config.tools.clankbox_path = stub_checkout()
    Config.mcp_servers = { { name = "clankbox", command = "custom-shim", args = {} } }
    local client = started()
    assert.equal(1, #client.mcp)
    assert.equal("custom-shim", client.mcp[1].command)
  end)

  it("setup() registers the suite into an installed clankbox", function()
    local server = fake_clankbox()
    package.preload["clankbox"] = function()
      return server
    end
    require("weave").setup({})
    assert.is_not_nil(server.tools.read)
    assert.is_not_nil(server.tools.write)
    assert.is_not_nil(server.tools.edit)
  end)
end)
