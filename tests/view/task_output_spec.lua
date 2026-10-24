local mount = require("fibrous.inline.mount")
local Tasks = require("weave.task_store")
local Store = require("weave.session_store")
local ToolCall = require("weave.view.tool_call")
local Renderer = require("weave.view.renderers.task")

local function buffers()
  local found = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].weave_task_stream then
      found[vim.b[buf].weave_task_stream] = buf
    end
  end
  return found
end

local function contents(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

describe("separate expanded task streams", function()
  before_each(function() Tasks._reset(); ToolCall.reset(); Renderer.install() end)
  after_each(function() Tasks._reset(); ToolCall.reset() end)

  it("mounts separate read-only stdout/stderr buffers only while expanded", function()
    local task = assert(Tasks.start({ command = "printf stdout-marker; printf stderr-marker >&2" }))
    assert.is_true(vim.wait(5000, function() return task.status ~= "running" end, 10))
    local store = Store:new()
    task.owner = { get_store = function() return store end }
    store:upsert_tool_call({ tool_call_id = "output", kind = "execute", status = "completed",
      mcp = { server = "clankbox", tool = "weave_task_start" }, input = { command = task.command },
      body = { ("task %d exited (code 0) [weave task: %s]"):format(task.id, task.receipt) } })
    local app = mount.floating(require("weave.view.transcript").Transcript,
      { store = store, prefs = require("weave.view.prefs"):new() }, { width = 80, height = 26, mode = "scroll" })
    assert.same({}, buffers())
    store:toggle_tool_call("output")
    local streams = buffers()
    local ok = streams.stdout and streams.stderr
    if not ok then app.unmount() end
    assert.truthy(ok)
    assert.equal("stdout-marker", contents(streams.stdout))
    assert.equal("stderr-marker", contents(streams.stderr))
    assert.is_false(vim.bo[streams.stdout].modifiable)
    assert.is_false(vim.bo[streams.stderr].modifiable)
    local text = contents(app.bufnr)
    assert.truthy(text:find("╭", 1, true))
    assert.truthy(text:find("stdout", 1, true))
    assert.truthy(text:find("stderr", 1, true))
    assert.falsy(text:find("[out]", 1, true))
    store:toggle_tool_call("output")
    assert.same({}, buffers())
    assert.is_false(vim.api.nvim_buf_is_valid(streams.stdout))
    assert.is_false(vim.api.nvim_buf_is_valid(streams.stderr))
    app.unmount()
  end)

  it("separates explicitly identified recorded streams without guessing a live task", function()
    local app = mount.floating(Renderer.Body, { expanded = true, block = {
      kind = "execute", input = { command = "old command" },
      output = { stdout = "recorded out", stderr = "recorded err" },
    } }, { width = 60, height = 20, mode = "scroll" })
    local streams = buffers()
    local ok = streams.stdout and streams.stderr
    if not ok then app.unmount() end
    assert.truthy(ok)
    assert.equal("recorded out", contents(streams.stdout))
    assert.equal("recorded err", contents(streams.stderr))
    app.unmount()
  end)

  it("labels unseparated historical output honestly and retains more than 80 lines", function()
    local text = ("recorded output\n"):rep(100)
    local app = mount.floating(Renderer.Body, { expanded = true, block = {
      kind = "execute", input = { command = "old command" }, body = { text },
    } }, { width = 60, height = 20, mode = "scroll" })
    local streams = buffers()
    local ok = streams["recorded result"] ~= nil
    if not ok then app.unmount() end
    assert.is_true(ok)
    assert.is_nil(streams.stdout)
    assert.is_nil(streams.stderr)
    assert.equal(text, contents(streams["recorded result"]))
    app.unmount()
  end)

  it("keeps raw tool inspection available inside a stream buffer", function()
    local block = { kind = "execute", tool_call_id = "inspect-stream", input = { command = "printf original" },
      output = { stdout = "shown output" }, meta = { marker = "RAW_TOOL_ONLY" } }
    local app = mount.floating(Renderer.Body, { expanded = true, block = block },
      { width = 60, height = 20, mode = "scroll" })
    local maps = vim.api.nvim_buf_get_keymap(buffers().stdout, "n")
    local peek
    for _, map in ipairs(maps) do if map.lhs == "K" then peek = map.callback end end
    local Peek, seen = require("weave.view.peek"), nil
    local original = Peek.open
    Peek.open = function(text, title, ft) seen = { vim.json.decode(text), title, ft } end
    if peek then peek() end
    Peek.open = original
    app.unmount()
    assert.is_not_nil(peek)
    assert.same(block, seen[1])
    assert.equal("json", seen[3])
  end)

  it("does not expose another session's streams", function()
    local task = assert(Tasks.start({ command = "printf private-output" }))
    assert.is_true(vim.wait(5000, function() return task.status ~= "running" end, 10))
    task.owner = { get_store = function() return Store:new() end }
    local app = mount.floating(Renderer.Body, { expanded = true, store = Store:new(), block = {
      mcp = { server = "clankbox", tool = "weave_task_status" }, input = { id = task.id },
      body = { ("task %d exited (code 0) [weave task: %s]"):format(task.id, task.receipt) },
    } }, { width = 60, height = 20, mode = "scroll" })
    local streams = buffers()
    assert.is_nil(streams.stdout)
    assert.is_nil(streams.stderr)
    app.unmount()
  end)
end)

describe("incremental task output buffers", function()
  local created
  before_each(function() created = {} end)
  after_each(function() for _, value in ipairs(created) do value:destroy() end end)
  local function new(stream)
    local value = require("weave.view.task_output").new(stream or "stdout")
    created[#created + 1] = value
    return value
  end

  it("retains history beyond the old preview tail and joins partial chunks", function()
    local value, chunks = new(), {}
    for i = 1, 120 do chunks[i] = "line " .. i .. "\n" end
    value:append(chunks)
    chunks[#chunks + 1] = "partial"
    value:append(chunks)
    chunks[#chunks + 1] = "-line"
    value:append(chunks)
    assert.equal(table.concat(chunks), contents(value.bufnr))
    assert.equal(121, value:line_count())
  end)

  it("does not rewrite previously rendered output when a new chunk arrives", function()
    local value, chunks = new(), { ("history\n"):rep(1000) }
    value:append(chunks)
    local changes = {}
    vim.api.nvim_buf_attach(value.bufnr, false, { on_lines = function(_, _, _, first, last)
      changes[#changes + 1] = { first, last }
    end })
    chunks[2] = "latest"
    value:append(chunks)
    assert.same({ { 1000, 1001 } }, changes)
  end)

  it("handles ANSI and UTF-8 sequences split across output callbacks", function()
    local value, chunks = new(), { "first\27[3" }
    value:append(chunks)
    assert.equal("first", contents(value.bufnr))
    chunks[2] = "1mred\27[0m \231\149"
    value:append(chunks)
    chunks[3] = "\140"
    value:append(chunks)
    assert.equal("firstred 界", contents(value.bufnr))
  end)

  it("does not accumulate unfinished ANSI parameters indefinitely", function()
    local value, chunks = new(), { "before\27[" }
    value:append(chunks)
    for i = 1, 20 do
      chunks[#chunks + 1] = ("1"):rep(1000)
      value:append(chunks)
    end
    assert.is_true(#value.pending <= 4)
    chunks[#chunks + 1] = "mafter"
    value:append(chunks)
    assert.equal("beforeafter", contents(value.bufnr))
  end)

  it("clears old content if the recorded source is replaced", function()
    local value = new()
    value:append({ "old stream" })
    value:append({ "new stream" })
    assert.equal("new stream", contents(value.bufnr))
  end)

  it("appends without readonly warnings", function()
    local value = new()
    vim.cmd("messages clear")
    value:append({ "new output" })
    local messages = vim.api.nvim_exec2("messages", { output = true }).output
    assert.falsy(messages:find("W10", 1, true))
  end)

  it("hides empty streams without allocating a sub-buffer", function()
    local app = mount.floating(require("weave.view.task_output").Pane, { stream = "stdout", chunks = {} },
      { width = 60, height = 20, mode = "scroll" })
    assert.same({}, buffers())
    app.unmount()
  end)
end)

describe("task output appearance", function()
  it("derives a darker background and preserves explicit highlight overrides", function()
    require("weave.view.task_output")
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local original = vim.api.nvim_get_hl(0, { name = "WeaveTaskOutput", link = false })
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xeeeeee, bg = 0x303030 })
    vim.api.nvim_set_hl(0, "WeaveTaskOutput", {})
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    local derived = vim.api.nvim_get_hl(0, { name = "WeaveTaskOutput", link = false })
    vim.api.nvim_set_hl(0, "WeaveTaskOutput", { bg = 0x112233 })
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    local overridden = vim.api.nvim_get_hl(0, { name = "WeaveTaskOutput", link = false })
    vim.api.nvim_set_hl(0, "Normal", normal)
    vim.api.nvim_set_hl(0, "WeaveTaskOutput", original)
    assert.is_true(derived.bg and derived.bg < 0x303030)
    assert.equal(0x112233, overridden.bg)
  end)
end)
