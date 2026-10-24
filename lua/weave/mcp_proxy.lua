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
-- single-client. Normal requests retain their IDs and are never multiplexed.
-- Initialization is replayed and its response consumed after restart. The connection closing
-- takes its server down. Stopped servers retain their connection so the UI
-- can restart them and replay the MCP initialization handshake.
--
-- Sandboxing the real server is OPTIONAL, per server: an McpServer entry
-- may carry `sandbox = { binds?, network? }` (the tool-hull vocabulary),
-- and the process is then bwrap'd via Sandbox.wrap_tool. Unlike presets
-- there is no project-bind default — a server that needs nothing gets
-- nothing.
--
-- Only tools/call is permission-mediated. Initialization and tools/list
-- responses are observed for the inspector; normal frames pass through.
-- Process controls fail pending requests and retain the agent connection.

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
local subscribers, next_instance = {}, 0
local function notify()
  vim.schedule(function()
    for _, fn in ipairs({ unpack(subscribers) }) do fn() end
  end)
end

function M.subscribe(fn)
  subscribers[#subscribers + 1] = fn
  return function()
    for i, value in ipairs(subscribers) do
      if value == fn then table.remove(subscribers, i); break end
    end
  end
end

function M.list()
  local result = {}
  for name, proxy in pairs(M._proxies) do
    result[#result + 1] = { name = name, command = proxy.cfg.command, instances = proxy.instances or {} }
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

local function instance_for(id)
  for _, proxy in pairs(M._proxies) do
    for _, instance in ipairs(proxy.instances or {}) do
      if instance.id == id then return instance end
    end
  end
end

function M.kill(id)
  local instance = instance_for(id)
  if not instance or instance.status == "disconnected" then return false end
  instance.stop()
  return true
end

function M.restart(id)
  local instance = instance_for(id)
  if not instance or instance.status == "disconnected" then return false end
  instance.start()
  return true
end

local function attach(conn, cfg, ctx)
  next_instance = next_instance + 1
  local instance = { id = next_instance, status = "starting", tools = {}, caller = ctx and ctx.caller }
  local proxy = M._proxies[cfg.name]
  proxy.instances = proxy.instances or {}
  proxy.instances[#proxy.instances + 1] = instance
  local generation, last_start, pipes, proc = 0, 0, {}, nil
  local bootstrap_timer
  local pending, init_frame, initialized, bootstrap = {}, nil, nil, false
  local closed = false

  local function to_agent(frame)
    if not closed and not conn:is_closing() then
      conn:write(type(frame) == "string" and (frame .. "\n") or (vim.json.encode(frame) .. "\n"))
    end
  end

  local function fail_pending()
    local requests = pending
    pending = {}
    for id, request in pairs(requests) do
      if request.cancel then request.cancel() end
      to_agent({ jsonrpc = "2.0", id = id, error = { code = -32000, message = "MCP server stopped" } })
    end
  end

  local function stop(status)
    generation = generation + 1
    if bootstrap_timer then
      bootstrap_timer:stop()
      bootstrap_timer:close()
      bootstrap_timer = nil
    end
    fail_pending()
    for _, pipe in ipairs(pipes) do
      if not pipe:is_closing() then pipe:close() end
    end
    pipes = {}
    if proc and not proc:is_closing() then
      -- SIGKILL makes the UI operation deterministic, including servers that
      -- ignore SIGTERM. The exit callback owns closing the process handle.
      proc:kill("sigkill")
    end
    proc = nil
    instance.status = status or "stopped"
    instance.finished_at = os.time()
    notify()
  end
  instance.stop = function() stop("stopped") end

  local function to_server(line)
    if pipes[1] and not pipes[1]:is_closing() then pipes[1]:write(line .. "\n") end
  end

  instance.start = function()
    stop("starting")
    local epoch = generation
    last_start = epoch
    local cmd, args = cfg.command, cfg.args or {}
    if cfg.sandbox then
      local Permissions = require("weave.permissions")
      local binds = {}
      for i, b in ipairs(cfg.sandbox.binds or {}) do
        binds[i] = { path = (b.path:gsub("%${project}", (Permissions.project_root():gsub("%%", "%%%%")))), mode = b.mode }
      end
      cmd, args = require("weave.sandbox").wrap_tool(cfg.command, cfg.args, {
        binds = binds, network = cfg.sandbox.network == true,
      })
    end
    pipes = { uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false) }
    local spawned
    local pid
    spawned, pid = M._spawn(cmd, { args = args, stdio = pipes, env = env_list(cfg.env) }, function(code, signal)
      vim.schedule(function()
        if spawned and not spawned:is_closing() then spawned:close() end
        if epoch ~= last_start then return end
        if epoch == generation then stop("exited") end
        instance.exit_code, instance.signal = code, signal
        notify()
      end)
    end)
    proc = spawned
    if not spawned then
      stop("failed")
      instance.error = tostring(pid or ("cannot spawn " .. cmd))
      require("weave.utils.logger").notify(
        ("weave: cannot spawn MCP server %q (%s)"):format(cfg.name, tostring(cmd)), vim.log.levels.ERROR)
      return
    end
    instance.pid, instance.started_at = pid, os.time()
    instance.finished_at, instance.error, instance.exit_code, instance.signal = nil, nil, nil, nil
    bootstrap = init_frame ~= nil
    instance.status = bootstrap and "starting" or "running"
    pipes[2]:read_start(line_reader(function(line)
      vim.schedule(function()
        if epoch ~= generation then return end
        local ok, frame = pcall(vim.json.decode, line)
        if ok and type(frame) == "table" then
          if bootstrap and frame.method == nil and frame.id == init_frame.id then
            bootstrap = false
            if bootstrap_timer then
              bootstrap_timer:stop()
              bootstrap_timer:close()
              bootstrap_timer = nil
            end
            if frame.error then
              stop("failed")
              instance.error = vim.inspect(frame.error)
              return
            end
            if initialized then to_server(vim.json.encode(initialized)) end
            instance.status = "running"
            notify()
            return
          end
          local request = frame.method == nil and frame.id ~= nil and pending[frame.id] or nil
          if request then
            pending[frame.id] = nil
            if request.method == "initialize" and type(frame.result) == "table" then
              instance.server_info = frame.result.serverInfo
            elseif request.method == "tools/list" and type(frame.result) == "table" then
              if not request.params or not request.params.cursor then instance.tools = {} end
              for _, tool in ipairs(frame.result.tools or {}) do
                instance.tools[#instance.tools + 1] = tool
              end
              notify()
            end
          end
        end
        to_agent(line)
      end)
    end, function()
      vim.schedule(function() if epoch == generation then stop("exited") end end)
    end))
    pipes[3]:read_start(function() end)
    if bootstrap then
      bootstrap_timer = uv.new_timer()
      bootstrap_timer:start(10000, 0, vim.schedule_wrap(function()
        if epoch ~= generation then return end
        stop("failed")
        instance.error = "MCP initialization timed out after restart"
      end))
      to_server(vim.json.encode(init_frame))
    end
    notify()
  end

  local function receive(line)
      if closed then return end
      if not require("weave.tools.gate").valid(ctx) then instance.close(); return end
      local ok, frame = pcall(vim.json.decode, line)
      if not ok or type(frame) ~= "table" then return end
      if frame.method == "initialize" then init_frame = frame end
      if frame.method == "notifications/initialized" then initialized = frame end
      if instance.status ~= "running" then
        if frame.method and frame.id ~= nil then
          to_agent({ jsonrpc = "2.0", id = frame.id, error = { code = -32000, message = "MCP server unavailable" } })
        end
        return
      end
      local epoch = generation
      -- Only requests originating at the agent need a response. The agent can
      -- also reply to server-originated requests using the same ID namespace.
      local request
      if frame.method and frame.id ~= nil then
        request = { method = frame.method, params = frame.params }
        pending[frame.id] = request
      end
      local function active()
        return not closed and epoch == generation and instance.status == "running"
          and (not request or pending[frame.id] == request)
      end
      local function forward()
        if active() then to_server(line) end
      end
      if frame.method == "tools/call" and frame.id ~= nil then
        local name = frame.params and frame.params.name or "?"
        request.cancel = require("weave.tools.gate").mediate({ tool = "mcp:" .. name },
          ("MCP tool %s (%s)"):format(name, cfg.name), "other", forward, function(ret)
            if not active() then return end
            pending[frame.id] = nil
            to_agent({ jsonrpc = "2.0", id = frame.id, result = to_result(ret) })
          end, ctx)
      else
        forward()
      end
  end
  conn:read_start(line_reader(function(line) vim.schedule(function() receive(line) end) end, function()
    vim.schedule(function()
      closed = true
      stop("disconnected")
      if not conn:is_closing() then conn:close() end
    end)
  end))
  instance.close = function()
    closed = true
    stop("disconnected")
    if not conn:is_closing() then conn:close() end
  end
  instance.start()
  return receive
end

--- The proxy socket for a configured server entry: one listener per server
--- name, created on first use; every connection gets its own real-server
--- process. Returns nil when the listener cannot be created.
--- @param cfg table McpServer entry
--- @return { path: string }|nil
function M.listener_for(cfg, authenticated)
  local existing = M._proxies[cfg.name]
  if existing then
    if authenticated and not existing.require_auth then
      existing.require_auth = true
      for _, instance in ipairs(existing.instances) do instance.close() end
    end
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
      local proxy = M._proxies[cfg.name]
      if not proxy then conn:close(); return end
      if not proxy.require_auth then attach(conn, cfg); return end
      local dispatch, rejected
      conn:read_start(line_reader(function(line)
        vim.schedule(function()
          if rejected or conn:is_closing() then return end
          if dispatch then dispatch(line); return end
          local token = line:match("^CLANKBOX_AUTH ([^\r\n]+)$")
          local caller = require("weave.tool_context").authenticate(token)
          if not caller then
            rejected = true
            conn:write(vim.json.encode({ jsonrpc = "2.0", id = vim.NIL,
              error = { code = -32001, message = "Authentication failed" } }) .. "\n",
              function() if not conn:is_closing() then conn:close() end end)
            return
          end
          conn:read_stop()
          dispatch = attach(conn, cfg, { caller = caller })
        end)
      end, function()
        if not conn:is_closing() then conn:close() end
      end))
    end)
  end)
  if not ok then
    server:close()
    uv.fs_unlink(path)
    return nil
  end

  local proxy = { path = path, server = server, cfg = cfg, instances = {}, require_auth = authenticated == true }
  M._proxies[cfg.name] = proxy
  notify()
  return proxy
end

--- The McpServer entry the AGENT receives for a wrapped server: the clankbox
--- shim in byte-pump mode against this server's proxy socket. nil when
--- wrapping is impossible (no clankbox shim to run) — the caller falls back
--- to handing over the raw entry.
--- @param cfg table McpServer entry
--- @return table|nil
function M.entry_for(cfg, session)
  local shim = require("weave.tools").shim_path()
  if not shim then
    return nil
  end
  local proxy = M.listener_for(cfg, session ~= nil)
  if not proxy then
    return nil
  end
  local env = { { name = "CLANKBOX_SOCKET", value = proxy.path } }
  if session then env[#env + 1] = { name = "CLANKBOX_AUTH_TOKEN", value = require("weave.tool_context").bind(session) } end
  return {
    name = cfg.name,
    command = vim.v.progpath,
    args = { "-l", shim },
    env = env,
  }
end

function M.close_session(session)
  for _, proxy in pairs(M._proxies) do
    for _, instance in ipairs(proxy.instances or {}) do
      if instance.caller and instance.caller.session == session then instance.close() end
    end
  end
end

-- Test hook: close listeners, agent connections, and their managed processes.
function M._reset()
  for name, proxy in pairs(M._proxies) do
    for _, instance in ipairs(proxy.instances or {}) do instance.close() end
    if proxy.server and not proxy.server:is_closing() then
      proxy.server:close()
    end
    uv.fs_unlink(proxy.path)
    M._proxies[name] = nil
  end
end

return M
