-- weave.mcp_proxy: clientside ownership of configured MCP servers
-- (design-agent-sandbox-v2.md, phase G).
--
-- An MCP server the agent spawned itself lives inside the agent sandbox
-- (where its tools are as confined as the agent — useless) and its calls
-- are invisible to weave. Wrapping inverts that: the REAL server runs out
-- here, spawned and owned by weave; what the agent's mcpServers config
-- lists is the dumb clankbox shim in byte-pump mode, pointed at a proxy
-- socket. Frames relay through this module with weave's permission gate in
-- the middle, so arbitrary third-party MCP tools flow through the same
-- clientside handling as weave's own — as mcp:<tool> rules.
--
-- One REAL server process per agent connection: MCP stdio servers are
-- single-client, and per-connection processes keep the relay a pure
-- passthrough (no id remapping, no multiplexing). The connection closing
-- takes its server down; a server dying closes its connection.
--
-- Sandboxing the real server is OPTIONAL, per server: an McpServer entry
-- may carry `sandbox = { binds?, network? }` (the tool-hull vocabulary),
-- and the process is then bwrap'd via Sandbox.wrap_tool. Unlike presets
-- there is no project-bind default — a server that needs nothing gets
-- nothing.
--
-- Only tools/call is mediated. Everything else — initialize, tools/list,
-- notifications, cancellations, and every server->agent frame — passes
-- through untouched: the gate decides what may HAPPEN, not what may be
-- seen to exist.

local M = {}

local uv = vim.uv or vim.loop

--- name -> { path: string, server: uv_pipe, cfg: table }
M._proxies = {}

--- Spawn seam (specs capture the argv instead of spawning).
--- @param cmd string
--- @param opts table uv.spawn opts
--- @param on_exit fun(code: integer, signal: integer)
--- @return userdata|nil proc, integer|string pid_or_err
function M._spawn(cmd, opts, on_exit)
  return uv.spawn(cmd, opts, on_exit)
end

