-- Pending feedback eligible for a human prompt in this conversation.
-- A custom feedback sink remains explicit; never reroute its comments.
local Comments = require("weave.feedback_store")
local Edits = require("weave.edit_sync")
local Sinks = require("weave.feedback_sinks")
local Settings = require("weave.settings")
local M = {}

function M.capture(session)
  if not Settings.for_session(session):get("flush_with_next_message") then return end
  local parts = {}
  local diff = Edits.pending_message(session)
  if diff then
    -- Priority delivery can put an older snapshot after a newer one.
    diff.text = ("[Weave: user edits captured through revision %d]\n"):format(diff.revision) .. diff.text
    parts[#parts + 1] = diff
  end
  local comments = Sinks.default_is_builtin() and require("weave.feedback").pending_message(session)
  if comments then parts[#parts + 1] = comments end
  return #parts > 0 and parts or nil
end

local function label(c, f)
  local out = {}
  if c > 0 then out[#out + 1] = c .. (c == 1 and " comment" or " comments") end
  if f > 0 then out[#out + 1] = f .. (f == 1 and " file" or " files") end
  return table.concat(out, " · ")
end

function M.attached(parts)
  local c, f = 0, 0
  for _, part in ipairs(parts or {}) do c, f = c + (part.comments or 0), f + (part.files or 0) end
  return label(c, f)
end

function M.pending(session)
  if not session or not Settings.for_session(session):get("flush_with_next_message") then return "" end
  local item = Sinks.default_is_builtin() and Comments.item_for(session)
  local summary = Edits.pending_summary(session)
  return label(item and #item.comments or 0, summary and summary.files or 0)
end

function M.subscribe(session, fn)
  if not session then return end
  local subscriptions = { Comments.subscribe(fn), Edits.subscribe(fn),
    require("weave.revision_log").subscribe(fn), Settings.for_session(session):subscribe(fn) }
  return function() for _, off in ipairs(subscriptions) do off() end end
end

return M
