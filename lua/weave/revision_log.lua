-- weave.revision_log: where user edits become revisions (weave.revision).
--
-- Append-only and UNBOUNDED. Sessions read it through a CURSOR — an id they
-- have already sent — rather than draining it, so two sessions in tutor mode
-- debouncing at different phases each get exactly their own unseen window and
-- neither consumes the other's. Nothing is durable across a restart; that is
-- what git is for.
--
-- ── What counts as a user edit ──────────────────────────────────────────────
--
-- Three things write to a buffer, and only one of them is the user:
--
--   * weave's own tools. Exact: they run inside M.suppress, which re-baselines
--     instead of recording, so the agent's write becomes the floor the user's
--     NEXT edit is measured from rather than being attributed to them.
--   * a reload from disk (:e!, autoread, a checktime after an external
--     change). M.rebaseline, wired to nvim_buf_attach's on_reload, adopts the
--     new content silently. It is not the user's work and it is not the
--     agent's either.
--   * the user. Everything else.
--
-- The known hole is `task_start`: a formatter or codemod the agent runs in a
-- shell touches files without weave ever seeing the write, so it lands here as
-- the user's edit. Closing it would mean snapshotting the project around every
-- task, which costs more than the misattribution does — so the tutor prompt
-- says out loud that a diff may contain the agent's own work.
--
-- ── Bursts ──────────────────────────────────────────────────────────────────
--
-- A revision covers an editing BURST, not a keystroke: changes accumulate
-- against a per-buffer baseline and close_burst() turns everything dirty into
-- ONE revision. Since sends squash anyway, the exact boundary barely matters —
-- it exists so the log reads as a sequence of edits rather than of characters.

local Revision = require("weave.revision")

local M = {}

--- Idle time after a change before the burst closes. Bursts are cut on
--- InsertLeave and BufWritePost too; this catches normal-mode editing that
--- never leaves insert or saves.
M.BURST_MS = 2000

--- @type weave.revision.Revision[] append-only, oldest first
local revisions = {}
local next_id = 1

--- Per tracked buffer: the content the next revision is measured FROM. A nil
--- entry with a live `tracked` flag means the file did not exist — that is
--- what makes a creation a creation rather than a modification of nothing.
--- @type table<integer, string|nil>
local baseline = {}
--- @type table<integer, boolean>
local tracked = {}
--- @type table<integer, string>
local buf_path = {}
--- Buffers changed since the last close_burst.
--- @type table<integer, boolean>
local dirty = {}
--- Paths whose buffer went away while the file was gone, pending a burst.
--- @type table<string, string> path -> content it last held
local removed = {}

--- @type fun(rev: weave.revision.Revision)[]
local subscribers = {}

local suppressed = false
local burst_timer = nil
local augroup = nil
local attached = {}

--- @param bufnr integer
--- @return boolean
local function valid(bufnr)
  return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr)
end

