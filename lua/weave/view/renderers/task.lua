-- Live views require a reported task ID. Never guess by command: identical
-- commands are common, including across sibling sessions.
local ui = require("fibrous.inline.components")
local TaskStore = require("weave.task_store")
local TerminalTasks = require("weave.view.terminal_tasks")
local ToolCall = require("weave.view.tool_call")
local C = require("weave.view.renderers.common")
local M = { PREVIEW_LINES = 8 }
local supported = { task_start = true, task_status = true, task_wait = true, task_kill = true, task_list = true }

function M.task_id_from_output(block)
  local text = C.output.text(block)
  local id = text and (text:match("^task (%d+)[ :]")
    or text:match("^sent SIGTERM to task (%d+)'s process group"))
  return id and tonumber(id) or nil
end

local function allowed(task, store)
  if TaskStore.get(task.id) ~= task then return false end
  if task.caller and not task.caller.valid() then return false end
  if not store then return true end -- trusted direct Lua rendering
  if not task.owner then return false end
  if task.owner:get_store() == store then return true end
  local registry = require("weave.registry")
  local owner = registry.entry_for(task.owner)
  if not owner then return false end
  for _, entry in ipairs(registry.list()) do
    if entry.session:get_store() == store then return registry.is_descendant(owner.key, entry.key) end
  end
  return false
end

function M.task_for(block, store)
  local tool = ToolCall.weave_tool(block)
  if store and not supported[tool] then return nil end
  local id = M.task_id_from_output(block)
  local task = id and TaskStore.get(id)
  if store and task then
    local text = C.output.text(block) or ""
    local first = text:match("^[^\n]+") or ""
    local receipt = first:match("%[weave task: ([%w%-]+)%]$")
    if receipt ~= task.receipt then return nil end
  end
  return task and allowed(task, store) and task or nil
end

function M.match(block)
  local tool = ToolCall.weave_tool(block)
  if tool then return supported[tool] == true end
  if block.mcp then return false end
  local input = type(block.input) == "table" and block.input or {}
  return block.kind == "execute" and (type(input.command) == "string" or type(input.cmd) == "string")
    or M.task_id_from_output(block) ~= nil
end

