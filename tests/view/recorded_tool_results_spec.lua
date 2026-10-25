local mount = require("fibrous.inline.mount")
local Store = require("weave.session_store")
local TaskStore = require("weave.task_store")
local Tasks = require("weave.tools.tasks")
local TaskView = require("weave.view.renderers.task")
local Fs = require("weave.tools.fs")
local FsView = require("weave.view.renderers.fs_diff")
local Diff = require("weave.view.diff").Diff
local C = require("weave.view.renderers.common")

local function text(result)
  return type(result) == "string" and result or result.content[1].text
end
local function block(tool, input, output)
  return { tool_call_id = "recorded", status = "completed", kind = "other",
    mcp = { server = "clankbox", tool = "weave_" .. tool }, input = input or {}, output = output }
end
local function streams()
  local found = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_is_valid(buf) and vim.b[buf].weave_task_stream
    if name then found[name] = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
  end
  return found
end
local function find(node, component)
  if node.comp == component then return node end
  for _, child in ipairs(node.children or {}) do local result = find(child, component); if result then return result end end
end

describe("recorded task results use the real tool format", function()
  after_each(function() TaskStore._reset() end)

  for _, body_only in ipairs({ false, true }) do
    it("separates actual task reports without a live task (" .. (body_only and "ACP content body" or "MCP result") .. ")", function()
      local task = assert(TaskStore.start({ command = "printf 'actual out'; printf 'actual err' >&2" }))
      assert.is_true(vim.wait(5000, function() return task.status ~= "running" end, 10))
      local result = Tasks.status.handler({ id = task.id })
      TaskStore._reset()
      local call = block("task_status", { id = task.id }, body_only and nil or result)
      if body_only then call.output, call.body = nil, { text(result) } end
      local app = mount.floating(TaskView.Details, { block = call, store = Store:new(), expanded = true },
        { width = 90, height = 26, mode = "scroll" })
      local shown = streams()
      local transcript = table.concat(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false), "\n")
      app.unmount()
      assert.equal("actual out", shown.stdout)
      assert.equal("actual err", shown.stderr)
      assert.is_nil(shown["recorded result"])
      assert.truthy(transcript:find("printf 'actual out'", 1, true))
    end)
  end

  it("handles the legacy report shape, hiding genuinely empty stderr", function()
    local output = 'task 45: exited (code 0)\ncommand: printf instructions\n\n--- stdout ---\n"## Weave\\n\\nUse weave tools.\\n"\n\n\n--- stderr ---\n(empty)'
    local call = block("task_status", { id = 45 }, output)
    local app = mount.floating(TaskView.Body, { block = call, store = Store:new(), expanded = true },
      { width = 80, height = 20, mode = "scroll" })
    local shown = streams()
    app.unmount()
    assert.equal('"## Weave\\n\\nUse weave tools.\\n"\n', shown.stdout)
    assert.is_nil(shown.stderr)
    assert.is_nil(shown["recorded result"])
  end)

  it("keeps ambiguous legacy text intact instead of losing or mislabeling output", function()
    local output = "task 45: exited (code 0)\ncommand: echo markers\n\n--- stdout ---\nfirst\n\n--- stderr ---\nprinted marker\n\n--- stderr ---\nreal stderr"
    local app = mount.floating(TaskView.Body, { block = block("task_status", {}, output), expanded = true },
      { width = 80, height = 20, mode = "scroll" })
    local shown = streams()
    app.unmount()
    assert.equal(output, shown["recorded result"])
    assert.is_nil(shown.stdout)
  end)

  it("does not put timeout metadata into a stderr pane", function()
    local output = "task 45: running (pid 123)\ncommand: sleep 5\n\n--- stdout ---\n(empty)\n\n--- stderr ---\n(empty)\n\n(still running after 100ms; it continues in the background)"
    local app = mount.floating(TaskView.Body, { block = block("task_wait", {}, output), expanded = true },
      { width = 80, height = 20, mode = "scroll" })
    local shown = streams()
    local transcript = table.concat(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false), "\n")
    app.unmount()
    assert.is_nil(shown.stderr)
    assert.is_nil(shown["recorded result"])
    assert.truthy(transcript:find("still running after 100ms", 1, true))
  end)

  it("emits explicit stream fields and keeps literal empty/delimiter text unambiguous", function()
    local task = assert(TaskStore.start({ command = "printf '(empty)'; printf '\\n\\n--- stdout ---\\n' >&2" }))
    assert.is_true(vim.wait(5000, function() return task.status ~= "running" end, 10))
    local result = Tasks.status.handler({ id = task.id })
    assert.equal("table", type(result))
    assert.equal("(empty)", result.structuredContent.stdout)
    assert.equal("\n\n--- stdout ---\n", result.structuredContent.stderr)
    assert.equal(task.command, result.structuredContent.command)
    assert.equal(task.cwd, result.structuredContent.cwd)
    TaskStore._reset()
    local app = mount.floating(TaskView.Body, { block = block("task_status", {}, result), expanded = true },
      { width = 80, height = 20, mode = "scroll" })
    local shown = streams()
    app.unmount()
    assert.equal("(empty)", shown.stdout)
    assert.equal("\n\n--- stdout ---\n", shown.stderr)
  end)