--- Buffer content as one string, newline-terminated, matching how the file
--- would read on disk. One string rather than a table of lines because the log
--- is unbounded: a 2000-line file is one allocation here and 2000 there.
--- @param bufnr integer
--- @return string
local function content_of(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

--- @param path string
--- @return string|nil nil when the file does not exist
local function disk_content(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Is this a buffer whose edits are the user's work on the project? Ordinary
--- file buffers under the project root only: a terminal, weave's own panel and
--- a file in some unrelated checkout are all noise a tutor should not be shown.
--- @param bufnr integer
--- @return boolean, string|nil path
function M._eligible(bufnr)
  if not valid(bufnr) then
    return false, nil
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false, nil
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return false, nil
  end
  path = vim.fn.fnamemodify(path, ":p")
  local ok, Permissions = pcall(require, "weave.permissions")
  local root = ok and Permissions.project_root() or nil
  if not root or root == "" then
    return false, nil
  end
  root = root:gsub("/+$", "")
  if path ~= root and not vim.startswith(path, root .. "/") then
    return false, nil
  end
  return true, path
end

--- Start watching a buffer, taking its current state as the baseline.
--- Idempotent: re-tracking a buffer already known must NOT reset the baseline,
--- or every BufWinEnter would quietly forget the edits made since the last
--- send.
--- @param bufnr integer
--- @return boolean tracked
function M.track(bufnr)
  local ok, path = M._eligible(bufnr)
  if not ok then
    return false
  end
  if tracked[bufnr] then
    return true
  end
  tracked[bufnr] = true
  buf_path[bufnr] = path
  -- A file that is not on disk yet has NO before side. The buffer may already
  -- hold text (`:e new.lua` then typing before any save), and that text is the
  -- creation, not a modification of an empty file.
  --
  -- For a file that DOES exist, the baseline is what the buffer holds right
  -- now, not what disk holds: tracking starts when tutor mode does, and unsaved
  -- edits made before that are as much "already there" as saved ones.
  if vim.fn.filereadable(path) ~= 1 then
    baseline[bufnr] = nil
  elseif vim.api.nvim_buf_is_loaded(bufnr) then
    baseline[bufnr] = content_of(bufnr)
  else
    baseline[bufnr] = disk_content(path)
  end
  M._attach(bufnr)
  return true
end

--- Adopt a buffer's current content as the baseline without recording
--- anything. This is what a reload is, and what an agent write becomes.
--- @param bufnr integer
function M.rebaseline(bufnr)
  if not tracked[bufnr] or not valid(bufnr) then
    return
  end
  baseline[bufnr] = content_of(bufnr)
  dirty[bufnr] = nil
end

--- Adopt whatever is at `path` now as the baseline for whichever tracked
--- buffer holds it. The straight-to-disk write path has no buffer event to
--- ride on, so it says this explicitly.
--- @param path string
function M.rebaseline_path(path)
  if type(path) ~= "string" or path == "" then
    return
  end
  local abs = vim.fn.fnamemodify(path, ":p")
  for bufnr, tracked_path in pairs(buf_path) do
    if tracked_path == abs then
      if valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        M.rebaseline(bufnr)
      else
        baseline[bufnr] = disk_content(abs)
        dirty[bufnr] = nil
      end
    end
  end
end

--- Note that a tracked buffer changed. Cheap on purpose: it marks and arms,
--- and the content comparison waits for the burst to close.
--- @param bufnr integer
function M.note_change(bufnr)
  if suppressed then
    -- An agent write in flight. Take its result as the new floor rather than
    -- recording it, so the user's next edit is measured from what the agent
    -- left behind.
    M.rebaseline(bufnr)
    return
  end
  if not tracked[bufnr] then
    return
  end
  dirty[bufnr] = true
  M._arm()
end

--- Stop watching a buffer. If its file went with it, that is a deletion, and
--- it is held until the next burst so it lands in the same revision as
--- whatever else the user was doing.
--- @param bufnr integer
function M.forget(bufnr)
  if not tracked[bufnr] then
    return
  end
  local path = buf_path[bufnr]
  local before = baseline[bufnr]
  if path and before ~= nil and disk_content(path) == nil then
    removed[path] = before
    M._arm()
  end
  tracked[bufnr] = nil
  baseline[bufnr] = nil
  buf_path[bufnr] = nil
  dirty[bufnr] = nil
  attached[bufnr] = nil
end

--- Run `fn` with collection off: everything it touches re-baselines instead of
--- being recorded. This is the seam weave's own write tools go through.
--- @generic T
--- @param fn fun(): T
--- @return T
function M.suppress(fn)
  local was = suppressed
  suppressed = true
  local ok, result = pcall(fn)
  suppressed = was
  if not ok then
    error(result, 0)
  end
  return result
end

--- @return boolean
function M.suppressed()
  return suppressed
end

--- Close the current burst: turn every dirty buffer (and any pending deletion)
--- into ONE revision. A burst that netted no change appends nothing and burns
--- no id — an empty revision in the log would make `since()` look like there
--- is something to send when there is not.
--- @return weave.revision.Revision|nil the revision appended, if any
function M.close_burst()
  M._disarm()

  local files = {}
  for bufnr in pairs(dirty) do
    local path = buf_path[bufnr]
    if path then
      local before = baseline[bufnr]
      local after = valid(bufnr) and content_of(bufnr) or disk_content(path)
      if before ~= after then
        files[path] = { before = before, after = after }
      end
      baseline[bufnr] = after
    end
  end
  for path, before in pairs(removed) do
    files[path] = { before = before, after = nil }
  end
  dirty = {}
  removed = {}

  if next(files) == nil then
    return nil
  end

  local rev = Revision.new({ id = next_id, at = M._now(), files = files })
  next_id = next_id + 1
  revisions[#revisions + 1] = rev
  for _, fn in ipairs({ unpack(subscribers) }) do
    pcall(fn, rev)
  end
  return rev
end

--- Hear about each appended revision. Edit sync uses this to arm its
--- debounce; the log itself never decides when anything is sent.
--- @param fn fun(rev: weave.revision.Revision)
--- @return fun() unsubscribe
function M.subscribe(fn)
  subscribers[#subscribers + 1] = fn
  return function()
    for i, f in ipairs(subscribers) do
      if f == fn then
        table.remove(subscribers, i)
        return
      end
    end
  end
end

--- Every revision newer than `after_id`, oldest first.
--- @param after_id integer|nil a cursor; nil or 0 means "everything"
--- @return weave.revision.Revision[]
function M.since(after_id)
  after_id = after_id or 0
  local out = {}
  for _, rev in ipairs(revisions) do
    if rev.id > after_id then
      out[#out + 1] = rev
    end
  end
  return out
end

--- The window past `after_id` as a single revision — what a tutor-mode send
--- carries.
--- @param after_id integer|nil
--- @return weave.revision.Revision|nil
function M.squash_since(after_id)
  local squashed = Revision.squash(M.since(after_id))
  if Revision.is_empty(squashed) then
    return nil
  end
  return squashed
end

--- The newest revision id, or 0 when nothing has been recorded. A session
--- entering tutor mode starts its cursor here: the backlog from before it was
--- watching is not its business.
--- @return integer
function M.head_id()
  return #revisions > 0 and revisions[#revisions].id or 0
end

--- @return integer ms
function M._now()
  return math.floor(vim.uv and vim.uv.now() or vim.loop.now())
end

--- ── nvim wiring ─────────────────────────────────────────────────────────────

--- Watch a buffer's changes at the source. nvim_buf_attach rather than
--- TextChanged because it fires for EVERY mutation including programmatic
--- ones, which is what makes suppression the single point where provenance is
--- decided instead of a guess about which autocmd fires for whom.
--- @param bufnr integer
function M._attach(bufnr)
  if attached[bufnr] or not valid(bufnr) then
    return
  end
  attached[bufnr] = true
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      if not tracked[bufnr] then
        return true -- detach
      end
      M.note_change(bufnr)
    end,
    on_reload = function()
      M.rebaseline(bufnr)
    end,
    on_detach = function()
      attached[bufnr] = nil
    end,
  })
end

--- (Re)start the idle timer that closes the burst.
function M._arm()
  M._disarm()
  burst_timer = vim.defer_fn(function()
    burst_timer = nil
    M.close_burst()
  end, M.BURST_MS)
end

function M._disarm()
  if burst_timer then
    pcall(function()
      burst_timer:stop()
    end)
    burst_timer = nil
  end
end

--- Begin collecting. Called when the first session enters tutor mode; a second
--- one changes nothing (collection is editor-global, consumption is not).
function M.start()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("WeaveRevisionLog", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWinEnter" }, {
    group = augroup,
    callback = function(ev)
      M.track(ev.buf)
    end,
  })
  -- A save and leaving insert are natural burst boundaries: the user has
  -- finished a thought, and waiting out the idle timer would only delay it.
  vim.api.nvim_create_autocmd({ "BufWritePost", "InsertLeave" }, {
    group = augroup,
    callback = function()
      M.close_burst()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = augroup,
    callback = function(ev)
      M.forget(ev.buf)
    end,
  })
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.track(bufnr)
    end
  end
end

--- Stop collecting. The log itself is KEPT: a session that toggles tutor mode
--- off and on again should not be told the user changed nothing meanwhile, and
--- its cursor still points into this log.
function M.stop()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  M._disarm()
  M.close_burst()
  tracked = {}
  baseline = {}
  buf_path = {}
  dirty = {}
end

--- @return boolean
function M.collecting()
  return augroup ~= nil
end

-- test hook
function M._reset()
  M.stop()
  revisions = {}
  next_id = 1
  removed = {}
  attached = {}
  suppressed = false
end

return M
