-- weave.sandbox: confine the ACP agent process with bubblewrap (design doc:
-- design-agent-sandbox.md, phase 2). The whole module is an argv rewrite —
-- `Sandbox.wrap(command, args, opts)` turns the provider invocation into a
-- `bwrap` one; the transport spawns whatever comes back, so there is exactly
-- one touch point (ACPClient:_setup_transport) and zero protocol changes.
--
-- Profiles, by what the PROJECT directory looks like from inside:
--   off        no wrapping (the default, and the forced result when no
--              backend exists on this platform — one-time notify)
--   workspace  project rw; the rest of $HOME hidden behind a tmpfs except
--              state_paths. Pure containment.
--   readonly   project ro: the agent's own read/search tools still work, but
--              every write must flow through the weave MCP tools.
--   blackbox   project absent: even reads go through weave, so the
--              transcript shows every file the agent ever saw.
--
-- In every sandboxed profile the rest of the filesystem is bound read-only
-- (/nix/store, /etc/ssl, resolv.conf and friends keep working), /tmp /dev
-- /proc are private, and the network is SHARED — domain filtering is
-- explicitly out of scope here. This is guardrails plus tool-forcing, not a
-- security boundary against a hostile agent with network access.
--
-- MCP servers are spawned BY the agent, so they live inside the same
-- sandbox: the $NVIM socket is bind-mounted (over the private /tmp when it
-- lives there) so the clankbox shim can still reach nvim, and the nvim
-- binary + clankbox checkout are bound read-only in case they sit under the
-- hidden $HOME.

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

local PROFILES = { off = true, workspace = true, readonly = true, blackbox = true }

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

--- Degrade a requested profile to what this platform can actually deliver,
--- warning once. Both resolve() and wrap() go through here so the profile
--- weave REPORTS is the profile the agent RUNS at: claiming `blackbox` on a
--- machine without bwrap would have the permissions UI and the sandboxed
--- presets vouching for a confinement that is not there.
--- @param profile string
--- @return string
local function degrade(profile)
  if profile == "off" or M._available() then
    return profile
  end
  if not notified then
    notified = true
    vim.notify(
      ('weave: sandbox profile "%s" requested but no backend is available on this platform; agents run unsandboxed'):format(
        profile
      ),
      vim.log.levels.WARN
    )
  end
  return "off"
end

--- Merge the global `Config.sandbox` with a provider's override: scalars
--- (profile, env_allowlist) — the provider wins; path lists — concatenated,
--- global first, so per-provider grants ADD to machine-wide ones. The
--- resulting profile is the EFFECTIVE one (see degrade).
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
    profile = degrade(p.profile or global.profile or "off"),
    state_paths = cat(global.state_paths, p.state_paths),
    ro_paths = cat(global.ro_paths, p.ro_paths),
    env_allowlist = p.env_allowlist or global.env_allowlist,
  }
end

--- @class weave.sandbox.WrapOpts : weave.SandboxConfig
--- @field cwd? string Project dir the profile applies to (default: getcwd)
--- @field home? string $HOME to hide (default: the real one)
--- @field nvim_socket? string|false Socket to bind for MCP shims (default: v:servername; false = none)
--- @field runtime_ro_paths? string[] Infra ro binds (default: M._runtime_ro_paths())

--- Rewrite a provider invocation into its sandboxed form. Pure on its
--- inputs: profile "off" (or a missing backend) returns the command
--- untouched; anything else returns `"bwrap", argv`.
--- @param command string
--- @param args string[]|nil
--- @param opts weave.sandbox.WrapOpts
--- @return string command
--- @return string[] args
function M.wrap(command, args, opts)
  opts = opts or {}
  local profile = opts.profile or "off"
  if not PROFILES[profile] then
    error("unknown sandbox profile: " .. tostring(profile))
  end
  if profile == "off" then
    return command, args or {}
  end
  if degrade(profile) == "off" then
    return command, args or {}
  end

  local home = opts.home or uv.os_homedir() or vim.env.HOME
  local cwd = opts.cwd or vim.fn.getcwd()
  local function expand(path)
    return (path:gsub("^~", home))
  end

  -- Mounts apply in order, later ones on top: the ro root first, then the
  -- private /tmp /dev /proc and the $HOME tmpfs, then the project policy and
  -- the explicit grants punched through them.
  local argv = {
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
  -- Is this path inside an area we replaced with a tmpfs ($HOME, /tmp)?
  -- There bwrap can create mountpoints freely; everywhere else it cannot.
  local function hidden(abs)
    return vim.startswith(abs, home .. "/") or abs == home or vim.startswith(abs, "/tmp/") or abs == "/tmp"
  end

  local function mount(flag, path)
    local abs = expand(path)
    if not M._exists(abs) then
      return
    end
    -- The SOURCE resolves through symlinks by itself; the DESTINATION does
    -- not. Outside the tmpfs areas the mountpoint has to be a real existing
    -- path: bwrap cannot mkdir it on our read-only root, and it refuses to
    -- bind over a symlink (nix puts plenty of those on the runtime paths).
    -- Inside them the literal path is the right one and bwrap creates it.
    local dest = abs
    if not hidden(abs) then
      dest = M._realpath(abs) or abs
    end
    vim.list_extend(argv, { flag, abs, dest })
  end

  if profile == "workspace" then
    mount("--bind", cwd)
  elseif profile == "readonly" then
    mount("--ro-bind", cwd)
  else -- blackbox
    vim.list_extend(argv, { "--tmpfs", cwd })
  end

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

  -- The $NVIM socket, over the private /tmp when it lives there. A rw bind:
  -- connect(2) needs write access to the socket inode.
  local sock = opts.nvim_socket
  if sock == nil then
    sock = vim.v.servername
  end
  if sock and sock ~= "" then
    mount("--bind-try", sock)
  end

  vim.list_extend(argv, { "--", command })
  vim.list_extend(argv, args or {})
  return "bwrap", argv
end

return M
