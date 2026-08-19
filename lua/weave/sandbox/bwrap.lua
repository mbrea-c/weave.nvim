-- weave.sandbox.bwrap: the Linux backend (bubblewrap), the reference
-- implementation of the v2 hulls (design-agent-sandbox-v2.md).
--
-- A mount namespace, so confinement here is about what EXISTS in the view:
-- the rest of the filesystem is bound read-only (/nix/store, /etc/ssl,
-- resolv.conf and friends keep working) and /tmp /dev /proc are private.
-- $HOME and the project are TMPFS mounts, not denials — the agent sees an
-- empty directory rather than an error, which is what makes the first-prompt
-- steering note necessary. The seatbelt backend cannot reproduce that and
-- returns EPERM instead; anything matching on the failure has to accept both.
--
-- Both entry points are pure argv rewrites the spawner runs verbatim.

local M = {}

M.name = "bwrap"

--- What this backend delivers, for the permissions window (see the seatbelt
--- backend, which delivers strictly less and has to say so).
M.confines = "files + network"

--- @return boolean
function M.available()
  return vim.fn.has("linux") == 1 and vim.fn.executable("bwrap") == 1
end

--- $HOME and the project become tmpfs MOUNTPOINTS, and a mountpoint must
--- exist, as a real directory, inside the read-only root we bind — bwrap
--- cannot mkdir it there. Corporate home layouts break that in two ways:
--- $HOME behind a symlink (/home/u -> /export/home/u) leaves the literal
--- path unresolvable in the new namespace, and $HOME on an autofs map may
--- simply not be mounted yet — the automount trigger cannot fire inside the
--- private namespace, so bwrap sees nothing and mount(2) fails with the
--- baffling "Can't mount tmpfs on /newroot/home/u: No such file or
--- directory". Resolving host-side fixes both at once: realpath follows the
--- symlinks to the real directory, and because it stats every component it
--- fires the automount NOW, while the daemon can still see it, so the
--- concrete mount is present when bwrap recursively binds /. On an ordinary
--- box this is the identity. nil (the path truly does not exist) falls back
--- to the literal path — bwrap's own error is the best report we have then.
--- @param path string
--- @param fs { realpath: fun(path: string): string|nil }
--- @return string
local function mountable(path, fs)
  return fs.realpath(path) or path
end

