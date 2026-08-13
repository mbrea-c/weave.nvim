-- weave.sandbox.seatbelt: the macOS backend (Seatbelt), driving the same two
-- hulls as weave.sandbox.bwrap through an SBPL profile passed inline with
-- `sandbox-exec -p`.
--
-- Seatbelt is a syscall filter with path predicates, NOT a mount namespace,
-- and that single difference is where every deviation from the Linux backend
-- comes from:
--
--   * Nothing can be HIDDEN, only denied. Where bwrap shows the agent an
--     empty read-only tmpfs over the project and $HOME, this backend returns
--     EPERM. Better for the read case — an empty directory reads as fact,
--     which is exactly the failure the first-prompt steering note exists to
--     pre-empt, while a denial is self-describing — but a different failure
--     SHAPE, so nothing may match on EROFS or on "the directory was empty".
--     It is worse for the write case: an agent that unconditionally creates
--     ~/.something on startup gets a hard error here where bwrap let it
--     write into the throwaway tmpfs. The state-dir grants cover the
--     providers weave ships defaults for; anything else goes in state_paths.
--   * /tmp is the host's, not a private one. Scratch space is shared with
--     everything else on the machine.
--   * No pid/ipc/uts isolation, and mach lookups stay open. This confines
--     the filesystem and the network, not the process — weaker than bwrap,
--     and worth saying out loud rather than letting "sandbox: on" imply
--     parity.
--
-- SBPL evaluates rules IN ORDER with the LAST match winning, which is the
-- same later-mounts-on-top semantics the bwrap grant list already relies on,
-- so both backends consume the hull's ordered grants unchanged.
--
-- Not verified against a real macOS kernel — the profile builders are pure
-- string functions and specced exhaustively as such, but whether the kernel
-- enforces what they say has to be checked on a Mac (see DEVELOPMENT.md).

local M = {}

M.name = "seatbelt"

--- The binary. Formally deprecated by Apple for over a decade and still the
--- only supported way to hand an inline profile to an arbitrary child (nix's
--- own darwin sandbox rides on it), so "deprecated" here means "will warn in
--- the man page", not "will stop working next release".
M.EXEC = "sandbox-exec"

local READ = "file-read*"
local WRITE = "file-write*"
local RW = "file-read* file-write*"

--- What "hide this subtree" means here, and it is NOT `file-read*`.
---
--- A process cannot BOOT if it cannot stat its own working directory: getcwd
--- walks the path to the root, and node dies in bootstrap on EPERM from uv_cwd
--- before a line of agent code runs (`shell-init: error retrieving current
--- directory`, then `process.cwd failed`). bwrap never meets this, because its
--- hidden project is an empty TMPFS — the directory still exists and stats
--- fine, it simply contains nothing. Denying existence is a luxury only a
--- mount namespace has.
---
--- So this backend denies CONTENT and leaves metadata alone: `file-read-data`
--- covers both reading a file and listing a directory, which is the whole of
--- what "hidden" has to mean, while `file-read-metadata` keeps stat() working
--- so paths still resolve. The cost is that the agent can learn whether a path
--- it already knows about exists — it cannot enumerate, and it cannot read.
local DENY_CONTENT = "file-read-data file-write*"

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

--- The shared floor both profiles open with: read everything (bwrap's
--- `--ro-bind / /` is exactly that — the confinement is on WRITES and on the
--- two hidden subtrees, not on reads of the system), write nothing except
--- devices and scratch, then $HOME denied.
local function floor(p, home, fs)
  p.raw("(allow default)")
  p.raw("(deny file-write*)")
  p.rule("allow", WRITE, { "/dev" })
  p.rule("allow", RW, M.scratch_paths(fs))
  p.rule("deny", DENY_CONTENT, { home })
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
  -- The project. bwrap mounts an empty read-only tmpfs here; the closest this
  -- backend gets is denying its CONTENT, so the agent is told "no" instead of
  -- being shown "nothing". Metadata stays readable — this is usually the
  -- agent's cwd, and a process that cannot stat its own cwd never starts (see
  -- DENY_CONTENT).
  p.rule("deny", DENY_CONTENT, { hull.cwd })
  -- ...then the ordered grants punched back through, exactly as the bwrap
  -- mounts stack on each other.
  for _, grant in ipairs(hull.grants or {}) do
    p.rule("allow", grant.mode == "ro" and READ or RW, { grant.path })
  end
  return p.build()
end

--- A tool hull as SBPL. Note what is NOT here: the project is not denied
--- unless it happens to live under $HOME. That matches bwrap, where a tool
--- reads the project through the read-only root bind whether or not the hull
--- binds it — a hull's `rw` bind is what grants WRITES, and `ro` is what
--- re-exposes something the $HOME denial would otherwise have taken.
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
  for _, b in ipairs(hull.binds or {}) do
    p.rule("allow", b.mode == "ro" and READ or RW, { b.path })
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
