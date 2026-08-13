-- weave.sandbox.seatbelt: the macOS backend (Seatbelt), driving the same two
-- hulls as weave.sandbox.bwrap through an SBPL profile passed inline with
-- `sandbox-exec -p`.
--
-- ── THIS BACKEND DOES NOT CONFINE READS ─────────────────────────────────────
--
-- Say it first because everything else here is downstream of it. On macOS,
-- mode "on" means the agent cannot WRITE outside its grants and its tools have
-- no network. It can READ the project, and $HOME, and the rest of the disk.
-- That is a real and material gap against the bwrap backend, and weave says so
-- in the permissions window rather than letting "sandbox: on" imply parity.
--
-- It is not a shortcut taken for convenience. Seatbelt is a syscall filter
-- with path predicates and NO mount namespace, so a subtree cannot be replaced
-- with an empty one — it can only be denied. And denying reads on the agent's
-- own cwd, or on any ancestor of it, kills the process before it starts:
-- `getcwd` walks that path to the root, and node dies in bootstrap with
--
--     shell-init: error retrieving current directory: getcwd: cannot access
--     parent directories: Operation not permitted
--     Error: EPERM: process.cwd failed ... uv_cwd
--
-- Two attempts went into narrowing that — first denying `file-read*`, then
-- only `file-read-data` while leaving metadata alone — and both died the same
-- way on a real kernel. bwrap never meets any of it, because its hidden
-- project is an empty TMPFS: the directory still exists, still stats, still
-- lists, and merely contains nothing. Read confinement here would mean
-- enumerating and re-allowing every ancestor of the cwd, and getting that
-- subtly wrong fails QUIETLY, in the direction where weave claims a
-- confinement it is not delivering. An honest "writes and network" beats a
-- read rule nobody can verify.
--
-- The rest of the differences from the Linux backend:
--
--   * /tmp is the host's, not a private one. Scratch space is shared with
--     everything else on the machine.
--   * No pid/ipc/uts isolation, and mach lookups stay open.
--   * A denied WRITE is EPERM, where bwrap gives EROFS against the read-only
--     project mount — so nothing may match on either spelling.
--
-- SBPL evaluates rules IN ORDER with the LAST match winning, which is the
-- same later-mounts-on-top semantics the bwrap grant list already relies on,
-- so both backends consume the hull's ordered grants unchanged.

local M = {}

M.name = "seatbelt"

--- What this backend actually delivers, for the permissions window. bwrap says
--- "files + network"; this one must not, and the difference belongs where the
--- user decides whether to trust the mode — not only in a comment.
M.confines = "writes + network; reads NOT confined"

--- The binary. Formally deprecated by Apple for over a decade and still the
--- only supported way to hand an inline profile to an arbitrary child (nix's
--- own darwin sandbox rides on it), so "deprecated" here means "will warn in
--- the man page", not "will stop working next release".
M.EXEC = "sandbox-exec"

local WRITE = "file-write*"
local RW = "file-read* file-write*"

--- @return boolean
function M.available()
  return vim.fn.has("mac") == 1 and vim.fn.executable(M.EXEC) == 1
end

--- A path as an SBPL string literal, or nil if it cannot be carried safely.
--- The whole profile travels as ONE argv string, so a path is a genuine
--- injection surface: a quote or a backslash would end the literal, a
--- newline would end the s-expression outright and let the rest of the path
--- be read as rules. The first two escape cleanly; control characters have
--- no escape TinyScheme is guaranteed to read back the same way, so such a
--- path is DROPPED (losing a grant fails closed) rather than guessed at.
--- @param path string
--- @return string|nil
function M.quote(path)
  if path:find("%c") then
    return nil
  end
  return '"' .. (path:gsub('[\\"]', "\\%0")) .. '"'
end

--- macOS firmlinks: the paths users and configs write are not the paths the
--- kernel matches rules against. /tmp, /var and /etc are all synthetic links
--- into /private, and a rule naming the short form silently never fires — a
--- deny that never fires is a hole, so this normalisation is load-bearing,
--- not cosmetic. Trailing slashes go too (subpath is prefix-matched at a
--- component boundary and a trailing slash breaks the match).
local FIRMLINKS = { "/tmp", "/var", "/etc" }

--- @param path string
--- @param fs table|nil
--- @return string
function M.normalize(path, fs)
  fs = fs or require("weave.sandbox.fs")
  local p = fs.realpath(path) or path
  p = p:gsub("/+$", "")
  if p == "" then
    return "/"
  end
  for _, link in ipairs(FIRMLINKS) do
    if p == link or vim.startswith(p, link .. "/") then
      return "/private" .. p
    end
  end
  return p
end

