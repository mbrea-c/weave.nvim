-- weave's MCP fs tools (design-agent-sandbox.md, phase 0): read/write/edit
-- with builtin-agent-tool parity, routed through the editor. Open buffers win
-- over disk (reads serve live state, writes land in the buffer and save), and
-- buffers with no backing file are first-class targets via `buffer` — which
-- plain path-based tools cannot reach at all.

local Fs = require("weave.tools.fs")

local created_bufs = {}
local tmp_root

local function tmpfile(rel, content)
  local path = tmp_root .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
  return path
end

local function slurp(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

--- Open `path` into a real loaded buffer, tracked for cleanup.
local function open_buf(path)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  created_bufs[#created_bufs + 1] = bufnr
  return bufnr
end

--- A [No Name] scratch buffer holding `lines`.
local function scratch_buf(lines)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  created_bufs[#created_bufs + 1] = bufnr
  return bufnr
end

local function call(name, args)
  return Fs[name].handler(args)
end

describe("tools.fs", function()
  before_each(function()
    tmp_root = vim.fn.tempname()
    vim.fn.mkdir(tmp_root, "p")
  end)

  after_each(function()
    for _, bufnr in ipairs(created_bufs) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    created_bufs = {}
    vim.fn.delete(tmp_root, "rf")
  end)

  describe("read", function()
    it("reads a disk file with line numbers", function()
      local path = tmpfile("plain.txt", "alpha\nbeta\n")
      local out = call("read", { path = path })
      assert.truthy(out:find("1\talpha", 1, true))
      assert.truthy(out:find("2\tbeta", 1, true))
    end)

    it("serves live buffer state over disk when the file is open", function()
      local path = tmpfile("open.txt", "stale disk line\n")
      local bufnr = open_buf(path)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "live edited line" })
      local out = call("read", { path = path })
      assert.truthy(out:find("live edited line", 1, true))
      assert.falsy(out:find("stale disk line", 1, true))
      -- the unsaved state is flagged so the agent knows disk differs
      assert.truthy(out:find("unsaved", 1, true))
    end)

    it("honors offset/limit and reports truncation", function()
      local lines = {}
      for i = 1, 10 do
        lines[i] = "l" .. i
      end
      local path = tmpfile("long.txt", table.concat(lines, "\n") .. "\n")
      local out = call("read", { path = path, offset = 3, limit = 2 })
      assert.truthy(out:find("3\tl3", 1, true))
      assert.truthy(out:find("4\tl4", 1, true))
      assert.falsy(out:find("5\tl5", 1, true))
      assert.truthy(out:find("of 10", 1, true))
      assert.truthy(out:find("offset=5", 1, true))
    end)

    it("reads a buffer with no backing file by id", function()
      local bufnr = scratch_buf({ "scratch one", "scratch two" })
      local out = call("read", { buffer = bufnr })
      assert.truthy(out:find("1\tscratch one", 1, true))
      assert.truthy(out:find("no backing file", 1, true))
    end)

    it("resolves a buffer by name suffix", function()
      local path = tmpfile("sub/target.txt", "found me\n")
      open_buf(path)
      local out = call("read", { buffer = "sub/target.txt" })
      assert.truthy(out:find("found me", 1, true))
    end)

    it("errors on an ambiguous buffer name", function()
      open_buf(tmpfile("a/same.txt", "a\n"))
      open_buf(tmpfile("b/same.txt", "b\n"))
      assert.has_error(function()
        call("read", { buffer = "same.txt" })
      end, "ambiguous")
    end)

    it("errors on a missing file", function()
      assert.has_error(function()
        call("read", { path = tmp_root .. "/absent.txt" })
      end, "file not found")
    end)

    it("errors without a target", function()
      assert.has_error(function()
        call("read", {})
      end, "path")
    end)
  end)

  -- Agents carry a strong prior toward `file_path` (Claude's builtin tools) and
  -- `filePath` (OpenCode sends camelCase over ACP -- see acp_client.lua). Our
  -- schema says `path`; accepting the aliases turns a guaranteed retry into a
  -- working call, at the cost of three lines.
  describe("path aliases", function()
    it("accepts file_path and filePath as targets", function()
      local path = tmpfile("aliased.txt", "alpha\n")
      assert.truthy(call("read", { file_path = path }):find("alpha", 1, true))
      assert.truthy(call("read", { filePath = path }):find("alpha", 1, true))
    end)

    it("aliases work for write and edit, not just read", function()
      local path = tmpfile("aliased_rw.txt", "alpha\n")
      call("write", { file_path = path, content = "beta\n" })
      assert.equal("beta\n", slurp(path))
      call("edit", { filePath = path, old_string = "beta", new_string = "gamma" })
      assert.equal("gamma\n", slurp(path))
    end)

    it("`path` still wins when both are given", function()
      local real = tmpfile("real.txt", "real\n")
      local decoy = tmpfile("decoy.txt", "decoy\n")
      assert.truthy(call("read", { path = real, file_path = decoy }):find("real", 1, true))
    end)
  end)

  -- The announced schema has to describe what resolve() actually enforces:
  -- exactly one of path/buffer, and `buffer` really is number-or-string.
  describe("inputSchema honesty", function()
    it("advertises the path/buffer requirement instead of leaving it implicit", function()
      for _, name in ipairs({ "read", "write", "edit" }) do
        local props = Fs[name].inputSchema.properties
        assert.truthy(props.path, name .. " must advertise path")
        assert.truthy(Fs[name].inputSchema.anyOf, name .. " must state that a target is required")
      end
    end)

    it("gives `buffer` an explicit union type", function()
      assert.same({ "integer", "string" }, Fs.read.inputSchema.properties.buffer.type)
    end)
  end)

  describe("write", function()
    it("creates a new file, parent dirs included", function()
      local path = tmp_root .. "/a/b/new.txt"
      local out = call("write", { path = path, content = "one\ntwo" })
      assert.equal("one\ntwo", slurp(path))
      assert.truthy(out:find("2 lines", 1, true))
    end)

    it("routes through an open buffer and saves to disk", function()
      local path = tmpfile("routed.txt", "before\n")
      local bufnr = open_buf(path)
      call("write", { path = path, content = "after" })
      assert.same({ "after" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.truthy(slurp(path):find("after", 1, true))
      assert.is_false(vim.bo[bufnr].modified)
    end)

    it("writes a fileless buffer without touching disk", function()
      local bufnr = scratch_buf({ "old" })
      local out = call("write", { buffer = bufnr, content = "x\ny" })
      assert.same({ "x", "y" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.truthy(out:find("buffer", 1, true))
    end)
  end)

  describe("edit", function()
    it("replaces a unique occurrence on disk", function()
      local path = tmpfile("code.lua", "local function a()\n  return 1\nend\n")
      local out = call("edit", { path = path, old_string = "return 1", new_string = "return 2" })
      assert.truthy(slurp(path):find("return 2", 1, true))
      assert.truthy(out:find("1 occurrence", 1, true))
    end)

    it("edits through the open buffer, using live (unsaved) text", function()
      local path = tmpfile("live.lua", "disk only\n")
      local bufnr = open_buf(path)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "live marker" })
      call("edit", { path = path, old_string = "marker", new_string = "replaced" })
      assert.same({ "live replaced" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.truthy(slurp(path):find("live replaced", 1, true))
      assert.is_false(vim.bo[bufnr].modified)
    end)

    it("errors when old_string is absent", function()
      local path = tmpfile("miss.txt", "nothing here\n")
      assert.has_error(function()
        call("edit", { path = path, old_string = "ghost", new_string = "x" })
      end, "not found")
    end)

    it("errors when old_string is not unique", function()
      local path = tmpfile("dup.txt", "x\nx\n")
      assert.has_error(function()
        call("edit", { path = path, old_string = "x", new_string = "y" })
      end, "occurs 2 times")
    end)

    it("replace_all replaces every occurrence", function()
      local path = tmpfile("all.txt", "x\nx\n")
      local out = call("edit", { path = path, old_string = "x", new_string = "y", replace_all = true })
      assert.equal("y\ny\n", slurp(path))
      assert.truthy(out:find("2 occurrence", 1, true))
    end)
  end)
end)
