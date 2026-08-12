-- weave.sandbox: the bwrap spawn wrapper (design-agent-sandbox.md phase 2).
-- Sandbox.wrap is a pure argv rewrite — given the provider command and a
-- resolved sandbox config it returns the bwrap invocation (or the command
-- untouched for profile "off" / no backend). These specs pin the argv per
-- profile; the final describe actually spawns bwrap when a backend exists.

local Sandbox = require("weave.sandbox")

-- Deterministic wrap opts: fixed home/cwd, no nvim socket, no runtime
-- ro-binds (progpath/clankbox are environment-dependent).
local function opts(extra)
  local o = {
    mode = "on",
    home = "/home/u",
    cwd = "/home/u/proj",
    nvim_socket = false,
    runtime_ro_paths = {},
    attachment_paths = {},
  }
  for k, v in pairs(extra or {}) do
    o[k] = v
  end
  return o
end

--- index of the first occurrence of the consecutive values `seq` in `list`
local function find_seq(list, seq)
  for i = 1, #list - #seq + 1 do
    local hit = true
    for j = 1, #seq do
      if list[i + j - 1] ~= seq[j] then
        hit = false
        break
      end
    end
    if hit then
      return i
    end
  end
  return nil
end

describe("sandbox wrap", function()
  local real_available = Sandbox._available
  local real_exists = Sandbox._exists
  local real_realpath = Sandbox._realpath

  before_each(function()
    Sandbox._available = function()
      return true
    end
    -- the argv specs work on made-up paths; existence and symlink
    -- resolution are their own specs below
    Sandbox._exists = function()
      return true
    end
    Sandbox._realpath = function(path)
      return path
    end
  end)

  after_each(function()
    Sandbox._available = real_available
    Sandbox._exists = real_exists
    Sandbox._realpath = real_realpath
    Sandbox._reset()
  end)

  it("mode off passes the command through untouched", function()
    local cmd, args = Sandbox.wrap("gemini", { "--acp" }, opts({ mode = "off" }))
    assert.equal("gemini", cmd)
    assert.same({ "--acp" }, args)
  end)

  it("mode on: containment floor, project an EMPTY READ-ONLY tmpfs", function()
    local cmd, args = Sandbox.wrap("gemini", { "--acp" }, opts())
    assert.equal("bwrap", cmd)
    assert.truthy(find_seq(args, { "--die-with-parent" }))
    assert.truthy(find_seq(args, { "--unshare-pid" }))
    assert.truthy(find_seq(args, { "--unshare-ipc" }))
    assert.truthy(find_seq(args, { "--ro-bind", "/", "/" }))
    assert.truthy(find_seq(args, { "--dev", "/dev" }))
    assert.truthy(find_seq(args, { "--proc", "/proc" }))
    assert.truthy(find_seq(args, { "--tmpfs", "/tmp" }))
    -- $HOME hidden; the project a read-only EMPTY tmpfs on top (writes must
    -- fail loudly, never land in a void) — and never bound to the host
    local home_at = find_seq(args, { "--tmpfs", "/home/u" })
    local proj_at = find_seq(args, { "--tmpfs", "/home/u/proj", "--remount-ro", "/home/u/proj" })
    assert.truthy(home_at)
    assert.truthy(proj_at)
    assert.is_true(home_at < proj_at)
    assert.is_nil(find_seq(args, { "--bind", "/home/u/proj", "/home/u/proj" }))
    assert.is_nil(find_seq(args, { "--ro-bind", "/home/u/proj", "/home/u/proj" }))
    -- the wrapped command comes last, after the -- separator
    assert.same({ "--", "gemini", "--acp" }, { args[#args - 2], args[#args - 1], args[#args] })
  end)

  it("binds the attachment staging dir READ-ONLY, so a file:// URI resolves", function()
    local _, args = Sandbox.wrap("gemini", {}, opts({ attachment_paths = { "/run/user/1000/weave/attachments/7" } }))
    assert.truthy(find_seq(args, {
      "--ro-bind-try",
      "/run/user/1000/weave/attachments/7",
      "/run/user/1000/weave/attachments/7",
    }))
  end)

  it("binds nothing for attachments when none are staged", function()
    local Attachments = require("weave.attachments")
    local saved = vim.env.XDG_RUNTIME_DIR
    vim.env.XDG_RUNTIME_DIR = vim.fn.tempname()
    Attachments._reset()
    assert.same({}, Sandbox._attachment_paths())
    vim.env.XDG_RUNTIME_DIR = saved
    Attachments._reset()
  end)

  it("state_paths bind rw with -try, ~ expanded against home", function()
    local _, args = Sandbox.wrap("gemini", {}, opts({ state_paths = { "~/.secrets/agent" } }))
    assert.truthy(find_seq(args, { "--bind-try", "/home/u/.secrets/agent", "/home/u/.secrets/agent" }))
  end)

  it("ro_paths and runtime_ro_paths bind ro with -try", function()
    local _, args =
      Sandbox.wrap("gemini", {}, opts({ ro_paths = { "~/notes" }, runtime_ro_paths = { "/opt/clankbox" } }))
    assert.truthy(find_seq(args, { "--ro-bind-try", "/home/u/notes", "/home/u/notes" }))
    assert.truthy(find_seq(args, { "--ro-bind-try", "/opt/clankbox", "/opt/clankbox" }))
  end)

  it("ships state-dir defaults for known provider commands", function()
    local _, args = Sandbox.wrap("claude-code-acp", {}, opts())
    assert.truthy(find_seq(args, { "--bind-try", "/home/u/.claude", "/home/u/.claude" }))
    assert.truthy(find_seq(args, { "--bind-try", "/home/u/.claude.json", "/home/u/.claude.json" }))
    -- defaults key on the basename, so an absolute command still matches
    local _, args2 = Sandbox.wrap("/nix/store/x/bin/codex-acp", {}, opts())
    assert.truthy(find_seq(args2, { "--bind-try", "/home/u/.codex", "/home/u/.codex" }))
  end)

  it("binds the $NVIM socket after the /tmp tmpfs so shims can reach nvim", function()
    local _, args = Sandbox.wrap("gemini", {}, opts({ nvim_socket = "/tmp/nvim.1/0" }))
    local tmp_at = find_seq(args, { "--tmpfs", "/tmp" })
    local sock_at = find_seq(args, { "--bind-try", "/tmp/nvim.1/0", "/tmp/nvim.1/0" })
    assert.truthy(sock_at)
    assert.is_true(tmp_at < sock_at)
  end)

  it("drops grants that do not exist on the host", function()
    -- bwrap would have to CREATE the mountpoint, and under our read-only /
    -- bind that mkdir fails and takes the whole spawn with it. A configured
    -- state dir that does not exist yet is normal, so it must be silent.
    Sandbox._exists = function(path)
      return path ~= "/home/u/.nope"
    end
    local _, args = Sandbox.wrap("gemini", {}, opts({ state_paths = { "~/.nope", "~/.yes" } }))
    assert.is_nil(find_seq(args, { "--bind-try", "/home/u/.nope", "/home/u/.nope" }))
    assert.truthy(find_seq(args, { "--bind-try", "/home/u/.yes", "/home/u/.yes" }))
  end)

  it("resolves symlinked mountpoints outside the tmpfs areas", function()
    -- bwrap refuses to bind over a symlink and cannot mkdir on our
    -- read-only root, so an OUTSIDE destination must be the real path (nix
    -- puts symlinks all over the runtime paths). Paths under the hidden
    -- $HOME stay literal: that tmpfs is writable, and the agent looks for
    -- them where the config said they are.
    Sandbox._realpath = function(path)
      return path == "/opt/link" and "/opt/real" or path
    end
    local _, args = Sandbox.wrap("gemini", {}, opts({ ro_paths = { "/opt/link", "~/link" } }))
    assert.truthy(find_seq(args, { "--ro-bind-try", "/opt/link", "/opt/real" }))
    assert.truthy(find_seq(args, { "--ro-bind-try", "/home/u/link", "/home/u/link" }))
  end)

  it("rejects an unknown mode loudly", function()
    assert.has_error(function()
      Sandbox.wrap("gemini", {}, opts({ mode = "chroot" }))
    end, "unknown sandbox mode")
  end)

  it("degrades to off with a single notify when no backend is available", function()
    Sandbox._available = function()
      return false
    end
    local notified = {}
    local orig = vim.notify
    vim.notify = function(msg, level)
      notified[#notified + 1] = { msg = msg, level = level }
    end
    local ok, err = pcall(function()
      local cmd, args = Sandbox.wrap("gemini", { "--acp" }, opts())
      assert.equal("gemini", cmd)
      assert.same({ "--acp" }, args)
      -- second wrap: still degraded, but silent
      Sandbox.wrap("gemini", { "--acp" }, opts())
    end)
    vim.notify = orig
    assert.is_true(ok, err)
    assert.equal(1, #notified)
    assert.truthy(notified[1].msg:find("sandbox"))
    assert.equal(vim.log.levels.WARN, notified[1].level)
  end)
end)

describe("sandbox resolve", function()
  local Config = require("weave.config")
  local saved

  before_each(function()
    saved = Config.sandbox
  end)

  after_each(function()
    Config.sandbox = saved
  end)

  it("merges the global config with a per-provider override", function()
    Config.sandbox = { mode = "on", state_paths = { "~/.global" }, ro_paths = {} }
    local resolved = Sandbox.resolve({ mode = "off", state_paths = { "~/.mine" } })
    -- scalars: the provider wins
    assert.equal("off", resolved.mode)
    -- lists: concatenated, global first
    assert.same({ "~/.global", "~/.mine" }, resolved.state_paths)
  end)

  it("falls back to the global config when the provider has none", function()
    Config.sandbox = { mode = "on", state_paths = {}, ro_paths = {}, env_allowlist = { "PATH" } }
    local resolved = Sandbox.resolve(nil)
    -- resolves to "on" only when a backend exists; degraded is still honest
    assert.equal(Sandbox._available() and "on" or "off", resolved.mode)
    assert.same({ "PATH" }, resolved.env_allowlist)
  end)

  it("rejects an unknown mode loudly", function()
    Config.sandbox = { mode = "sideways" }
    local ok, err = pcall(Sandbox.resolve, nil)
    assert.is_false(ok)
    assert.truthy(tostring(err):find('`mode` must be "on" or "off"', 1, true))
  end)

  it("rejects the removed v1 `profile` key loudly", function()
    Config.sandbox = { profile = "readonly" }
    local ok, err = pcall(Sandbox.resolve, nil)
    assert.is_false(ok)
    assert.truthy(tostring(err):find("`profile` was removed", 1, true))
  end)
end)

-- Tool sandboxes (v2 phase D): wrap_tool is the same pure argv rewrite for
-- TOOL invocations — the base floor, the network cut unless granted, only
-- the hull's binds. wrap_shell is the task store's seam, resolving the
-- active preset's hull per spawn.
describe("tool sandbox wrap", function()
  local Config = require("weave.config")
  local Permissions = require("weave.permissions")
  local real_available = Sandbox._available
  local real_exists = Sandbox._exists
  local real_realpath = Sandbox._realpath
  local saved_sandbox

  before_each(function()
    saved_sandbox = vim.deepcopy(Config.sandbox)
    Permissions._reset()
    Permissions.set_project_root("/proj/demo")
    Sandbox._available = function()
      return true
    end
    Sandbox._exists = function()
      return true
    end
    Sandbox._realpath = function(path)
      return path
    end
  end)

  after_each(function()
    Config.sandbox = saved_sandbox
    Permissions._reset()
    Sandbox._available = real_available
    Sandbox._exists = real_exists
    Sandbox._realpath = real_realpath
  end)

  it("no backend: the command is untouched", function()
    Sandbox._available = function()
      return false
    end
    local cmd, args = Sandbox.wrap_tool("rg", { "-n", "x" }, { binds = {}, network = false })
    assert.equal("rg", cmd)
    assert.same({ "-n", "x" }, args)
  end)

  it("cuts the network unless the hull grants it", function()
    local _, args = Sandbox.wrap_tool("sh", { "-c", "x" }, { binds = {}, network = false, home = "/home/u" })
    assert.is_not_nil(find_seq(args, { "--unshare-net" }))
    local _, open = Sandbox.wrap_tool("sh", { "-c", "x" }, { binds = {}, network = true, home = "/home/u" })
    assert.is_nil(find_seq(open, { "--unshare-net" }))
  end)

  it("punches exactly the hull's binds through, rw and ro", function()
    local cmd, args = Sandbox.wrap_tool("sh", { "-c", "x" }, {
      home = "/home/u",
      network = false,
      binds = { { path = "/proj/demo", mode = "rw" }, { path = "/data", mode = "ro" } },
    })
    assert.equal("bwrap", cmd)
    assert.is_not_nil(find_seq(args, { "--bind", "/proj/demo", "/proj/demo" }))
    assert.is_not_nil(find_seq(args, { "--ro-bind", "/data", "/data" }))
    -- no agent-shaped grants: no state dirs, no sockets
    assert.is_nil(find_seq(args, { "--bind-try" }))
    assert.same({ "--", "sh", "-c", "x" }, { unpack(args, #args - 3) })
  end)

  it("wrap_shell is inert while sandboxing is off", function()
    Config.sandbox = { mode = "off" }
    local cmd, args = Sandbox.wrap_shell("echo hi")
    assert.equal("sh", cmd)
    assert.same({ "-c", "echo hi" }, args)
  end)

  it("wrap_shell derives the ACTIVE preset's hull per spawn", function()
    Config.sandbox = { mode = "on" }
    -- active preset "normal" has no sandbox section: default hull =
    -- project rw, network off
    local cmd, args = Sandbox.wrap_shell("echo hi")
    assert.equal("bwrap", cmd)
    assert.is_not_nil(find_seq(args, { "--bind", "/proj/demo", "/proj/demo" }))
    assert.is_not_nil(find_seq(args, { "--unshare-net" }))

    -- switching the preset changes the very next spawn, no restart anywhere
    Permissions.save_preset({
      name = "networked",
      rules = { { tool = "*", decision = "allow" } },
      sandbox = { binds = { { path = "/data", mode = "ro" } }, network = true },
    })
    Permissions.set_active("networked")
    local _, next_args = Sandbox.wrap_shell("echo hi")
    assert.is_not_nil(find_seq(next_args, { "--ro-bind", "/data", "/data" }))
    assert.is_nil(find_seq(next_args, { "--bind", "/proj/demo", "/proj/demo" }))
    assert.is_nil(find_seq(next_args, { "--unshare-net" }))
  end)
end)

-- Only when a backend actually exists (Linux + bwrap on PATH): spawn the
-- wrapped argv and verify the mode-on semantics for real.
if Sandbox._available() then
  describe("sandbox integration", function()
    local cwd

    before_each(function()
      cwd = vim.fn.tempname()
      vim.fn.mkdir(cwd .. "/sub", "p")
      vim.fn.writefile({ "hello" }, cwd .. "/f.txt")
    end)

    after_each(function()
      vim.fn.delete(cwd, "rf")
    end)

    local function run(script)
      local cmd, args = Sandbox.wrap("sh", { "-c", script }, {
        mode = "on",
        cwd = cwd,
        nvim_socket = false,
        runtime_ro_paths = {},
      })
      local out = vim.system(vim.list_extend({ cmd }, args), { text = true }):wait()
      return out
    end

    it("mode on: the project is not there at all", function()
      local out = run("ls " .. cwd)
      assert.equal(0, out.code, out.stderr)
      assert.is_nil(out.stdout:find("f%.txt"))
    end)

    it("mode on: a builtin-style write dies on EROFS, never a silent void", function()
      local out = run("touch " .. cwd .. "/w.txt")
      assert.is_true(out.code ~= 0)
      assert.truthy(out.stderr:lower():find("read%-only"))
      assert.equal(0, vim.fn.filereadable(cwd .. "/w.txt"))
    end)

    it("mode on: home is hidden", function()
      local out = run("ls ~")
      assert.equal(0, out.code, out.stderr)
      assert.is_nil(out.stdout:find("%S"))
    end)

    local function run_tool(hull, script)
      local cmd, args = Sandbox.wrap_tool("sh", { "-c", script }, hull)
      return vim.system(vim.list_extend({ cmd }, args), { text = true }):wait()
    end

    it("tool hull: bound dir writable, everything else the ro floor", function()
      local out = run_tool(
        { binds = { { path = cwd, mode = "rw" } }, network = false },
        "cat " .. cwd .. "/f.txt && touch " .. cwd .. "/t.txt && ls ~"
      )
      assert.equal(0, out.code, out.stderr)
      assert.truthy(out.stdout:find("hello"))
      assert.equal(1, vim.fn.filereadable(cwd .. "/t.txt"))
      -- home is an empty tmpfs
      assert.is_nil(out.stdout:find("%S", out.stdout:find("hello") + 6))
    end)

    it("tool hull: network off means a lonely loopback", function()
      -- /proc is freshly mounted (--proc), so /proc/net/dev reflects the
      -- process's OWN netns — unlike /sys, which rides the host ro bind
      local out = run_tool({ binds = {}, network = false }, "cat /proc/net/dev")
      assert.equal(0, out.code, out.stderr)
      assert.truthy(out.stdout:find("lo:"))
      local host = vim.system({ "cat", "/proc/net/dev" }, { text = true }):wait()
      local function ifaces(s)
        local n = 0
        for _ in s:gmatch("%f[%w][%w%d]+:") do
          n = n + 1
        end
        return n
      end
      -- the host has more interfaces than the sandbox's lonely lo (if it
      -- does not, this machine cannot distinguish the two — skip honestly)
      if ifaces(host.stdout) > 1 then
        assert.equal(1, ifaces(out.stdout))
      end
    end)
  end)
end
