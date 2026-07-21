-- Tool-call rendering and the override registry (weave.view.tool_call).
--
-- The contract under test, in one line each:
--   * `Entry` is parameterized by render_header / render_body / render_metadata,
--     defaulting to the builtins — so a partial override is COMPOSITION
--     (delegate to Entry, swap one) and a total override is just not delegating;
--   * `match` is a predicate over the wire block, because ACP tool calls carry
--     no tool name (see the identity note in tool_call.lua);
--   * precedence is priority-first, newest-registered on ties, since plugin
--     load order is not something anyone controls;
--   * anything that fails — no match, a throwing matcher — falls through to
--     the builtin rendering silently.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local Prefs = require("weave.view.prefs")
local SessionStore = require("weave.session_store")
local Theme = require("weave.view.theme")
local ToolCall = require("weave.view.tool_call")
local ToolIdent = require("weave.tool_ident")
local transcript = require("weave.view.transcript")

local function trimmed(bufnr)
  local out = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    out[i] = (l:gsub("%s+$", ""))
  end
  return out
end

local function mount_transcript(store)
  return mount.floating(
    transcript.Transcript,
    { store = store, prefs = Prefs:new() },
    { width = 60, height = 20, mode = "scroll" }
  )
end

local function header(status, kind, title, expanded)
  local chevron = expanded and Theme.CHEVRON.expanded or Theme.CHEVRON.collapsed
  return chevron .. " " .. Theme.STATUS_ICON[status] .. " " .. Theme.KIND_ICON[kind] .. "[" .. kind .. "] " .. title
end

--- A subrenderer/renderer that emits one identifiable line.
local function labeller(text)
  return function(_, props)
    return { comp = ui.label, props = { text = text .. ":" .. (props.block.tool_call_id or "?") } }
  end
end

local function kind_is(kind)
  return function(block)
    return block.kind == kind
  end
end

local function an_execute_call(store, id)
  store:upsert_tool_call({
    tool_call_id = id or "t1",
    kind = "execute",
    argument = "ls",
    status = "completed",
    input = { cmd = "ls -la" },
  })
  return store
end

