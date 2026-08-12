-- weave.sandbox: bubblewrap confinement, v2 (design-agent-sandbox-v2.md).
-- Two wraps, both pure argv rewrites the spawner runs verbatim:
--
--   wrap       the AGENT process. Mode "off" = untouched; mode "on" = the
--              one invariant maximal sandbox — the project an empty
--              READ-ONLY tmpfs, $HOME hidden except the provider's own
--              state/auth dirs, the scoped broker socket the only designed
--              path out. There is no policy on the agent process; all
--              capability lives at the tool layer.
--   wrap_tool  a TOOL invocation (a task's shell, a search subprocess),
--              confined to the active preset's hull (binds + network),
--              re-derived on every spawn.
--
-- In both, the rest of the filesystem is bound read-only (/nix/store,
-- /etc/ssl, resolv.conf and friends keep working) and /tmp /dev /proc are
-- private. The AGENT keeps the network (the model API is non-negotiable);
-- TOOLS lose it unless the hull grants it. The agent also keeps its own
-- state dirs — an agent that cannot authenticate is just broken — so
-- "no access to anything" carries exactly those two footnotes.

local M = {}

local uv = vim.uv or vim.loop

--- Shipped rw state/auth grants per provider binary (keyed by command
--- basename; every entry binds with -try, so absent paths are free). These
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

--- Backend availability: bwrap is Linux-only. Overridable test seam; a macOS
--- Seatbelt backend would slot in behind this same check (the config surface
--- is deliberately backend-agnostic).
function M._available()
  return vim.fn.has("linux") == 1 and vim.fn.executable("bwrap") == 1
end

--- Does this path exist on the host? Every grant is filtered through this
--- (test seam). `--bind-try` only tolerates a missing SOURCE: bwrap still
--- has to create the DESTINATION mountpoint, and under our read-only `/`
--- bind that mkdir fails outright ("Can't mkdir parents for ..."), taking
--- the whole spawn with it. Filtering here sidesteps that entirely: a
--- source that exists on the host also exists as a mountpoint inside, since
--- the host tree is bound in. Config listing a path that is not there yet
--- is normal (state dirs appear on first login), so this must never be an
--- error.
function M._exists(path)
  return uv.fs_lstat(path) ~= nil
end

--- Resolve a path through symlinks (test seam; see `mount` for why the
--- DESTINATION of a bind has to be the real path outside the tmpfs areas).
function M._realpath(path)
  return uv.fs_realpath(path)
end

-- One-time degradation notice (per nvim session, not per spawn).
local notified = false

function M._reset()
  notified = false
end

--- Read-only infrastructure binds every sandboxed agent needs and that may
--- hide under the $HOME tmpfs: the nvim binary serving the clankbox shim
--- (plus its symlink target), the clankbox checkout itself, and the
--- ~/.nix-profile PATH root on nix-managed machines. All bound with -try.
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
--- without bwrap would have the permissions UI and the auto-approve flow
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
      "weave: sandbox mode on requested but no backend is available on this platform; agents run unsandboxed",
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

--- The shared confinement floor for every sandboxed process, agent or tool:
--- everything readable except /tmp, /dev, /proc and $HOME, which are
--- private; own pid/ipc/uts namespaces; dies with nvim.
--- @param home string
--- @return string[]
local function base_argv(home)
  return {
    "--die-with-parent",
    "--unshare-pid",
    "--unshare-ipc",
    "--unshare-uts",
    "--unshare-cgroup-try",
    "--ro-bind",
    "/",
    "/",
    "--dev",
    "/dev",
    "--proc",
    "/proc",
    "--tmpfs",
    "/tmp",
    "--tmpfs",
    home,
  }
end

--- A mount() closure appending grants to `argv`. Shared mechanics for both
--- wrap flavours:
---  * missing sources are dropped entirely (bwrap cannot mkdir a mountpoint
---    on the read-only root, so even -try flags die there);
---  * the DESTINATION resolves through realpath outside the tmpfs areas
---    (bwrap refuses to bind over a symlink; nix is full of them), and stays
---    literal inside them, where bwrap can create it freely.
--- @param argv string[]
--- @param home string
--- @return fun(flag: string, path: string)
local function mounter(argv, home)
  local function expand(path)
    return (path:gsub("^~", home))
  end
  local function hidden(abs)
    return vim.startswith(abs, home .. "/") or abs == home or vim.startswith(abs, "/tmp/") or abs == "/tmp"
  end
  return function(flag, path)
    local abs = expand(path)
    if not M._exists(abs) then
      return
    end
    local dest = abs
    if not hidden(abs) then
      dest = M._realpath(abs) or abs
    end
    vim.list_extend(argv, { flag, abs, dest })
  end
end

--- @class weave.sandbox.WrapOpts : weave.SandboxConfig
--- @field cwd? string Project dir the mode-on tmpfs covers (default: getcwd)
--- @field home? string $HOME to hide (default: the real one)
--- @field nvim_socket? string|false Socket to bind for MCP shims (default: the weave broker socket when clankbox serves one, else v:servername; false = none)
--- @field runtime_ro_paths? string[] Infra ro binds (default: M._runtime_ro_paths())

--- Rewrite a provider invocation into its sandboxed form. Pure on its
--- inputs: mode "off" (or a missing backend) returns the command untouched;
--- mode "on" returns `"bwrap", argv` for THE agent sandbox — there is
--- exactly one, invariant, with nothing to configure on it.
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

  local home = opts.home or uv.os_homedir() or vim.env.HOME
  local cwd = opts.cwd or vim.fn.getcwd()

  -- Mounts apply in order, later ones on top: the ro root first, then the
  -- private /tmp /dev /proc and the $HOME tmpfs, then the project mount and
  -- the explicit grants punched through them.
  local argv = base_argv(home)
  local mount = mounter(argv, home)

  -- The project: an EMPTY READ-ONLY tmpfs, not a writable void. The agent's
  -- builtin Write must fail LOUDLY — on a writable tmpfs it would write,
  -- read its own write back, and report the work done while nothing ever
  -- landed (silent data loss). EROFS is what redirects the agent to the
  -- weave tools, which are the only paths that persist.
  vim.list_extend(argv, { "--tmpfs", cwd, "--remount-ro", cwd })

  local base = vim.fn.fnamemodify(command, ":t")
  for _, path in ipairs(STATE_PATH_DEFAULTS[base] or {}) do
    mount("--bind-try", path)
  end
  for _, suffix in ipairs({ "config", "cache", "local/share", "local/state" }) do
    mount("--bind-try", "~/." .. suffix .. "/" .. base)
  end
  for _, path in ipairs(opts.state_paths or {}) do
    mount("--bind-try", path)
  end
  for _, path in ipairs(opts.ro_paths or {}) do
    mount("--ro-bind-try", path)
  end
  for _, path in ipairs(opts.runtime_ro_paths or M._runtime_ro_paths()) do
    mount("--ro-bind-try", path)
  end

  -- The tool socket, over the private /tmp when it lives there. A rw bind:
  -- connect(2) needs write access to the socket inode. Prefer the scoped
  -- broker socket (weave.tools) — binding $NVIM hands the sandbox nvim's raw
  -- RPC (nvim_exec_lua = full escape), so the legacy fallback exists only
  -- for a clankbox that predates the broker.
  local sock = opts.nvim_socket
  if sock == nil then
    local tok, Tools = pcall(require, "weave.tools")
    local lst = tok and Tools.broker_listener() or nil
    sock = lst and lst.path or vim.v.servername
  end
  if sock and sock ~= "" then
    mount("--bind-try", sock)
  end

  vim.list_extend(argv, { "--", command })
  vim.list_extend(argv, args or {})
  return "bwrap", argv
end

--- ── Tool sandboxes (design-agent-sandbox-v2.md, phase D) ────────────────────

--- Rewrite a TOOL invocation (a task's shell, a search subprocess) into its
--- sandboxed form under a hull (weave.permissions.tool_sandbox): the base
--- floor, network cut unless granted, ONLY the hull's binds punched through.
--- No state dirs, no runtime grants, no sockets — tools are not agents; what
--- a tool can see is exactly what the preset's sandbox section says.
--- Pure on its inputs; no backend = the command untouched (the caller keeps
--- policy enforcement, only kernel enforcement degrades).
--- @param command string
--- @param args string[]|nil
--- @param hull { binds: { path: string, mode: "rw"|"ro" }[], network: boolean, home?: string }
--- @return string command
--- @return string[] args
function M.wrap_tool(command, args, hull)
  if not M._available() then
    return command, args or {}
  end
  local home = hull.home or uv.os_homedir() or vim.env.HOME
  local argv = base_argv(home)
  -- Tools do not need the model API, so the network is deniable here in a
  -- way it never was for the agent process.
  if not hull.network then
    argv[#argv + 1] = "--unshare-net"
  end
  local mount = mounter(argv, home)
  for _, b in ipairs(hull.binds or {}) do
    mount(b.mode == "ro" and "--ro-bind" or "--bind", b.path)
  end
  vim.list_extend(argv, { "--", command })
  vim.list_extend(argv, args or {})
  return "bwrap", argv
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
