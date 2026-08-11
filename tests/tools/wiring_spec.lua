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
    require("weave.mcp_proxy")._reset()
    package.preload["clankbox"] = nil
    package.loaded["clankbox"] = nil
    package.preload["clankbox.broker"] = nil
    package.loaded["clankbox.broker"] = nil
  end)

  --- Install fake clankbox + broker modules; returns the broker's capture
  --- table ({ opts = the listen() opts, listener = what it returned }).
  local function fake_broker()
    local capture = {}
    package.preload["clankbox"] = function()
      return fake_clankbox()
    end
    package.preload["clankbox.broker"] = function()
      return {
        listen = function(opts)
          capture.opts = opts
          capture.listener = {
            path = "/tmp/fake-broker.sock",
            closed = 0,
            close = function(self)
              self.closed = self.closed + 1
            end,
          }
          return capture.listener
        end,
      }
    end
    return capture
  end

  it("register_into plants the fs and task tools", function()
    local server = fake_clankbox()
    Tools.register_into(server)
    for _, name in ipairs({
      "read",
      "write",
      "edit",
      "glob",
      "grep",
      "task_start",
      "task_status",
      "task_wait",
      "task_kill",
      "request_access",
    }) do
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
    -- phase G: the configured server is WRAPPED — the agent gets the shim
    -- against a weave-owned proxy socket, and the real command never leaves
    -- the client side
    assert.equal(vim.v.progpath, names.other.command)
    local other_env = {}
    for _, e in ipairs(names.other.env) do
      other_env[e.name] = e.value
    end
    assert.truthy(other_env.CLANKBOX_SOCKET)
    assert.is_nil(other_env.NVIM)
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

  it("the broker listener is scoped to exactly weave's own suite", function()
    local capture = fake_broker()
    local listener = Tools.broker_listener()
    assert.is_not_nil(listener)
    -- memoized: one listener per editor
    assert.equal(listener, Tools.broker_listener())
    local scoped = vim.deepcopy(capture.opts.tools)
    table.sort(scoped)
    local owned = vim.tbl_keys(Tools.OWNS)
    table.sort(owned)
    assert.same(owned, scoped)
  end)

  it("agents ride the broker socket, never $NVIM, when the broker exists", function()
    fake_broker()
    Config.tools.clankbox_path = stub_checkout()
    Config.mcp_servers = { { name = "other", command = "other-cmd", args = {} } }
    local client = started()
    local by_name = {}
    for _, srv in ipairs(client.mcp or {}) do
      by_name[srv.name] = srv
    end
    local env = {}
    for _, e in ipairs(by_name.clankbox.env) do
      env[e.name] = e.value
    end
    assert.equal("/tmp/fake-broker.sock", env.CLANKBOX_SOCKET)
    -- $NVIM is nvim's raw RPC socket (nvim_exec_lua): it must never reach a
    -- server that already has the scoped broker
    assert.is_nil(env.NVIM)
    -- other servers ride their own proxy sockets (phase G), never $NVIM
    local other_env = {}
    for _, e in ipairs(by_name.other.env) do
      other_env[e.name] = e.value
    end
    assert.truthy(other_env.CLANKBOX_SOCKET)
    assert.is_nil(other_env.NVIM)
  end)

  it("falls back to the $NVIM shim path when clankbox has no broker", function()
    package.preload["clankbox"] = function()
      return fake_clankbox()
    end
    Config.tools.clankbox_path = stub_checkout()
    Config.mcp_servers = {}
    local client = started()
    assert.equal("clankbox", client.mcp[1].name)
    local env = {}
    for _, e in ipairs(client.mcp[1].env) do
      env[e.name] = e.value
    end
    assert.is_nil(env.CLANKBOX_SOCKET)
    if vim.v.servername ~= "" then
      assert.equal(vim.v.servername, env.NVIM)
    end
  end)

  it("_reset closes the broker listener", function()
    local capture = fake_broker()
    assert.is_not_nil(Tools.broker_listener())
    Tools._reset()
    assert.equal(1, capture.listener.closed)
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
