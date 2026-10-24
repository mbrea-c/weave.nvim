-- The task lifecycle tools (weave_task_start/weave_task_status/
-- weave_task_wait/weave_task_kill): the execute interface from design-agent-sandbox.md, as thin MCP defs over
-- weave.task_store. Blocking start and wait are ASYNC clankbox tools, so the
-- user's editor never freezes while an agent waits on a command; the store
-- fires waiter callbacks on the main loop, which is where respond must run.

local TaskStore = require("weave.task_store")

local M = {}

local DEFAULT_TIMEOUT_MS = 120000
local MAX_STREAM_BYTES = 30000

local ID_PROP = { id = { type = "integer", description = "Task id, as returned by weave_task_start" } }

local function tail(text)
  if #text <= MAX_STREAM_BYTES then
    return text
  end
  return ("(truncated: showing last %d of %d bytes)\n"):format(MAX_STREAM_BYTES, #text)
    .. text:sub(#text - MAX_STREAM_BYTES + 1)
end

local function stamp(task, text)
  if type(task.receipt) ~= "string" then return text end
  local tag = " [weave task: " .. task.receipt .. "]"
  local first = text:find("\n", 1, true)
  return first and (text:sub(1, first - 1) .. tag .. text:sub(first)) or text .. tag
end

local function status_line(task)
  if task.status == "running" then
    return stamp(task, ("task %d: running (pid %d)"):format(task.id, task.pid))
  elseif task.status == "killed" then
    return stamp(task, ("task %d: killed (signal %d)"):format(task.id, task.signal or 0))
  end
  return stamp(task, ("task %d: exited (code %d)"):format(task.id, task.exit_code or 0))
end

--- The full report: status line, command, both streams (tail-truncated).
local function render(task)
  local out = TaskStore.stdout_text(task)
  local err = TaskStore.stderr_text(task)
  return table.concat({
    status_line(task),
    "command: " .. task.command,
    "",
    "--- stdout ---",
    out ~= "" and tail(out) or "(empty)",
    "",
    "--- stderr ---",
    err ~= "" and tail(err) or "(empty)",
  }, "\n")
end

local function visible(task, ctx)
  if not ctx or not ctx.caller then return true end
  if task.caller and not task.caller.valid() then return false end
  local actor = ctx.caller.session
  if task.owner == actor then return true end
  local Registry = require("weave.registry")
  local owner, caller = Registry.entry_for(task.owner), Registry.entry_for(actor)
  return owner and caller and Registry.is_descendant(owner.key, caller.key) or false
end

local function find(args, ctx)
  local id = tonumber(args.id)
  local task = id and TaskStore.get(id)
  if not task or not visible(task, ctx) then
    error(("no task with id %s"):format(tostring(args.id)), 0)
  end
  return task
end

---------------------------------------------------------------------------
-- task_start
---------------------------------------------------------------------------

M.start = {
  description = table.concat({
    "Start a shell command (sh -c) as a managed task in the user's live editor environment;",
    "prefer this over other shell tools in this session.",
    "Default: returns a task id IMMEDIATELY while the command runs in the background;",
    "follow up with weave_task_status / weave_task_wait / weave_task_kill.",
    "With blocking=true it waits for completion (up to timeout_ms) and returns the full report;",
    "on timeout the task keeps running.",
  }, " "),
  inputSchema = {
    type = "object",
    properties = {
      command = { type = "string", description = "Shell command line, run via sh -c" },
      cwd = { type = "string", description = "Working directory (default: the editor's cwd)" },
      blocking = {
        type = "boolean",
        description = "Wait for completion and return the report instead of the id (default false)",
      },
      timeout_ms = {
        type = "integer",
        description = "blocking=true only: max wait before reporting back (default " .. DEFAULT_TIMEOUT_MS .. ")",
      },
    },
    required = { "command" },
  },
  async = true,
  handler = function(args, respond, ctx)
    local task, err = TaskStore.start({ command = args.command, cwd = args.cwd, context = ctx })
    if not task then
      error(err, 0)
    end
    if not args.blocking then
      respond(stamp(task,
        ("task %d started (pid %d): %s\ncheck it with weave_task_status, block on it with weave_task_wait, stop it with weave_task_kill"):format(
          task.id, task.pid, task.command
        )))
      return
    end
    local timeout = tonumber(args.timeout_ms) or DEFAULT_TIMEOUT_MS
    TaskStore.wait(task.id, timeout, function(t, timed_out)
      if timed_out then
        respond(
          render(t)
            .. ("\n\n(still running after %dms; it continues in the background: weave_task_status / weave_task_wait / weave_task_kill with id %d)"):format(
              timeout,
              t.id
            )
        )
      else
        respond(render(t))
      end
    end)
  end,
}

---------------------------------------------------------------------------
-- task_status
---------------------------------------------------------------------------

M.status = {
  description = "Report a task's state (running/exited/killed, exit code) and its stdout/stderr so far.",
  inputSchema = { type = "object", properties = ID_PROP, required = { "id" } },
  handler = function(args, ctx)
    return render(find(args, ctx))
  end,
}

---------------------------------------------------------------------------
-- task_wait
---------------------------------------------------------------------------

M.wait = {
  description = table.concat({
    "Wait for a task to finish and return its full report (status, exit code, stdout/stderr).",
    "Waits up to timeout_ms (default " .. DEFAULT_TIMEOUT_MS .. "); on timeout the task keeps running.",
  }, " "),
  inputSchema = {
    type = "object",
    properties = {
      id = ID_PROP.id,
      timeout_ms = { type = "integer", description = "Max wait (default " .. DEFAULT_TIMEOUT_MS .. ")" },
    },
    required = { "id" },
  },
  async = true,
  handler = function(args, respond, ctx)
    local task = find(args, ctx)
    local timeout = tonumber(args.timeout_ms) or DEFAULT_TIMEOUT_MS
    TaskStore.wait(task.id, timeout, function(t, timed_out)
      if timed_out then
        respond(render(t) .. ("\n\n(still running after %dms; it continues in the background)"):format(timeout))
      else
        respond(render(t))
      end
    end)
  end,
}

---------------------------------------------------------------------------
-- task_kill
---------------------------------------------------------------------------

M.kill = {
  description = "Kill a running task: SIGTERM to its process group, SIGKILL if it does not exit.",
  inputSchema = { type = "object", properties = ID_PROP, required = { "id" } },
  handler = function(args, ctx)
    local task = find(args, ctx)
    local ok, err = TaskStore.kill(task.id)
    if not ok then
      error(err, 0)
    end
    return stamp(task, ("sent SIGTERM to task %d's process group; SIGKILL follows in %ds if it does not exit. Use weave_task_wait to confirm."):format(
      task.id, math.floor(TaskStore._sigkill_ms / 1000)
    ))
  end,
}

-- Compact task summaries; output remains available through task_status.
M.list = {
  description = "List managed tasks, newest first. Defaults to running tasks and at most 10 results. "
    .. "Use status=all for every state, failed for non-zero exits or killed tasks, "
    .. "or successful for tasks that exited with code 0. Output is available via weave_task_status.",
  inputSchema = {
    type = "object",
    properties = {
      status = {
        type = "string",
        enum = { "running", "all", "failed", "successful" },
        default = "running",
        description = "Task outcome filter (default running); failed includes killed tasks.",
      },
      limit = {
        type = "integer",
        minimum = 1,
        default = 10,
        description = "Maximum matching tasks returned (default 10), newest first.",
      },
    },
  },
  handler = function(args, ctx)
    local status = args.status or "running"
    if status ~= "running" and status ~= "all" and status ~= "failed" and status ~= "successful" then
      error("status must be running, all, failed, or successful", 0)
    end
    local limit = args.limit == nil and 10 or args.limit
    if type(limit) ~= "number" or limit ~= limit or limit == math.huge or limit < 1 or limit % 1 ~= 0 then
      error("limit must be a positive integer", 0)
    end
    local tasks, rows, matched = TaskStore.list(), {}, 0
    for i = #tasks, 1, -1 do
      local task = tasks[i]
      local successful = task.status == "exited" and task.exit_code == 0
      local failed = task.status == "killed"
        or (task.status == "exited" and task.exit_code ~= nil and task.exit_code ~= 0)
      if visible(task, ctx) and (status == "all" or (status == "running" and task.status == "running")
        or (status == "successful" and successful) or (status == "failed" and failed)) then
        matched = matched + 1
        if #rows < limit then
          rows[#rows + 1] = status_line(task) .. "\ncommand: " .. task.command .. "\ncwd: " .. task.cwd
        end
      end
    end
    if matched == 0 then
      return "No matching tasks (status: " .. status .. ")."
    end
    return ("Showing %d of %d matching tasks (status: %s, newest first)\n\n"):format(#rows, matched, status)
      .. table.concat(rows, "\n\n")
  end,
}

return M
