-- Pre-write content capture, so a full-content write can be shown as a diff.
--
-- A write tool call arrives as {path, content}: the NEW side only. Nothing in
-- the ACP payload carries what the file used to be, and the renderer runs
-- after the write has landed, so it cannot go and read it -- the file already
-- holds `content` and the diff would be empty. The old side therefore has to
-- be taken before the handler runs, which is what weave's clankbox middleware
-- is positioned to do.
--
-- ── Correlating a snapshot with its tool call ───────────────────────────────
--
-- The renderer sees an ACP block with rawInput; it has no handle on the
-- clankbox invocation that produced it. So the key is the pair we know both
-- sides agree on: the path and the exact new content. Path alone would be
-- ambiguous when an agent writes the same file twice in one turn -- with the
-- content in the key, each call finds its own snapshot regardless of order.
--
-- Lookup is deliberately NON-consuming. A transcript entry re-renders every
-- time the view flushes, and its matcher re-runs on every resolve, so a
-- single-use snapshot would draw the diff once and then silently revert the
-- entry to the builtin rendering. The bound below is what keeps this in
-- check: it holds whole file contents in memory, and a session is long.

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

function M.reset()
  snapshots = {}
end

return M
