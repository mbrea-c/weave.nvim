-- Canonical, deliberately limited transcript content. No provider config or drafts.
local M = {}

function M.recall(record)
  if record.entry.kind == "thought" then return false end
  if record.tool then
    local name = require("weave.view.tool_call").weave_tool(record.tool)
    if name == "transcript_search" or name == "transcript_read" then return false end
  end
  return true
end

function M.text(record, details)
  local entry = record.entry
  if entry.kind ~= "tool_call" then return entry.payload or entry.text or "" end
  local tool = record.tool or {}
  local Call = require("weave.view.tool_call")
  local text = Call.tool_tag(tool) .. " " .. Call.tool_title(tool) .. " [" .. (tool.status or "pending") .. "]"
  if details then
    local ok, input = pcall(vim.json.encode, tool.input)
    if ok and tool.input ~= nil then text = text .. "\ninput: " .. input end
    local output = require("weave.tool_output").text(tool)
    if output then text = text .. "\noutput:\n" .. output end
  end
  return text
end

local function display(text)
  if type(text) == "string" then return require("weave.view.renderers.common").clean(text, nil, true) end
end

function M.part(record, part)
  if part == "text" and record.entry.kind ~= "tool_call" then return record.entry.text end
  if part == "entry" then return record.tool and M.text(record, false) or record.entry.text or "" end
  local tool = record.tool
  if not tool then return nil end
  if part == "tool.header" then return M.text(record, false) end
  if part == "tool.command" then
    local input = type(tool.input) == "table" and tool.input or {}
    return display(input.command or input.cmd or require("weave.view.renderers.task_result").parse(tool).command)
  end
  if part == "tool.stdout" or part == "tool.stderr" then
    return display(require("weave.view.renderers.task_result").parse(tool)[part:sub(6)])
  end
  if part == "tool.output" then return display(require("weave.tool_output").text(tool)) end
end

return M
