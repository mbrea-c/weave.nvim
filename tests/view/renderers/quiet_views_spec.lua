local mount = require("fibrous.inline.mount")
local ToolCall = require("weave.view.tool_call")
local C = require("weave.view.renderers.common")
local Store = require("weave.session_store")

local function call(name, command)
  return { tool_call_id = "quiet", kind = "other", status = "completed",
    mcp = { server = "clankbox", tool = "weave_" .. name },
    input = { command = command or "printf hello", path = "/tmp/example.lua", subagent_id = 7 },
    body = { "OUTPUT_MUST_STAY_HIDDEN" } }
end

describe("quiet collapsed tool views", function()
  before_each(function() require("weave").setup({}) end)
  after_each(function() ToolCall.reset() end)

  for _, name in ipairs({ "read", "glob", "grep", "task_start", "task_status", "task_wait", "task_kill",
    "task_list", "document_symbols", "workspace_symbols", "definition", "references", "hover",
    "subagent_create", "subagent_list", "subagent_send", "subagent_read", "subagent_wait", "subagent_cancel", "subagent_close" }) do
    it("keeps " .. name .. " header-only in every status", function()
      for _, status in ipairs({ "pending", "in_progress", "completed", "failed" }) do
        local block = call(name)
        block.status = status
        local app = mount.floating(ToolCall.Dispatch, { block = block, store = Store:new(), expanded = false },
          { width = 80, height = 12, mode = "scroll" })
        local lines = vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)
        app.unmount()
        assert.equal(1, #lines, name .. " (" .. status .. ") should only draw its header")
        assert.falsy(lines[1]:find("OUTPUT_MUST_STAY_HIDDEN", 1, true))
      end
    end)
  end

  it("keeps native shell output hidden too", function()
    local block = call("task_start")
    block.mcp, block.kind = nil, "execute"
    local app = mount.floating(ToolCall.Dispatch, { block = block, store = Store:new(), expanded = false },
      { width = 42, height = 12, mode = "scroll" })
    local lines = vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)
    app.unmount()
    assert.equal(1, #lines)
  end)

  it("ellipsizes task headers to the actual width, including wide and composed characters", function()
    local block = call("task_start", "printf '界é" .. string.rep("long-command ", 20) .. "'\nprintf done")
    for _, width in ipairs({ 24, 42, 90 }) do
      for _, expanded in ipairs({ false, true }) do
        local app = mount.floating(ToolCall.Header, { block = block, store = Store:new(),
          expanded = expanded, truncate_header = true }, { width = width, height = 12, mode = "scroll" })
        local lines = vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)
        app.unmount()
        assert.equal(1, #lines)
        assert.is_true(vim.api.nvim_strwidth(lines[1]) <= width)
        assert.truthy(lines[1]:gsub("%s+$", ""):match("…$"))
      end
    end
  end)

  it("does not add ellipses to commands which fit", function()
    local app = mount.floating(ToolCall.Dispatch, { block = call("task_start", "pwd"), store = Store:new() },
      { width = 60, height = 12, mode = "scroll" })
    local text = table.concat(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false), "\n")
    app.unmount()
    assert.truthy(text:find("pwd", 1, true))
    assert.falsy(text:find("…", 1, true))
  end)

  it("preserves shell syntax highlight spans inside a visibly framed, wrapped command block", function()
    local highlighter = require("fibrous.doc.highlight")
    local old, seen = highlighter.code_lines, nil
    local command = "printf 'quoted value'\n# ```\n  printf done"
    highlighter.code_lines = function(code, lang)
      seen = { code, lang }
      return { { { "printf ", hl = "@function" }, { "'quoted value'", hl = "@string" } },
        { { "# ```", hl = "@comment" } }, { { "  printf done", hl = "@function" } } }
    end
    local ok, err = pcall(function()
      local app = mount.floating(C.Code, { code = command, lang = "bash", title = "Shell command (bash)", line_numbers = false },
        { width = 18, height = 12, mode = "scroll" })
      local text = table.concat(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false), "\n")
      local marks = vim.api.nvim_buf_get_extmarks(app.bufnr, -1, 0, -1, { details = true })
      app.unmount()
      assert.same({ command, "bash" }, seen)
      assert.truthy(text:find("Shell command", 1, true))
      assert.truthy(text:find("│", 1, true))
      local string_mark = false
      for _, mark in ipairs(marks) do
        if mark[4].hl_group == "@string" then string_mark = true end
      end
      assert.is_true(string_mark)
    end)
    highlighter.code_lines = old
    if not ok then error(err) end
  end)
end)
