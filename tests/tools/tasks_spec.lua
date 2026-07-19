-- The execute task API (design-agent-sandbox.md, phase 0): the editor-global
-- task store spawning real `sh -c` processes under this nvim, and the
-- task_start/task_status/task_wait/task_kill tool defs over it. Tool handlers
-- are exercised directly (the async ones with a captured respond), so no
-- clankbox is needed here.

local TaskStore = require("weave.task_store")
local Tools = require("weave.tools.tasks")

--- Pump until the task leaves "running" (or ms elapse).
local function wait_done(task, ms)
  vim.wait(ms or 5000, function()
    return task.status ~= "running"
  end, 10)
  return task
end

local function process_alive(pid)
  return vim.uv.kill(pid, 0) == 0
end

describe("task store", function()
  before_each(function()
    TaskStore._reset()
  end)

  after_each(function()
    TaskStore._reset()
  end)

  it("runs a command and captures stdout and the exit code", function()
    local task = assert(TaskStore.start({ command = "echo hi" }))
    assert.equal("running", task.status)
    wait_done(task)
    assert.equal("exited", task.status)
    assert.equal(0, task.exit_code)
    assert.equal("hi\n", TaskStore.stdout_text(task))
    assert.equal("", TaskStore.stderr_text(task))
    assert.is_not_nil(task.finished_at)
  end)

  it("captures stderr and non-zero exit codes", function()
    local task = assert(TaskStore.start({ command = "echo oops >&2; exit 3" }))
    wait_done(task)
    assert.equal("exited", task.status)
    assert.equal(3, task.exit_code)
    assert.equal("oops\n", TaskStore.stderr_text(task))
    assert.equal("", TaskStore.stdout_text(task))
  end)

  it("list keeps start order and get finds by id", function()
    local a = assert(TaskStore.start({ command = "echo a" }))
    local b = assert(TaskStore.start({ command = "echo b" }))
    local ids = {}
    for _, t in ipairs(TaskStore.list()) do
      ids[#ids + 1] = t.id
    end
    assert.same({ a.id, b.id }, ids)
    assert.equal("echo b", TaskStore.get(b.id).command)
    assert.is_nil(TaskStore.get(999))
  end)

  it("kill ends a running task and its whole process group", function()
    -- the task prints its CHILD's pid, so we can check the group died too
    local task = assert(TaskStore.start({ command = "sleep 30 & echo $!; wait" }))
    vim.wait(5000, function()
      return TaskStore.stdout_text(task):find("\n") ~= nil
    end, 10)
    local child_pid = tonumber(TaskStore.stdout_text(task):match("%d+"))
    assert.is_not_nil(child_pid)

    assert.is_true(TaskStore.kill(task.id))
    wait_done(task)
    assert.equal("killed", task.status)
    assert.equal(15, task.signal)
    vim.wait(3000, function()
      return not process_alive(child_pid)
    end, 10)
    assert.is_false(process_alive(child_pid))
  end)

  it("escalates to SIGKILL when the group ignores SIGTERM", function()
    TaskStore._sigkill_ms = 200
    local task = assert(TaskStore.start({ command = "trap '' TERM; echo ready; while true; do sleep 1; done" }))
    -- only kill once the trap is provably installed, or TERM wins the race
    vim.wait(5000, function()
      return TaskStore.stdout_text(task):find("ready") ~= nil
    end, 10)
    assert.is_true(TaskStore.kill(task.id))
    wait_done(task, 5000)
    assert.equal("killed", task.status)
    assert.equal(9, task.signal)
  end)

  it("kill on a finished task reports instead of throwing", function()
    local task = assert(TaskStore.start({ command = "echo done" }))
    wait_done(task)
    local ok, err = TaskStore.kill(task.id)
    assert.is_nil(ok)
    assert.truthy(err:find("already exited"))
  end)

  it("wait fires on completion, and immediately for finished tasks", function()
    local task = assert(TaskStore.start({ command = "echo done" }))
    local got, got_timed_out
    TaskStore.wait(task.id, nil, function(t, timed_out)
      got, got_timed_out = t, timed_out
    end)
    vim.wait(5000, function()
      return got ~= nil
    end, 10)
    assert.equal(task.id, got.id)
    assert.is_false(got_timed_out)

    local again
    TaskStore.wait(task.id, nil, function(t)
      again = t
    end)
    vim.wait(1000, function()
      return again ~= nil
    end, 10)
    assert.equal(task.id, again.id)
  end)

  it("wait can time out without ending the task", function()
    local task = assert(TaskStore.start({ command = "sleep 5" }))
    local got, got_timed_out
    TaskStore.wait(task.id, 100, function(t, timed_out)
      got, got_timed_out = t, timed_out
    end)
    vim.wait(3000, function()
      return got ~= nil
    end, 10)
    assert.is_true(got_timed_out)
    assert.equal("running", task.status)
    TaskStore.kill(task.id)
    wait_done(task)
  end)

  it("a background grandchild holding the pipes does not stall completion", function()
    TaskStore._linger_ms = 200
    local task = assert(TaskStore.start({ command = "sleep 2 & echo hi" }))
    local t0 = vim.uv.hrtime()
    wait_done(task, 3000)
    local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
    assert.equal("exited", task.status)
    assert.truthy(TaskStore.stdout_text(task):find("hi"))
    assert.is_true(elapsed_ms < 1500)
  end)

  it("spawn failures report instead of throwing", function()
    local task, err = TaskStore.start({ command = "echo x", cwd = "/nonexistent/dir/for/weave/tests" })
    assert.is_nil(task)
    assert.truthy(err:find("failed to start task"))
  end)

  it("subscribers hear lifecycle changes until they unsubscribe", function()
    local count = 0
    local unsub = TaskStore.subscribe(function()
      count = count + 1
    end)
    local task = assert(TaskStore.start({ command = "echo ping" }))
    wait_done(task)
    vim.wait(1000, function()
      return count > 0
    end, 10)
    assert.is_true(count > 0)

    unsub()
    local before = count
    local task2 = assert(TaskStore.start({ command = "echo pong" }))
    wait_done(task2)
    vim.wait(200, function()
      return false
    end, 50)
    assert.equal(before, count)
  end)
end)

describe("task tools", function()
  before_each(function()
    TaskStore._reset()
  end)

  after_each(function()
    TaskStore._reset()
  end)

  local function capture()
    local box = {}
    return function(ret)
      box.ret = ret
    end, box
  end

  it("task_start returns the id immediately without blocking", function()
    assert.is_true(Tools.start.async)
    local respond, box = capture()
    Tools.start.handler({ command = "sleep 5" }, respond)
    assert.is_not_nil(box.ret)
    local id = tonumber(box.ret:match("task (%d+) started"))
    assert.is_not_nil(id)
    local task = TaskStore.get(id)
    assert.equal("running", task.status)
    TaskStore.kill(id)
    wait_done(task)
  end)

  it("blocking task_start responds with the final report", function()
    local respond, box = capture()
    Tools.start.handler({ command = "echo bloop", blocking = true }, respond)
    vim.wait(5000, function()
      return box.ret ~= nil
    end, 10)
    assert.truthy(box.ret:find("exited (code 0)", 1, true))
    assert.truthy(box.ret:find("bloop", 1, true))
  end)

  it("blocking task_start reports a timeout and leaves the task running", function()
    local respond, box = capture()
    Tools.start.handler({ command = "sleep 5", blocking = true, timeout_ms = 100 }, respond)
    vim.wait(3000, function()
      return box.ret ~= nil
    end, 10)
    assert.truthy(box.ret:find("still running", 1, true))
    local id = tonumber(box.ret:match("task (%d+)"))
    assert.equal("running", TaskStore.get(id).status)
    TaskStore.kill(id)
    wait_done(TaskStore.get(id))
  end)

  it("task_status reports state and output so far", function()
    local task = assert(TaskStore.start({ command = "echo now; sleep 5" }))
    vim.wait(5000, function()
      return TaskStore.stdout_text(task) ~= ""
    end, 10)
    local report = Tools.status.handler({ id = task.id })
    assert.truthy(report:find("running", 1, true))
    assert.truthy(report:find("now", 1, true))
    TaskStore.kill(task.id)
    wait_done(task)
  end)

  it("unknown ids error", function()
    assert.has_error(function()
      Tools.status.handler({ id = 99 })
    end, "no task with id 99")
  end)

  it("task_wait responds when the task exits", function()
    assert.is_true(Tools.wait.async)
    local task = assert(TaskStore.start({ command = "sleep 0.2; echo waited" }))
    local respond, box = capture()
    Tools.wait.handler({ id = task.id }, respond)
    vim.wait(5000, function()
      return box.ret ~= nil
    end, 10)
    assert.truthy(box.ret:find("exited (code 0)", 1, true))
    assert.truthy(box.ret:find("waited", 1, true))
  end)

  it("task_kill terminates and reports the escalation contract", function()
    local task = assert(TaskStore.start({ command = "sleep 5" }))
    local ret = Tools.kill.handler({ id = task.id })
    assert.truthy(ret:find("SIGTERM", 1, true))
    wait_done(task)
    assert.equal("killed", task.status)
  end)
end)
