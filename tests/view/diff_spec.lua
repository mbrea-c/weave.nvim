-- The diff component (roadmap R6): an old/new pair rendered through fibrous's
-- ui.diff — syntax highlighting under the Diff* line fills, a sign column,
-- opt-in real line numbers. Store-agnostic (props in, vnodes out); the
-- ToolCallEntry spec pins the transcript-side wiring.

local mount = require("fibrous.inline.mount")
local diff = require("weave.view.diff")

local function trimmed(bufnr)
  local out = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    out[i] = (l:gsub("%s+$", ""))
  end
  return out
end

local function marks_with(bufnr, hl)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    if m[4].hl_group == hl then
      out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col }
    end
  end
  return out
end

local function mount_diff(props)
  return mount.floating(diff.Diff, props, { width = 50, height = 16 })
end

describe("view.diff", function()
  it("renders an interleaved hunk: context plain, -/+ rows filled", function()
    local handle = mount_diff({
      old = { "keep", "drop me", "keep too" },
      new = { "keep", "add me", "keep too" },
    })
    local lines = trimmed(handle.bufnr)
    assert.equal("  keep", lines[1])
    assert.equal("- drop me", lines[2])
    assert.equal("+ add me", lines[3])
    assert.equal("  keep too", lines[4])

    -- the changed rows carry the Diff* fills (no syntax here: no path/lang)
    assert.truthy(#marks_with(handle.bufnr, "DiffDelete") >= 1)
    assert.truthy(#marks_with(handle.bufnr, "DiffAdd") >= 1)
    handle.unmount()
  end)

  it("infers the language from `path` and paints syntax spans", function()
    local handle = mount_diff({
      old = { "-- note", "local a = 1" },
      new = { "-- note", "local a = 2" },
      path = "a.lua",
    })
    -- the context line's syntax fg paints over no fill, so its treesitter
    -- group survives verbatim — proof the sides went through the highlighter
    local found = false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(handle.bufnr, -1, 0, -1, { details = true })) do
      local hl = m[4].hl_group
      if type(hl) == "string" and hl:find("^@comment") then
        found = true
      end
    end
    assert.is_true(found, "treesitter comment group on the context line")
    handle.unmount()
  end)

  it("keeps line numbers off by default (fragments), on by request", function()
    local fragment = mount_diff({ old = { "a", "x", "b" }, new = { "a", "y", "b" } })
    assert.equal("  a", trimmed(fragment.bufnr)[1])
    fragment.unmount()

    local numbered = mount_diff({
      old = { "a", "x", "b" },
      new = { "a", "y", "b" },
      line_numbers = true,
      start_line = 40,
    })
    assert.same({
      "40 40   a",
      "41    - x",
      "   41 + y",
      "42 42   b",
    }, vim.list_slice(trimmed(numbered.bufnr), 1, 4))
    numbered.unmount()
  end)

  it("indent shifts every row; max_lines truncates with a marker", function()
    local old, new = {}, {}
    for i = 1, 12 do
      old[i] = "line " .. i
      new[i] = "line " .. i .. " changed"
    end
    local handle = mount_diff({ old = old, new = new, indent = "  ", max_lines = 5 })
    local lines = trimmed(handle.bufnr)
    assert.equal("  - line 1", lines[1])
    assert.equal("  - line 5", lines[5])
    assert.truthy(lines[6]:find("truncated"))
    assert.equal("", lines[7])
    handle.unmount()
  end)

  it("identical sides say so instead of rendering nothing", function()
    local handle = mount_diff({ old = { "same" }, new = { "same" } })
    assert.truthy(trimmed(handle.bufnr)[1]:find("no changes", 1, true))
    handle.unmount()
  end)
end)
