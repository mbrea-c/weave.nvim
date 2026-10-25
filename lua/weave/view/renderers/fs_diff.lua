-- Whole-operation snapshots when available, requested fragments otherwise.
local ui = require("fibrous.inline.components")
local Diff = require("weave.view.diff")
local Snapshots = require("weave.tools.write_snapshots")
local ToolCall = require("weave.view.tool_call")
local C = require("weave.view.renderers.common")
local M = {}

local function split(text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then table.remove(lines) end
  return lines
end

local function own_or_legacy(block, name)
  local tool = ToolCall.weave_tool(block)
  if tool then return tool == name end
  if block.mcp then return false end
  local input = type(block.input) == "table" and block.input or {}
  if name == "edit" then
    return type(input.path) == "string" and type(input.old_string) == "string" and type(input.new_string) == "string"
  end
  return type(input.path) == "string" and type(input.content) == "string"
    and Snapshots.get(input.path, input.content) ~= nil
end

local function render(_, props)
  local block = props.block
  local input = type(block.input) == "table" and block.input or {}
  local snap = Snapshots.for_call(block, props.store)
  local old, new, path = snap and snap.old, snap and snap.new, snap and snap.path or block.file_path or input.path
  local reported = not snap and type(block.diff) == "table"
    and type(block.diff.old) == "table" and type(block.diff.new) == "table"
  local result = C.output.text(block)
  local created = not snap and not reported and ToolCall.weave_tool(block) == "write"
    and block.status == "completed" and not C.output.failed(block) and type(input.content) == "string"
    and result and result:match("^wrote %d+ lines to ")
    and result:match("\n%[weave write: created%]\n%[weave change: %x+%-%d+%]%s*$")
  local requested = not snap and not reported and not created
  if created then old, new = {}, input.content == "" and {} or split(input.content)
  elseif reported then old, new = block.diff.old, block.diff.new
  elseif not snap and type(input.old_string) == "string" and type(input.new_string) == "string" then
    old, new = split(input.old_string), split(input.new_string)
  elseif not snap and not props.store and type(input.path) == "string" and type(input.content) == "string" then
    old = Snapshots.get(input.path, input.content)
    new = split(input.content)
  end
  return C.entry(props, function()
    if props.show_diff == false then return nil end
    if not old or not new then
      if type(input.content) == "string" then
        local waiting = block.status == "pending" or block.status == "in_progress"
        local label = C.output.failed(block) and "Write failed; requested content only (previous content unavailable)."
          or waiting and "Requested content (previous content unavailable)."
          or "Written content (previous content unavailable; not a before/after diff)."
        return C.column({ C.line(label), { comp = C.Code, props = { code = input.content, path = path,
          max_lines = not props.expanded and ToolCall.DIFF_PREVIEW_MAX_LINES or nil } } })
      end
      return C.column({ C.line((block.status == "pending" or block.status == "in_progress")
        and "Waiting for change result..." or "Diff unavailable: original content was not recorded; K for details.") })
    end
    local label = C.output.failed(block) and (snap and "Call reported failure; recorded filesystem change shown."
        or "Call reported failure; requested/reported change shown.")
      or created and "Created file (recorded tool result)."
      or requested and "Requested change (fragment-relative lines; application not established by this preview)."
      or reported and "Provider-reported change (recorded ACP diff)."
      or "Applied change (recorded snapshot)."
    local diff = { comp = Diff.Diff, props = { old = old, new = new, path = path,
      max_lines = not props.expanded and ToolCall.DIFF_PREVIEW_MAX_LINES or nil, indent = "    " } }
    return { comp = ui.col, props = {},
      children = { C.column({ C.line(label) }), diff } }
  end, nil, nil, true)
end

M.edit = { name = "weave.fs.edit", match = function(block) return own_or_legacy(block, "edit") end, render = render }
M.write = { name = "weave.fs.write", match = function(block) return own_or_legacy(block, "write") end, render = render }

function M.install()
  ToolCall.register(M.edit)
  ToolCall.register(M.write)
end

return M
