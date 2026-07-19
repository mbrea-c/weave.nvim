-- The terminal-task UI (design-agent-sandbox.md, phase 0c): projections of
-- the editor-global task store (weave.task_store) — the shell tasks agents
-- start through task_start. Three surfaces: a sidebar section listing
-- RUNNING tasks, the full task list float (every task ever, with status
-- flags), and a per-task live view streaming stdout/stderr with a kill
-- button. All three re-render off one bridge hook over TaskStore.subscribe.

local ui = require("fibrous.inline.components")
local TaskStore = require("weave.task_store")
local Theme = require("weave.view.theme")

local M = {}

-- The live view caps each stream at this many tail lines (test hook).
M._tail_lines = 200

--- The store→fibrous bridge for the task store. Unlike SessionStore there is
--- no immutable snapshot to swap — tasks mutate in place and subscribe(fn)
--- carries no payload — so a bumped version counter drives the re-render and
--- the component re-reads the store directly.
--- @param ctx table fibrous ReactiveCtx
--- @return weave.Task[]
local function use_tasks(ctx)
  local ver = ctx.use_state(0)
  ctx.use_effect(function()
    return TaskStore.subscribe(function()
      ver.set(ver.get() + 1)
    end)
  end, { TaskStore })
  ver.get() -- read it: the version bump is what re-renders us
  return TaskStore.list()
end

local function header(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "Title" } } }
end

local function dim(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "@comment" } } }
end

--- The status flag: the plan-task glyph vocabulary, keyed by outcome —
--- running ■ (amber), clean exit ✔ (green), non-zero exit or killed ✖ (red).
--- @param task weave.Task
--- @return string glyph, string hl
function M.flag(task)
  if task.status == "running" then
    return Theme.TASK_ICON.in_progress, Theme.TASK_ICON_HL.in_progress
  end
  if task.status == "killed" or (task.exit_code or 0) ~= 0 then
    return Theme.TASK_ICON.failed, Theme.TASK_ICON_HL.failed
  end
  return Theme.TASK_ICON.completed, Theme.TASK_ICON_HL.completed
end

--- "running (pid N)" / "exited (code N)" / "killed (signal N)" — the same
--- phrasing the task tools report, so transcripts and the UI agree.
--- @param task weave.Task
--- @return string
function M.status_label(task)
  if task.status == "running" then
    return ("running (pid %d)"):format(task.pid)
  end
  if task.status == "killed" then
    return ("killed (signal %d)"):format(task.signal or 0)
  end
  return ("exited (code %d)"):format(task.exit_code or 0)
end

--- One-line clamp: whitespace (a multiline command) collapses to single
--- spaces, and overflow past `w` cells is cut with a trailing ellipsis.
--- @param text string
--- @param w integer
--- @return string
function M.truncate(text, w)
  w = math.max(w, 4)
  text = (text:gsub("%s+", " "))
  if vim.api.nvim_strwidth(text) <= w then
    return text
  end
  while text ~= "" and vim.api.nvim_strwidth(text) + 1 > w do
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
  end
  return text .. "…"
end

