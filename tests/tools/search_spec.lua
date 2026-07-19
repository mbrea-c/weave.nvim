-- glob/grep (design-search-tools.md). The pure halves — argv construction,
-- --json parsing, rendering — are tested without a subprocess; the end of the
-- file drives real rg over a temp tree, and skips when rg is absent.

local Search = require("weave.tools.search")
local Config = require("weave.config")

local function has(argv, ...)
  local want = { ... }
  for i = 1, #argv - #want + 1 do
    local hit = true
    for j = 1, #want do
      if argv[i + j - 1] ~= want[j] then
        hit = false
        break
      end
    end
    if hit then
      return true
    end
  end
  return false
end

describe("Search.rg_path", function()
  after_each(function()
    Config.tools = Config.tools or {}
    Config.tools.ripgrep_path = nil
  end)

  it("prefers the configured path over PATH lookup", function()
    Config.tools = Config.tools or {}
    Config.tools.ripgrep_path = "/nix/store/whatever/bin/rg"
    assert.equal("/nix/store/whatever/bin/rg", Search.rg_path())
  end)
end)

describe("Search.grep_argv", function()
  it("defaults to files_with_matches over the given root", function()
    local argv = Search.grep_argv({ pattern = "TODO" }, { rg = "rg", root = "/proj" })
    assert.equal("rg", argv[1])
    assert.is_true(has(argv, "--files-with-matches"))
    assert.is_true(has(argv, "-e", "TODO"))
    assert.equal("/proj", argv[#argv])
  end)

  it("uses --json for content mode and caps column width", function()
    local argv = Search.grep_argv({ pattern = "x", output_mode = "content" }, { rg = "rg", root = "/proj" })
    assert.is_true(has(argv, "--json"))
    assert.is_true(has(argv, "--max-columns=500"))
    assert.is_true(has(argv, "--max-columns-preview"))
  end)

  it("uses --count-matches for count mode", function()
    local argv = Search.grep_argv({ pattern = "x", output_mode = "count" }, { rg = "rg", root = "/proj" })
    assert.is_true(has(argv, "--count-matches"))
  end)

  it("passes the pattern with -e so a leading dash is not a flag", function()
    local argv = Search.grep_argv({ pattern = "-foo" }, { rg = "rg", root = "/proj" })
    assert.is_true(has(argv, "-e", "-foo"))
  end)

  it("maps the flag-shaped parity options", function()
    local argv = Search.grep_argv({
      pattern = "x",
      output_mode = "content",
      ["-i"] = true,
      ["-A"] = 2,
      ["-B"] = 3,
      glob = "*.lua",
      type = "lua",
      multiline = true,
      hidden = true,
      no_ignore = true,
    }, { rg = "rg", root = "/proj" })

    assert.is_true(has(argv, "--ignore-case"))
    assert.is_true(has(argv, "--after-context", "2"))
    assert.is_true(has(argv, "--before-context", "3"))
    assert.is_true(has(argv, "--glob", "*.lua"))
    assert.is_true(has(argv, "--type", "lua"))
    assert.is_true(has(argv, "--multiline"))
    assert.is_true(has(argv, "--multiline-dotall"))
    assert.is_true(has(argv, "--hidden"))
    assert.is_true(has(argv, "--no-ignore"))
  end)

  it("accepts the readable aliases, with the flag form winning", function()
    local aliased = Search.grep_argv(
      { pattern = "x", output_mode = "content", case_insensitive = true, after = 4, context = 1 },
      { rg = "rg", root = "/proj" }
    )
    assert.is_true(has(aliased, "--ignore-case"))
    assert.is_true(has(aliased, "--after-context", "4"))
    assert.is_true(has(aliased, "--context", "1"))

    local both = Search.grep_argv({ pattern = "x", output_mode = "content", ["-A"] = 9, after = 4 }, {
      rg = "rg",
      root = "/proj",
    })
    assert.is_true(has(both, "--after-context", "9"))
  end)

  it("ignores context flags outside content mode", function()
    local argv = Search.grep_argv({ pattern = "x", ["-A"] = 2 }, { rg = "rg", root = "/proj" })
    assert.is_false(has(argv, "--after-context", "2"))
  end)

  it("searches stdin as --json regardless of output mode", function()
    local argv = Search.grep_argv({ pattern = "x", output_mode = "count" }, { rg = "rg", stdin = true })
    assert.is_true(has(argv, "--json"))
    assert.is_false(has(argv, "--count-matches"))
    assert.equal("-", argv[#argv])
  end)
end)

describe("Search.glob_argv", function()
  it("lists files under the root filtered by the glob", function()
    local argv = Search.glob_argv({ pattern = "**/*.lua" }, { rg = "rg", root = "/proj" })
    assert.is_true(has(argv, "--files"))
    assert.is_true(has(argv, "--glob", "**/*.lua"))
    assert.equal("/proj", argv[#argv])
  end)
end)

describe("Search.parse_json", function()
  local out = table.concat({
    [[{"type":"begin","data":{"path":{"text":"/proj/a.lua"}}}]],
    [[{"type":"context","data":{"path":{"text":"/proj/a.lua"},"line_number":6,"lines":{"text":"before\n"}}}]],
    [[{"type":"match","data":{"path":{"text":"/proj/a.lua"},"line_number":7,"lines":{"text":"local url = \"http://x\"\n"},"submatches":[{"start":0,"end":3}]}}]],
    [[{"type":"end","data":{"path":{"text":"/proj/a.lua"}}}]],
    [[{"type":"begin","data":{"path":{"text":"/proj/b.lua"}}}]],
    [[{"type":"match","data":{"path":{"text":"/proj/b.lua"},"line_number":2,"lines":{"text":"two\n"}}}]],
    [[{"type":"end","data":{"path":{"text":"/proj/b.lua"}}}]],
    [[{"type":"summary","data":{}}]],
    "",
  }, "\n")

  it("groups events by path in output order", function()
    local recs = Search.parse_json(out)
    assert.equal(2, #recs)
    assert.equal("/proj/a.lua", recs[1].path)
    assert.equal("/proj/b.lua", recs[2].path)
  end)

  it("keeps context lines distinguishable from matches", function()
    local recs = Search.parse_json(out)
    assert.same({ n = 6, text = "before", kind = "context" }, recs[1].lines[1])
    assert.equal("match", recs[1].lines[2].kind)
    assert.equal(1, recs[1].count)
  end)

  it("does not mangle content containing the separator", function()
    local recs = Search.parse_json(out)
    assert.equal([[local url = "http://x"]], recs[1].lines[2].text)
  end)
end)

describe("Search.render", function()
  local recs = {
    {
      path = "/p/a.lua",
      count = 2,
      lines = {
        { n = 3, text = "hit one", kind = "match" },
        { n = 4, text = "ctx", kind = "context" },
      },
    },
    { path = "/p/b.lua", count = 1, lines = { { n = 9, text = "hit two", kind = "match" } } },
  }

  it("renders path:line:content for matches and path-line-content for context", function()
    local text = Search.render(recs, { output_mode = "content", ["-n"] = true })
    assert.equal("/p/a.lua:3:hit one\n/p/a.lua-4-ctx\n/p/b.lua:9:hit two", text)
  end)

  it("drops line numbers without -n", function()
    local text = Search.render(recs, { output_mode = "content" })
    assert.equal("/p/a.lua:hit one\n/p/a.lua-ctx\n/p/b.lua:hit two", text)
  end)

  it("renders a bare path list for files_with_matches", function()
    assert.equal("/p/a.lua\n/p/b.lua", Search.render(recs, { output_mode = "files_with_matches" }))
  end)

  it("renders path:count for count mode", function()
    assert.equal("/p/a.lua:2\n/p/b.lua:1", Search.render(recs, { output_mode = "count" }))
  end)

  it("says so when it truncates", function()
    local text = Search.render(recs, { output_mode = "content", head_limit = 1 })
    assert.equal("/p/a.lua:hit one", (text:gsub("\n.*", "")))
    assert.is_not_nil(text:match("truncated"))
  end)

  it("reports no matches rather than an empty string", function()
    assert.equal("(no matches)", Search.render({}, { output_mode = "content" }))
  end)
end)

---------------------------------------------------------------------------
-- Integration: a real rg over a real tree.
---------------------------------------------------------------------------

local rg = vim.fn.exepath("rg")

local function tree()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/sub", "p")
  local function put(rel, text)
    local f = assert(io.open(root .. "/" .. rel, "w"))
    f:write(text)
    f:close()
  end
  put("a.lua", "local x = 1\nlocal needle = 2\n")
  put("sub/b.lua", "needle\nneedle again\n")
  put("c.txt", "needle in text\n")
  return root
end

local function sync(def, args)
  local result
  def.handler(args, function(r)
    result = r
  end)
  vim.wait(10000, function()
    return result ~= nil
  end, 10)
  return result
end

if rg == "" then
  describe("Search integration", function()
    it("SKIPPED: ripgrep is not installed", function()
      assert.is_true(true)
    end)
  end)
else
  describe("Search integration", function()
    local root

    before_each(function()
      root = tree()
      Config.tools = Config.tools or {}
      Config.tools.ripgrep_path = nil
    end)

    after_each(function()
      vim.fn.delete(root, "rf")
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) then
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
    end)

    it("globs by pattern", function()
      local out = sync(Search.glob, { pattern = "**/*.lua", path = root })
      assert.is_not_nil(out:match("a%.lua"))
      assert.is_not_nil(out:match("b%.lua"))
      assert.is_nil(out:match("c%.txt"))
    end)

    it("greps files_with_matches by default", function()
      local out = sync(Search.grep, { pattern = "needle", path = root })
      assert.is_not_nil(out:match("a%.lua"))
      assert.is_not_nil(out:match("c%.txt"))
      assert.is_nil(out:match(":")) -- bare paths, no line/content
    end)

    it("greps content with line numbers", function()
      local out = sync(Search.grep, { pattern = "needle", path = root, output_mode = "content", ["-n"] = true })
      assert.is_not_nil(out:match("a%.lua:2:local needle = 2"))
    end)

    it("counts matches per file", function()
      local out = sync(Search.grep, { pattern = "needle", path = root, output_mode = "count", glob = "b.lua" })
      assert.is_not_nil(out:match("b%.lua:2"))
    end)

    it("honours the glob filter", function()
      local out = sync(Search.grep, { pattern = "needle", path = root, glob = "*.txt" })
      assert.is_not_nil(out:match("c%.txt"))
      assert.is_nil(out:match("a%.lua"))
    end)

    it("searches the LIVE buffer: an unsaved edit adds and removes matches", function()
      local bufnr = vim.fn.bufadd(root .. "/a.lua")
      vim.fn.bufload(bufnr)
      -- drop the one disk match, add one the disk does not have
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = 1", "-- gone", "needle needle" })
      vim.bo[bufnr].modified = true

      local out = sync(Search.grep, { pattern = "needle", path = root, output_mode = "count", glob = "a.lua" })
      assert.is_not_nil(out:match("a%.lua:2"))

      local content =
        sync(Search.grep, { pattern = "needle", path = root, output_mode = "content", ["-n"] = true, glob = "a.lua" })
      assert.is_not_nil(content:match("a%.lua:3:needle needle"))
      assert.is_nil(content:match("local needle = 2"))
    end)

    it("buffers = off ignores unsaved state", function()
      local bufnr = vim.fn.bufadd(root .. "/a.lua")
      vim.fn.bufload(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "nothing here" })
      vim.bo[bufnr].modified = true

      local out =
        sync(Search.grep, { pattern = "needle", path = root, output_mode = "content", glob = "a.lua", buffers = "off" })
      assert.is_not_nil(out:match("local needle = 2"))
    end)

    it("reports no matches instead of an error", function()
      local out = sync(Search.grep, { pattern = "zzzznope", path = root })
      assert.equal("(no matches)", out)
    end)
  end)
end
