-- weave.revision: the unit tutor mode collects and sends to the agent.
--
-- A revision stores CONTENT, not hunks: per file, what it held before the
-- change and what it holds after. That choice is the whole design, and it buys
-- two things nothing else does.
--
--   * Merging is trivial and exactly right. Squashing a burst of edits into one
--     revision is "take the earliest before and the latest after" per file —
--     associative, order-free, and impossible to get subtly wrong. Composing
--     two sets of hunks is a real diff-algebra problem that would be.
--   * A change the user made and then undid is not a change. Edit a line, hit
--     u, and the squashed revision correctly says nothing happened, because
--     before and after compare equal. No hunk arithmetic can see that.
--
-- Creation and deletion are the same operation as an edit, expressed as a nil
-- side: `before = nil` is a file that did not exist, `after = nil` is one that
-- no longer does. Merge handles them without a special case, so create-then-
-- delete inside one window vanishes the same way an undone edit does. A RENAME
-- arrives as a deletion plus a creation; nothing here reconstructs it.
--
-- Everything in this module is pure — no buffers, no autocmds, no clock. The
-- collection side (who edited what, when a burst ends) is weave.revision_log.

local M = {}

--- How much diff text one send may carry before it is cut short. The agent is
--- reading these to tutor, not to apply them; a 400kB paste of a vendored file
--- costs context that the actual lesson needs.
M.MAX_BYTES = 100 * 1024

--- @class weave.revision.FileChange
--- @field before string|nil whole content before (nil = the file did not exist)
--- @field after string|nil whole content after (nil = the file was deleted)

--- @class weave.revision.Revision
--- @field id integer this revision's id (the LAST one, for a squashed span)
--- @field from_id integer the first id the span covers (== id when unsquashed)
--- @field at integer ms timestamp of the last change in the span
--- @field files table<string, weave.revision.FileChange> keyed by absolute path

--- @param files table<string, weave.revision.FileChange>
--- @return table<string, weave.revision.FileChange>
local function copy_files(files)
  local out = {}
  for path, fc in pairs(files or {}) do
    out[path] = { before = fc.before, after = fc.after }
  end
  return out
end

--- @param opts { id: integer, at?: integer, from_id?: integer, files?: table<string, weave.revision.FileChange> }
--- @return weave.revision.Revision
function M.new(opts)
  return {
    id = opts.id,
    from_id = opts.from_id or opts.id,
    at = opts.at or 0,
    files = copy_files(opts.files),
  }
end

--- What a file entry describes.
--- @param fc weave.revision.FileChange
--- @return "created"|"deleted"|"modified"
function M.kind(fc)
  if fc.before == nil then
    return "created"
  end
  if fc.after == nil then
    return "deleted"
  end
  return "modified"
end

--- Drop every file whose net change is nothing — the undone edit, the scratch
--- file created and removed again. Safe to apply mid-fold: a pruned entry had
--- before == after == C, and any later revision touching that path opens with
--- before == C, so its own `before` says exactly what the pruned one would
--- have.
--- @param rev weave.revision.Revision
--- @return weave.revision.Revision the same table, mutated
local function prune(rev)
  for path, fc in pairs(rev.files) do
    if fc.before == fc.after then
      rev.files[path] = nil
    end
  end
  return rev
end

--- Merge two revisions, `b` being the LATER one. Per file: the earlier
--- revision's `before` and the later one's `after`, which is what makes the
--- result describe the whole span as if it had happened at once. Neither input
--- is mutated. A nil operand is the identity.
--- @param a weave.revision.Revision|nil
--- @param b weave.revision.Revision|nil
--- @return weave.revision.Revision|nil
function M.merge(a, b)
  if not a and not b then
    return nil
  end
  if not a or not b then
    local one = a or b
    return prune(M.new(one))
  end

  local files = copy_files(a.files)
  for path, fc in pairs(b.files) do
    -- Presence of the ENTRY decides, never truthiness of the field: a creation
    -- carries before = nil, and `earlier and earlier.before or fc.before` would
    -- read that as "no earlier side" and adopt the later revision's before —
    -- turning create-then-edit into a modification of a file that never existed.
    local earlier = files[path]
    local before = fc.before
    if earlier ~= nil then
      before = earlier.before
    end
    files[path] = { before = before, after = fc.after }
  end
  return prune(M.new({ id = b.id, from_id = a.from_id, at = b.at, files = files }))
end

