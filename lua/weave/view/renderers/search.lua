local ui = require("fibrous.inline.components")
local ToolCall = require("weave.view.tool_call")
local C = require("weave.view.renderers.common")
local M = {}

local function parse(block)
  local text = C.output.text(block)
  if not text or C.output.failed(block) then return nil end
  local input = type(block.input) == "table" and block.input or {}
  local tool = ToolCall.weave_tool(block)
  local mode = tool == "glob" and "files_with_matches" or input.output_mode or "files_with_matches"
  local items, notes = {}, {}
  local numbered = input["-n"] == true or input.line_numbers == true
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line:sub(1, 1) == "(" then
      notes[#notes + 1] = line
    elseif line ~= "" then
      local item
      if mode == "content" and numbered then
        -- Ambiguous historical plain-text paths must not invent a target.
        local path, n, content = line:match("^(.-):(%d+):(.*)$")
        local kind = "match"
        if not path then path, n, content = line:match("^(.-)%-(%d+)%-(.*)$"); kind = "context" end
        local _, separators = line:gsub("[:%-]%d+[:%-]", "")
        if path and separators == 1 then
          item = { path = path, range = { start = { line = tonumber(n), column = 1 } },
            text = content, kind = kind }
        end
      elseif mode == "count" then
        local path, count = line:match("^(.*):(%d+)$")
        if path then item = { path = path, count = tonumber(count) } end
      elseif mode == "files_with_matches" then
        item = { path = line }
      end
      items[#items + 1] = item or { text = line }
    end
    if #items > 10000 then return nil end
  end
  return { items = items, notes = notes, mode = mode, numbered = numbered }
end

function M.Body(_, props)
  local data = props.search_result
  if not data or C.output.failed(props.block) then return C.column({ C.notice(props.block) }) end
  local rows = { C.line(("Recorded search: %d returned entries"):format(#data.items)) }
  if data.mode == "content" and not data.numbered then
    rows[#rows + 1] = C.line("Line numbers unavailable; request -n=true for navigable matches.")
  end
  local shown, previous = math.min(#data.items, props.expanded and 300 or 3), nil
  for i = 1, shown do
    local item = data.items[i]
    if data.mode == "content" and item.range then
      if previous ~= item.path then rows[#rows + 1] = C.line(C.clean(item.path, 1024), "Title"); previous = item.path end
      rows[#rows + 1] = { comp = ui.row, props = { gap = 1 }, children = {
        C.location(item, tostring(item.range.start.line)),
        C.line(C.clean(item.text, props.expanded and 4096 or 160, true), item.kind == "match" and "Normal" or "@comment"),
      } }
    elseif item.path then
      local label = C.clean(item.path, 1024) .. (item.count and (" (" .. item.count .. " matches)") or "")
      rows[#rows + 1] = C.location({ path = item.path, range = { start = { line = 1, column = 1 } } }, label)
    else
      rows[#rows + 1] = C.line(C.clean(item.text, props.expanded and 4096 or 160, true))
    end
  end
  C.omitted(rows, #data.items, shown, props.expanded)
  for _, note in ipairs(data.notes) do rows[#rows + 1] = C.line(C.clean(note, 1024, true)) end
  return C.column(rows)
end

function M.Render(ctx, props)
  return C.entry(props, M.Body, nil, { search_result = C.cached(ctx, props.block, parse) })
end

function M.install()
  ToolCall.register({ name = "weave.fs.search", match = function(block)
    local name = ToolCall.weave_tool(block)
    return name == "glob" or name == "grep"
  end, render = M.Render })
end

return M
