local ToolCall = require("weave.view.tool_call")
local C = require("weave.view.renderers.common")
local M = {}

local function parse(block)
  local text = C.output.text(block)
  if not text or C.output.failed(block) then return nil end
  local code, notes, first, previous = {}, {}, nil, nil
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local number, source = line:match("^(%d+)\t(.*)$")
    if number then
      local n = tonumber(number)
      if previous and n ~= previous + 1 then return nil end
      first, previous = first or n, n
      code[#code + 1] = source
    else
      notes[#notes + 1] = line
    end
  end
  if #code == 0 then return nil end
  return { code = table.concat(code, "\n"), first = first, lines = #code, notes = notes }
end

function M.Body(_, props)
  local data = props.read_result
  if not data or C.output.failed(props.block) then return C.column({ C.notice(props.block) }) end
  local input = type(props.block.input) == "table" and props.block.input or {}
  local path = type(input.path) == "string" and input.path or props.block.file_path
  local rows = { C.line(("Recorded read: lines %d-%d"):format(data.first, data.first + data.lines - 1)) }
  rows[#rows + 1] = { comp = C.Code, props = { code = data.code, path = path, start_line = data.first,
    max_lines = not props.expanded and 4 or nil } }
  for _, note in ipairs(data.notes) do
    if note ~= "" then rows[#rows + 1] = C.line(C.clean(note, 1024, true)) end
  end
  return C.column(rows)
end

function M.Render(ctx, props)
  return C.entry(props, M.Body, nil, { read_result = C.cached(ctx, props.block, parse) })
end

function M.install()
  ToolCall.register({ name = "weave.fs.read", match = function(block) return ToolCall.weave_tool(block) == "read" end,
    render = M.Render })
end

return M
