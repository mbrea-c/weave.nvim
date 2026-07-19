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
    profile = "workspace",
    home = "/home/u",
    cwd = "/home/u/proj",
    nvim_socket = false,
    runtime_ro_paths = {},
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

  it("profile off passes the command through untouched", function()
    local cmd, args = Sandbox.wrap("gemini", { "--acp" }, opts({ profile = "off" }))
    assert.equal("gemini", cmd)
    assert.same({ "--acp" }, args)
  end)

  it("workspace: bwrap argv with containment flags and the project bound rw", function()
    local cmd, args = Sandbox.wrap("gemini", { "--acp" }, opts())
    assert.equal("bwrap", cmd)
    assert.truthy(find_seq(args, { "--die-with-parent" }))
    assert.truthy(find_seq(args, { "--unshare-pid" }))
    assert.truthy(find_seq(args, { "--unshare-ipc" }))
    assert.truthy(find_seq(args, { "--ro-bind", "/", "/" }))
    assert.truthy(find_seq(args, { "--dev", "/dev" }))
    assert.truthy(find_seq(args, { "--proc", "/proc" }))
    assert.truthy(find_seq(args, { "--tmpfs", "/tmp" }))
    -- $HOME hidden, project rw on top (order matters: the bind must follow)
    local home_at = find_seq(args, { "--tmpfs", "/home/u" })
    local proj_at = find_seq(args, { "--bind", "/home/u/proj", "/home/u/proj" })
    assert.truthy(home_at)
    assert.truthy(proj_at)
    assert.is_true(home_at < proj_at)
    -- the wrapped command comes last, after the -- separator
    assert.same({ "--", "gemini", "--acp" }, { args[#args - 2], args[#args - 1], args[#args] })
  end)

  it("readonly: project bound ro, never rw", function()
    local _, args = Sandbox.wrap("gemini", {}, opts({ profile = "readonly" }))
    assert.truthy(find_seq(args, { "--ro-bind", "/home/u/proj", "/home/u/proj" }))
    assert.is_nil(find_seq(args, { "--bind", "/home/u/proj", "/home/u/proj" }))
  end)

  it("blackbox: project hidden under a tmpfs", function()
    local _, args = Sandbox.wrap("gemini", {}, opts({ profile = "blackbox" }))
    assert.truthy(find_seq(args, { "--tmpfs", "/home/u/proj" }))
    assert.is_nil(find_seq(args, { "--bind", "/home/u/proj", "/home/u/proj" }))
    assert.is_nil(find_seq(args, { "--ro-bind", "/home/u/proj", "/home/u/proj" }))
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

  it("rejects an unknown profile loudly", function()
    assert.has_error(function()
      Sandbox.wrap("gemini", {}, opts({ profile = "chroot" }))
    end, "unknown sandbox profile")
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
    Config.sandbox = { profile = "readonly", state_paths = { "~/.global" }, ro_paths = {} }
    local resolved = Sandbox.resolve({ profile = "off", state_paths = { "~/.mine" } })
    -- scalars: the provider wins
    assert.equal("off", resolved.profile)
    -- lists: concatenated, global first
    assert.same({ "~/.global", "~/.mine" }, resolved.state_paths)
  end)

  it("falls back to the global config when the provider has none", function()
    Config.sandbox = { profile = "workspace", state_paths = {}, ro_paths = {}, env_allowlist = { "PATH" } }
    local resolved = Sandbox.resolve(nil)
    assert.equal("workspace", resolved.profile)
    assert.same({ "PATH" }, resolved.env_allowlist)
  end)
end)

-- Only when a backend actually exists (Linux + bwrap on PATH): spawn the
-- wrapped argv and verify the profile semantics for real.
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

    local function run(profile, script)
      local cmd, args = Sandbox.wrap("sh", { "-c", script }, {
        profile = profile,
        cwd = cwd,
        nvim_socket = false,
        runtime_ro_paths = {},
      })
      local out = vim.system(vim.list_extend({ cmd }, args), { text = true }):wait()
      return out
    end

    it("workspace: project writable, home hidden", function()
      local out = run("workspace", "cat " .. cwd .. "/f.txt && touch " .. cwd .. "/w.txt && ls ~")
      assert.equal(0, out.code, out.stderr)
      assert.truthy(out.stdout:find("hello"))
      -- the write really landed (same path, host side)
      assert.equal(1, vim.fn.filereadable(cwd .. "/w.txt"))
      -- home is an empty tmpfs (ls output after "hello" is nothing)
      assert.is_nil(out.stdout:find("%S", out.stdout:find("hello") + 6))
    end)

    it("readonly: reads work, writes fail", function()
      local ok_read = run("readonly", "cat " .. cwd .. "/f.txt")
      assert.equal(0, ok_read.code, ok_read.stderr)
      local write = run("readonly", "touch " .. cwd .. "/w.txt")
      assert.is_true(write.code ~= 0)
      assert.truthy(write.stderr:lower():find("read%-only"))
      assert.equal(0, vim.fn.filereadable(cwd .. "/w.txt"))
    end)

    it("blackbox: the project is not there at all", function()
      local out = run("blackbox", "ls " .. cwd)
      assert.equal(0, out.code, out.stderr)
      assert.is_nil(out.stdout:find("f%.txt"))
    end)
  end)
end
