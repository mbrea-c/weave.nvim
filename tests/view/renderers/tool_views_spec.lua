local ui = require("fibrous.inline.components")
local ToolCall = require("weave.view.tool_call")
local Store = require("weave.session_store")
local Fs = require("weave.tools.fs")
local Snapshots = require("weave.tools.write_snapshots")

local function block(name, input, result)
  return { tool_call_id = "call1", kind = "other", status = "completed",
    mcp = { server = "clankbox", tool = "weave_" .. name },
    input = input or {}, body = result and { result } or nil }
end

local function context()
  local ref = {}
  return { use_ref = function() return ref end }
end

local function collect(tree, predicate, out)
  out = out or {}
  if type(tree) ~= "table" then return out end
  if predicate(tree) then out[#out + 1] = tree end
  for _, child in ipairs(tree.children or {}) do collect(child, predicate, out) end
  return out
end

local function text_of(tree)
  local out = {}
  collect(tree, function(node)
    local p = node.props or {}
    if type(p.text) == "string" then out[#out + 1] = p.text end
    if type(p.label) == "string" then out[#out + 1] = p.label end
    if type(p.code) == "string" then out[#out + 1] = p.code end
    return false
  end)
  return table.concat(out, "\n")
end

describe("expanded tool views", function()
  it("uncaps native diffs when expanded", function()
    local tree = ToolCall.Body({}, { block = { diff = { old = { "a" }, new = { "b" } } }, expanded = true })
    local diffs = collect(tree, function(node) return node.comp == require("weave.view.diff").Diff end)
    assert.equal(1, #diffs)
    assert.is_nil(diffs[1].props.max_lines)
  end)

  it("uncaps MCP edit diffs and replaces duplicate raw metadata", function()
    local spec = require("weave.view.renderers.fs_diff").edit
    local entry = spec.render(context(), { block = block("edit", { path = "/a.lua", old_string = "a", new_string = "b" }),
      expanded = true, show_diff = true })
    local body = entry.props.render_body({}, entry.props)
    local diffs = collect(body, function(node) return node.comp == require("weave.view.diff").Diff end)
    assert.is_nil(diffs[1].props.max_lines)
    assert.is_not_nil(entry.props.render_metadata)
    assert.is_nil(entry.props.render_metadata({}, entry.props))
  end)

  it("retains exact changes for repeated writes, loaded buffers, and relative paths", function()
    local store = Store:new()
    local ctx = { caller = { session = { get_store = function() return store end } } }
    local path = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "disk" }, path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
    local cwd = vim.fn.getcwd()
    vim.api.nvim_set_current_dir(vim.fn.fnamemodify(path, ":h"))
    local input = { path = "./" .. vim.fn.fnamemodify(path, ":t"), content = "first\n" }
    local first = Fs.write.handler(input, ctx)
    local second = Fs.write.handler(input, ctx)
    vim.api.nvim_set_current_dir(cwd)
    for i = 1, Snapshots.LIMIT + 2 do Snapshots.capture("/tmp/other" .. i, "new") end
    local a = Snapshots.for_call(block("write", input, first), store)
    local b = Snapshots.for_call(block("write", input, second), store)
    assert.same({ "unsaved" }, a.old)
    assert.same({ "first" }, b.old)
    assert.same({ "first" }, a.new)
    assert.is_nil(Snapshots.for_call(block("write", input, first), Store:new()))
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(path)
  end)

  it("captures scratch-buffer writes and clears retained changes on conversation reset", function()
    local store = Store:new()
    local ctx = { caller = { session = { get_store = function() return store end } } }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "scratch before" })
    local input = { buffer = buf, content = "scratch after" }
    local result = Fs.write.handler(input, ctx)
    local call = block("write", input, result)
    assert.same({ "scratch before" }, Snapshots.for_call(call, store).old)
    store:reset()
    assert.is_nil(Snapshots.for_call(call, store))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("captures the whole replace-all operation, including edits through a buffer target", function()
    local store = Store:new()
    local ctx = { caller = { session = { get_store = function() return store end } } }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "between", "one" })
    local input = { buffer = buf, old_string = "one", new_string = "two", replace_all = true }
    local result = Fs.edit.handler(input, ctx)
    local recorded = Snapshots.for_call(block("edit", input, result), store)
    assert.same({ "one", "between", "one" }, recorded.old)
    assert.same({ "two", "between", "two" }, recorded.new)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("bounds direct-Lua receipts even when managed writes interleave", function()
    Snapshots.reset()
    local store = Store:new()
    local ctx = { caller = { session = { get_store = function() return store end } } }
    local first = Snapshots.record(nil, { "old" }, { "new" }, {})
    for _ = 1, Snapshots.LIMIT + 1 do
      Snapshots.record(ctx, { "old" }, { "new" }, {})
      Snapshots.record(ctx, { "old" }, { "new" }, {})
      Snapshots.record(nil, { "old" }, { "new" }, {})
    end
    assert.is_nil(Snapshots.for_call({ body = { first } }))
  end)

  it("uses editor-qualified change receipts so restored history cannot collide", function()
    local store = Store:new()
    local ctx = { caller = { session = { get_store = function() return store end } } }
    local receipt = Snapshots.record(ctx, { "old" }, { "new" }, { path = "/tmp/a" })
    assert.truthy(receipt:match("weave change: %x+%-%d+"))
    assert.is_nil(Snapshots.for_call({ body = { "[weave change: previous-editor-1]" } }, store))
  end)

  it("keeps a provider's standard ACP diff when no local change receipt is available", function()
    local call = block("write", { path = "/a", content = "new" })
    call.diff = { old = { "provider before" }, new = { "provider after" } }
    local spec = require("weave.view.renderers.fs_diff").write
    local entry = spec.render(context(), { block = call, store = Store:new(), expanded = true })
    local body = entry.props.render_body({}, entry.props)
    local diff = collect(body, function(node) return node.comp == require("weave.view.diff").Diff end)[1]
    assert.is_not_nil(diff)
    assert.same({ "provider before" }, diff.props.old)
    assert.same({ "provider after" }, diff.props.new)
    assert.is_nil(diff.props.max_lines)
  end)

  it("never guesses an unknown write's old content", function()
    local spec = require("weave.view.renderers.fs_diff").write
    assert.is_true(spec.match(block("write", { path = "/a", content = "new" })))
    local entry = spec.render(context(), { block = block("write", { path = "/a", content = "new" }), expanded = true })
    local body = entry.props.render_body({}, entry.props)
    assert.truthy(text_of(body):find("unavailable", 1, true))
  end)

  it("renders a read page as code at the recorded line, preserving truncation", function()
    local renderer = require("weave.view.renderers.read")
    local call = block("read", { path = "/a.lua", offset = 20 }, "20\tlocal a = 1\n21\treturn a\n(truncated: lines 20-21 of 60; continue with offset=22)")
    local entry = renderer.Render(context(), { block = call, expanded = true })
    local body = entry.props.render_body({}, entry.props)
    local code = collect(body, function(node) return node.comp == require("weave.view.renderers.common").Code end)[1]
    assert.equal("local a = 1\nreturn a", code.props.code)
    assert.equal(20, code.props.start_line)
    assert.truthy(text_of(body):find("offset=22", 1, true))
    assert.is_nil(entry.props.render_metadata({}, entry.props))
  end)

  it("groups numbered grep matches with safe locations and keeps context", function()
    local renderer = require("weave.view.renderers.search")
    local call = block("grep", { output_mode = "content", ["-n"] = true },
      "/tmp/a.lua:12:match: with colon\n/tmp/a.lua-13-context line\n/tmp/b.lua:2:other")
    local entry = renderer.Render(context(), { block = call, expanded = true })
    local body = entry.props.render_body({}, entry.props)
    local buttons = collect(body, function(node) return node.comp == ui.button end)
    assert.equal(3, #buttons)
    assert.truthy(text_of(body):find("context line", 1, true))
    assert.truthy(text_of(body):find("match: with colon", 1, true))
  end)

  it("does not invent line numbers for an unnumbered grep result", function()
    local renderer = require("weave.view.renderers.search")
    local entry = renderer.Render(context(), { block = block("grep", { output_mode = "content" }, "/tmp/a:hello"), expanded = true })
    local body = entry.props.render_body({}, entry.props)
    assert.equal(0, #collect(body, function(node) return node.comp == ui.button end))
    assert.truthy(text_of(body):find("Line numbers unavailable", 1, true))
  end)

  it("renders glob results as file controls", function()
    local renderer = require("weave.view.renderers.search")
    local entry = renderer.Render(context(), { block = block("glob", {}, "/tmp/a\n/tmp/b"), expanded = true })
    assert.equal(2, #collect(entry.props.render_body({}, entry.props), function(node) return node.comp == ui.button end))
  end)

  it("renders LSP locations, containers, and each client's independent status", function()
    local renderer = require("weave.view.renderers.lsp")
    local payload = { status = "partial", total = 1, offset = 0, partial = true, filtered = true,
      clients = { { name = "jdtls", state = "initializing", status = "not_requested" },
        { name = "other", state = "ready", status = "ok" } },
      items = { { path = "/tmp/a", name = "method", container = "Class", range_available = true,
        range = { start = { line = 10, column = 2 } }, selection_range = { start = { line = 11, column = 3 } } } } }
    local entry = renderer.Render(context(), { block = block("document_symbols", {}, vim.json.encode(payload)), expanded = true })
    local body = entry.props.render_body({}, entry.props)
    assert.truthy(text_of(body):find("Class", 1, true))
    assert.truthy(text_of(body):find("11:3", 1, true))
    assert.truthy(text_of(body):find("jdtls", 1, true))
    assert.truthy(text_of(body):find("initializing", 1, true))
    assert.truthy(text_of(body):find("permissions", 1, true))
  end)

  it("renders unresolved workspace symbols without fake navigation", function()
    local renderer = require("weave.view.renderers.lsp")
    local payload = { status = "ok", items = { { name = "unresolved", path = "/tmp/a", range_available = false, range = vim.NIL } } }
    local entry = renderer.Render(context(), { block = block("workspace_symbols", {}, vim.json.encode(payload)), expanded = true })
    local body = entry.props.render_body({}, entry.props)
    assert.equal(0, #collect(body, function(node) return node.comp == ui.button end))
    assert.truthy(text_of(body):find("unresolved", 1, true))
  end)

  it("renders hover markdown without treating plaintext as markdown", function()
    local renderer = require("weave.view.renderers.lsp")
    local payload = { status = "ok", items = { { text = "**markdown**", format = "markdown" },
      { text = "*literal*", format = "plaintext" } } }
    local entry = renderer.Render(context(), { block = block("hover", {}, vim.json.encode(payload)), expanded = true })
    local body = entry.props.render_body({}, entry.props)
    assert.equal(1, #collect(body, function(node) return node.comp == ui.markdown end))
    assert.truthy(text_of(body):find("*literal*", 1, true))
  end)

  it("renders subagent snapshots and bounded returned assistant output", function()
    local renderer = require("weave.view.renderers.subagent")
    local payload = { subagent_id = 3, run_id = 7, status = "running", output = "assistant response", has_more = true, next_cursor = 99 }
    local entry = renderer.Render(context(), { block = block("subagent_read", {}, vim.json.encode(payload)), expanded = true })
    local body = entry.props.render_body({}, entry.props)
    assert.truthy(text_of(body):find("assistant response", 1, true))
    assert.truthy(text_of(body):find("running", 1, true))
    assert.truthy(text_of(body):find("99", 1, true))
    assert.is_nil(entry.props.render_metadata({}, entry.props))
  end)

  it("gives the new views meaningful target/session titles", function()
    assert.equal("/project/a.lua", ToolCall.tool_title(block("document_symbols", { path = "/project/a.lua" })))
    assert.equal("Widget", ToolCall.tool_title(block("workspace_symbols", { query = "Widget" })))
    assert.equal("subagent 3 / run 7", ToolCall.tool_title(block("subagent_read", { subagent_id = 3, run_id = 7 })))
    assert.equal("Reviewer", ToolCall.tool_title(block("subagent_create", { name = "Reviewer", prompt = "Review" })))
    assert.equal("buffer 12", ToolCall.tool_title(block("write", { buffer = 12 })))
  end)

  it("installs all new own-tool renderers without claiming foreign MCP tools", function()
    require("weave").setup({})
    for _, name in ipairs({ "write", "read", "glob", "grep", "task_start", "task_status", "task_wait", "task_kill",
      "task_list", "document_symbols", "workspace_symbols", "definition", "references", "hover",
      "subagent_create", "subagent_list", "subagent_send", "subagent_read", "subagent_wait", "subagent_cancel", "subagent_close" }) do
      assert.is_not_nil(ToolCall.resolve(block(name)))
      local foreign = block(name)
      foreign.mcp.server = "foreign"
      assert.is_nil(ToolCall.resolve(foreign))
    end
  end)
end)
