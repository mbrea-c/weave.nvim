-- The task store's spawn goes through Sandbox.wrap_shell on EVERY start
-- (design-agent-sandbox-v2.md, phase D): with sandboxing off the argv is
-- plain `sh -c`, with it on the task runs bwrap'd under the active preset's
-- hull. The wrap itself is pinned in sandbox_spec; here we pin the seam.

local Sandbox = require("weave.sandbox")
local Store = require("weave.task_store")

describe("task store sandbox seam", function()
  local real_wrap_shell = Sandbox.wrap_shell

  after_each(function()
    Sandbox.wrap_shell = real_wrap_shell
    Store._reset()
  end)

  it("every spawn consults wrap_shell and runs what it returns", function()
    local seen
    Sandbox.wrap_shell = function(command)
      seen = command
      return "sh", { "-c", "echo WRAPPED-" .. command }
    end
    local task = assert(Store.start({ command = "hello" }))
    vim.wait(4000, function()
      return Store.get(task.id).status ~= "running"
    end, 10)
    assert.equal("hello", seen)
    assert.truthy(Store.stdout_text(Store.get(task.id)):find("WRAPPED-hello", 1, true))
  end)
end)
