-- The MCP proxy (design-agent-sandbox-v2.md, phase G): configured MCP
-- servers run CLIENTSIDE, weave-owned, and the agent talks to them through
-- a proxy socket with the permission gate in the middle. A REAL fake server
-- subprocess (nvim -l) sits behind the proxy in these specs; the "agent" is
-- an in-process uv client.

local McpProxy = require("weave.mcp_proxy")
local Permissions = require("weave.permissions")
local Gate = require("weave.tools.gate")
local SessionStore = require("weave.session_store")

local uv = vim.uv

-- A minimal stdio MCP server: answers initialize with its own name and
-- tools/call with "real:<tool>". Written to disk per run; spawned by the
-- proxy exactly like a user-configured server would be.
local FAKE_SERVER = [[
local stdin = vim.uv.new_pipe()
stdin:open(0)
local queue, eof, partial = {}, false, ""
stdin:read_start(function(err, chunk)
  if err or chunk == nil then
    eof = true
    return
  end
  partial = partial .. chunk
  while true do
    local nl = partial:find("\n", 1, true)
    if not nl then break end
    local line = partial:sub(1, nl - 1)
    partial = partial:sub(nl + 1)
    if line ~= "" then queue[#queue + 1] = line end
  end
end)
local function reply(res)
  io.write(vim.json.encode(res) .. "\n")
  io.flush()
end
while true do
  vim.wait(100, function() return #queue > 0 or eof end, 5)
  while #queue > 0 do
    local frame = vim.json.decode(table.remove(queue, 1))
    if frame.id ~= nil and frame.method == "initialize" then
      reply({ jsonrpc = "2.0", id = frame.id, result = { serverInfo = { name = "fake-real-server" } } })
    elseif frame.id ~= nil and frame.method == "tools/list" then
      reply({ jsonrpc = "2.0", id = frame.id, result = { tools = {
        { name = "echo_tool", description = "Echo a value", inputSchema = { type = "object" } },
      } } })
    elseif frame.method == "test/exit" then
      os.exit(7)
    elseif frame.method == "test/server_request" then
      reply({ jsonrpc = "2.0", id = 81, method = "roots/list" })
    elseif frame.method == nil and frame.id == 81 then
      reply({ jsonrpc = "2.0", method = "test/accepted" })
    elseif frame.id ~= nil and frame.method == "tools/call" and frame.params.name ~= "hang" then
      reply({
        jsonrpc = "2.0",
        id = frame.id,
        result = { content = { { type = "text", text = "real:" .. frame.params.name } } },
      })
    end
  end
  if eof and #queue == 0 then break end
end
]]

local function fake_server_cfg(name)
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(vim.split(FAKE_SERVER, "\n"), script)
  return { name = name or "fake", command = vim.v.progpath, args = { "-l", script }, env = {} }
end

--- An in-process "agent": connects to `path`, decodes response frames.
local function connect(path, frames)
  local sock = uv.new_pipe(false)
  local connected = false
  sock:connect(path, function()
    connected = true
  end)
  vim.wait(2000, function()
    return connected
  end, 10)
  local partial = ""
  sock:read_start(function(err, chunk)
    if err or chunk == nil then
      return
    end
    partial = partial .. chunk
    while true do
      local nl = partial:find("\n", 1, true)
      if not nl then
        break
      end
      local line = partial:sub(1, nl - 1)
      partial = partial:sub(nl + 1)
      if line ~= "" then
        frames[#frames + 1] = vim.json.decode(line)
      end
    end
  end)
  return sock
end

local function send(sock, frame)
  sock:write(vim.json.encode(frame) .. "\n")
end

local function wait_frames(frames, n)
  vim.wait(8000, function()
    return #frames >= n
  end, 10)
  assert.equal(n, #frames)
end

describe("mcp proxy", function()
  local saved_ask_store, saved_spawn
  before_each(function()
    saved_ask_store, saved_spawn = Gate._ask_store, McpProxy._spawn
    Permissions.save_preset({ name = "proxy_test", rules = { { tool = "*", decision = "allow" } } })
    Permissions.set_active("proxy_test")
  end)

  after_each(function()
    Gate._ask_store, McpProxy._spawn = saved_ask_store, saved_spawn
    McpProxy._reset()
    Permissions._reset()
  end)

  it("authenticates before spawning and mediates with the bound session policy", function()
    local Session = require("weave.session")
    local Context = require("weave.tool_context")
    local session = Session:new({ permissions = {
      rules = { { tool = "mcp:*", decision = "deny" } },
    } })
    session:_reset_config_session(true)
    local proxy = assert(McpProxy.listener_for(fake_server_cfg(), true))
    local frames = {}
    local sock = connect(proxy.path, frames)
    vim.wait(50, function() return false end, 5)
    assert.equal(0, #proxy.instances)
    sock:write("CLANKBOX_AUTH " .. Context.bind(session) .. "\n")
    send(sock, { jsonrpc = "2.0", id = 1, method = "tools/call",
      params = { name = "echo_tool", arguments = { caller = "another-session" } } })
    wait_frames(frames, 1)
    assert.is_true(frames[1].result.isError)
    assert.truthy(frames[1].result.content[1].text:find("permission denied", 1, true))
    session:stop()
    sock:close()
  end)

  it("tracks metadata and restarts a stopped process on the same agent connection", function()
    local proxy = assert(McpProxy.listener_for(fake_server_cfg()))
    local frames = {}
    local sock = connect(proxy.path, frames)
    send(sock, { jsonrpc = "2.0", id = 1, method = "initialize", params = {} })
    wait_frames(frames, 1)
    send(sock, { jsonrpc = "2.0", method = "notifications/initialized" })
    send(sock, { jsonrpc = "2.0", id = 2, method = "tools/list" })
    wait_frames(frames, 2)
    local server = McpProxy.list()[1]
    assert.equal("fake", server.name)
    local instance = server.instances[1]
    assert.equal("running", instance.status)
    assert.is_not_nil(instance.pid)
    assert.is_not_nil(instance.started_at)
    assert.equal("echo_tool", instance.tools[1].name)
    assert.equal("object", instance.tools[1].inputSchema.type)
    local old_pid = instance.pid
    assert.is_true(McpProxy.kill(instance.id))
    assert.equal("stopped", instance.status)
    send(sock, { jsonrpc = "2.0", id = 3, method = "tools/call", params = { name = "echo_tool" } })
    wait_frames(frames, 3)
    assert.is_not_nil(frames[3].error)
    assert.is_true(McpProxy.restart(instance.id))
    vim.wait(8000, function() return instance.status == "running" end, 10)
    assert.equal("running", instance.status)
    assert.is_true(instance.pid ~= old_pid)
    send(sock, { jsonrpc = "2.0", id = 4, method = "tools/call", params = { name = "echo_tool" } })
    wait_frames(frames, 4)
    assert.equal("real:echo_tool", frames[4].result.content[1].text)
    sock:close()
  end)

  it("fails pending requests on kill without stopping another instance", function()
    local proxy = assert(McpProxy.listener_for(fake_server_cfg()))
    local frames, other_frames = {}, {}
    local sock = connect(proxy.path, frames)
    local other = connect(proxy.path, other_frames)
    vim.wait(3000, function() return #McpProxy.list()[1].instances == 2 end, 10)
    local instances = McpProxy.list()[1].instances
    send(sock, { jsonrpc = "2.0", id = 10, method = "tools/call", params = { name = "hang" } })
    vim.wait(100, function() return false end, 10)
    assert.is_true(McpProxy.kill(instances[1].id))
    wait_frames(frames, 1)
    assert.equal(10, frames[1].id)
    assert.is_not_nil(frames[1].error)
    assert.equal("running", instances[2].status)
    send(other, { jsonrpc = "2.0", id = 20, method = "tools/call", params = { name = "echo_tool" } })
    wait_frames(other_frames, 1)
    assert.equal("real:echo_tool", other_frames[1].result.content[1].text)
    sock:close()
    other:close()
  end)

  it("retains the exit result when stdout closes before the exit callback", function()
    McpProxy._spawn = function(cmd, opts, on_exit)
      return saved_spawn(cmd, opts, function(code, signal)
        vim.defer_fn(function() on_exit(code, signal) end, 30)
      end)
    end
    local proxy = assert(McpProxy.listener_for(fake_server_cfg()))
    local frames = {}
    local sock = connect(proxy.path, frames)
    send(sock, { jsonrpc = "2.0", method = "test/exit" })
    vim.wait(2000, function()
      local instance = McpProxy.list()[1].instances[1]
      return instance and instance.exit_code ~= nil
    end, 10)
    local instance = McpProxy.list()[1].instances[1]
    sock:close()
    assert.equal("exited", instance.status)
    assert.equal(7, instance.exit_code)
  end)

  it("does not treat replies to server requests as pending client requests", function()
    local proxy = assert(McpProxy.listener_for(fake_server_cfg()))
    local frames = {}
    local sock = connect(proxy.path, frames)
    send(sock, { jsonrpc = "2.0", method = "test/server_request" })
    wait_frames(frames, 1)
    assert.equal("roots/list", frames[1].method)
    send(sock, { jsonrpc = "2.0", id = 81, result = { roots = {} } })
    wait_frames(frames, 2)
    assert.equal("test/accepted", frames[2].method)
    McpProxy.kill(McpProxy.list()[1].instances[1].id)
    vim.wait(100, function() return #frames > 2 end, 10)
    sock:close()
    assert.equal(2, #frames)
  end)

  it("fails calls awaiting approval on kill and cancels their permission prompts", function()
    local store = SessionStore:new()
    Gate._ask_store = function() return store end
    Permissions.save_preset({ name = "proxy_ask", rules = { { tool = "*", decision = "ask" } } })
    Permissions.set_active("proxy_ask")
    local proxy = assert(McpProxy.listener_for(fake_server_cfg()))
    local frames = {}
    local sock = connect(proxy.path, frames)
    send(sock, { jsonrpc = "2.0", id = 55, method = "tools/call", params = { name = "echo_tool" } })
    vim.wait(2000, function() return store:get_permission() ~= nil end, 10)
    local permission = assert(store:get_permission())
    McpProxy.kill(McpProxy.list()[1].instances[1].id)
    vim.wait(1000, function() return #frames > 0 end, 10)
    sock:close()
    assert.equal(1, #frames)
    assert.equal(55, frames[1].id)
    assert.is_not_nil(frames[1].error)
    assert.is_nil(store:get_permission())
    permission.respond("allow_always")
    permission.respond("reject_once")
    assert.equal(0, #Permissions.grants())
    assert.equal(1, #frames)
  end)

  it("relays a REAL clientside server: initialize and allowed calls pass", function()
    local proxy = assert(McpProxy.listener_for(fake_server_cfg()))
    local frames = {}
    local sock = connect(proxy.path, frames)

    send(sock, { jsonrpc = "2.0", id = 1, method = "initialize", params = vim.empty_dict() })
    wait_frames(frames, 1)
    assert.equal("fake-real-server", frames[1].result.serverInfo.name)

    -- active preset "normal": * allows, so the call reaches the server
    send(sock, { jsonrpc = "2.0", id = 2, method = "tools/call", params = { name = "echo_tool", arguments = {} } })
    wait_frames(frames, 2)
    assert.equal("real:echo_tool", frames[2].result.content[1].text)

    sock:close()
  end)

  it("the gate answers a denied tool locally; the server keeps serving", function()
    Permissions.save_preset({
      name = "guarded",
      rules = {
        { tool = "mcp:blocked", decision = "deny" },
        { tool = "*", decision = "allow" },
      },
    })
    Permissions.set_active("guarded")

    local proxy = assert(McpProxy.listener_for(fake_server_cfg("guarded_srv")))
    local frames = {}
    local sock = connect(proxy.path, frames)

    send(sock, { jsonrpc = "2.0", id = 1, method = "tools/call", params = { name = "blocked", arguments = {} } })
    wait_frames(frames, 1)
    assert.is_true(frames[1].result.isError)
    assert.truthy(frames[1].result.content[1].text:find("permission denied", 1, true))

    -- the refusal was clientside: the connection (and its server) live on
    send(sock, { jsonrpc = "2.0", id = 2, method = "tools/call", params = { name = "fine", arguments = {} } })
    wait_frames(frames, 2)
    assert.equal("real:fine", frames[2].result.content[1].text)

    sock:close()
  end)

  it("entry_for hands the agent the shim against the proxy socket, never $NVIM", function()
    local Config = require("weave.config")
    local saved = vim.deepcopy(Config.tools)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "-- stub shim" }, root .. "/shim.lua")
    Config.tools.clankbox_path = root

    local entry = McpProxy.entry_for({ name = "srv", command = "real-server", args = {} })
    Config.tools = saved
    assert.is_not_nil(entry)
    assert.equal("srv", entry.name)
    assert.equal(vim.v.progpath, entry.command)
    assert.same({ "-l", root .. "/shim.lua" }, entry.args)
    local env = {}
    for _, e in ipairs(entry.env) do
      env[e.name] = e.value
    end
    assert.truthy(env.CLANKBOX_SOCKET)
    assert.is_nil(env.NVIM)
  end)

  it("a per-server sandbox section bwraps the real process", function()
    local Sandbox = require("weave.sandbox")
    local real_backend, real_exists, real_realpath = Sandbox._backend, Sandbox._exists, Sandbox._realpath
    -- pin the backend: this spec asserts the BWRAP rendering of the hull
    Sandbox._backend = function()
      return require("weave.sandbox.bwrap")
    end
    Sandbox._exists = function()
      return true
    end
    Sandbox._realpath = function(p)
      return p
    end
    local captured
    local real_spawn = McpProxy._spawn
    McpProxy._spawn = function(cmd, opts)
      captured = { cmd = cmd, args = opts.args }
      return nil -- spawn "fails": attach tears down, which is fine here
    end

    local proxy = assert(McpProxy.listener_for({
      name = "sandboxed_srv",
      command = "real-server",
      args = { "--serve" },
      env = {},
      sandbox = { binds = { { path = "/data", mode = "ro" } }, network = false },
    }))
    local frames = {}
    local sock = connect(proxy.path, frames)
    vim.wait(2000, function()
      return captured ~= nil
    end, 10)

    McpProxy._spawn = real_spawn
    Sandbox._backend = real_backend
    Sandbox._exists = real_exists
    Sandbox._realpath = real_realpath

    assert.is_not_nil(captured)
    assert.equal("bwrap", captured.cmd)
    local function has_seq(list, seq)
      for i = 1, #list - #seq + 1 do
        local hit = true
        for j = 1, #seq do
          if list[i + j - 1] ~= seq[j] then
            hit = false
            break
          end
        end
        if hit then
          return true
        end
      end
      return false
    end
    assert.is_true(has_seq(captured.args, { "--unshare-net" }))
    assert.is_true(has_seq(captured.args, { "--ro-bind", "/data", "/data" }))
    assert.is_true(has_seq(captured.args, { "--", "real-server", "--serve" }))
    if not sock:is_closing() then
      sock:close()
    end
  end)
end)
