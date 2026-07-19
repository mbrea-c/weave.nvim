-- Editor-global task store: every shell task an agent starts runs under THIS
-- nvim via uv.spawn, with weave owning the stdio streams. The agent tools
-- (weave.tools.tasks) and the task UI observe the same lifecycle here,
-- including completed and killed tasks — see design-agent-sandbox.md in the
-- superproject, phase 0.
--
-- Tasks run `sh -c command` in their own process group (detached), so kill()
-- reaches the whole tree, and a VimLeavePre hook takes running tasks down
-- with the editor.

local M = {}

local DEFAULT_LINGER_MS = 500
local DEFAULT_SIGKILL_MS = 3000

-- test hooks: _reset() restores both
M._linger_ms = DEFAULT_LINGER_MS
M._sigkill_ms = DEFAULT_SIGKILL_MS

--- @class weave.Task
--- @field id integer
--- @field command string shell command line (run via sh -c)
--- @field cwd string
--- @field pid integer
--- @field status "running"|"exited"|"killed"
--- @field exit_code integer|nil
--- @field signal integer|nil non-zero when a signal ended the task
--- @field stdout string[] output chunks in arrival order (stdout_text concats)
--- @field stderr string[]
--- @field started_at integer os.time()
--- @field finished_at integer|nil

--- @type table<integer, weave.Task>
local tasks = {}
--- @type integer[]
local order = {}
local next_id = 1
local subscribers = {}
-- runtime bookkeeping kept off the task (uv handles, timers, waiters)
local handles = {}
local cleanup_installed = false
local notify_scheduled = false

-- Coalesced change signal: subscribers re-read whatever they render.
local function notify()
  if notify_scheduled then
    return
  end
  notify_scheduled = true
  vim.schedule(function()
    notify_scheduled = false
    local snapshot = { unpack(subscribers) }
    for _, fn in ipairs(snapshot) do
      pcall(fn)
    end
  end)
end

local function close_timer(t)
  if t and not t:is_closing() then
    t:stop()
    t:close()
  end
end

--- Signal the task's process group (negative pid); fall back to the direct
--- process handle if the group is already gone.
local function send_signal(task, h, sig)
  local ok, res = pcall(vim.uv.kill, -task.pid, sig)
  if (not ok or res ~= 0) and h.proc and not h.proc:is_closing() then
    pcall(h.proc.kill, h.proc, sig)
  end
end

--- Settle a task exactly once: record the outcome, fire waiters, notify.
--- Reached when exit + both stream EOFs arrived, or from the linger timer
--- when a grandchild holds the pipes open past exit.
local function finalize(id)
  local task, h = tasks[id], handles[id]
  if not task or task.status ~= "running" then
    return
  end
  task.exit_code = h.exit_code
  task.signal = h.exit_signal
  task.status = (h.kill_requested or (h.exit_signal or 0) ~= 0) and "killed" or "exited"
  task.finished_at = os.time()
  close_timer(h.linger)
  h.linger = nil
  close_timer(h.sigkill)
  h.sigkill = nil
  for _, w in ipairs(h.waiters) do
    if not w.done then
      w.done = true
      close_timer(w.timer)
      vim.schedule(function()
        w.cb(task, false)
      end)
    end
  end
  h.waiters = {}
  notify()
end

--- Kill every running task's group outright (editor shutdown, _reset).
function M._kill_all()
  for _, id in ipairs(order) do
    local task = tasks[id]
    if task.status == "running" then
      handles[id].kill_requested = true
      send_signal(task, handles[id], "sigkill")
    end
  end
end