--- The full parent environment with the entry's own EnvVariable[] overrides
--- on top — mirroring the agent transport's inherit-all default (PATH, CA
--- bundles and proxies must keep working for a clientside server too).
--- @param overrides { name: string, value: string }[]|nil
--- @return string[]
local function env_list(overrides)
  local map = vim.fn.environ()
  for _, e in ipairs(overrides or {}) do
    map[e.name] = e.value
  end
  local out = {}
  for k, v in pairs(map) do
    out[#out + 1] = k .. "=" .. v
  end
  return out
end

--- Normalize a gate respond payload into an MCP tool result (the gate hands
--- back either a result table or plain text; clankbox does this same
--- normalization for its own tools).
local function to_result(ret)
  if type(ret) == "table" and ret.content ~= nil then
    return ret
  end
  return { content = { { type = "text", text = tostring(ret) } }, isError = false }
end

--- A line-splitting reader: uv chunks reassembled on newlines, each whole
--- frame handed to `on_line` (still in uv callback context).
local function line_reader(on_line, on_eof)
  local partial = ""
  return function(err, chunk)
    if err or chunk == nil then
      on_eof()
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
        on_line(line)
      end
    end
  end
end

--- Wire one agent connection to one fresh real-server process.
--- @param conn userdata accepted uv pipe
--- @param cfg table McpServer entry ({ name, command, args, env, sandbox? })
local function attach(conn, cfg)
  local stdin_p = uv.new_pipe(false)
  local stdout_p = uv.new_pipe(false)
  local stderr_p = uv.new_pipe(false)

  local cmd, args = cfg.command, cfg.args or {}
  if cfg.sandbox then
    local Permissions = require("weave.permissions")
    local binds = {}
    for i, b in ipairs(cfg.sandbox.binds or {}) do
      binds[i] = { path = (b.path:gsub("%${project}", (Permissions.project_root():gsub("%%", "%%%%")))), mode = b.mode }
    end
    cmd, args = require("weave.sandbox").wrap_tool(cfg.command, cfg.args, {
      binds = binds,
      network = cfg.sandbox.network == true,
    })
  end

  local closed = false
  local proc
  local function teardown()
    if closed then
      return
    end
    closed = true
    for _, h in ipairs({ stdin_p, stdout_p, stderr_p, conn }) do
      if h and not h:is_closing() then
        h:close()
      end
    end
    if proc and not proc:is_closing() then
      proc:kill("sigterm")
      proc:close()
    end
  end

  proc = M._spawn(cmd, {
    args = args,
    stdio = { stdin_p, stdout_p, stderr_p },
    env = env_list(cfg.env),
  }, function()
    vim.schedule(teardown)
  end)
  if not proc then
    vim.schedule(function()
      require("weave.utils.logger").notify(
        ("weave: cannot spawn MCP server %q (%s)"):format(cfg.name, tostring(cmd)),
        vim.log.levels.ERROR
      )
      teardown()
    end)
    return
  end

  local function to_agent(line)
    if not closed and not conn:is_closing() then
      conn:write(line .. "\n")
    end
  end
  local function to_server(line)
    if not closed and not stdin_p:is_closing() then
      stdin_p:write(line .. "\n")
    end
  end

  -- agent -> server: tools/call requests pass the gate first; everything
  -- else forwards verbatim. Handled on the main loop (the gate may open an
  -- interactive prompt).
  local function handle_agent_frame(line)
    local ok, frame = pcall(vim.json.decode, line)
    if not ok or type(frame) ~= "table" or frame.method ~= "tools/call" or frame.id == nil then
      to_server(line)
      return
    end
    local name = frame.params and frame.params.name or "?"
    local Gate = require("weave.tools.gate")
    Gate.mediate({ tool = "mcp:" .. name }, ("MCP tool %s (%s)"):format(name, cfg.name), "other", function()
      to_server(line)
    end, function(ret)
      -- refused (or errored) clientside: the real server never sees the
      -- call; answer the agent in the request's own id
      to_agent(vim.json.encode({ jsonrpc = "2.0", id = frame.id, result = to_result(ret) }))
    end)
  end

  conn:read_start(line_reader(function(line)
    vim.schedule(function()
      if not closed then
        handle_agent_frame(line)
      end
    end)
  end, function()
    vim.schedule(teardown)
  end))

  -- server -> agent: verbatim, but line-buffered — our locally answered
  -- frames interleave on the same connection and must never land inside a
  -- half-written server line.
  stdout_p:read_start(line_reader(to_agent, function()
    vim.schedule(teardown)
  end))
  stderr_p:read_start(function() end) -- drain; MCP servers log here freely
end

--- The proxy socket for a configured server entry: one listener per server
--- name, created on first use; every connection gets its own real-server
--- process. Returns nil when the listener cannot be created.
--- @param cfg table McpServer entry
--- @return { path: string }|nil
function M.listener_for(cfg)
  local existing = M._proxies[cfg.name]
  if existing then
    return existing
  end

  local path = vim.fn.stdpath("run") .. ("/weave-mcp-%s-%d.sock"):format(cfg.name:gsub("[^%w%-]", "_"), uv.os_getpid())
  local server = uv.new_pipe(false)
  uv.fs_unlink(path)
  local ok = server:bind(path)
  if not ok then
    server:close()
    return nil
  end
  uv.fs_chmod(path, 384) -- 0600: this socket reaches a weave-owned process
  ok = server:listen(16, function(lerr)
    if lerr then
      return
    end
    -- accept here (fast event context, pure uv), attach on the main loop —
    -- attach touches vim.fn (environ, getcwd via ${project} expansion),
    -- which fast contexts forbid. The kernel buffers anything the client
    -- writes before read_start.
    local conn = uv.new_pipe(false)
    server:accept(conn)
    vim.schedule(function()
      attach(conn, cfg)
    end)
  end)
  if not ok then
    server:close()
    uv.fs_unlink(path)
    return nil
  end

  local proxy = { path = path, server = server, cfg = cfg }
  M._proxies[cfg.name] = proxy
  return proxy
end

--- The McpServer entry the AGENT receives for a wrapped server: the clankbox
--- shim in byte-pump mode against this server's proxy socket. nil when
--- wrapping is impossible (no clankbox shim to run) — the caller falls back
--- to handing over the raw entry.
--- @param cfg table McpServer entry
--- @return table|nil
function M.entry_for(cfg)
  local shim = require("weave.tools").shim_path()
  if not shim then
    return nil
  end
  local proxy = M.listener_for(cfg)
  if not proxy then
    return nil
  end
  return {
    name = cfg.name,
    command = vim.v.progpath,
    args = { "-l", shim },
    env = { { name = "CLANKBOX_SOCKET", value = proxy.path } },
  }
end

-- test hook: drop every listener (running per-connection servers die with
-- their connections)
function M._reset()
  for name, proxy in pairs(M._proxies) do
    if proxy.server and not proxy.server:is_closing() then
      proxy.server:close()
    end
    uv.fs_unlink(proxy.path)
    M._proxies[name] = nil
  end
end

return M
