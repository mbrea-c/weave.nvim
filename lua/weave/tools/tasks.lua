-- The task lifecycle tools (task_start/task_status/task_wait/task_kill): the
-- execute interface from design-agent-sandbox.md, as thin MCP defs over
-- weave.task_store. Blocking start and wait are ASYNC clankbox tools, so the
-- user's editor never freezes while an agent waits on a command; the store
-- fires waiter callbacks on the main loop, which is where respond must run.

local TaskStore = require("weave.task_store")

local M = {}

local DEFAULT_TIMEOUT_MS = 120000
local MAX_STREAM_BYTES = 30000

local ID_PROP = { id = { type = "integer", description = "Task id, as returned by task_start" } }

local function tail(text)
  if #text <= MAX_STREAM_BYTES then
    return text
  end
  return ("(truncated: showing last %d of %d bytes)\n"):format(MAX_STREAM_BYTES, #text)
    .. text:sub(#text - MAX_STREAM_BYTES + 1)
end

local function status_line(task)
  if task.status == "running" then
    return ("task %d: running (pid %d)"):format(task.id, task.pid)
  elseif task.status == "killed" then
    return ("task %d: killed (signal %d)"):format(task.id, task.signal or 0)
  end
  return ("task %d: exited (code %d)"):format(task.id, task.exit_code or 0)
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

local function find(args)
  local id = tonumber(args.id)
  local task = id and TaskStore.get(id)
  if not task then
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
    "follow up with task_status / task_wait / task_kill.",
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
  handler = function(args, respond)
    local task, err = TaskStore.start({ command = args.command, cwd = args.cwd })
    if not task then
      error(err, 0)
    end
    if not args.blocking then
      respond(
        ("task %d started (pid %d): %s\ncheck it with task_status, block on it with task_wait, stop it with task_kill"):format(
          task.id,
          task.pid,
          task.command
        )
      )
      return
    end
    local timeout = tonumber(args.timeout_ms) or DEFAULT_TIMEOUT_MS
    TaskStore.wait(task.id, timeout, function(t, timed_out)
      if timed_out then
        respond(
          render(t)
            .. ("\n\n(still running after %dms; it continues in the background: task_status / task_wait / task_kill with id %d)"):format(
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
  handler = function(args)
    return render(find(args))
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
  handler = function(args, respond)
    local task = find(args)
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
  handler = function(args)
    local task = find(args)
    local ok, err = TaskStore.kill(task.id)
    if not ok then
      error(err, 0)
    end
    return ("sent SIGTERM to task %d's process group; SIGKILL follows in %ds if it does not exit. Use task_wait to confirm."):format(
      task.id,
      math.floor(TaskStore._sigkill_ms / 1000)
    )
  end,
}

return M
