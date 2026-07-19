-- weave's fs tools reach the agent over MCP, which strips the two things the
-- builtin diff rendering keys on: a tool name and `kind == "edit"`. These
-- renderers put the diff back by duck-typing rawInput.

local FsDiff = require("weave.view.renderers.fs_diff")
local Snapshots = require("weave.tools.write_snapshots")
local ToolCall = require("weave.view.tool_call")

local function block(input)
  return { tool_call_id = "tc1", kind = "other", status = "completed", input = input }
end

--- The diff props the renderer ends up handing weave.view.diff, by walking
--- the Entry override it returns.
local function body_props(spec, props)
  local entry = spec.render({
    use_ref = function()
      return {}
    end,
  }, props)
  return entry.props.render_body()
end

describe("fs diff renderers", function()
  before_each(function()
    Snapshots.reset()
    ToolCall.reset()
  end)

  describe("edit", function()
    local input = { path = "/tmp/a.lua", old_string = "local a = 1", new_string = "local a = 2" }

    it("claims an edit-shaped call", function()
      assert.is_true(FsDiff.edit.match(block(input)))
    end)

    it("ignores calls missing either side of the diff", function()
      assert.is_false(FsDiff.edit.match(block({ path = "/tmp/a.lua", content = "x" })))
      assert.is_false(FsDiff.edit.match(block({ path = "/tmp/a.lua", old_string = "x" })))
      assert.is_false(FsDiff.edit.match(block({})))
      assert.is_false(FsDiff.edit.match({ tool_call_id = "tc1" }))
    end)

    it("diffs the two rawInput sides", function()
      local body = body_props(FsDiff.edit, { block = block(input), show_diff = true })
      assert.same({ "local a = 1" }, body.props.old)
      assert.same({ "local a = 2" }, body.props.new)
    end)

    it("draws nothing when the show_diffs pref is off", function()
      assert.is_nil(body_props(FsDiff.edit, { block = block(input), show_diff = false }))
    end)
  end)

  describe("write", function()
    local path = "/tmp/w.lua"
    local input = { path = path, content = "one\ntwo\n" }

    it("claims a write only once its pre-write snapshot exists", function()
      assert.is_false(FsDiff.write.match(block(input)))
      Snapshots.capture(path, "one\ntwo\n")
      assert.is_true(FsDiff.write.match(block(input)))
    end)

    -- Without the old side there is nothing honest to draw: diffing against
    -- an empty file would claim the agent added the whole file.
    it("declines a write whose snapshot was evicted, leaving the builtin rendering", function()
      Snapshots.capture(path, "different content")
      assert.is_false(FsDiff.write.match(block(input)))
    end)

    it("diffs the snapshot against the written content", function()
      vim.fn.writefile({ "one" }, path)
      Snapshots.capture(path, "one\ntwo\n")
      local body = body_props(FsDiff.write, { block = block(input), show_diff = true })
      assert.same({ "one" }, body.props.old)
      assert.same({ "one", "two" }, body.props.new)
      vim.fn.delete(path)
    end)
  end)

  it("installs both renderers so Dispatch resolves them", function()
    FsDiff.install()
    local spec = ToolCall.resolve(block({ path = "/x", old_string = "a", new_string = "b" }))
    assert.is_not_nil(spec)
    assert.equal("weave.fs.edit", spec.name)
  end)
end)
