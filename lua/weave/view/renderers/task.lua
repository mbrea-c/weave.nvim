-- The first real consumer of the tool-renderer registry, and the case that
-- motivated it: a task_start call renders inline as a LIVE task view (status
-- flag, tail of stdout, kill button) instead of a vim.inspect dump of its
-- rawInput sitting behind an expand toggle.
--
-- This is opt-in — `require("weave.view.renderers.task").install()` — because
-- matching a call to its task is exact only once the call's own result has
-- landed; before that it falls back to a command-line join. See the
-- correlation note below.

local ui = require("fibrous.inline.components")
local TaskStore = require("weave.task_store")
local TerminalTasks = require("weave.view.terminal_tasks")
local ToolCall = require("weave.view.tool_call")

local M = {}

-- Inline preview is short on purpose: the transcript is a conversation, not a
-- terminal. The full stream is one <CR> away in the task view float.
M.PREVIEW_LINES = 8

--- ── Correlating a tool call with its task ──────────────────────────────────
---
--- Nothing identifies the task on the way IN. rawInput is exactly the
--- arguments we declared in our own inputSchema (clankbox hands the handler
--- `params.arguments` and nothing else) — command, cwd, blocking, timeout_ms.
--- No ACP toolCallId, no MCP _meta.
---
--- But the id travels OUT. Every task_start response opens with "task <id>"
--- (tools/tasks.lua status_line), and that id is ours — the task store minted
--- it. The provider reports the tool result back as rawOutput, so the block
--- carries the exact task it started. No correlation id needed on either
--- side.
---
--- Fallback: rawOutput is optional in ACP and not every provider populates it
--- (and it is absent anyway between the call starting and its result landing,
--- which is exactly when a live view is most interesting). So an
--- output-derived id wins when present, and otherwise we join on the command
--- line, newest task first. That fallback is a heuristic, and wrong in a
--- bounded way: run the same command twice and the older call points at the
--- newer task until its own output arrives and corrects it.

--- Any text carried in an MCP tool result, whatever shape the provider used:
--- a bare string, {content={{type="text",text=...}}}, or a plain field.
--- @param output any rawOutput off the block
--- @return string
local function output_text(output)
  if type(output) == "string" then
    return output
  end
  if type(output) ~= "table" then
    return ""
  end
  local parts = {}
  for _, item in ipairs(output.content or {}) do
    if type(item) == "table" and type(item.text) == "string" then
      parts[#parts + 1] = item.text
    end
  end
  if #parts == 0 then
    for _, key in ipairs({ "text", "output", "result" }) do
      if type(output[key]) == "string" then
        parts[#parts + 1] = output[key]
      end
    end
  end
  return table.concat(parts, "\n")
end

--- The task id this call reported starting, from its own result text.
--- @param block table
--- @return integer|nil
function M.task_id_from_output(block)
  local id = output_text(block.output):match("^task (%d+)")
  return id and tonumber(id) or nil
end

--- @param block table
--- @return weave.Task|nil
function M.task_for(block)
  local id = M.task_id_from_output(block)
  if id then
    -- Exact: the task this very call started.
    return TaskStore.get(id)
  end

  local command = type(block.input) == "table" and block.input.command
  if type(command) ~= "string" then
    return nil
  end
  local tasks = TaskStore.list()
  for i = #tasks, 1, -1 do
    if tasks[i].command == command then
      return tasks[i]
    end
  end
  return nil
end

--- Matches a call that both LOOKS like task_start (a `command` in rawInput,
--- no other weave tool takes that field) and actually resolves to a task we
--- started. The second half is what keeps this from hijacking a provider's
--- own shell tool: if we never started it, we have nothing better to draw.
--- @param block table
--- @return boolean
function M.match(block)
  return M.task_for(block) ~= nil
end

--- The BODY subrenderer: everything below the header, always visible.
--- @param props weave.view.ToolCallProps
function M.Body(ctx, props)
  -- Subscribe to the task store: this is why renderers are components. The
  -- store mutates in place with no payload, so the version bump re-renders us
  -- on every chunk of output the task produces.
  local ver = ctx.use_state(0)
  ctx.use_effect(function()
    return TaskStore.subscribe(function()
      ver.set(ver.get() + 1)
    end)
  end, { TaskStore })
  ver.get()

  local task = M.task_for(props.block)
  if not task then
    -- The task aged out of the store between match and render.
    return { comp = ui.label, props = { text = "    (task no longer tracked)", style = { text_hl = "@comment" } } }
  end

  local glyph, hl = TerminalTasks.flag(task)
  local rows = {
    {
      comp = ui.row,
      props = { gap = 1 },
      children = {
        { comp = ui.label, props = { text = "    " .. glyph, style = { text_hl = hl } } },
        {
          comp = ui.label,
          props = { text = TerminalTasks.status_label(task), style = { text_hl = "@comment" } },
        },
      },
    },
  }

  local lines, omitted = TerminalTasks.tail(TaskStore.stdout_text(task), M.PREVIEW_LINES)
  if omitted > 0 then
    rows[#rows + 1] = {
      comp = ui.label,
      props = { text = ("    │ (… %d earlier lines)"):format(omitted), style = { text_hl = "@comment" } },
    }
  end
  for _, line in ipairs(lines) do
    rows[#rows + 1] = { comp = ui.label, props = { text = "    │ " .. line } }
  end

  rows[#rows + 1] = {
    comp = ui.button,
    props = {
      label = task.status == "running" and "    kill" or "    open",
      theme = false,
      on_press = function()
        if task.status == "running" then
          TaskStore.kill(task.id)
        else
          TerminalTasks.open_task_view(task.id)
        end
      end,
    },
  }

  return { comp = ui.col, props = {}, children = rows }
end

--- Delegates to the builtin Entry with only the body swapped, so the header
--- (status glyph, expand toggle, keys) and the expandable raw input/output
--- metadata stay exactly as they are for every other tool call. This is the
--- intended shape of a partial override.
--- @param props weave.view.ToolCallProps
function M.Render(_, props)
  return { comp = ToolCall.Entry, props = vim.tbl_extend("force", props, { render_body = M.Body }) }
end

--- Register the renderer. Idempotent (the registry replaces by name).
--- Priority stays at the 0 default: this is a weave builtin, so a user or
--- plugin renderer at any positive priority outranks it.
function M.install()
  ToolCall.register({ name = "weave:task", match = M.match, render = M.Render })
end

return M
