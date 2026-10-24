-- Navigation and hover use recorded tool responses, never live LSP requests.
local ui = require("fibrous.inline.components")
local ToolCall = require("weave.view.tool_call")
local C = require("weave.view.renderers.common")
local M = {}
local supported = { document_symbols = true, workspace_symbols = true, definition = true, references = true, hover = true }

local function parse(block)
  return C.output.json(block, function(value)
    return type(value.status) == "string" and type(value.items) == "table"
      and vim.islist(value.items) and #value.items <= 1000
  end)
end

local function clients(rows, data)
  rows[#rows + 1] = C.line("Language servers", "Title")
  local list = type(data.clients) == "table" and data.clients or {}
  if #list == 0 then rows[#rows + 1] = C.line("No language server reported for this query.") end
  for i = 1, math.min(#list, 32) do
    local item = type(list[i]) == "table" and list[i] or {}
    rows[#rows + 1] = C.line(C.clean(item.name, 160) .. ": " .. C.clean(item.state, 80)
      .. " | request: " .. C.clean(item.status or "not_requested", 80))
  end
  C.omitted(rows, #list, math.min(#list, 32), true)
  local startup = type(data.startup) == "table" and data.startup or {}
  if type(startup.waited_ms) == "number" then
    rows[#rows + 1] = C.line("Startup: " .. startup.waited_ms .. " ms" .. (startup.timed_out and " (timed out)" or ""))
  end
  local next_action = type(data.next_action) == "table" and data.next_action or {}
  if type(next_action.message) == "string" then rows[#rows + 1] = C.line(C.clean(next_action.message, 1024, true)) end
end

function M.Body(_, props)
  local data, block = props.lsp_result, props.block
  if not data then return C.column({ C.notice(block) }) end
  local rows = { C.line("Recorded LSP result; indexing/analysis completeness unknown.") }
  local successful = not C.output.failed(block) and (data.status == "ok" or data.status == "partial")
  if not successful then
    rows[#rows + 1] = C.line("Query did not complete: " .. C.clean(data.status, 100), "DiagnosticWarn")
    if data.message then rows[#rows + 1] = C.line(C.clean(data.message, 2048, true)) end
  else
    if data.partial then rows[#rows + 1] = C.line("Partial results; see each server's state.", "DiagnosticWarn") end
    rows[#rows + 1] = C.line(#data.items .. " returned items")
    local limit, previous = props.expanded and 300 or 3, nil
    local shown = math.min(#data.items, limit)
    local hover = ToolCall.weave_tool(block) == "hover"
    for i = 1, shown do
      local item = type(data.items[i]) == "table" and data.items[i] or {}
      if hover then
        local content = C.clean(item.text, props.expanded and 64000 or 240, true)
        if props.expanded and item.format == "markdown" then
          rows[#rows + 1] = { comp = ui.markdown, props = { text = content } }
        else rows[#rows + 1] = C.line(content, "Normal") end
        if item.truncated then rows[#rows + 1] = C.line("Hover text truncated by the tool.") end
      else
        local path = type(item.path) == "string" and item.path or ("buffer:" .. C.clean(item.buffer or "?", 40))
        local group = path .. (type(item.container) == "string" and (" / " .. item.container) or "")
        if group ~= previous then rows[#rows + 1] = C.line(C.clean(group, 1024), "Title"); previous = group end
        local range = type(item.selection_range) == "table" and item.selection_range or item.range
        local at = type(range) == "table" and range.start
        local position = type(at) == "table" and (C.clean(at.line, 20) .. ":" .. C.clean(at.column, 20)) or "unresolved location"
        local name = type(item.name) == "string" and (C.clean(item.name, 1024) .. "  ") or ""
        local target = item.range_available == false and {} or item
        rows[#rows + 1] = C.location(target, name .. position)
        if props.expanded and type(item.detail) == "string" then rows[#rows + 1] = C.line(C.clean(item.detail, 2048, true)) end
      end
    end
    C.omitted(rows, #data.items, shown, props.expanded)
    C.page(rows, data, #data.items)
    if #data.items == 0 then rows[#rows + 1] = C.line("An empty response does not establish complete analysis.") end
  end
  if props.expanded or not successful then clients(rows, data) end
  return C.column(rows)
end

function M.Render(ctx, props)
  return C.entry(props, M.Body, nil, { lsp_result = C.cached(ctx, props.block, parse) })
end

function M.install()
  ToolCall.register({ name = "weave.lsp.navigation", match = function(block) return supported[ToolCall.weave_tool(block)] == true end,
    render = M.Render })
end

return M
