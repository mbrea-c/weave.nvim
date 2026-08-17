-- The edit gate + the check_user_edits tool: with the `edit_gate` session
-- setting on, the agent's write/edit/task_start calls are refused while the
-- user has edits the conversation has not seen, until it pulls them through
-- check_user_edits (or auto-send delivers them first). "Seen" is
-- weave.edit_sync's per-session cursor — one cursor for both roads.
--
-- The gate closes a race no prompt can: the agent writing over (or reasoning
-- about stale versions of) files the user is editing RIGHT NOW — pending()
-- closes the open burst, so mid-typing counts. The check→write race is
-- self-healing: edits landing between the two are simply the next refusal.
--
-- MCP calls arrive over clankbox with no session identity attached, so the
-- acting session is resolved exactly like the permission gate's ask-store:
-- the selected session, else the first active one (see weave.tools.gate).

local M = {}

--- The session whose gate applies. Overridable seam for specs.
--- @return table|nil
function M._session()
  local ok, Registry = pcall(require, "weave.registry")
  if not ok then
    return nil
  end
  local entry = Registry.selected() or Registry.list()[1]
  return entry and entry.session or nil
end

--- Why the gate refuses right now, or nil when it does not: the acting
--- session must have edit_gate on AND unseen edits pending.
--- @return string|nil reason
function M.gate_reason()
  local session = M._session()
  if not session then
    return nil
  end
  local Settings = require("weave.settings")
  if not Settings.for_session(session).state.edit_gate then
    return nil
  end
  if not require("weave.edit_sync").pending(session) then
    return nil
  end
  return "blocked: the user has made edits you have not seen."
    .. " Call check_user_edits to receive them, then retry this call."
end

--- Wrap a tool def so it refuses while the gate holds. Wraps INSIDE
--- Gate.wrap (permissions first, then this): the throw lands in clankbox's
--- pcall on the allow path and in the gate's own pcall on the ask path,
--- either way reaching the agent as an isError result.
--- @param def table raw clankbox tool def
--- @return table guarded
function M.guard(def)
  return {
    description = def.description,
    inputSchema = def.inputSchema,
    async = def.async,
    handler = function(args, respond)
      local reason = M.gate_reason()
      if reason then
        error(reason, 0)
      end
      if def.async then
        return def.handler(args, respond)
      end
      return def.handler(args)
    end,
  }
end

M.check = {
  description = table.concat({
    "Everything the user changed since you last saw their edits, squashed into one diff.",
    "Call this when a write/edit/task_start is refused because of unseen user edits,",
    "or whenever you want to be sure you are reasoning about the code as it is NOW.",
    "Returns 'no pending user edits' when you are already in sync.",
  }, " "),
  -- empty_dict, not {}: this tool takes no arguments, and a bare empty Lua
  -- table encodes as `[]`, which is not a valid JSON Schema `properties` —
  -- strict clients reject the tool (or the whole tools/list) over it.
  inputSchema = { type = "object", properties = vim.empty_dict() },
  handler = function()
    local session = M._session()
    if not session then
      error("no active weave session", 0)
    end
    local Settings = require("weave.settings")
    local state = Settings.for_session(session).state
    if not (state.edit_gate or state.auto_send_edits) then
      return "edit tracking is not enabled for this session — nothing to check."
    end
    local diff = require("weave.edit_sync").consume(session)
    if not diff then
      return "no pending user edits."
    end
    return "Everything the user changed since you last saw their edits, squashed into one diff:\n\n" .. diff
  end,
}

return M
