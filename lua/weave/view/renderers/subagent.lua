-- Delegation previews show only returned assistant output, never thoughts or
-- an implicit read of another Session's transcript.
local ui = require("fibrous.inline.components")
local ToolCall = require("weave.view.tool_call")
local C = require("weave.view.renderers.common")
local M = {}
local supported = { subagent_create = true, subagent_list = true, subagent_send = true,
  subagent_read = true, subagent_wait = true, subagent_cancel = true, subagent_close = true }

local function parse(block)
  return C.output.json(block, function(value)
    return type(value.subagent_id) == "number" or vim.islist(value) and #value <= 1000
  end)
end

local function entry_for(id)
  local registry = require("weave.registry")
  return type(id) == "number" and registry.get(id) or nil
end

-- Only explicit activation selects/opens a Session. Revalidate the object:
-- stale history must not navigate to a different child after it was closed.
local function open_button(item)
  local entry = entry_for(item.subagent_id)
  if not entry then return nil end
  return { comp = ui.button, props = { label = "Open session", theme = false,
    on_press = function()
      if entry_for(item.subagent_id) ~= entry then
        vim.notify("weave: subagent session is no longer available", vim.log.levels.WARN)
        return
      end
      require("weave").open_session(entry.key)
    end,
  } }
end

function M.Body(_, props)
  local block, data = props.block, props.subagent_result
  if C.output.failed(block) then return C.column({ C.notice(block) }) end
  if ToolCall.weave_tool(block) == "subagent_close" and C.output.text(block) == "Subagent subtree closed." then
    return C.column({ C.line("Subagent subtree closed.") })
  end
  if not data then return C.column({ C.notice(block) }) end
  local list = vim.islist(data) and data or { data }
  local rows, shown = { C.line("Recorded subagent result") }, math.min(#list, props.expanded and 100 or 3)
  for i = 1, shown do
    local item = type(list[i]) == "table" and list[i] or {}
    rows[#rows + 1] = C.line("Subagent #" .. C.clean(item.subagent_id, 20)
      .. (item.name and (" / " .. C.clean(item.name, 256)) or "")
      .. (item.provider and (" / " .. C.clean(item.provider, 160)) or ""), "Title")
    rows[#rows + 1] = C.line((item.run_id and ("Run #" .. C.clean(item.run_id, 20) .. " | ") or "")
      .. C.clean(item.status or "unknown", 80))
    if item.error then rows[#rows + 1] = C.line(C.clean(item.error, 2048, true), "DiagnosticError") end
    if item.timed_out then rows[#rows + 1] = C.line("Wait timed out; the child may still be running.") end
    if type(item.output) == "string" and item.output ~= "" then
      local output = C.clean(item.output, props.expanded and 65536 or 240, true)
      if props.expanded then rows[#rows + 1] = { comp = ui.markdown, props = { text = output } }
      else rows[#rows + 1] = C.line(output, "Normal") end
    end
    if item.has_more then rows[#rows + 1] = C.line("More output available; next cursor: " .. C.clean(item.next_cursor, 20)) end
    if props.expanded then rows[#rows + 1] = open_button(item) end
  end
  C.omitted(rows, #list, shown, props.expanded)
  if #list == 0 then rows[#rows + 1] = C.line("No subagents in the returned list.") end
  return C.column(rows)
end

function M.Render(ctx, props)
  return C.entry(props, M.Body, nil, { subagent_result = C.cached(ctx, props.block, parse) })
end

function M.install()
  ToolCall.register({ name = "weave.subagents", match = function(block) return supported[ToolCall.weave_tool(block)] == true end,
    render = M.Render })
end

return M
