-- Successful filesystem change snapshots, captured before mutation and
-- committed after the handler lands the change. Managed conversations retain
-- whole-operation before/after pairs by an editor-qualified receipt, including
-- buffer targets and repeated identical writes. The raw response contains only
-- the short receipt, not another copy of the source.
--
-- The old bounded (path, content) API remains for trusted direct Lua consumers.
-- It is a compatibility fallback, not an authoritative managed-session join.

local M = {}

--- How many pre-write snapshots to retain. Oldest are dropped first. A
--- transcript entry whose snapshot has been evicted degrades to no diff, which
--- is what it rendered before this existed.
M.LIMIT = 32

--- @class weave.tools.WriteSnapshot
--- @field path string
--- @field new string the new content, verbatim as the tool was called with it
--- @field old string[] the lines the file held before the write

--- @type weave.tools.WriteSnapshot[] oldest first
local snapshots = {}

--- The content a path holds RIGHT NOW: the live buffer when one is loaded
--- (unsaved edits are part of what the write is about to replace), else disk,
--- else empty for a file that does not exist yet.
--- @param path string
--- @return string[]
local function current_lines(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  if vim.fn.filereadable(path) == 1 then
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok then
      return lines
    end
  end
  return {}
end

--- Record what `path` holds before it is overwritten with `new_content`.
--- @param path string
--- @param new_content string
function M.capture(path, new_content)
  if type(path) ~= "string" or path == "" or type(new_content) ~= "string" then
    return
  end
  snapshots[#snapshots + 1] = { path = path, new = new_content, old = current_lines(path) }
  while #snapshots > M.LIMIT do
    table.remove(snapshots, 1)
  end
end

--- The pre-write lines for a (path, new_content) write, or nil. Newest match
--- first, so a repeated identical write resolves to the most recent capture.
--- Does not consume: see the note above.
--- @param path string
--- @param new_content string
--- @return string[]|nil
function M.get(path, new_content)
  for i = #snapshots, 1, -1 do
    local snap = snapshots[i]
    if snap.path == path and snap.new == new_content then
      return snap.old
    end
  end
  return nil
end

--- @return integer
function M.count()
  return #snapshots
end

-- Exact successful changes are scoped to their owning conversation. The small
-- receipt in the tool response distinguishes even two identical writes. File
-- contents stay editor-side, not in the receipt or the model's tool response.
local next_id = 0
local unscoped, unscoped_order = {}, {}
local function store_for(ctx)
  return ctx and ctx.caller and ctx.caller.session:get_store() or nil
end

--- @param ctx table|nil
--- @param old string[]|nil
--- @param new string[]
--- @param target { path?: string, bufnr?: integer }
--- @return string receipt
function M.record(ctx, old, new, target)
  next_id = next_id + 1
  local store = store_for(ctx)
  local records = unscoped
  if store then
    store._file_changes = store._file_changes or {}
    records = store._file_changes
  end
  local epoch = require("weave.tool_output").epoch
  local id = epoch .. "-" .. next_id
  records[id] = { old = old and vim.list_slice(old), new = vim.list_slice(new),
    path = target.path, buffer = target.bufnr }
  if not store then
    unscoped_order[#unscoped_order + 1] = id
    while #unscoped_order > M.LIMIT do records[table.remove(unscoped_order, 1)] = nil end
  end
  return "\n[weave change: " .. id .. "]"
end

--- @param block table
--- @param store weave.store.SessionStore|nil
--- @return { old?: string[], new: string[], path?: string, buffer?: integer }|nil
function M.for_call(block, store)
  local text = require("weave.tool_output").text(block)
  -- Only our suffix is a receipt. Source text can itself contain that phrase.
  local id = text and text:match("\n%[weave change: (%x+%-%d+)%]%s*$")
  if not id then return nil end
  return (store and store._file_changes or not store and unscoped or {})[id]
end

function M.reset()
  snapshots, unscoped, unscoped_order = {}, {}, {}
end

return M
