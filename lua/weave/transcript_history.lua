-- Conversation-owned identities over the canonical store entries, never buffer rows.
--- @class weave.transcript.Record
--- @field id string
--- @field sequence integer
--- @field revision integer
--- @field created_at integer
--- @field entry weave.store.ChatEntry
--- @field tool? table
--- @field prompt? string Original sent user text

--- @class weave.transcript.History
--- @field id string
--- @field records weave.transcript.Record[]
--- @field by_id table<string, weave.transcript.Record>
--- @field by_tool table<string, integer>
--- @field prompts weave.transcript.Record[] Sent prompts ordered by sequence
local M = {}
M.__index = M
local serial = 0

--- @return weave.transcript.History
function M.new()
  serial = serial + 1
  local id = require("weave.tool_output").epoch .. "-conversation-" .. serial
  return setmetatable({ id = id, records = {}, by_id = {}, by_tool = {}, prompts = {} }, M)
end

--- @param id string
--- @return weave.transcript.Record|nil
function M:get(id) return self.by_id[id] end

function M:append(entry, tool, prompt_text)
  local seq = #self.records + 1
  local record = { id = self.id .. ":e" .. seq, sequence = seq, revision = 1,
    created_at = os.time(), entry = entry, tool = tool }
  self.records[seq], self.by_id[record.id] = record, record
  local prompt = prompt_text or entry.text
  if entry.kind == "user" and type(prompt) == "string" and prompt:find("%S") then
    record.prompt = prompt
    self.prompts[#self.prompts + 1] = record
  end
  if entry.tool_call_id then self.by_tool[entry.tool_call_id] = seq end
  return record
end

-- A prompt hidden by transcript windowing is still a predecessor.
function M:prompt_before(sequence)
  local lo, hi = 1, #self.prompts
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if self.prompts[mid].sequence < sequence then lo = mid + 1
    else hi = mid - 1 end
  end
  return self.prompts[hi] and self.prompts[hi].prompt
end

function M:replace(seq, entry, tool)
  local old = assert(self.records[seq], "missing transcript entry")
  local record = { id = old.id, sequence = seq, revision = old.revision + 1,
    created_at = old.created_at, entry = entry, tool = tool }
  self.records[seq], self.by_id[old.id] = record, record
  return record
end

return M
