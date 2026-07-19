-- weave's MCP tool suite (design-agent-sandbox.md, phase 0). weave is a tool
-- PROVIDER into the shared clankbox host, exactly like perijove: a pcall'd
-- soft dependency, nothing breaks when clankbox is absent. Beyond providing
-- the tools, weave also hands every ACP agent a clankbox server entry (the
-- stdio shim run by THIS nvim) at session/new, so the suite reaches agents
-- with zero per-user MCP configuration — see Session:_resolve_mcp_servers.

local Config = require("weave.config")

local M = {}

local registered = false

--- Plant the suite into anything exposing register_tool(name, def).
--- @param server { register_tool: fun(name: string, def: table) }
function M.register_into(server)
  local fs = require("weave.tools.fs")
  server.register_tool("read", fs.read)
  server.register_tool("write", fs.write)
  server.register_tool("edit", fs.edit)
  local tasks = require("weave.tools.tasks")
  server.register_tool("task_start", tasks.start)
  server.register_tool("task_status", tasks.status)
  server.register_tool("task_wait", tasks.wait)
  server.register_tool("task_kill", tasks.kill)
end

--- Register into clankbox when it is installed. Idempotent; called from
--- setup() and again lazily at session creation, so the tools exist whenever
--- an agent is handed the server entry.
--- @return boolean registered
function M.ensure_registered()
  if registered then
    return true
  end
  local ok, clankbox = pcall(require, "clankbox")
  if not ok then
    return false
  end
  M.register_into(clankbox)
  registered = true
  return true
end

--- The MCP server entry handed to agents: the clankbox stdio shim, run by
--- this very nvim binary (works inside a future sandbox: /nix/store is a
--- read-only grant). The checkout root comes from `tools.clankbox_path` or
--- is auto-detected from the runtimepath/package.path. nil when clankbox
--- cannot be located (entry without a shim would just break the agent).
--- @return weave.acp.McpServer|nil
function M.clankbox_server_entry()
  local root = Config.tools and Config.tools.clankbox_path
  if not root then
    local hit = vim.api.nvim_get_runtime_file("lua/clankbox/init.lua", false)[1]
    if not hit then
      local ok, found = pcall(package.searchpath, "clankbox", package.path)
      hit = (ok and found) or nil
    end
    if hit then
      root = vim.fn.fnamemodify(hit, ":h:h:h")
    end
  end
  if not root then
    return nil
  end
  local shim = root .. "/shim.lua"
  if vim.fn.filereadable(shim) ~= 1 then
    return nil
  end
  return { name = "clankbox", command = vim.v.progpath, args = { "-l", shim }, env = {} }
end

-- test hook: registration is once-per-process; specs restore a clean slate
function M._reset()
  registered = false
end

return M