--- Start a task.
--- @param opts { command: string, cwd?: string }
--- @return weave.Task|nil task, string|nil err
function M.start(opts)
  opts = opts or {}
  if type(opts.command) ~= "string" or opts.command == "" then
    return nil, "command must be a non-empty string"
  end
  local cwd = opts.cwd or vim.fn.getcwd()
  local id = next_id
  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()
  local h = { stdout = stdout, stderr = stderr, waiters = {}, open = 3 }
  local function dec()
    h.open = h.open - 1
    if h.open <= 0 then
      finalize(id)
    end
  end

  local sok, proc, pid = pcall(vim.uv.spawn, "sh", {
    args = { "-c", opts.command },
    cwd = cwd,
    stdio = { nil, stdout, stderr },
    detached = true, -- own process group, so kill() reaches descendants
  }, function(code, signal)
    h.exit_code, h.exit_signal = code, signal
    if h.proc and not h.proc:is_closing() then
      h.proc:close()
    end
    dec()
    if tasks[id] and tasks[id].status == "running" then
      -- grandchildren may inherit our pipes and never close them; don't let
      -- that stall completion past a short grace for trailing output
      h.linger = vim.uv.new_timer()
      h.linger:start(M._linger_ms, 0, function()
        finalize(id)
      end)
    end
  end)
  if not sok or not proc then
    for _, p in ipairs({ stdout, stderr }) do
      if not p:is_closing() then
        p:close()
      end
    end
    return nil, "failed to start task: " .. tostring(sok and pid or proc)
  end
  h.proc = proc

  --- @type weave.Task
  local task = {
    id = id,
    command = opts.command,
    cwd = cwd,
    pid = pid,
    status = "running",
    stdout = {},
    stderr = {},
    started_at = os.time(),
  }
  tasks[id] = task
  handles[id] = h
  order[#order + 1] = id
  next_id = id + 1

  local function read_into(pipe, chunks)
    local ended = false
    pipe:read_start(function(_err, chunk)
      if chunk then
        chunks[#chunks + 1] = chunk
        notify()
      elseif not ended then
        ended = true
        if not pipe:is_closing() then
          pipe:close()
        end
        dec()
      end
    end)
  end
  read_into(stdout, task.stdout)
  read_into(stderr, task.stderr)

  if not cleanup_installed then
    cleanup_installed = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        M._kill_all()
      end,
    })
  end

  notify()
  return task
end

--- @param id integer
--- @return weave.Task|nil
function M.get(id)
  return tasks[id]
end

--- Every task ever started (running, exited, killed), in start order.
--- @return weave.Task[]
function M.list()
  local out = {}
  for _, id in ipairs(order) do
    out[#out + 1] = tasks[id]
  end
  return out
end

function M.stdout_text(task)
  return table.concat(task.stdout)
end

function M.stderr_text(task)
  return table.concat(task.stderr)
end

--- SIGTERM the task's process group now; SIGKILL after _sigkill_ms if it is
--- still running.
--- @param id integer
--- @return boolean|nil ok, string|nil err
function M.kill(id)
  local task = tasks[id]
  if not task then
    return nil, ("no task with id %s"):format(tostring(id))
  end
  if task.status ~= "running" then
    return nil, ("task %d already %s"):format(id, task.status)
  end
  local h = handles[id]
  h.kill_requested = true
  send_signal(task, h, "sigterm")
  if not h.sigkill then
    h.sigkill = vim.uv.new_timer()
    h.sigkill:start(M._sigkill_ms, 0, function()
      if task.status == "running" then
        send_signal(task, h, "sigkill")
      end
    end)
  end
  notify()
  return true
end

--- Call cb(task, timed_out) when the task settles, immediately (scheduled)
--- if it already has, or with timed_out=true after timeout_ms while it still
--- runs. cb always fires on the main loop.
--- @param id integer
--- @param timeout_ms integer|nil nil = wait forever
--- @param cb fun(task: weave.Task, timed_out: boolean)
--- @return boolean|nil ok, string|nil err
function M.wait(id, timeout_ms, cb)
  local task = tasks[id]
  if not task then
    return nil, ("no task with id %s"):format(tostring(id))
  end
  if task.status ~= "running" then
    vim.schedule(function()
      cb(task, false)
    end)
    return true
  end
  local h = handles[id]
  local w = { cb = cb }
  h.waiters[#h.waiters + 1] = w
  if timeout_ms and timeout_ms > 0 then
    w.timer = vim.uv.new_timer()
    w.timer:start(timeout_ms, 0, function()
      if w.done then
        return
      end
      w.done = true
      close_timer(w.timer)
      vim.schedule(function()
        cb(task, true)
      end)
    end)
  end
  return true
end

--- @param fn fun() called (coalesced, scheduled) on any task change
--- @return fun() unsubscribe
function M.subscribe(fn)
  subscribers[#subscribers + 1] = fn
  return function()
    for i, f in ipairs(subscribers) do
      if f == fn then
        table.remove(subscribers, i)
        return
      end
    end
  end
end

-- test hook: kill stragglers, drop all state, restore default timings
function M._reset()
  M._kill_all()
  for _, id in ipairs(order) do
    local h = handles[id]
    close_timer(h.linger)
    close_timer(h.sigkill)
    for _, w in ipairs(h.waiters) do
      close_timer(w.timer)
    end
    for _, p in ipairs({ h.stdout, h.stderr }) do
      if p and not p:is_closing() then
        p:close()
      end
    end
    if h.proc and not h.proc:is_closing() then
      h.proc:close()
    end
  end
  tasks, order, handles, subscribers = {}, {}, {}, {}
  next_id = 1
  M._linger_ms = DEFAULT_LINGER_MS
  M._sigkill_ms = DEFAULT_SIGKILL_MS
end

return M
