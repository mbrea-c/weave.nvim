-- Kiro names MCP calls in rawInput.tool_id and an @server/tool title.
-- Normalize those signals before argument-based renderers or permissions run.
local ACPClient = require("weave.acp.acp_client")
local AcpBridge = require("weave.acp_bridge")
local FsDiff = require("weave.view.renderers.fs_diff")
local Permissions = require("weave.permissions")
local SessionStore = require("weave.session_store")
local ToolCall = require("weave.view.tool_call")
local ToolIdent = require("weave.tool_ident")

local function build(update)
  -- Exercise the protected normalizer without starting a provider.
  ---@diagnostic disable-next-line: invisible
  return ACPClient.__build_tool_call_message(ACPClient, update)
end

local function kiro_call(tool, arguments)
  return {
    toolCallId = "kiro-1",
    kind = "other",
    title = "@clankbox/" .. tool,
    rawInput = { tool_id = "clankbox::" .. tool, arguments = arguments },
    _meta = { kiro = { serverName = "clankbox", toolOrigin = "default" } },
  }
end

describe("Kiro MCP normalization", function()
  after_each(function()
    ToolIdent.reset()
  end)

  it("unwraps qualified tool_id arguments and preserves identity, metadata and content", function()
    local args = { path = "/p/a.lua", old_string = "one", new_string = "two" }
    local update = kiro_call("weave_edit", args)
    update.status = "completed"
    update.content = { { type = "content", content = { type = "text", text = "replaced 1 occurrence" } } }
    local original = vim.deepcopy(update)
    local msg = build(update)
    assert.same(args, msg.input)
    assert.same({ server = "clankbox", tool = "weave_edit" }, msg.mcp)
    assert.same(update._meta, msg.meta)
    assert.same({ "replaced 1 occurrence" }, msg.body)
    assert.equal("completed", msg.status)
    assert.same(original, update)
  end)

  it("accepts an empty or omitted argument object for a qualified tool_id", function()
    for _, raw in ipairs({
      { tool_id = "clankbox::weave_task_list", arguments = {} },
      { tool_id = "clankbox::weave_task_list" },
    }) do
      local msg = build({ toolCallId = "kiro-1", rawInput = raw })
      assert.same({}, msg.input)
      assert.same({ server = "clankbox", tool = "weave_task_list" }, msg.mcp)
    end
  end)

  it("does not unwrap a builtin tool_id or trust server metadata alone", function()
    local args = { tool_id = "fs_read", arguments = { path = "/p/a.lua" } }
    local msg = build({
      toolCallId = "kiro-1", kind = "read", rawInput = args,
      _meta = { kiro = { serverName = "clankbox" } },
    })
    assert.same(args, msg.input)
    assert.is_nil(msg.mcp)
    assert.equal("read", ToolCall.tool_tag(msg))
  end)

  it("leaves malformed or ambiguous tool_id values untouched", function()
    for _, id in ipairs({
      "", "::weave_read", "clankbox::", "clankbox::weave_read::extra",
      "clank box::weave_read", "clankbox::weave read", "clankbox/weave_read", false, 42, vim.NIL,
    }) do
      local raw = { tool_id = id, arguments = { path = "/p/a.lua" } }
      local msg = build({ toolCallId = "kiro-1", rawInput = raw })
      assert.same(raw, msg.input)
      assert.is_nil(msg.mcp)
    end
  end)

  it("does not discard non-object arguments in a tool_id-shaped value", function()
    for _, value in ipairs({ "not an object", false, 42, vim.NIL }) do
      local raw = { tool_id = "clankbox::weave_read", arguments = value }
      local msg = build({ toolCallId = "kiro-1", rawInput = raw })
      assert.same(raw, msg.input)
      assert.is_nil(msg.mcp)
    end
  end)

  it("tags and titles an edit without relying on the correlation ring", function()
    local msg = build(kiro_call("weave_edit", {
      path = "/p/a.lua", old_string = "one", new_string = "two",
    }))
    assert.equal("w:edit", ToolCall.tool_tag(msg))
    assert.equal("/p/a.lua", ToolCall.tool_title(msg))
  end)

  it("makes Kiro edits available to the normal diff renderer", function()
    local msg = build(kiro_call("weave_edit", {
      path = "/p/a.lua", old_string = "one", new_string = "two",
    }))
    assert.is_true(FsDiff.edit.match(msg))
    local entry = FsDiff.edit.render({}, {
      block = msg, store = SessionStore:new(), expanded = false, awaiting = false, show_diff = true,
    })
    local diff = entry.props.render_body()
    assert.same({ "one" }, diff.props.old)
    assert.same({ "two" }, diff.props.new)
    assert.equal("/p/a.lua", diff.props.path)
  end)

  it("normalizes arguments for grep and task headers too", function()
    local grep = build(kiro_call("weave_grep", { pattern = "needle" }))
    assert.equal("w:grep", ToolCall.tool_tag(grep))
    assert.equal("needle", ToolCall.tool_title(grep))
    local task = build(kiro_call("weave_task_start", { command = "make test" }))
    assert.equal("w:task_start", ToolCall.tool_tag(task))
    assert.equal("make test", ToolCall.tool_title(task))
  end)

  it("recognizes an exact @server/tool title when no envelope is present", function()
    local msg = build({
      toolCallId = "kiro-1", kind = "other", title = "@clankbox/weave_edit",
      rawInput = { path = "/p/a.lua", old_string = "one", new_string = "two" },
    })
    assert.same({ server = "clankbox", tool = "weave_edit" }, msg.mcp)
    assert.equal("w:edit", ToolCall.tool_tag(msg))
    assert.equal("/p/a.lua", ToolCall.tool_title(msg))
  end)

  it("does not interpret ordinary prose or malformed @titles as endpoint names", function()
    for _, title in ipairs({
      "Calling @clankbox/weave_read", "@clankbox/weave_read extra", "@clankbox/",
      "@/weave_read", "@clankbox/weave_read/extra", "@clank box/weave_read",
    }) do
      local msg = build({ toolCallId = "kiro-1", kind = "other", title = title })
      assert.is_nil(msg.mcp)
      assert.equal("other", ToolCall.tool_tag(msg))
    end
  end)

  it("does not claim another server's weave-named tool", function()
    local msg = build({
      toolCallId = "kiro-1", kind = "other",
      rawInput = { tool_id = "external::weave_edit", arguments = {} },
    })
    assert.same({ server = "external", tool = "weave_edit" }, msg.mcp)
    assert.equal("external:weave_edit", ToolCall.tool_tag(msg))
  end)

  it("does not claim an unknown tool on clankbox", function()
    local msg = build(kiro_call("exec_lua", { code = "print(1)" }))
    assert.equal("clankbox:exec_lua", ToolCall.tool_tag(msg))
  end)

  it("prefers a structured tool_id over a conflicting endpoint title", function()
    local msg = build({
      toolCallId = "kiro-1", title = "@clankbox/weave_read",
      rawInput = { tool_id = "external::query", arguments = { sql = "select 1" } },
    })
    assert.same({ server = "external", tool = "query" }, msg.mcp)
    assert.same({ sql = "select 1" }, msg.input)
  end)
end)