end)

describe("write previews without in-memory snapshots", function()
  local paths
  before_each(function() paths = {} end)
  after_each(function() for _, path in ipairs(paths) do vim.fn.delete(path) end end)

  it("retains confirmed creation in the actual write response across snapshot loss", function()
    local path, store = vim.fn.tempname(), Store:new()
    paths[#paths + 1] = path
    local input = { path = path, content = "new first line\nnew second line\n" }
    local ctx = { caller = { session = { get_store = function() return store end } } }
    local result = Fs.write.handler(input, ctx)
    store:reset()
    local call = block("write", input, result)
    local entry = FsView.write.render({}, { block = call, store = store, expanded = true })
    local body = entry.props.render_body({}, entry.props)
    local diff = find(body, Diff)
    assert.is_not_nil(diff)
    assert.same({}, diff.props.old)
    assert.same({ "new first line", "new second line" }, diff.props.new)
  end)

  it("shows complete content for unknown historical writes without inventing old content", function()
    local input = { path = "/historical/file.lua", content = "local value = 1\nreturn value\n" }
    for _, expanded in ipairs({ false, true }) do
      local entry = FsView.write.render({}, { block = block("write", input, "wrote 2 lines to /historical/file.lua"),
        store = Store:new(), expanded = expanded })
      local body = entry.props.render_body({}, entry.props)
      local code = find(body, C.Code)
      assert.is_not_nil(code)
      assert.is_nil(find(body, Diff))
      assert.equal("local value = 1\nreturn value\n", code.props.code)
      if expanded then assert.is_nil(code.props.max_lines) else assert.equal(60, code.props.max_lines) end
    end
  end)

  it("does not mark overwrites as file creation", function()
    local path, store = vim.fn.tempname(), Store:new()
    paths[#paths + 1] = path
    vim.fn.writefile({ "before" }, path)
    local input = { path = path, content = "after" }
    local result = Fs.write.handler(input, { caller = { session = { get_store = function() return store end } } })
    store:reset()
    local entry = FsView.write.render({}, { block = block("write", input, result), store = store, expanded = true })
    local body = entry.props.render_body({}, entry.props)
    assert.is_nil(find(body, Diff))
    assert.equal("after", find(body, C.Code).props.code)
  end)

  it("does not turn failed or pending writes into applied creation diffs", function()
    for _, status in ipairs({ "pending", "failed" }) do
      local call = block("write", { path = "/a", content = "requested" }, "failure")
      call.status = status
      local entry = FsView.write.render({}, { block = call, store = Store:new(), expanded = true })
      local body = entry.props.render_body({}, entry.props)
      assert.is_nil(find(body, Diff))
      assert.equal("requested", find(body, C.Code).props.code)
    end
  end)
end)
