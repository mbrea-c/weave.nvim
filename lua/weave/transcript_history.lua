-- Conversation-owned identities over the canonical store entries, never buffer rows.
--- @class weave.transcript.Record
--- @field id string
--- @field sequence integer
--- @field revision integer
--- @field created_at integer
--- @field entry weave.store.ChatEntry
--- @field tool? table

--- @class weave.transcript.History
--- @field id string
--- @field records weave.transcript.Record[]
--- @field by_id table<string, weave.transcript.Record>
--- @field by_tool table<string, integer>
local M = {}
M.__index = M
local serial = 0

--- @return weave.transcript.History
function M.new()
  serial = serial + 1
  local id = require("weave.tool_output").epoch .. "-conversation-" .. serial
  return setmetatable({ id = id, records = {}, by_id = {}, by_tool = {} }, M)
end

--- @param id string
--- @return weave.transcript.Record|nil
function M:get(id) return self.by_id[id] end

function M:append(entry, tool)
  local seq = #self.records + 1
  local record = { id = self.id .. ":e" .. seq, sequence = seq, revision = 1,
    created_at = os.time(), entry = entry, tool = tool }
  self.records[seq], self.by_id[record.id] = record, record
  if entry.tool_call_id then self.by_tool[entry.tool_call_id] = seq end
  return record
end

function M:replace(seq, entry, tool)
  local old = assert(self.records[seq], "missing transcript entry")
  local record = { id = old.id, sequence = seq, revision = old.revision + 1,
    created_at = old.created_at, entry = entry, tool = tool }
  self.records[seq], self.by_id[old.id] = record, record
  return record
end

return M
