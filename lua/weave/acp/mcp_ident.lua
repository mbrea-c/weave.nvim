-- How a provider NAMES an MCP tool call on the ACP wire.
--
-- ACP has no field for it. A tool call carries a title, a kind and an opaque
-- rawInput, and none of them is specified to hold the endpoint, so every
-- provider invented its own channel:
--
--   * codex wraps the call in an ENVELOPE — { server, tool, arguments } — in
--     place of the arguments other providers report verbatim
--   * codex and claude also spell the endpoint in the TITLE, as
--     `mcp.<server>.<tool>` and `mcp__<server>__<tool>` respectively
--   * opencode names it loosely, with no shape to key on ("clankbox_read")
--
-- This module exists because TWO paths need that answer and they must agree.
-- The render path (weave.acp.acp_client) unwraps the envelope so a call shows
-- as `[w:read]` with its real arguments. The PERMISSION path
-- (weave.acp_bridge) uses the name to tell "the agent is calling a tool WE
-- broker" from "the agent is calling its own builtin" — which under a
-- sandboxed preset is the whole difference between allow and deny.
--
-- They were two separate parsers, and only the renderer was taught the
-- envelope: codex's clankbox calls rendered correctly and were REJECTED, by
-- the acp:* deny meant for the agent's own tools. One parser, both callers.

--- @class weave.acp.McpIdent
local M = {}

--- @class weave.acp.McpName
--- @field server string|nil The MCP server, when the provider named it
--- @field tool string The tool on that server

--- Codex's envelope: the call wrapped in { server, tool, arguments } rather
--- than reported as its own arguments.
---
--- Duck-typed tightly, because a tool's own arguments could perfectly well
--- include a key called `tool`: a bare `tool` string is not enough, it must
--- come with an `arguments` TABLE or a `server` name beside it. Guessing wrong
--- here would gut a real call's arguments.
--- @param raw any A tool call's rawInput
--- @return { server: string|nil, tool: string, arguments: table }|nil
function M.envelope(raw)
  if type(raw) ~= "table" then
    return nil
  end
  if type(raw.tool) ~= "string" or raw.tool == "" then
    return nil
  end
  if type(raw.arguments) ~= "table" and type(raw.server) ~= "string" then
    return nil
  end
  return {
    server = type(raw.server) == "string" and raw.server or nil,
    tool = raw.tool,
    arguments = type(raw.arguments) == "table" and raw.arguments or {},
  }
end

--- The other channel: the title IS the endpoint name.
---
--- Titles are agent-authored prose in general, so only the exact endpoint
--- shape counts — "Editing tool_call.lua" is a title, not a name. Anchored at
--- both ends for that reason, and non-greedy on the server so a tool with
--- underscores of its own survives: `mcp__clankbox__task_start` is
--- clankbox/task_start, not clankbox__task.
--- @param title any A tool call's title
--- @return { server: string, tool: string }|nil
function M.from_title(title)
  if type(title) ~= "string" then
    return nil
  end
  local server, tool = title:match("^mcp__(.-)__(.+)$")
  if not server then
    server, tool = title:match("^mcp%.(.-)%.(.+)$")
  end
  if server and server ~= "" and tool and tool ~= "" then
    return { server = server, tool = tool }
  end
  return nil
end

--- The tool a wire frame names, through whichever channel its provider used.
--- The envelope wins: it is data the provider structured, where the title is
--- a string that merely looks like a name.
--- @param tc table|nil ToolCall / ToolCallUpdate as it arrives on the wire
--- @return weave.acp.McpName|nil
function M.identify(tc)
  if type(tc) ~= "table" then
    return nil
  end
  local env = M.envelope(tc.rawInput)
  if env then
    return { server = env.server, tool = env.tool }
  end
  return M.from_title(tc.title)
end

return M
