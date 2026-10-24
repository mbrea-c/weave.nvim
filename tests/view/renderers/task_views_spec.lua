local Tasks = require("weave.task_store")
local Renderer = require("weave.view.renderers.task")
local Store = require("weave.session_store")

local function call(id, command)
  return { tool_call_id = "task1", kind = "other", status = "completed",
    mcp = { server = "clankbox", tool = "weave_task_start" }, input = { command = command },
    body = id and { "task " .. id .. " started (pid 1)"
      .. (Tasks.get(id) and (" [weave task: " .. Tasks.get(id).receipt .. "]") or "") } or nil }
end

describe("safe managed task views", function()
  before_each(function() Tasks._reset() end)
  after_each(function() Tasks._reset() end)

  it("never correlates tasks by command, including duplicate commands", function()
    assert(Tasks.start({ command = "sleep 5" }))
    assert(Tasks.start({ command = "sleep 5" }))
    assert.is_nil(Renderer.task_for(call(nil, "sleep 5")))
  end)

  it("uses Kiro body results to identify the exact task", function()
    local task = assert(Tasks.start({ command = "sleep 5" }))
    assert.equal(task.id, Renderer.task_for(call(task.id, task.command)).id)
  end)

  it("does not expose a task from a sibling session or a revoked conversation", function()
    local own, sibling = Store:new(), Store:new()
    local valid = true
    local owner = { get_store = function() return own end, permissions = function()
      return { current_mode = function() return "off" end }
    end }
    local task = assert(Tasks.start({ command = "sleep 5", context = {
      caller = { session = owner, valid = function() return valid end } } }))
    local block = call(task.id, task.command)
    assert.is_nil(Renderer.task_for(block, sibling))
    assert.equal(task.id, Renderer.task_for(block, own).id)
    valid = false
    assert.is_nil(Renderer.task_for(block, own))
  end)

  it("does not attach a historical result with a different editor receipt", function()
    local store = Store:new()
    local owner = { get_store = function() return store end, permissions = function()
      return { current_mode = function() return "off" end }
    end }
    local task = assert(Tasks.start({ command = "sleep 5", context = {
      caller = { session = owner, valid = function() return true end } } }))
    local old = call(task.id, task.command)
    old.body[1] = "task " .. task.id .. " started (pid 1) [weave task: previous-editor-" .. task.id .. "]"
    assert.is_nil(Renderer.task_for(old, store))
  end)

  it("records the observed interleaving of stdout and stderr, including partial chunks", function()
    local task = assert(Tasks.start({ command = "printf first; sleep 0.03; printf error >&2; sleep 0.03; printf last" }))
    assert.is_true(vim.wait(5000, function() return task.status ~= "running" end, 10))
    assert.is_not_nil(task.events)
    local merged = {}
    for _, event in ipairs(task.events) do merged[#merged + 1] = event.stream .. ":" .. event.text end
    assert.equal("stdout:first|stderr:error|stdout:last", table.concat(merged, "|"))
  end)

  it("expands to a shell code snippet and omits raw argument dumps", function()
    local entry = Renderer.Render({}, { block = call(nil, "printf 'hello'\nprintf 'world'"), expanded = true })
    local tree = entry.props.render_metadata({}, entry.props)
    local function find(node)
      if node.comp == require("weave.view.renderers.common").Code then return node end
      for _, child in ipairs(node.children or {}) do local found = find(child); if found then return found end end
    end
    local code = find(tree)
    assert.is_not_nil(code)
    assert.equal("bash", code.props.lang)
    assert.equal("Shell command (bash)", code.props.title)
    assert.equal("printf 'hello'\nprintf 'world'", code.props.code)
  end)
end)
