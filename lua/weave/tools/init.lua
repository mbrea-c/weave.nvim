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
  check_user_edits = true,
  request_access = true,
  web_fetch = true,
  annotate = true,
  annotate_list = true,
  annotate_update = true,
  annotate_dismiss = true,
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
  -- The mutating tools additionally sit behind the EDIT gate (weave.tools.
  -- user_edits): with the edit_gate setting on, they refuse while the user
  -- has edits the conversation has not seen. Guard inside, permissions
  -- outside — a permission deny should not leak the gate's refusal text.
  local UserEdits = require("weave.tools.user_edits")
  server.register_tool("read", Gate.wrap("read", fs.read, { resource = fs_resource, kind = "read" }))
  server.register_tool(
    "write",
    Gate.wrap("write", UserEdits.guard(fs.write), { resource = fs_resource, kind = "edit" })
  )
  server.register_tool("edit", Gate.wrap("edit", UserEdits.guard(fs.edit), { resource = fs_resource, kind = "edit" }))
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
  server.register_tool(
    "task_start",
    Gate.wrap("task_start", UserEdits.guard(tasks.start), { resource = command, kind = "execute" })
  )
  -- The gate's other half: how the agent gets back in sync (and a tool any
  -- agent may call defensively — cheap when clean).
  server.register_tool("check_user_edits", Gate.wrap("check_user_edits", UserEdits.check, { kind = "read" }))
  server.register_tool("task_status", Gate.wrap("task_status", tasks.status, { kind = "execute" }))
  server.register_tool("task_wait", Gate.wrap("task_wait", tasks.wait, { kind = "execute" }))
  server.register_tool("task_kill", Gate.wrap("task_kill", tasks.kill, { kind = "execute" }))
  -- The web. Gated on the URL, so a rule can scope by host ("https://docs.
  -- example.com/**"), and tagged with the ACP `fetch` kind so it reads like
  -- the agent's own fetch tool in the transcript. The curl subprocess is
  -- confined by the hull for `weave:web_fetch` (network, no binds, under the
  -- builtin sandboxed presets) — see weave.sandbox.wrap_for_tool.
  local web_fetch = require("weave.tools.web_fetch")
  local url_resource = function(args)
    return type(args.url) == "string" and args.url ~= "" and args.url or nil
  end
  server.register_tool("web_fetch", Gate.wrap("web_fetch", web_fetch.def, { resource = url_resource, kind = "fetch" }))
  -- Feedback ON the user's code (weave.annotations): the agent's half of
  -- inline code feedback, and its whole output channel in tutor mode. Gated on
  -- the PATH like the fs tools, so a rule can scope where the agent may leave
  -- notes; the query/edit/dismiss three carry no resource, like the task query
  -- tools, because they name an annotation id rather than a file.
  local annotate = require("weave.tools.annotate")
  server.register_tool("annotate", Gate.wrap("annotate", annotate.annotate, { resource = fs_resource }))
  server.register_tool("annotate_list", Gate.wrap("annotate_list", annotate.annotate_list))
  server.register_tool("annotate_update", Gate.wrap("annotate_update", annotate.annotate_update))
  server.register_tool("annotate_dismiss", Gate.wrap("annotate_dismiss", annotate.annotate_dismiss))
  -- The elevation tool goes in UNwrapped: it IS the asking mechanism (its
  -- handler always prompts), so gating it would prompt twice per question.
  server.register_tool("request_access", require("weave.tools.access").def)
  -- Everything else the agent can reach over this host — clankbox's own
  -- exec_lua, another plugin's tools — through the same engine, as mcp:<tool>.
  -- Without this the sandbox is decorative: exec_lua runs arbitrary Lua
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

local listener = nil

--- The broker listener agents connect through: one per editor, created on
--- first use, scoped to EXACTLY weave's own suite (design-agent-sandbox-v2:
--- the socket is the only path out of the agent sandbox, so what it exposes
--- is precisely what an agent can ever reach — clankbox's other tools are
--- not even visible, as opposed to gated). nil when clankbox is absent or
--- predates the broker; the legacy $NVIM shim path still works there, for
--- unsandboxed agents.
--- @return ClankboxListener|nil
function M.broker_listener()
  if listener then
    return listener
  end
  if not M.ensure_registered() then
    return nil
  end
  local ok, broker = pcall(require, "clankbox.broker")
  if not ok or type(broker.listen) ~= "function" then
    return nil
  end
  local names = {}
  for name in pairs(M.OWNS) do
    names[#names + 1] = name
  end
  listener = broker.listen({ tools = names })
  return listener
end

--- The MCP server entry handed to agents: the clankbox stdio shim, run by
--- this very nvim binary (works inside the sandbox: /nix/store is a
--- read-only grant). The checkout root comes from `tools.clankbox_path` or
--- is auto-detected from the runtimepath/package.path. nil when clankbox
--- cannot be located (entry without a shim would just break the agent).
---
--- With the broker available the entry carries $CLANKBOX_SOCKET, putting the
--- shim in byte-pump mode against the scoped listener — the sandbox-safe
--- transport. Without it the env stays empty and the session's legacy $NVIM
--- injection takes over (see Session:_resolve_mcp_servers).
--- The clankbox stdio shim on disk, or nil when clankbox cannot be located.
--- The checkout root comes from `tools.clankbox_path` or is auto-detected
--- from the runtimepath/package.path. Shared by the weave entry below and
--- by the MCP proxy (whose wrapped servers ride the same shim in byte-pump
--- mode).
--- @return string|nil
function M.shim_path()
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
  return shim
end

--- @return weave.acp.McpServer|nil
function M.clankbox_server_entry()
  local shim = M.shim_path()
  if not shim then
    return nil
  end
  local env = {}
  local lst = M.broker_listener()
  if lst then
    env[#env + 1] = { name = "CLANKBOX_SOCKET", value = lst.path }
  end
  return { name = "clankbox", command = vim.v.progpath, args = { "-l", shim }, env = env }
end

-- test hook: registration is once-per-process; specs restore a clean slate
function M._reset()
  registered = false
  if listener then
    pcall(function()
      listener:close()
    end)
    listener = nil
  end
end

return M
