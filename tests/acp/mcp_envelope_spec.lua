-- Providers do not agree on what `rawInput` holds for an MCP tool call.
--
-- Most report the agent's call VERBATIM — the tool's own arguments, and
-- nothing else — which is what everything downstream assumes: the renderer
-- duck-types on argument shape, and weave.tool_ident correlates a block back
-- to the weave tool that produced it by hashing those arguments.
--
-- Codex reports an ENVELOPE instead: { server, tool, arguments }. Everything
-- keyed on argument shape then misses, so weave's own calls came out as
-- generic `[execute]` rows titled `mcp.clankbox.grep`. Since the envelope also
-- names the tool outright — which the ACP wire format otherwise never does —
-- unwrapping it is a strict gain: the block looks like every other provider's
-- AND carries a real name.

local ACPClient = require("weave.acp.acp_client")

--- __build_tool_call_message without standing up a client.
local function build(update)
  return ACPClient.__build_tool_call_message({}, update)
end

describe("mcp envelope rawInput", function()
  it("unwraps { server, tool, arguments } into the arguments", function()
    local msg = build({
      toolCallId = "exec-1",
      kind = "execute",
      title = "mcp.clankbox.grep",
      rawInput = {
        server = "clankbox",
        tool = "grep",
        arguments = { pattern = "struct EditorDocument", path = "src/bin/asset_editor.rs" },
      },
    })
    assert.same({ pattern = "struct EditorDocument", path = "src/bin/asset_editor.rs" }, msg.input)
  end)

  it("keeps the server and tool the envelope named", function()
    local msg = build({
      toolCallId = "exec-1",
      rawInput = { server = "clankbox", tool = "grep", arguments = { pattern = "x" } },
    })
    assert.same({ server = "clankbox", tool = "grep" }, msg.mcp)
  end)

  it("leaves a verbatim rawInput alone", function()
    local msg = build({
      toolCallId = "t1",
      rawInput = { pattern = "x", path = "/p" },
    })
    assert.same({ pattern = "x", path = "/p" }, msg.input)
    assert.is_nil(msg.mcp)
  end)

  -- Duck-typing has to be tight: a tool whose OWN arguments happen to include
  -- a `tool` string must not be mistaken for an envelope and gutted.
  it("does not unwrap something that merely has a `tool` argument", function()
    local msg = build({ toolCallId = "t1", rawInput = { tool = "hammer", count = 2 } })
    assert.same({ tool = "hammer", count = 2 }, msg.input)
    assert.is_nil(msg.mcp)
  end)

  it("does not unwrap when `arguments` is not a table", function()
    local msg = build({ toolCallId = "t1", rawInput = { tool = "grep", arguments = "nope" } })
    assert.same({ tool = "grep", arguments = "nope" }, msg.input)
    assert.is_nil(msg.mcp)
  end)

  it("survives an envelope carrying no arguments at all", function()
    local msg = build({ toolCallId = "t1", rawInput = { server = "clankbox", tool = "task_status" } })
    assert.same({}, msg.input)
    assert.equal("task_status", msg.mcp.tool)
  end)
end)

describe("mcp envelope rendering", function()
  local ToolCall = require("weave.view.tool_call")
  local ToolIdent = require("weave.tool_ident")

  after_each(function()
    ToolIdent.reset()
  end)

  --- What the transcript sees for a codex-shaped clankbox call.
  local function codex_block(tool, arguments)
    return build({
      toolCallId = "exec-1",
      kind = "execute",
      title = "mcp.clankbox." .. tool,
      rawInput = { server = "clankbox", tool = tool, arguments = arguments },
    })
  end

  it("tags a weave tool from the name the envelope gave, with no correlation record", function()
    -- ToolIdent is empty: the envelope is the only source of the name, and it
    -- is the more reliable one — the correlation ring is bounded, so a busy
    -- turn can evict a record the tag would otherwise depend on.
    assert.equal("w:grep", ToolCall.tool_tag(codex_block("grep", { pattern = "x" })))
  end)

  it("titles it by its meaningful argument, not the MCP endpoint name", function()
    local block = codex_block("grep", { pattern = "struct EditorDocument" })
    assert.equal("struct EditorDocument", ToolCall.tool_title(block))
  end)

  it("still finds the tool through the correlation store for other providers", function()
    ToolIdent.record("grep", { pattern = "verbatim" })
    local block = build({ toolCallId = "t1", kind = "execute", rawInput = { pattern = "verbatim" } })
    assert.equal("w:grep", ToolCall.tool_tag(block))
  end)

  -- Another server's tools are not weave's to claim, but the envelope still
  -- names them, and `<server>:<tool>` beats a bare kind.
  it("names a foreign MCP tool by its server", function()
    local block = build({
      toolCallId = "t1",
      kind = "other",
      rawInput = { server = "postgres", tool = "query", arguments = { sql = "select 1" } },
    })
    assert.equal("postgres:query", ToolCall.tool_tag(block))
  end)

  it("does not claim a clankbox tool weave does not own", function()
    local block = build({
      toolCallId = "t1",
      kind = "other",
      rawInput = { server = "clankbox", tool = "exec_lua", arguments = { code = "print(1)" } },
    })
    assert.equal("clankbox:exec_lua", ToolCall.tool_tag(block))
  end)
end)