--- A hull may ask for the whole filesystem, writable — the `yolo` preset
--- does. That cannot be honoured as one more grant: `/` is the bind every
--- other mount is layered ONTO, so binding it again after the private /dev,
--- /proc and tmpfs mounts would re-lay the host root over them and undo the
--- floor. The coherent reading is that the request is about the ROOT bind's
--- MODE, which is exactly where this puts it — the private mounts still land
--- on top, and the writable root only changes what the rest of the
--- filesystem allows.
---
--- A `ro` bind of `/` is dropped rather than honoured backwards: read-only is
--- what the root already is, so it asks for nothing.
--- @param binds weave.sandbox.Grant[]|nil
--- @return boolean rw_root
--- @return weave.sandbox.Grant[] rest the binds that are ordinary grants
local function split_root(binds)
  local rw_root, rest = false, {}
  for _, b in ipairs(binds or {}) do
    if b.path == "/" then
      rw_root = rw_root or b.mode ~= "ro"
    else
      rest[#rest + 1] = b
    end
  end
  return rw_root, rest
end

--- The shared confinement floor for every sandboxed process, agent or tool:
--- everything readable except /tmp, /dev, /proc and $HOME, which are
--- private; own pid/ipc/uts namespaces; dies with nvim.
--- @param home string
--- @param rw_root? boolean bind the root read-WRITE (see split_root)
--- @return string[]
local function base_argv(home, rw_root)
  return {
    "--die-with-parent",
    "--unshare-pid",
    "--unshare-ipc",
    "--unshare-uts",
    "--unshare-cgroup-try",
    rw_root and "--bind" or "--ro-bind",
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
---  * missing sources are dropped entirely. `--bind-try` only tolerates a
---    missing SOURCE: bwrap still has to create the DESTINATION mountpoint,
---    and under our read-only `/` bind that mkdir fails outright ("Can't
---    mkdir parents for ..."), taking the whole spawn with it. Filtering
---    here sidesteps that: a source that exists on the host also exists as a
---    mountpoint inside, since the host tree is bound in. Config listing a
---    path that is not there yet is normal (state dirs appear on first
---    login), so this must never be an error.
---  * the DESTINATION resolves through realpath outside the tmpfs areas
---    (bwrap refuses to bind over a symlink; nix is full of them), and stays
---    literal inside them, where bwrap can create it freely. `home` here is
---    the RESOLVED home (see mountable): on a symlinked-home box a grant
---    expanded against the literal home misses the prefix check and takes
---    the realpath branch instead — which lands it inside the home tmpfs at
---    the same place, so both roads agree.
--- @param argv string[]
--- @param home string
--- @param fs { exists: fun(path: string): boolean, realpath: fun(path: string): string|nil }
--- @return fun(flag: string, path: string)
local function mounter(argv, home, fs)
  local function expand(path)
    return (path:gsub("^~", home))
  end
  local function hidden(abs)
    return vim.startswith(abs, home .. "/") or abs == home or vim.startswith(abs, "/tmp/") or abs == "/tmp"
  end
  return function(flag, path)
    local abs = expand(path)
    if not fs.exists(abs) then
      return
    end
    local dest = abs
    if not hidden(abs) then
      dest = fs.realpath(abs) or abs
    end
    vim.list_extend(argv, { flag, abs, dest })
  end
end

--- THE agent sandbox — there is exactly one, invariant, with nothing to
--- configure on it. The project is an EMPTY READ-ONLY tmpfs, not a writable
--- void: the agent's builtin Write must fail LOUDLY, because on a writable
--- tmpfs it would write, read its own write back, and report the work done
--- while nothing ever landed (silent data loss). EROFS is what redirects the
--- agent to the weave tools, which are the only paths that persist.
--- @param command string
--- @param args string[]
--- @param hull weave.sandbox.AgentHull
--- @param fs table|nil
--- @return string command
--- @return string[] args
function M.wrap_agent(command, args, hull, fs)
  fs = fs or require("weave.sandbox.fs")
  local home = mountable(hull.home, fs)
  local cwd = mountable(hull.cwd, fs)
  local rw_root, grants = split_root(hull.grants)

  -- Mounts apply in order, later ones on top: the root bind first, then the
  -- private /tmp /dev /proc and the $HOME tmpfs, then the project mount and
  -- the explicit grants punched through them.
  local argv = base_argv(home, rw_root)
  vim.list_extend(argv, { "--tmpfs", cwd, "--remount-ro", cwd })

  local mount = mounter(argv, home, fs)
  for _, grant in ipairs(grants) do
    mount(grant.mode == "ro" and "--ro-bind-try" or "--bind-try", grant.path)
  end

  vim.list_extend(argv, { "--", command })
  vim.list_extend(argv, args or {})
  return "bwrap", argv
end

--- A TOOL invocation (a task's shell, a search subprocess) under a preset
--- hull: the same floor, network cut unless granted, ONLY the hull's binds
--- punched through. No state dirs, no runtime grants, no sockets — tools are
--- not agents; what a tool can see is exactly what the preset says.
--- @param command string
--- @param args string[]
--- @param hull weave.sandbox.ToolHull
--- @param fs table|nil
--- @return string command
--- @return string[] args
function M.wrap_tool(command, args, hull, fs)
  fs = fs or require("weave.sandbox.fs")
  local home = mountable(hull.home, fs)
  local rw_root, binds = split_root(hull.binds)

  local argv = base_argv(home, rw_root)
  -- Tools do not need the model API, so the network is deniable here in a
  -- way it never was for the agent process.
  if not hull.network then
    argv[#argv + 1] = "--unshare-net"
  end

  local mount = mounter(argv, home, fs)
  for _, b in ipairs(binds) do
    mount(b.mode == "ro" and "--ro-bind" or "--bind", b.path)
  end

  vim.list_extend(argv, { "--", command })
  vim.list_extend(argv, args or {})
  return "bwrap", argv
end

return M
