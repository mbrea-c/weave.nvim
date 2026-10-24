local Output = require("weave.tool_output")
local Common = require("weave.view.renderers.common")
local Search = require("weave.view.renderers.search")
local Tasks = require("weave.view.renderers.task")
local ui = require("fibrous.inline.components")
local function context()
  local ref = {}
  return { use_ref = function() return ref end }
end
local function walk(node, comp, out)
  out = out or {}
  if node.comp == comp then out[#out + 1] = node end
  for _, child in ipairs(node.children or {}) do walk(child, comp, out) end
  return out
end

describe("tool result presentation safety", function()
  it("recognizes errors inside provider result envelopes", function()
    assert.is_true(Output.failed({ output = { result = { isError = true, content = { { type = "text", text = "no" } } } } }))
  end)

  it("bounds cyclic envelopes and oversized body results", function()
    local cyclic = {}; cyclic.result = cyclic
    assert.is_nil(Output.text({ output = cyclic }))
    assert.is_nil(Output.json({ output = cyclic }, function() return false end))
    assert.is_nil(Output.text({ body = { ("x"):rep(Output.MAX_BYTES + 1) } }))
  end)

  it("caches decoding across expansion without mutating the original payload", function()
    local ctx, count = context(), 0
    local block = { output = { content = { { type = "text", text = "recorded" } } } }
    local before = vim.deepcopy(block)
    local parse = function(value) count = count + 1; return Output.text(value) end
    assert.equal("recorded", Common.cached(ctx, block, parse))
    assert.equal("recorded", Common.cached(ctx, block, parse))
    assert.equal(1, count)
    assert.same(before, block)
  end)

  it("does not assign a misleading location when text has ambiguous numbered separators", function()
    local entry = Search.Render(context(), { expanded = true, block = {
      tool_call_id = "s", status = "completed", mcp = { server = "clankbox", tool = "weave_grep" },
      input = { output_mode = "content", ["-n"] = true },
      body = { "/tmp/name:12:file.lua:3:source" },
    } })
    assert.equal(0, #walk(entry.props.render_body({}, entry.props), ui.button))
  end)

  it("formats provider-native execute calls but does not treat foreign MCP commands as managed tasks", function()
    assert.is_true(Tasks.match({ kind = "execute", input = { command = "echo hi" } }))
    assert.is_false(Tasks.match({ kind = "execute", input = { command = "echo hi" },
      mcp = { server = "other", tool = "shell" } }))
  end)

  it("keeps partial stdout chunks together rather than dropping the beginning", function()
    local events = {}
    for i = 1, 20 do events[#events + 1] = { stream = "stdout", text = tostring(i) .. "," } end
    events[#events + 1] = { stream = "stdout", text = "\n" }
    local rows, omitted = Tasks.tail({ events = events }, 8)
    assert.equal("1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,", rows[1].text)
    assert.is_false(omitted)
  end)

  it("announces truncation when a single output line exceeds the byte budget", function()
    local rows, omitted = Tasks.tail({ events = { { stream = "stdout", text = ("x"):rep(70000) } } }, 8)
    assert.equal(65536, #rows[1].text)
    assert.is_true(omitted)
  end)

  it("renders wrapped source with separate logical-line gutters", function()
    local tree = Common.Code(context(), { code = "long source line\nnext", start_line = 20 })
    local rows = walk(tree, ui.row)
    assert.equal(2, #rows)
    assert.equal("20", rows[1].children[1].props.text)
    assert.equal("21", rows[2].children[1].props.text)
    assert.equal("char", rows[1].children[2].props.wrap)
  end)
end)
