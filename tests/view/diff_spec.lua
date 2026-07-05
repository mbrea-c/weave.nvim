-- The diff component (roadmap R6): an old/new pair rendered as a properly
-- interleaved unified diff — reusable and store-agnostic like view.markdown.
-- This extracts the transcript's inline append_diff_preview into a component;
-- the ToolCallEntry spec pins the transcript-side wiring.

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
  it("renders an interleaved hunk: context plain, -/+ highlighted", function()
    local handle = mount_diff({
      old = { "keep", "drop me", "keep too" },
      new = { "keep", "add me", "keep too" },
    })
    local lines = trimmed(handle.bufnr)
    assert.truthy(lines[1]:find("@@", 1, true))
    assert.equal(" keep", lines[2])
    assert.equal("-drop me", lines[3])
    assert.equal("+add me", lines[4])
    assert.equal(" keep too", lines[5])

    assert.equal(1, #marks_with(handle.bufnr, "DiffDelete"))
    assert.equal(1, #marks_with(handle.bufnr, "DiffAdd"))
    -- hunk header dimmed
    assert.equal(1, #marks_with(handle.bufnr, "@comment"))
    handle.unmount()
  end)

  it("indent prefixes every row; max_lines truncates with a marker", function()
    local old, new = {}, {}
    for i = 1, 12 do
      old[i] = "line " .. i
      new[i] = "line " .. i .. " changed"
    end
    local handle = mount_diff({ old = old, new = new, indent = "  ", max_lines = 5 })
    local lines = trimmed(handle.bufnr)
    assert.truthy(lines[1]:find("^  @@"))
    assert.truthy(lines[2]:find("^  %-line 1"))
    -- The @@ header is a rendered row too: 5 rows then the marker.
    assert.truthy(lines[6]:find("truncated"))
    assert.equal("", lines[7])
    handle.unmount()
  end)

  it("identical sides render nothing", function()
    local handle = mount_diff({ old = { "same" }, new = { "same" } })
    -- Only the float's empty canvas remains.
    assert.equal("", table.concat(trimmed(handle.bufnr), ""))
    handle.unmount()
  end)
end)
