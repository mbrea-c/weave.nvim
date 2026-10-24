-- Provider-independent, bounded access to recorded MCP/ACP results.
-- No editor reads and no renderer state: this also serves change receipts.
local M = { MAX_BYTES = 8 * 1024 * 1024 }
-- Not a capability: this only prevents restored numeric IDs matching objects
-- created in a different editor incarnation. Ownership is checked separately.
M.epoch = vim.fn.sha256(tostring(os.time()) .. ":" .. tostring(vim.uv.hrtime()) .. ":" .. vim.fn.getpid()):sub(1, 16)

local function extract(value, depth)
  if depth > 5 then return nil end
  if type(value) == "string" then
    if #value <= M.MAX_BYTES then return value end
    return nil
  end
  if type(value) ~= "table" then return nil end
  if type(value.content) == "table" then
    local parts, size = {}, 0
    for i = 1, math.min(#value.content, 64) do
      local part = value.content[i]
      if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
        size = size + #part.text + 1
        if size > M.MAX_BYTES then return nil end
        parts[#parts + 1] = part.text
      end
    end
    if #parts > 0 then return table.concat(parts, "\n") end
  end
  for _, key in ipairs({ "text", "output", "result" }) do
    local found = extract(value[key], depth + 1)
    if found then return found end
  end
end

function M.text(block)
  local found = extract(block.output, 0)
  if found then return found end
  if type(block.body) == "table" then
    local parts, size = {}, 0
    for _, part in ipairs(block.body) do
      if type(part) ~= "string" then return nil end
      size = size + #part + 1
      if size > M.MAX_BYTES then return nil end
      parts[#parts + 1] = part
    end
    if #parts > 0 then return table.concat(parts, "\n") end
  end
end

local function decode(value, predicate, depth)
  if depth > 5 then return nil end
  if type(value) == "string" and #value <= M.MAX_BYTES then
    local ok, parsed = pcall(vim.json.decode, value)
    if ok then return decode(parsed, predicate, depth + 1) end
  elseif type(value) == "table" then
    if predicate(value) then return value end
    for _, key in ipairs({ "structuredContent", "result", "output", "text" }) do
      local found = decode(value[key], predicate, depth + 1)
      if found then return found end
    end
    local contents = extract(value, 0)
    if contents then return decode(contents, predicate, depth + 1) end
  end
end

function M.json(block, predicate)
  return decode(block.output, predicate, 0) or decode(M.text(block), predicate, 0)
end

local function failed(value, depth)
  if depth > 5 or type(value) ~= "table" then return false end
  if value.isError == true then return true end
  for _, key in ipairs({ "result", "output" }) do
    if failed(value[key], depth + 1) then return true end
  end
  return false
end

function M.failed(block)
  return block.status == "failed" or failed(block.output, 0)
end

return M
