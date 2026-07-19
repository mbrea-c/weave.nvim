-- Diffs for weave's own fs tool calls, which arrive over MCP and so lose the
-- signals the builtin rendering keys on.
--
-- `tool_call.Body` renders a diff when the normalized block carries one, and
-- acp_client builds that block's diff from either an ACP `content` diff part
-- or a rawInput fallback -- but the fallback is gated on `kind == "edit"`,
-- and an MCP tool call has no such kind (nor a tool name; see the identity
-- note in weave.view.tool_call). So an edit through weave's own `edit` tool
-- renders as a vim.inspect dump behind an expand toggle, even though both
-- sides of the diff are sitting right there in rawInput.
--
-- Two renderers, because the two tools lose different things:
--
--   edit   {path, old_string, new_string} -- both sides present, purely a
--          matching problem.
--   write  {path, content}                -- the new side only. The old side
--          comes from the pre-write snapshot (weave.tools.write_snapshots);
--          with no snapshot there is nothing honest to draw, so it falls
--          through to the builtin rendering rather than diffing against an
--          empty file and claiming the whole file was added.
--
-- Both delegate to `ToolCall.Entry` with a `render_body` override, so headers,
-- expansion and metadata stay exactly as they are everywhere else, and both
-- draw through `weave.view.diff`, the same component the native edit path
-- uses.

local Diff = require("weave.view.diff")
local Snapshots = require("weave.tools.write_snapshots")
local ToolCall = require("weave.view.tool_call")

local M = {}

--- @param value any
--- @return boolean
local function is_str(value)
  return type(value) == "string"
end

--- rawInput off a normalized block, or nil when it is not a table.
--- @param block table
--- @return table|nil
local function input_of(block)
  return type(block.input) == "table" and block.input or nil
end

--- Split content the way the store does, so a diff built here lines up with
--- one built upstream. A trailing newline must not become a phantom last line.
--- @param text string
--- @return string[]
local function split(text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- An Entry whose body is the given diff, honouring the show_diffs pref and
--- the same preview cap as the builtin body.
--- @param props weave.view.ToolCallProps
--- @param old string[]
--- @param new string[]
--- @return table
local function entry_with_diff(props, old, new)
  return {
    comp = ToolCall.Entry,
    props = vim.tbl_extend("force", {}, props, {
      render_body = function()
        if props.show_diff == false then
          return nil
        end
        return {
          comp = Diff.Diff,
          props = {
            old = old,
            new = new,
            max_lines = ToolCall.DIFF_PREVIEW_MAX_LINES,
            indent = "    ",
          },
        }
      end,
    }),
  }
end

--- @type weave.view.ToolRenderer
M.edit = {
  name = "weave.fs.edit",
  match = function(block)
    local input = input_of(block)
    return input ~= nil and is_str(input.path) and is_str(input.old_string) and is_str(input.new_string)
  end,
  render = function(_, props)
    local input = props.block.input
    return entry_with_diff(props, split(input.old_string), split(input.new_string))
  end,
}

--- @type weave.view.ToolRenderer
M.write = {
  name = "weave.fs.write",
  match = function(block)
    local input = input_of(block)
    if input == nil or not is_str(input.path) or not is_str(input.content) then
      return false
    end
    -- Only claim the block when there is a snapshot to diff against.
    return Snapshots.get(input.path, input.content) ~= nil
  end,
  render = function(_, props)
    local input = props.block.input
    local old = Snapshots.get(input.path, input.content) or {}
    return entry_with_diff(props, old, split(input.content))
  end,
}

--- Register both. Idempotent: the registry replaces by name.
function M.install()
  ToolCall.register(M.edit)
  ToolCall.register(M.write)
end

return M
