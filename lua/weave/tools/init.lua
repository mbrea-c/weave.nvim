-- weave's MCP tool suite (design-agent-sandbox.md, phase 0). weave is a tool
-- PROVIDER into the shared clankbox host, exactly like perijove: a pcall'd
-- soft dependency, nothing breaks when clankbox is absent. Beyond providing
-- the tools, weave also hands every ACP agent a clankbox server entry (the
-- stdio shim run by THIS nvim) at session/new, so the suite reaches agents
-- with zero per-user MCP configuration — see Session:_resolve_mcp_servers.

local Config = require("weave.config")

local M = {}

local registered = false

--- The tools weave registers itself. Gate.wrap already mediates these, so the
--- foreign-tool middleware skips them: gating twice would raise two prompts
--- for one call.
M.OWNS = {
  read = true,
  write = true,
  edit = true,
  glob = true,
  grep = true,
  task_start = true,
  task_status = true,
  task_wait = true,
  task_kill = true,
}

--- The fs tools' resource for the permission engine: the ABSOLUTE path (so
--- resource globs match however the agent spelled it), or the buffer ref as
--- passed (rules match buffer names via suffix globs).
--- @param args table
--- @return string|nil
local function fs_resource(args)
  if args.buffer ~= nil then
    return tostring(args.buffer)
  end
  if type(args.path) == "string" and args.path ~= "" then
    return vim.fn.fnamemodify(args.path, ":p")
  end
  return nil
end

--- Plant the suite into anything exposing register_tool(name, def). Every
--- def goes in wrapped behind the client-side permission engine (weave.
--- tools.gate) as weave:<tool>; under the builtin presets the gate is inert.
--- @param server { register_tool: fun(name: string, def: table) }
function M.register_into(server)
  local Gate = require("weave.tools.gate")
  local fs = require("weave.tools.fs")
  server.register_tool("read", Gate.wrap("read", fs.read, { resource = fs_resource, kind = "read" }))
  server.register_tool("write", Gate.wrap("write", fs.write, { resource = fs_resource, kind = "edit" }))
  server.register_tool("edit", Gate.wrap("edit", fs.edit, { resource = fs_resource, kind = "edit" }))
  -- Discovery. The gate's resource is the search ROOT, not the files matched:
  -- gating per result would mean one prompt per file, so a deny rule on
  -- `*/secrets/*` blocks a search rooted inside it but not a cwd-rooted
  -- search that surfaces content from within it. Content-level exclusion
  -- belongs in rg's own filters, not in the permission engine.
  local search = require("weave.tools.search")
  local search_resource = function(args)
    return search.root(args)
  end
  server.register_tool("glob", Gate.wrap("glob", search.glob, { resource = search_resource, kind = "read" }))
  server.register_tool("grep", Gate.wrap("grep", search.grep, { resource = search_resource, kind = "read" }))
  local tasks = require("weave.tools.tasks")
  local command = function(args)
    return type(args.command) == "string" and args.command or nil
  end
  server.register_tool("task_start", Gate.wrap("task_start", tasks.start, { resource = command, kind = "execute" }))
  server.register_tool("task_status", Gate.wrap("task_status", tasks.status, { kind = "execute" }))
  server.register_tool("task_wait", Gate.wrap("task_wait", tasks.wait, { kind = "execute" }))
  server.register_tool("task_kill", Gate.wrap("task_kill", tasks.kill, { kind = "execute" }))
  -- Everything else the agent can reach over this host — clankbox's own
  -- exec_lua, another plugin's tools — through the same engine, as mcp:<tool>.
  -- Without this a sandbox profile is decorative: exec_lua runs arbitrary Lua
  -- in the unsandboxed editor. Soft: an older clankbox has no `use`.
  if type(server.use) == "function" then
    server.use(Gate.middleware())
  end
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