-- A bounded tail of both streams in callback-arrival order, not a guessed
-- reconstruction of ordering from the separately retained stdout/stderr.
function M.tail(task, limit)
  local events, selected, bytes, lines, trimmed = task.events or {}, {}, 0, 0, false
  for i = #events, 1, -1 do
    local event = events[i]
    local value = event.text
    if #value > 65536 then value = value:sub(-65536); trimmed = true end
    selected[#selected + 1] = { stream = event.stream, text = value }
    bytes = bytes + #value
    local _, count = value:gsub("\n", "")
    lines = lines + count
    if i < #events and events[i + 1].stream ~= event.stream then lines = lines + 1 end
    if bytes >= 65536 or lines >= limit + 1 then break end
  end
  local groups = {}
  for i = #selected, 1, -1 do
    local event, last = selected[i], groups[#groups]
    if last and last.stream == event.stream then last.parts[#last.parts + 1] = event.text
    else groups[#groups + 1] = { stream = event.stream, parts = { event.text } } end
  end
  local rows = {}
  for _, group in ipairs(groups) do
    local values = vim.split(C.clean(table.concat(group.parts), nil, true), "\n", { plain = true })
    if values[#values] == "" then table.remove(values) end
    for _, value in ipairs(values) do rows[#rows + 1] = { stream = group.stream, text = value } end
  end
  return vim.list_slice(rows, math.max(1, #rows - limit + 1)), trimmed or #selected < #events or #rows > limit
end

local function use_task(ctx, props)
  local ver = ctx.use_state(0)
  ctx.use_effect(function()
    -- Ignore unrelated task output. The signal is coalesced by TaskStore.
    local task = M.task_for(props.block, props.store)
    local n, status = task and #task.events, task and task.status
    if not task then return end
    local available = true
    return TaskStore.subscribe(function()
      local current = TaskStore.get(task.id) == task and allowed(task, props.store)
      if current ~= available or current and (#task.events ~= n or task.status ~= status) then
        available, n, status = current, #task.events, task.status
        ver.set(ver.get() + 1)
      end
    end)
  end, { props.block, props.store })
  ver.get()
  return M.task_for(props.block, props.store)
end

local function runtime(task)
  return math.max(0, (task.finished_at or os.time()) - task.started_at) .. "s"
end

function M.Body(ctx, props)
  if ToolCall.weave_tool(props.block) == "task_list" then return M.List({}, props) end
  local task = use_task(ctx, props)
  if not task then
    local block = props.block
    local text, own = C.output.text(block), supported[ToolCall.weave_tool(block)]
    local rows = { C.line(own and (text and "Live task unavailable; showing recorded result."
      or "Waiting for reported task ID; live output is not yet associated.")
      or "Recorded command output (no live task association).") }
    if C.output.failed(block) then rows[#rows + 1] = C.line("Command call failed.", "DiagnosticWarn") end
    if text then
      local values = vim.split(C.clean(text:gsub(" %[%s*weave task: [%w%-]+%]", ""), nil, true), "\n", { plain = true })
      local shown = math.min(#values, props.expanded and 80 or M.PREVIEW_LINES)
      for i = 1, shown do rows[#rows + 1] = C.line(values[i], "Normal") end
      if shown < #values then rows[#rows + 1] = C.line((#values - shown) .. " more lines; K for recorded output.") end
    end
    return C.column(rows)
  end
  local glyph, hl = TerminalTasks.flag(task)
  local rows = { C.line(glyph .. " " .. TerminalTasks.status_label(task) .. " | runtime " .. runtime(task), hl) }
  local lines, omitted = M.tail(task, props.expanded and 40 or M.PREVIEW_LINES)
  if omitted then rows[#rows + 1] = C.line("Earlier output omitted; open full output.") end
  for _, line in ipairs(lines) do
    rows[#rows + 1] = C.line((line.stream == "stderr" and "[err] " or "[out] ") .. line.text,
      line.stream == "stderr" and "DiagnosticWarn" or "Normal")
  end
  if #lines == 0 then rows[#rows + 1] = C.line("No output received yet.") end
  if props.expanded then
    rows[#rows + 1] = C.line("Combined output uses editor-observed chunk order; it is not a PTY.")
    rows[#rows + 1] = { comp = ui.button, props = { label = "Open full output", theme = false,
      on_press = function() if allowed(task, props.store) then TerminalTasks.open_task_view(task.id, { full = true }) end end } }
    if task.status == "running" then
      rows[#rows + 1] = { comp = ui.button, props = { label = "Stop task", theme = false,
        on_press = function() if allowed(task, props.store) then TaskStore.kill(task.id) end end } }
    end
  end
  return C.column(rows)
end

function M.Details(_, props)
  if ToolCall.weave_tool(props.block) == "task_list" then return nil end
  local input = type(props.block.input) == "table" and props.block.input or {}
  local task = M.task_for(props.block, props.store)
  local command = task and task.command or type(input.command) == "string" and input.command
    or type(input.cmd) == "string" and input.cmd
  local rows = {}
  local cwd = task and task.cwd or input.cwd
  rows[#rows + 1] = C.line("cwd: " .. C.clean(cwd or "(not reported)", 2048))
  if command then rows[#rows + 1] = { comp = C.Code, props = { code = command, lang = "sh", line_numbers = false } } end
  return C.column(rows)
end

function M.List(_, props)
  local text = C.output.text(props.block)
  if not text or C.output.failed(props.block) then return C.column({ C.notice(props.block) }) end
  local rows, shown, total = {}, 0, 0
  local limit = props.expanded and 100 or 3
  for record in (text .. "\n\n"):gmatch("(.-)\n\n") do
    local id = tonumber(record:match("^task (%d+)"))
    if id then
      total = total + 1
      if shown < limit then
        shown = shown + 1
        rows[#rows + 1] = C.line(C.clean(record:gsub(" %[%s*weave task: [%w%-]+%]", ""), 4096, true), "Normal")
        local task = M.task_for({ mcp = props.block.mcp, input = props.block.input, body = { record } }, props.store)
        if props.expanded and task and allowed(task, props.store) then
          rows[#rows + 1] = { comp = ui.button, props = { label = "Open task #" .. id, theme = false,
            on_press = function() if allowed(task, props.store) then TerminalTasks.open_task_view(id, { full = true }) end end } }
        end
      end
    elseif record ~= "" then rows[#rows + 1] = C.line(C.clean(record, 1024, true)) end
  end
  C.omitted(rows, total, shown, props.expanded)
  return C.column(rows)
end

function M.Render(_, props)
  return C.entry(props, M.Body, M.Details)
end

function M.install()
  ToolCall.register({ name = "weave:task", match = M.match, render = M.Render })
end

return M
