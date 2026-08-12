-- Indented JSON, for reading rather than for the wire.
--
-- `vim.json.encode` emits one line, which is exactly the shape a human cannot
-- inspect — and inspecting is the whole point of the peek float. So this walks
-- the value itself and only borrows vim.json.encode for scalars (correct
-- string escaping is not worth re-deriving).
--
-- Object keys are sorted, so the same tool call always renders the same way:
-- Lua's `pairs` order is not stable across runs, and a dump that reshuffles
-- between two looks at the same call is worse than useless.

local M = {}

local INDENT = "  "

--- @param value any
--- @return string
local function scalar(value)
  if value == nil or value == vim.NIL then
    return "null"
  end
  local t = type(value)
  if t == "number" or t == "boolean" then
    return tostring(value)
  end
  if t == "string" then
    return vim.json.encode(value)
  end
  -- A function/userdata cannot appear in a decoded payload, but a caller can
  -- hand us anything; describe it instead of erroring in a viewer.
  return vim.json.encode("<" .. t .. ">")
end

--- @param tbl table
--- @return string[]
local function sorted_keys(tbl)
  local keys = {}
  for k in pairs(tbl) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  return keys
end

--- Pretty-print `value` as JSON. Empty tables render `{}` (Lua cannot tell an
--- empty object from an empty array, and an absent-argument object is the
--- commoner case in a tool call). Cycles render as "<cycle>" rather than
--- hanging the editor.
--- @param value any
--- @param indent? string current indent (internal)
--- @param seen? table<table, true> ancestors on this path (internal)
--- @return string
function M.pretty(value, indent, seen)
  indent = indent or ""
  if type(value) ~= "table" then
    return scalar(value)
  end
  seen = seen or {}
  if seen[value] then
    return '"<cycle>"'
  end
  if next(value) == nil then
    return "{}"
  end
  seen[value] = true
  local inner = indent .. INDENT
  local parts = {}
  if vim.islist(value) then
    for _, v in ipairs(value) do
      parts[#parts + 1] = inner .. M.pretty(v, inner, seen)
    end
    seen[value] = nil
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end
  for _, key in ipairs(sorted_keys(value)) do
    -- sorted_keys stringified; look the value up under whichever key type is
    -- actually present (a numeric key in a non-list table).
    local v = value[key]
    if v == nil then
      v = value[tonumber(key)]
    end
    parts[#parts + 1] = inner .. vim.json.encode(key) .. ": " .. M.pretty(v, inner, seen)
  end
  seen[value] = nil
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

return M