--- The last `max` lines of `text` (a trailing newline ends no extra line).
--- @param text string
--- @param max integer
--- @return string[] lines, integer omitted
function M.tail(text, max)
  local lines = vim.split(text, "\n")
  if lines[#lines] == "" then
    table.remove(lines)
  end
  if #lines <= max then
    return lines, 0
  end
  return vim.list_slice(lines, #lines - max + 1, #lines), #lines - max
end

--- One task row: the status glyph, then a bare-button "[id] command" label
--- (clamped to `w` cells) opening that task's live view.
local function task_row(task, w)
  local glyph, hl = M.flag(task)
  return {
    comp = ui.row,
    props = { gap = 1 },
    children = {
      { comp = ui.label, props = { text = glyph, style = { text_hl = hl } } },
      {
        comp = ui.button,
        props = {
          label = M.truncate(("[%d] %s"):format(task.id, task.command), w),
          theme = false, -- no chip chrome: the row reads as a plain line
          style = { _hover = { hl = "FibrousHover" } },
          on_press = function()
            M.open_task_view(task.id)
          end,
        },
      },
    },
  }
end

--- The sidebar section (above Permissions): currently RUNNING tasks only.
--- The header is itself the way in — activating it opens the full task
--- list — and each row opens that task's live view.
--- @param ctx table
--- @param props { width?: integer }
function M.Section(ctx, props)
  local tasks = use_tasks(ctx)
  local rows = {
    {
      comp = ui.button,
      props = {
        label = "Terminal tasks",
        theme = false,
        style = { text_hl = "Title", _hover = { hl = "FibrousHover" } },
        on_press = function()
          M.open_task_list()
        end,
      },
    },
  }
  -- text width inside the sidebar: its col chrome (3) + icon column and gap (2)
  local text_w = math.max((props.width or 30) - 5, 4)
  local running = 0
  for _, t in ipairs(tasks) do
    if t.status == "running" then
      running = running + 1
      rows[#rows + 1] = task_row(t, text_w)
    end
  end
  if running == 0 then
    rows[#rows + 1] = dim("(none running)")
  end
  return { comp = ui.col, props = {}, children = rows }
end

--- The FULL task list in its own floating mount: every task ever started —
--- running, exited, killed — each a live-view button over a dim status
--- line, live off the store; q/<Esc> closes.
function M.open_task_list()
  local mount = require("fibrous.inline.mount")
  local function FullList(ctx)
    local tasks = use_tasks(ctx)
    local rows = { header(("Terminal tasks (%d)"):format(#tasks)) }
    if #tasks == 0 then
      rows[2] = dim("(no tasks yet)")
    end
    for _, t in ipairs(tasks) do
      local row = task_row(t, 60)
      row.children[2] = {
        comp = ui.col,
        props = {},
        children = { row.children[2], dim(M.status_label(t)) },
      }
      rows[#rows + 1] = row
    end
    return { comp = ui.col, props = {}, children = rows }
  end
  local app = mount.floating(FullList, {}, {
    width = 70,
    height = math.min(math.max(#TaskStore.list() * 2 + 2, 4), math.max(vim.o.lines - 6, 8)),
    mode = "scroll",
    border = "rounded",
    backdrop = true,
  })
  require("weave.keys").map(app.bufnr, "close_float", function()
    app.unmount()
  end, { nowait = true, desc = "weave: close terminal task list" })
  app.focus()
  return app
end

--- One task's LIVE view: flag + status header, the command and cwd, then the
--- stdout and stderr streams re-rendered as chunks arrive (each capped to the
--- last _tail_lines lines), with a kill button while it runs; q/<Esc> closes.
--- @param id integer
function M.open_task_view(id)
  local mount = require("fibrous.inline.mount")
  local function TaskView(ctx)
    use_tasks(ctx)
    local task = TaskStore.get(id)
    if not task then
      return { comp = ui.col, props = {}, children = { dim(("(no task with id %s)"):format(tostring(id))) } }
    end
    local glyph, hl = M.flag(task)
    local rows = {
      {
        comp = ui.row,
        props = { gap = 1 },
        children = {
          { comp = ui.label, props = { text = glyph, style = { text_hl = hl } } },
          {
            comp = ui.label,
            props = { text = ("task %d: %s"):format(task.id, M.status_label(task)), style = { text_hl = "Title" } },
          },
        },
      },
      dim("command: " .. task.command),
      dim("cwd: " .. task.cwd),
    }
    if task.status == "running" then
      rows[#rows + 1] = {
        comp = ui.button,
        props = {
          label = "kill task",
          on_press = function()
            TaskStore.kill(id)
          end,
        },
      }
    end
    for _, stream in ipairs({ { "stdout", TaskStore.stdout_text(task) }, { "stderr", TaskStore.stderr_text(task) } }) do
      rows[#rows + 1] = header(stream[1])
      local lines, omitted = M.tail(stream[2], M._tail_lines)
      if omitted > 0 then
        rows[#rows + 1] = dim(("(… %d earlier lines omitted)"):format(omitted))
      end
      if #lines == 0 then
        rows[#rows + 1] = dim("(empty)")
      else
        rows[#rows + 1] = { comp = ui.label, props = { text = table.concat(lines, "\n") } }
      end
    end
    return { comp = ui.col, props = {}, children = rows }
  end
  local app = mount.floating(TaskView, {}, {
    width = 80,
    height = math.min(30, math.max(vim.o.lines - 6, 8)),
    mode = "scroll",
    border = "rounded",
    backdrop = true,
  })
  require("weave.keys").map(app.bufnr, "close_float", function()
    app.unmount()
  end, { nowait = true, desc = "weave: close task view" })
  app.focus()
  return app
end

return M