describe("Kiro MCP permission routing", function()
  before_each(function()
    Permissions._reset()
    Permissions.set_mode("on")
    Permissions.set_active("ask")
  end)

  after_each(function()
    Permissions._reset()
  end)

  local function decision(tc, announced)
    local store = SessionStore:new()
    local handlers = AcpBridge.build_handlers(store)
    if announced then handlers.on_tool_call(build(announced)) end
    local answer
    handlers.on_request_permission({
      sessionId = "kiro-session",
      toolCall = tc,
      options = {
        { optionId = "once", kind = "allow_once", name = "Allow once" },
        { optionId = "reject", kind = "reject_once", name = "Reject once" },
      },
    }, function(id) answer = id end)
    return answer, store
  end

  it("routes a qualified tool_id with no title through the MCP gate", function()
    local tc = kiro_call("weave_edit", { path = "/p/a.lua", old_string = "one", new_string = "two" })
    tc.title = nil
    local answer, store = decision(tc)
    assert.equal("once", answer)
    assert.is_nil(store:get_permission())
  end)

  it("routes an exact Kiro endpoint title as MCP", function()
    assert.equal("once", decision({ kind = "other", title = "@clankbox/weave_read" }))
  end)

  it("retains the normalized identity for a later id-only permission request", function()
    local announced = kiro_call("weave_read", { path = "/p/a.lua" })
    assert.equal("once", decision({ toolCallId = "kiro-1" }, announced))
  end)

  it("does not bypass policy for an unbrokered tool_id", function()
    assert.equal("reject", decision({
      kind = "other", rawInput = { tool_id = "external::query", arguments = {} },
    }))
  end)

  it("does not bypass policy for a builtin with Kiro server metadata", function()
    assert.equal("reject", decision({
      kind = "read", title = "Read", rawInput = { tool_id = "fs_read", arguments = {} },
      _meta = { kiro = { serverName = "clankbox" } },
    }))
  end)

  it("keeps legacy title routing when an envelope omits its server", function()
    assert.equal("once", decision({
      kind = "other", title = "clankbox_weave_read",
      rawInput = { tool = "weave_read", arguments = { path = "/p/a.lua" } },
    }))
  end)

  it("does not let a title override an explicitly unbrokered tool_id", function()
    assert.equal("reject", decision({
      kind = "other", title = "@clankbox/weave_read",
      rawInput = { tool_id = "external::query", arguments = {} },
    }))
  end)
end)