--- Fold a list of revisions, OLDEST FIRST, into one. This is what a tutor-mode
--- send carries: not twelve revisions, one revision spanning twelve.
--- @param list weave.revision.Revision[] oldest first
--- @return weave.revision.Revision|nil nil for an empty list
function M.squash(list)
  local out = nil
  for _, rev in ipairs(list or {}) do
    out = M.merge(out, rev)
  end
  return out and prune(out) or nil
end

--- @param rev weave.revision.Revision|nil
--- @return boolean
function M.is_empty(rev)
  if not rev then
    return true
  end
  return next(rev.files) == nil
end

--- Every path in the revision, sorted. Sorted rather than insertion-ordered so
--- two sends describing the same files read the same way.
--- @param rev weave.revision.Revision
--- @return string[]
function M.paths(rev)
  local out = {}
  for path in pairs(rev.files) do
    out[#out + 1] = path
  end
  table.sort(out)
  return out
end

--- @param rev weave.revision.Revision
--- @return { files: integer, created: integer, deleted: integer, modified: integer }
function M.summary(rev)
  local out = { files = 0, created = 0, deleted = 0, modified = 0 }
  for _, fc in pairs(rev.files) do
    out.files = out.files + 1
    local kind = M.kind(fc)
    out[kind] = out[kind] + 1
  end
  return out
end

--- How a path is spelled in the rendered diff: project-relative under `root`,
--- and plainly ABSOLUTE outside it. Wrapping an outside path in git's a//b/
--- prefixes would read as project-relative and point the agent somewhere that
--- does not exist.
--- @param path string
--- @param root string|nil
--- @return string display, boolean relative
local function display_path(path, root)
  if root and root ~= "" then
    local prefix = root:gsub("/+$", "") .. "/"
    if vim.startswith(path, prefix) then
      return path:sub(#prefix + 1), true
    end
  end
  return path, false
end

--- Content as vim.diff wants it: a string ending in a newline, so the last
--- line is a line rather than a fragment. nil (absent file) is the empty side.
--- @param content string|nil
--- @return string
local function diff_side(content)
  if content == nil or content == "" then
    return ""
  end
  return vim.endswith(content, "\n") and content or (content .. "\n")
end

--- One file's section of the rendered diff.
--- @param path string
--- @param fc weave.revision.FileChange
--- @param root string|nil
--- @return string
local function section(path, fc, root)
  local disp, relative = display_path(path, root)
  local a = relative and ("a/" .. disp) or disp
  local b = relative and ("b/" .. disp) or disp
  local kind = M.kind(fc)

  local lines = {}
  if kind == "created" then
    lines[#lines + 1] = "new file: " .. disp
    a = "/dev/null"
  elseif kind == "deleted" then
    lines[#lines + 1] = "deleted file: " .. disp
    b = "/dev/null"
  end
  lines[#lines + 1] = "--- " .. a
  lines[#lines + 1] = "+++ " .. b

  local hunks = vim.diff(diff_side(fc.before), diff_side(fc.after), { result_type = "unified", ctxlen = 3 })
  if hunks and hunks ~= "" then
    lines[#lines + 1] = (hunks:gsub("\n$", ""))
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Cut `text` to at most `budget` bytes, on a line boundary where possible: a
--- diff sliced mid-line reads as a line that says something it does not.
--- @param text string
--- @param budget integer
--- @return string
local function clip(text, budget)
  if budget <= 0 then
    return ""
  end
  local cut = text:sub(1, budget)
  local last = cut:match("^.*()\n")
  return last and cut:sub(1, last) or cut
end

--- The revision as diff text for the agent, or nil when nothing changed —
--- callers use that nil to decide there is nothing to send at all.
--- @param rev weave.revision.Revision|nil
--- @param opts { root?: string, max_bytes?: integer }|nil
--- @return string|nil
function M.render(rev, opts)
  opts = opts or {}
  if M.is_empty(rev) then
    return nil
  end
  local max = opts.max_bytes or M.MAX_BYTES

  local out, used, omitted, cut = {}, 0, 0, false
  for _, path in ipairs(M.paths(rev)) do
    local text = section(path, rev.files[path], opts.root)
    if used >= max then
      omitted = omitted + 1
    else
      if used + #text > max then
        text = clip(text, max - used)
        cut = true
      end
      out[#out + 1] = text
      used = used + #text
    end
  end

  -- Truncation is stated, never silent: a diff that just stops reads as a
  -- complete account of a change that was in fact bigger.
  if cut or omitted > 0 then
    local note = ("[weave] diff truncated at %d bytes"):format(max)
    if omitted > 0 then
      note = note .. (", %d more file(s) omitted"):format(omitted)
    end
    out[#out + 1] = note .. "\n"
  end
  return table.concat(out)
end

return M