describe("view.tool_call registry", function()
  before_each(function()
    ToolCall.reset()
  end)
  after_each(function()
    ToolCall.reset()
  end)

  it("resolves nothing when no renderer is registered", function()
    assert.is_nil(ToolCall.resolve({ tool_call_id = "t1", kind = "execute" }))
  end)

  it("matches on a predicate over the whole block", function()
    ToolCall.register({
      name = "tasks",
      match = function(block)
        return block.input ~= nil and block.input.cmd ~= nil
      end,
      render = labeller("task"),
    })
    assert.truthy(ToolCall.resolve({ tool_call_id = "t1", input = { cmd = "ls" } }))
    assert.is_nil(ToolCall.resolve({ tool_call_id = "t2", input = { path = "a" } }))
  end)

  it("re-registering the same name replaces rather than stacks", function()
    ToolCall.register({ name = "x", match = kind_is("edit"), render = labeller("a") })
    ToolCall.register({ name = "x", match = kind_is("edit"), render = labeller("b") })
    assert.equal(1, #ToolCall.list())
  end)

  it("unregister removes by name", function()
    ToolCall.register({ name = "x", match = kind_is("edit"), render = labeller("a") })
    ToolCall.unregister("x")
    assert.is_nil(ToolCall.resolve({ kind = "edit" }))
  end)

  it("rejects a spec missing name, match, or render", function()
    assert.has_error(function()
      ToolCall.register({ match = kind_is("edit"), render = labeller("a") })
    end)
    assert.has_error(function()
      ToolCall.register({ name = "x", render = labeller("a") })
    end)
    assert.has_error(function()
      ToolCall.register({ name = "x", match = kind_is("edit") })
    end)
  end)

  it("rejects a string match: ACP carries no tool name, so predicates only", function()
    assert.has_error(function()
      ToolCall.register({ name = "x", match = "edit", render = labeller("a") })
    end)
  end)
end)

-- Registration order is decided by plugin load order, which nobody controls.
-- Priority is the escape hatch that makes precedence deterministic.
describe("view.tool_call precedence", function()
  before_each(function()
    ToolCall.reset()
  end)
  after_each(function()
    ToolCall.reset()
  end)

  it("takes the highest priority, regardless of registration order", function()
    ToolCall.register({ name = "low", match = kind_is("edit"), render = labeller("low"), priority = 1 })
    ToolCall.register({ name = "high", match = kind_is("edit"), render = labeller("high"), priority = 10 })
    assert.equal("high", ToolCall.resolve({ kind = "edit" }).name)

    -- and the same holds when the winner registered FIRST
    ToolCall.reset()
    ToolCall.register({ name = "high", match = kind_is("edit"), render = labeller("high"), priority = 10 })
    ToolCall.register({ name = "low", match = kind_is("edit"), render = labeller("low"), priority = 1 })
    assert.equal("high", ToolCall.resolve({ kind = "edit" }).name)
  end)

  it("breaks ties on most-recently-registered", function()
    ToolCall.register({ name = "first", match = kind_is("edit"), render = labeller("first") })
    ToolCall.register({ name = "second", match = kind_is("edit"), render = labeller("second") })
    assert.equal("second", ToolCall.resolve({ kind = "edit" }).name)
  end)

  it("defaults priority to 0, so a negative one yields to an unprioritized renderer", function()
    ToolCall.register({ name = "builtin", match = kind_is("edit"), render = labeller("builtin") })
    ToolCall.register({ name = "polite", match = kind_is("edit"), render = labeller("polite"), priority = -10 })
    assert.equal("builtin", ToolCall.resolve({ kind = "edit" }).name)
  end)

  it("a higher-priority renderer that does NOT match yields to a lower one that does", function()
    ToolCall.register({ name = "low", match = kind_is("edit"), render = labeller("low"), priority = 1 })
    ToolCall.register({ name = "high", match = kind_is("execute"), render = labeller("high"), priority = 10 })
    assert.equal("low", ToolCall.resolve({ kind = "edit" }).name)
  end)

  -- A matcher that throws is a config bug in an extension point; it must not
  -- take the transcript down or block a well-behaved renderer behind it.
  it("skips a throwing matcher silently and keeps resolving the rest", function()
    ToolCall.register({
      name = "bad",
      match = function()
        error("boom")
      end,
      render = labeller("never"),
      priority = 100,
    })
    assert.is_nil(ToolCall.resolve({ kind = "execute" }))

    ToolCall.register({ name = "good", match = kind_is("edit"), render = labeller("good") })
    assert.equal("good", ToolCall.resolve({ kind = "edit" }).name)
  end)
end)

describe("view.tool_call Entry subrenderers", function()
  before_each(function()
    ToolCall.reset()
  end)
  after_each(function()
    ToolCall.reset()
  end)

  it("renders the builtin header/body/metadata when nothing is registered", function()
    local store = an_execute_call(SessionStore:new())
    local handle = mount_transcript(store)

    assert.same({ header("completed", "execute", "ls") }, trimmed(handle.bufnr))
    store:toggle_tool_call("t1")
    assert.same({
      header("completed", "execute", "ls", true),
      "    kind: execute",
      "    status: completed",
      "    input:",
      "    │ {",
      '    │   cmd = "ls -la"',
      "    │ }",
    }, trimmed(handle.bufnr))
    handle.unmount()
  end)

  -- The headline case: swap ONE subrenderer, keep everything else.
  it("swapping render_body keeps the builtin header and metadata", function()
    ToolCall.register({
      name = "custom",
      match = kind_is("execute"),
      render = function(_, props)
        return { comp = ToolCall.Entry, props = vim.tbl_extend("force", props, { render_body = labeller("body") }) }
      end,
    })
    local store = an_execute_call(SessionStore:new())
    local handle = mount_transcript(store)

    assert.same({ header("completed", "execute", "ls"), "body:t1" }, trimmed(handle.bufnr))

    -- the body stays visible when expanded, with builtin metadata BELOW it:
    -- expand means "show me more", never "show me something else"
    store:toggle_tool_call("t1")
    local lines = trimmed(handle.bufnr)
    assert.equal(header("completed", "execute", "ls", true), lines[1])
    assert.equal("body:t1", lines[2])
    assert.equal("    kind: execute", lines[3])
    handle.unmount()
  end)

  it("swapping render_header keeps the builtin body", function()
    ToolCall.register({
      name = "custom",
      match = kind_is("edit"),
      render = function(_, props)
        return { comp = ToolCall.Entry, props = vim.tbl_extend("force", props, { render_header = labeller("head") }) }
      end,
    })
    local store = SessionStore:new()
    store:upsert_tool_call({
      tool_call_id = "e1",
      kind = "edit",
      file_path = "a.lua",
      status = "completed",
      diff = { old = { "local a = 1" }, new = { "local a = 2" } },
    })
    local handle = mount_transcript(store)

    -- our header, but the builtin diff body is untouched
    assert.same({ "head:e1", "    @@ -1 +1 @@", "    -local a = 1", "    +local a = 2" }, trimmed(handle.bufnr))
    handle.unmount()
  end)

  it("swapping render_metadata changes only what expand reveals", function()
    ToolCall.register({
      name = "custom",
      match = kind_is("execute"),
      render = function(_, props)
        return { comp = ToolCall.Entry, props = vim.tbl_extend("force", props, { render_metadata = labeller("meta") }) }
      end,
    })
    local store = an_execute_call(SessionStore:new())
    local handle = mount_transcript(store)

    assert.same({ header("completed", "execute", "ls") }, trimmed(handle.bufnr))
    store:toggle_tool_call("t1")
    assert.same({ header("completed", "execute", "ls", true), "meta:t1" }, trimmed(handle.bufnr))
    handle.unmount()
  end)

  -- Not delegating to Entry IS the total override. There is no flag for it.
  it("a renderer that ignores Entry owns the whole entry, header included", function()
    ToolCall.register({
      name = "full",
      match = kind_is("execute"),
      render = function(_, props)
        return { comp = ui.label, props = { text = "TAKEOVER " .. props.block.argument } }
      end,
    })
    local handle = mount_transcript(an_execute_call(SessionStore:new()))
    assert.same({ "TAKEOVER ls" }, trimmed(handle.bufnr))
    handle.unmount()
  end)

  it("a custom body replaces the builtin diff preview for edits", function()
    ToolCall.register({
      name = "custom",
      match = kind_is("edit"),
      render = function(_, props)
        return { comp = ToolCall.Entry, props = vim.tbl_extend("force", props, { render_body = labeller("mine") }) }
      end,
    })
    local store = SessionStore:new()
    store:upsert_tool_call({
      tool_call_id = "e1",
      kind = "edit",
      file_path = "a.lua",
      status = "completed",
      diff = { old = { "local a = 1" }, new = { "local a = 2" } },
    })
    local handle = mount_transcript(store)

    assert.same({ header("completed", "edit", "a.lua"), "mine:e1" }, trimmed(handle.bufnr))
    handle.unmount()
  end)

  -- Why `render` (and each subrenderer) is a component and not a
  -- "return me some lines" function: a live view needs hooks. This drives a
  -- re-render from renderer-owned state to prove ctx is a real fibrous ctx.
  it("gives subrenderers a real component ctx (hooks work, state re-renders)", function()
    local bump
    ToolCall.register({
      name = "stateful",
      match = kind_is("execute"),
      render = function(_, props)
        return {
          comp = ToolCall.Entry,
          props = vim.tbl_extend("force", props, {
            render_body = function(ctx)
              local n = ctx.use_state(0)
              bump = function()
                n.set(n.get() + 1)
              end
              return { comp = ui.label, props = { text = "count " .. n.get() } }
            end,
          }),
        }
      end,
    })
    local handle = mount_transcript(an_execute_call(SessionStore:new()))

    assert.equal("count 0", trimmed(handle.bufnr)[2])
    bump()
    assert.equal("count 1", trimmed(handle.bufnr)[2])
    handle.unmount()
  end)

  it("contains a throwing renderer to its own entry", function()
    ToolCall.register({
      name = "bad",
      match = kind_is("execute"),
      render = function()
        error("kaboom")
      end,
    })
    local store = an_execute_call(SessionStore:new())
    store:append_streaming_text("agent", "still here")
    local handle = mount_transcript(store)

    local lines = trimmed(handle.bufnr)
    assert.truthy(lines[1]:find("bad", 1, true))
    assert.truthy(lines[1]:find("renderer", 1, true))
    assert.equal("still here", lines[#lines])
    handle.unmount()
  end)
end)

-- weave's own clankbox tools carry no tool name on the wire, but the gate
-- records `args -> name` (weave.tool_ident) so the header can tag them apart
-- from the agent's builtins.
describe("view.tool_call weave-tool tag", function()
  before_each(function()
    ToolCall.reset()
    ToolIdent.reset()
  end)
  after_each(function()
    ToolCall.reset()
    ToolIdent.reset()
  end)

  it("tags a recognised weave clankbox call `w:<tool>` in the header", function()
    local input = { path = "a.lua", old_string = "x", new_string = "y" }
    ToolIdent.record("edit", input)
    local store = SessionStore:new()
    store:upsert_tool_call({
      tool_call_id = "e1",
      kind = "other", -- the provider's kind; the w: tag must win over it
      argument = "editing a.lua",
      status = "completed",
      input = input,
    })
    local handle = mount_transcript(store)
    local first = trimmed(handle.bufnr)[1]
    assert.truthy(first:find("[w:edit]", 1, true))
    assert.is_nil(first:find("[other]", 1, true))
    handle.unmount()
  end)

  it("leaves an unrecognised (builtin) call showing its ACP kind", function()
    local store = an_execute_call(SessionStore:new())
    local handle = mount_transcript(store)
    local first = trimmed(handle.bufnr)[1]
    assert.truthy(first:find("[execute]", 1, true))
    assert.is_nil(first:find("[w:", 1, true))
    handle.unmount()
  end)
end)

-- The MCP endpoint name ("mcp__clankbox__read") is a useless title next to the
-- `[w:read]` tag, so a weave tool's header shows its meaningful argument
-- instead: the path, the command, the pattern.
describe("view.tool_call weave-tool title", function()
  it("titles read/write/edit with the file path", function()
    assert.equal("a/b.lua", ToolCall.weave_title("read", { path = "a/b.lua" }))
    assert.equal("a/b.lua", ToolCall.weave_title("write", { path = "a/b.lua", content = "x" }))
    assert.equal("a/b.lua", ToolCall.weave_title("edit", { path = "a/b.lua", old_string = "x", new_string = "y" }))
  end)

  it("titles task_start with the command", function()
    assert.equal("ls -la", ToolCall.weave_title("task_start", { command = "ls -la" }))
  end)

  it("titles grep/glob with the pattern, glob naming its root", function()
    assert.equal("TODO", ToolCall.weave_title("grep", { pattern = "TODO" }))
    assert.equal("*.lua", ToolCall.weave_title("glob", { pattern = "*.lua" }))
    assert.equal("*.lua in src", ToolCall.weave_title("glob", { pattern = "*.lua", path = "src" }))
  end)

  it("titles task_status/wait/kill with the id", function()
    assert.equal("task 7", ToolCall.weave_title("task_status", { id = 7 }))
    assert.equal("task 7", ToolCall.weave_title("task_kill", { id = 7 }))
  end)

  it("returns nil when the meaningful argument is absent", function()
    assert.is_nil(ToolCall.weave_title("read", {}))
    assert.is_nil(ToolCall.weave_title("task_start", { command = "" }))
    assert.is_nil(ToolCall.weave_title("read", "not a table"))
    assert.is_nil(ToolCall.weave_title("some_foreign_tool", { path = "a.lua" }))
  end)

  it("shows the path in a recorded read call's header, not the MCP endpoint", function()
    ToolIdent.reset()
    local input = { path = "lua/weave/init.lua" }
    ToolIdent.record("read", input)
    local store = SessionStore:new()
    store:upsert_tool_call({
      tool_call_id = "r1",
      kind = "read",
      argument = "mcp__clankbox__read", -- the bare endpoint name we must NOT show
      status = "completed",
      input = input,
    })
    local handle = mount_transcript(store)
    local first = trimmed(handle.bufnr)[1]
    assert.truthy(first:find("[w:read]", 1, true))
    assert.truthy(first:find("lua/weave/init.lua", 1, true))
    assert.is_nil(first:find("mcp__clankbox__read", 1, true))
    handle.unmount()
    ToolIdent.reset()
  end)
end)

describe("view.tool_call config surface", function()
  after_each(function()
    ToolCall.reset()
  end)

  it("setup registers tool_renderers from config", function()
    require("weave").setup({
      tool_renderers = { { name = "from-config", match = kind_is("edit"), render = labeller("cfg") } },
    })
    assert.equal("from-config", ToolCall.resolve({ kind = "edit" }).name)
  end)
end)

-- The end-to-end proof that the API carries its motivating case: a real
-- task_start call drawing live output inline, driven by the real task store.
describe("view.renderers.task", function()
  local TaskStore = require("weave.task_store")
  local TaskRenderer = require("weave.view.renderers.task")

  before_each(function()
    ToolCall.reset()
    TaskStore._reset()
  end)
  after_each(function()
    ToolCall.reset()
    TaskStore._reset()
  end)

  local function text_of(bufnr)
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end

  it("streams a running task's output into the transcript entry", function()
    TaskRenderer.install()
    local task = assert(TaskStore.start({ command = "printf 'hello-from-task\\n'; sleep 5" }))

    local store = SessionStore:new()
    store:upsert_tool_call({
      tool_call_id = "t1",
      kind = "execute",
      argument = "run it",
      status = "in_progress",
      input = { command = task.command },
    })
    local handle = mount_transcript(store)

    -- output the task produced AFTER the entry mounted shows up on its own:
    -- the body's use_effect subscription is what makes this live
    vim.wait(5000, function()
      return text_of(handle.bufnr):find("hello-from-task", 1, true) ~= nil
    end, 10)
    local text = text_of(handle.bufnr)
    assert.truthy(text:find("hello-from-task", 1, true))
    assert.truthy(text:find(Theme.TASK_ICON.in_progress, 1, true))

    -- it delegated to Entry, so the builtin header is still there and the raw
    -- input dump is still one <CR> away rather than gone
    assert.truthy(text:find("run it", 1, true))
    assert.is_nil(text:find("command =", 1, true))
    store:toggle_tool_call("t1")
    assert.truthy(text_of(handle.bufnr):find("command =", 1, true))

    TaskStore.kill(task.id)
    handle.unmount()
  end)

  it("declines calls whose command we never started, leaving them builtin", function()
    TaskRenderer.install()
    assert.is_nil(ToolCall.resolve({ kind = "execute", input = { command = "never ran this" } }))
    assert.is_nil(ToolCall.resolve({ kind = "execute", input = {} }))
  end)

  -- Nothing identifies the task on the way in (rawInput is just our declared
  -- schema fields), but task_start's own result opens with "task <id>", and
  -- that id came from our store. Two calls of the SAME command is the case
  -- the command-line fallback gets wrong and the output join gets right.
  describe("correlating a call with its task", function()
    it("reads the exact task id out of the call's own result", function()
      local first = assert(TaskStore.start({ command = "sleep 5" }))
      local second = assert(TaskStore.start({ command = "sleep 5" }))
      assert.is_true(first.id ~= second.id)

      local block = {
        input = { command = "sleep 5" },
        output = { content = { { type = "text", text = ("task %d started (pid 1): sleep 5"):format(first.id) } } },
      }
      assert.equal(first.id, TaskRenderer.task_for(block).id)

      -- without the output it can only guess, and guesses newest-first
      block.output = nil
      assert.equal(second.id, TaskRenderer.task_for(block).id)

      TaskStore.kill(first.id)
      TaskStore.kill(second.id)
    end)

    it("reads the id from a bare-string result too (provider shapes vary)", function()
      local task = assert(TaskStore.start({ command = "sleep 5" }))
      assert.equal(task.id, TaskRenderer.task_for({ output = ("task %d: running (pid 2)"):format(task.id) }).id)
      TaskStore.kill(task.id)
    end)

    it("ignores output that isn't one of ours", function()
      assert.is_nil(TaskRenderer.task_id_from_output({ output = { content = { { text = "wrote 3 lines" } } } }))
      assert.is_nil(TaskRenderer.task_id_from_output({ output = "the task 7 you mentioned" }))
      assert.is_nil(TaskRenderer.task_id_from_output({}))
    end)

    it("declines when the reported task is gone, rather than matching by command", function()
      -- a replayed transcript from a previous session: the id is real in the
      -- text but nothing in this store answers to it
      assert.is_nil(TaskRenderer.task_for({ input = { command = "sleep 5" }, output = "task 999 started (pid 3)" }))
    end)
  end)
end)