--- Writable scratch. bwrap hands out a PRIVATE /tmp; there is no such thing
--- here, so the host's temp dirs are shared in. $TMPDIR is per-user on macOS
--- (under /var/folders) and is what most software actually uses, so it is
--- granted specifically rather than opening /var/folders wholesale.
--- @param fs table|nil
--- @return string[]
function M.scratch_paths(fs)
  local out, seen = {}, {}
  local function add(path)
    local p = M.normalize(path, fs)
    if not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  add("/tmp")
  add("/var/tmp")
  local tmpdir = vim.env.TMPDIR
  if tmpdir and tmpdir ~= "" then
    add(tmpdir)
  end
  return out
end

--- Profile accumulator: `raw` for a literal line, `rule` for a filesystem
--- rule over a path list (dropping paths quote() refuses, and the rule
--- entirely when nothing survives — an empty filter list is a syntax error).
local function builder(fs)
  local lines = {}
  return {
    raw = function(line)
      lines[#lines + 1] = line
    end,
    rule = function(verb, ops, paths)
      local filters = {}
      for _, path in ipairs(paths) do
        local quoted = M.quote(M.normalize(path, fs))
        if quoted then
          filters[#filters + 1] = "(subpath " .. quoted .. ")"
        end
      end
      if #filters > 0 then
        lines[#lines + 1] = ("(%s %s %s)"):format(verb, ops, table.concat(filters, " "))
      end
    end,
    build = function()
      return table.concat(lines, "\n") .. "\n"
    end,
  }
end

--- The shared floor both profiles open with: read everything, write nothing
--- except devices and scratch. `$HOME` is NOT denied — see the header; denying
--- reads on an ancestor of the cwd stops the process from starting at all.
--- @param p table profile builder
--- @param _home string unused: kept in the signature so the day read
---   confinement becomes possible, the subtree to hide is already to hand
--- @param fs table|nil
local function floor(p, _home, fs)
  p.raw("(allow default)")
  p.raw("(deny file-write*)")
  p.rule("allow", WRITE, { "/dev" })
  p.rule("allow", RW, M.scratch_paths(fs))
end

--- The agent hull as SBPL.
--- @param hull weave.sandbox.AgentHull
--- @param fs table|nil
--- @return string
function M.profile_agent(hull, fs)
  local p = builder(fs)
  p.raw("(version 1)")
  p.raw(";; weave agent hull — generated per spawn; last matching rule wins.")
  floor(p, hull.home, fs)
  -- No rule for the project: bwrap mounts an empty read-only tmpfs over it,
  -- and this backend cannot. It is unWRITABLE (the floor's blanket write deny)
  -- but readable, and that is the gap the header is about — the project is
  -- normally the agent's cwd, and denying reads there is what stopped it
  -- booting on a real kernel, twice.
  --
  -- The ordered grants still stack exactly as the bwrap mounts do; here they
  -- only ever ADD write access, since reading was never taken away. A `ro`
  -- grant is therefore a no-op rather than a mistake: it says "readable",
  -- which is already true.
  for _, grant in ipairs(hull.grants or {}) do
    if grant.mode ~= "ro" then
      p.rule("allow", RW, { grant.path })
    end
  end
  return p.build()
end

--- A tool hull as SBPL. What a tool CANNOT do here is write outside its `rw`
--- binds, and reach the network unless the hull grants it. What it can do,
--- unlike under bwrap, is read anything — including $HOME. See the header.
--- @param hull weave.sandbox.ToolHull
--- @param fs table|nil
--- @return string
function M.profile_tool(hull, fs)
  local p = builder(fs)
  p.raw("(version 1)")
  p.raw(";; weave tool hull — generated per spawn; last matching rule wins.")
  floor(p, hull.home, fs)
  if not hull.network then
    -- bwrap cuts the network with --unshare-net, which leaves AF_UNIX alone.
    -- `network*` here also covers unix sockets when they are given a path
    -- filter, so this is marginally stricter — acceptable because no weave
    -- tool talks to the broker (the AGENT does, and the agent hull never
    -- denies the network).
    p.raw("(deny network*)")
  end
  -- `ro` binds are no-ops: reading was never taken away, so a bind that only
  -- promises readability already holds. Only `rw` adds anything.
  for _, b in ipairs(hull.binds or {}) do
    if b.mode ~= "ro" then
      p.rule("allow", RW, { b.path })
    end
  end
  return p.build()
end

--- @param command string
--- @param args string[]
--- @param hull weave.sandbox.AgentHull
--- @param fs table|nil
--- @return string command
--- @return string[] args
function M.wrap_agent(command, args, hull, fs)
  local argv = { "-p", M.profile_agent(hull, fs), command }
  vim.list_extend(argv, args or {})
  return M.EXEC, argv
end

--- @param command string
--- @param args string[]
--- @param hull weave.sandbox.ToolHull
--- @param fs table|nil
--- @return string command
--- @return string[] args
function M.wrap_tool(command, args, hull, fs)
  local argv = { "-p", M.profile_tool(hull, fs), command }
  vim.list_extend(argv, args or {})
  return M.EXEC, argv
end

return M
