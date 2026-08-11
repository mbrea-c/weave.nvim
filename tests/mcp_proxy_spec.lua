-- The MCP proxy (design-agent-sandbox-v2.md, phase G): configured MCP
-- servers run CLIENTSIDE, weave-owned, and the agent talks to them through
-- a proxy socket with the permission gate in the middle. A REAL fake server
-- subprocess (nvim -l) sits behind the proxy in these specs; the "agent" is
-- an in-process uv client.

local McpProxy = require("weave.mcp_proxy")
local Permissions = require("weave.permissions")

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
    elseif frame.id ~= nil and frame.method == "tools/call" then
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
  after_each(function()
    McpProxy._reset()
    Permissions._reset()
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
    local real_available, real_exists, real_realpath = Sandbox._available, Sandbox._exists, Sandbox._realpath
    Sandbox._available = function()
      return true
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
    Sandbox._available = real_available
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
