-- weave.sandbox: process confinement, v2 (design-agent-sandbox-v2.md).
-- Two wraps, both pure argv rewrites the spawner runs verbatim:
--
--   wrap       the AGENT process. Mode "off" = untouched; mode "on" = the
--              one invariant maximal sandbox — the project unreachable,
--              $HOME hidden except the provider's own state/auth dirs, the
--              scoped broker socket the only designed path out. There is no
--              policy on the agent process; all capability lives at the tool
--              layer.
--   wrap_tool  a TOOL invocation (a task's shell, a search subprocess),
--              confined to the active preset's hull (binds + network),
--              re-derived on every spawn.
--
-- This module owns the POLICY — what the hull contains — and hands the
-- finished hull to a backend, which owns the MECHANISM. Backends are tried
-- in order (weave.sandbox.bwrap on Linux, weave.sandbox.seatbelt on macOS)
-- and the first available one wins; with none available the wraps are inert
-- and the resolved mode degrades to "off", loudly, so weave never claims a
-- confinement it is not delivering. The two backends do NOT confine
-- identically — see weave/sandbox/seatbelt.lua for what macOS cannot do.
--
-- In both hulls the rest of the filesystem stays readable (/nix/store,
-- /etc/ssl, resolv.conf and friends keep working). The AGENT keeps the
-- network (the model API is non-negotiable); TOOLS lose it unless the hull
-- grants it. The agent also keeps its own state dirs — an agent that cannot
-- authenticate is just broken — so "no access to anything" carries exactly
-- those two footnotes.

local M = {}

local uv = vim.uv or vim.loop

--- Shipped rw state/auth grants per provider binary (keyed by command
--- basename; every entry is best-effort, so absent paths are free). These
--- are the dirs an agent needs to even authenticate; anything else goes in
--- `state_paths`. Every sandboxed provider ALSO gets the generic XDG
--- quartet for its basename (~/.config/<name> etc.).
local STATE_PATH_DEFAULTS = {
  ["claude-agent-acp"] = { "~/.claude", "~/.claude.json" },
  ["claude-code-acp"] = { "~/.claude", "~/.claude.json" },
  ["gemini"] = { "~/.gemini" },
  ["codex-acp"] = { "~/.codex" },
  ["goose"] = { "~/.local/share/goose" },
  ["copilot"] = { "~/.config/github-copilot" },
}

local SANDBOX_MODES = { off = true, on = true }

--- Backend chain, most-preferred first. bwrap is a mount namespace and is
--- the reference implementation; seatbelt is the macOS fallback and confines
--- strictly less (no process isolation, denials instead of empty mounts).
M.BACKENDS = { "weave.sandbox.bwrap", "weave.sandbox.seatbelt" }

--- The backend this machine will actually use, or nil. Test seam: specs
--- pin one so the argv assertions do not depend on what is installed.
--- @return table|nil
function M._backend()
  for _, mod in ipairs(M.BACKENDS) do
    local ok, backend = pcall(require, mod)
    if ok and backend.available() then
      return backend
    end
  end
  return nil
end

--- @return boolean
function M._available()
  return M._backend() ~= nil
end

--- @return string|nil
function M.backend_name()
  local backend = M._backend()
  return backend and backend.name or nil
end

--- The backend a wrap should use: `_available` is the one gate everything
--- else in weave already consults (degrade, tool_sandboxing_on), so honour
--- it here too rather than letting a wrap confine a process weave has
--- already told the rest of the plugin it is not confining.
--- @return table|nil
local function selected()
  if not M._available() then
    return nil
  end
  return M._backend()
end

--- Does this path exist on the host? (test seam; the bwrap backend filters
--- every grant through it — see its `mounter`.)
function M._exists(path)
  return require("weave.sandbox.fs").exists(path)
end

--- Resolve a path through symlinks (test seam; both backends need the real
--- path, bwrap for the bind destination and seatbelt for the rule filter).
function M._realpath(path)
  return require("weave.sandbox.fs").realpath(path)
end

--- The filesystem the backends see, routed through the seams above so a spec
--- can stub `Sandbox._exists` and have it apply inside the backend.
local function fs_seam()
  return {
    exists = function(path)
      return M._exists(path)
    end,
    realpath = function(path)
      return M._realpath(path)
    end,
  }
end

-- One-time degradation notice (per nvim session, not per spawn).
local notified = false

function M._reset()
  notified = false
end

--- The staged-attachment directory, when anything has been staged into it
--- (weave.attachments). A separate seam from the infra binds below because
--- it appears and disappears with what the USER attached, not with the
--- machine.
--- @return string[]
function M._attachment_paths()
  local ok, Attachments = pcall(require, "weave.attachments")
  return ok and Attachments.sandbox_paths() or {}
end

--- Read-only infrastructure grants every sandboxed agent needs and that may
--- hide under the $HOME denial: the nvim binary serving the clankbox shim
--- (plus its symlink target), the clankbox checkout itself, and the
--- ~/.nix-profile PATH root on nix-managed machines.
--- @return string[]
function M._runtime_ro_paths()
  local paths = { "~/.nix-profile" }
  local prog = vim.v.progpath
  if prog and prog ~= "" then
    paths[#paths + 1] = prog
    local real = uv.fs_realpath(prog)
    if real and real ~= prog then
      paths[#paths + 1] = real
    end
  end
  local ok, tools = pcall(require, "weave.tools")
  local entry = ok and tools.clankbox_server_entry() or nil
  if entry and entry.args and entry.args[2] then
    paths[#paths + 1] = vim.fn.fnamemodify(entry.args[2], ":h")
  end
  return paths
end

--- Degrade a requested mode to what this platform can actually deliver,
--- warning once. Both resolve() and wrap() go through here so the mode
--- weave REPORTS is the mode the agent RUNS at: claiming "on" on a machine
--- with no backend would have the permissions UI and the preset filtering
--- vouching for a confinement that is not there.
--- @param mode string
--- @return string
local function degrade(mode)
  if mode == "off" or M._available() then
    return mode
  end
  if not notified then
    notified = true
    vim.notify(
      "weave: sandbox mode on requested but no backend is available on this platform "
        .. "(bwrap on Linux, sandbox-exec on macOS); agents run unsandboxed",
      vim.log.levels.WARN
    )
  end
  return "off"
end

--- The mode one config level asks for. The v1 `profile` key was removed
--- with the profile machinery (design-agent-sandbox-v2.md phase F) — a
--- config still using it must fail LOUDLY, not silently run unsandboxed at
--- a different confinement than it named.
--- @param cfg weave.SandboxConfig
--- @return string|nil
local function requested_mode(cfg)
  if cfg.profile ~= nil then
    error(
      'weave.sandbox: `profile` was removed (sandbox v2): use `mode = "on"` (invariant maximal sandbox) or "off"',
      0
    )
  end
  if cfg.mode ~= nil and not SANDBOX_MODES[cfg.mode] then
    error(('weave.sandbox: `mode` must be "on" or "off", got %s'):format(vim.inspect(cfg.mode)), 0)
  end
  return cfg.mode
end

--- Merge the global `Config.sandbox` with a provider's override: scalars
--- (mode, env_allowlist) — the provider wins; path lists — concatenated,
--- global first, so per-provider grants ADD to machine-wide ones. The
--- resulting mode is the EFFECTIVE one (see degrade).
--- @param provider_sandbox weave.SandboxConfig|nil
--- @return weave.SandboxConfig
function M.resolve(provider_sandbox)
  local global = require("weave.config").sandbox or {}
  local p = provider_sandbox or {}
  local function cat(a, b)
    local out = {}
    vim.list_extend(out, a or {})
    vim.list_extend(out, b or {})
    return out
  end
  return {
    mode = degrade(requested_mode(p) or requested_mode(global) or "off"),
    state_paths = cat(global.state_paths, p.state_paths),
    ro_paths = cat(global.ro_paths, p.ro_paths),
    env_allowlist = p.env_allowlist or global.env_allowlist,
  }
end

--- @class weave.sandbox.Grant
--- @field path string absolute (~ already expanded against the hull's home)
--- @field mode "rw"|"ro"

--- What a backend needs to build the agent sandbox. The grants are ORDERED
--- and later ones win, which is the one semantic both backends implement
--- natively (bwrap stacks mounts, SBPL takes the last matching rule).
--- @class weave.sandbox.AgentHull
--- @field home string $HOME to hide
--- @field cwd string project dir to make unreachable
--- @field grants weave.sandbox.Grant[] punched back through, in order

--- @class weave.sandbox.ToolHull
--- @field binds weave.sandbox.Grant[]
--- @field network boolean
--- @field home string

--- @class weave.sandbox.WrapOpts : weave.SandboxConfig
--- @field cwd? string Project dir the mode-on hull covers (default: getcwd)
--- @field home? string $HOME to hide (default: the real one)
--- @field nvim_socket? string|false Socket to grant for MCP shims (default: the weave broker socket when clankbox serves one, else v:servername; false = none)
--- @field runtime_ro_paths? string[] Infra ro grants (default: M._runtime_ro_paths())
--- @field attachment_paths? string[] Staged-attachment ro grants (default: M._attachment_paths())

--- Rewrite a provider invocation into its sandboxed form. Pure on its
--- inputs: mode "off" (or a missing backend) returns the command untouched;
--- mode "on" builds THE agent hull — there is exactly one, invariant, with
--- nothing to configure on it — and hands it to the backend.
--- @param command string
--- @param args string[]|nil
--- @param opts weave.sandbox.WrapOpts
--- @return string command
--- @return string[] args
function M.wrap(command, args, opts)
  opts = opts or {}
  local mode = opts.mode or "off"
  if not SANDBOX_MODES[mode] then
    error("unknown sandbox mode: " .. tostring(mode))
  end
  if mode == "off" or degrade(mode) == "off" then
    return command, args or {}
  end
  local backend = selected()
  if not backend then
    return command, args or {}
  end

  local home = opts.home or uv.os_homedir() or vim.env.HOME
  local cwd = opts.cwd or vim.fn.getcwd()

  local grants = {}
  local function grant(mode_, path)
    grants[#grants + 1] = { path = (path:gsub("^~", home)), mode = mode_ }
  end

  local base = vim.fn.fnamemodify(command, ":t")
  for _, path in ipairs(STATE_PATH_DEFAULTS[base] or {}) do
    grant("rw", path)
  end
  for _, suffix in ipairs({ "config", "cache", "local/share", "local/state" }) do
    grant("rw", "~/." .. suffix .. "/" .. base)
  end
  for _, path in ipairs(opts.state_paths or {}) do
    grant("rw", path)
  end
  for _, path in ipairs(opts.ro_paths or {}) do
    grant("ro", path)
  end
  for _, path in ipairs(opts.runtime_ro_paths or M._runtime_ro_paths()) do
    grant("ro", path)
  end

  -- Files the USER attached to a prompt, staged by weave (weave.attachments)
  -- and granted READ-ONLY so an image the agent is asked to look at is a real
  -- file at a real path in here. Without this the file:// URI in the prompt
  -- resolves to nothing and a model that reads images natively sees no
  -- attachment at all. Empty until something is staged, so a session that
  -- never attaches anything gets no extra grant.
  for _, path in ipairs(opts.attachment_paths or M._attachment_paths()) do
    grant("ro", path)
  end

  -- The tool socket. Granted rw: connect(2) needs write access to the socket
  -- inode. Prefer the scoped broker socket (weave.tools) — handing over $NVIM
  -- gives the sandbox nvim's raw RPC (nvim_exec_lua = full escape), so the
  -- legacy fallback exists only for a clankbox that predates the broker.
  local sock = opts.nvim_socket
  if sock == nil then
    local tok, Tools = pcall(require, "weave.tools")
    local lst = tok and Tools.broker_listener() or nil
    sock = lst and lst.path or vim.v.servername
  end
  if sock and sock ~= "" then
    grant("rw", sock)
  end

  return backend.wrap_agent(command, args or {}, { home = home, cwd = cwd, grants = grants }, fs_seam())
end

--- ── Tool sandboxes (design-agent-sandbox-v2.md, phase D) ────────────────────

--- Rewrite a TOOL invocation (a task's shell, a search subprocess) into its
--- sandboxed form under a hull (weave.permissions.tool_sandbox).
--- Pure on its inputs; no backend = the command untouched (the caller keeps
--- policy enforcement, only kernel enforcement degrades).
--- @param command string
--- @param args string[]|nil
--- @param hull { binds: weave.sandbox.Grant[], network: boolean, home?: string }
--- @return string command
--- @return string[] args
function M.wrap_tool(command, args, hull)
  local backend = selected()
  if not backend then
    return command, args or {}
  end
  return backend.wrap_tool(command, args or {}, {
    binds = hull.binds or {},
    network = hull.network,
    home = hull.home or uv.os_homedir() or vim.env.HOME,
  }, fs_seam())
end

--- Whether tool invocations run sandboxed at all: one switch (the resolved
--- global mode) governs both the agent process and the tools.
--- @return boolean
function M.tool_sandboxing_on()
  return M._available() and M.resolve(nil).mode == "on"
end

--- The task store's spawn seam: `sh -c command`, wrapped under the ACTIVE
--- preset's hull for `weave:task_start` when tool sandboxing is on. Resolved
--- per invocation, so a preset switch, a per-tool override or an elevation
--- grant applies to the very next task with no restart anywhere.
--- @param command string
--- @return string command
--- @return string[] args
function M.wrap_shell(command)
  return M.wrap_for_tool("weave:task_start", "sh", { "-c", command })
end

--- The same, for a tool that spawns a BINARY rather than a shell (curl, under
--- w:web_fetch). Same resolution — the active preset's hull for that exact
--- tool name, re-derived per spawn — and the same degradation: with tool
--- sandboxing off the argv comes back untouched.
--- @param tool string namespaced tool name, e.g. "weave:web_fetch"
--- @param command string
--- @param args? string[]
--- @return string command
--- @return string[] args
function M.wrap_for_tool(tool, command, args)
  args = args or {}
  if not M.tool_sandboxing_on() then
    return command, args
  end
  local ok, Permissions = pcall(require, "weave.permissions")
  local hull = ok and Permissions.tool_sandbox(nil, tool) or { binds = {}, network = false }
  return M.wrap_tool(command, args, hull)
end

return M
