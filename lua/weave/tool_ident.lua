-- Which weave tool produced a given tool-call block, so the transcript header
-- can tag it `w:<tool>` (a call that went through weave's own clankbox suite,
-- not the agent's builtins).
--
-- ── Why a correlation store, and not the block ──────────────────────────────
--
-- ACP tool calls carry no tool name (see the identity note in
-- weave.view.tool_call): the block has kind / title / rawInput and nothing
-- that says "this is weave's edit". But weave DOES know — every one of its
-- tools passes through weave.tools.gate, which has the real name and the exact
-- arguments in hand. Those arguments ARE the block's rawInput (the provider
-- reports the agent's call verbatim), so the gate records `args -> name` and
-- the renderer looks the block up by the same key. Builtin agent tools never
-- reach the gate, so they are never recorded and never mislabelled.
--
-- This is weave.tools.write_snapshots generalized: a bounded, NON-consuming
-- ring keyed on the call arguments. Non-consuming because a transcript entry
-- re-renders every flush and its header re-derives the tag each time; a
-- single-use record would tag the call once and then revert to the kind.

local M = {}

--- How many recent invocations to retain. Oldest dropped first. A block whose
--- record has been evicted degrades to its ACP kind, which is what the header
--- showed before this existed. Generous: a busy turn is many tool calls.
M.LIMIT = 128

--- @class weave.ToolIdentRecord
--- @field name string bare tool name as registered ("edit", "grep", ...)
--- @field key string canonical serialization of the call arguments

--- @type weave.ToolIdentRecord[] oldest first
local records = {}

--- Order-independent serialization of a decoded-JSON value, so a record made
--- from the gate's `args` matches a lookup from the block's `rawInput` even
--- when the two tables enumerate their keys in a different order. Recurses so
--- nested arg tables (search flags, nested options) key stably too.
--- @param v any
--- @return string
local function canon(v)
  if type(v) ~= "table" then
    return type(v) .. ":" .. tostring(v)
  end
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = tostring(k) .. "=" .. canon(v[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
M._canon = canon

--- Record that weave's `name` tool was invoked with `args`.
--- @param name string
--- @param args table|nil
function M.record(name, args)
  if type(name) ~= "string" or name == "" or type(args) ~= "table" then
    return
  end
  records[#records + 1] = { name = name, key = canon(args) }
  while #records > M.LIMIT do
    table.remove(records, 1)
  end
end

--- The weave tool that was called with these exact arguments, or nil. Newest
--- match first, so a repeated identical call resolves to its latest record.
--- @param input table|nil the block's rawInput
--- @return string|nil name
function M.lookup(input)
  if type(input) ~= "table" then
    return nil
  end
  local key = canon(input)
  for i = #records, 1, -1 do
    if records[i].key == key then
      return records[i].name
    end
  end
  return nil
end

--- @return integer
function M.count()
  return #records
end

function M.reset()
  records = {}
end

return M
