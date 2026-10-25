-- Editor-global store for inline code feedback: ONE in-progress item at a time,
-- where an item is a BUNDLE of comments the user has attached to spans of code.
-- Comments can come from anywhere — weave's own commenting keymaps, perijove,
-- any plugin that calls M.add — and they all land in the same draft, which is
-- sent to the agent as a single message. See weave.feedback for the public API
-- users bind, and weave.feedback_sinks for where a sent item goes.
--
-- File comments are editor-global and choose their destination at send time.
-- Transcript comments share the draft UI but belong to their captured conversation.
-- Delivery and discard select only the destination's comments.
--
-- Anchoring lives in weave.feedback_anchors; this module only caches each
-- comment's last known position so an orphaned comment can still say where its
-- code used to be instead of vanishing.
--
-- Notification is synchronous, unlike weave.task_store's coalesced signal:
-- every mutation here is a discrete user action, not a stream of process
-- output, so there is nothing to coalesce and a caller can rely on the UI
-- having been told by the time add() returns.

local Anchors = require("weave.feedback_anchors")

local M = {}

--- @class weave.feedback.Comment
--- @field id integer
--- @field source string what created it ("weave", "perijove", ...)
--- @field bufnr integer|nil buffer it was captured in, if still valid
--- @field path string absolute file path ("" for a bufferless scratch)
--- @field anchor integer|nil extmark id, nil once it has died
--- @field quote string[] the code it points at, captured at comment time
--- @field lnum integer last known 1-based start line
--- @field end_lnum integer last known 1-based end line
--- @field col integer|nil 1-based start column for a partial selection
--- @field end_col integer|nil 1-based end column for a partial selection
--- @field body string the user's comment
--- @field reply_to weave.feedback.ReplyTo|nil the agent annotation this answers
--- @field created_at integer
--- @field target? table Semantic transcript target; absent for file comments
--- @field _owner? weave.store.SessionStore Owning conversation store, never serialized
--- @field _history? weave.transcript.History Captured history identity, never serialized

--- What a reply comment is answering. The message is a SNAPSHOT of the
--- annotation as the user read it: annotations get updated and dismissed while
--- a reply sits in the draft, and the reply must quote what was actually on
--- screen, not whatever the note says by send time. The id rides along so the
--- agent can correlate (and act on the annotation it still holds).
--- @class weave.feedback.ReplyTo
--- @field id integer the annotation id (weave.annotations)
--- @field message string the annotation text at reply time

--- @class weave.feedback.Item
--- @field id integer
--- @field comments weave.feedback.Comment[]
--- @field created_at integer

--- @type weave.feedback.Item|nil
local draft = nil
local next_item_id = 1
local next_comment_id = 1
local subscribers = {}
local autocmd_installed = false

local function notify()
  local transcript = package.loaded["weave.transcript_feedback"]
  if transcript then transcript.refresh(M.comments()) end
  for _, fn in ipairs({ unpack(subscribers) }) do
    pcall(fn)
  end
end

--- Re-place anchors on any buffer weave has comments for, once it is (re)read.
--- Registered on the first comment rather than at load: a user who never
--- comments never pays for the autocmd.
local function install_autocmd()
  if autocmd_installed then
    return
  end
  autocmd_installed = true
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = vim.api.nvim_create_augroup("WeaveFeedbackReattach", { clear = true }),
    callback = function(ev)
      M.reattach(ev.buf)
    end,
  })
end

--- @return weave.feedback.Item|nil
function M.draft()
  return draft
end

--- The open draft's comments (empty when there is no draft).
--- @return weave.feedback.Comment[]
function M.comments()
  return draft and draft.comments or {}
end

--- A view of the draft safe to deliver to this conversation. File comments keep
--- their existing editor-global behavior; transcript comments never follow UI focus.
function M.item_for(session)
  local store = session and session.get_store and session:get_store()
  local comments = {}
  for _, comment in ipairs(M.comments()) do
    if not comment.target or (comment._owner == store and comment._history == store:transcript()) then
      comments[#comments + 1] = comment
    end
  end
  if #comments > 0 then
    return { id = draft.id, created_at = draft.created_at, comments = comments }
  end
end

--- Capture what was queued, not mutable draft references.
function M.snapshot(item)
  local snapshot = {}
  for _, comment in ipairs((item or {}).comments or {}) do snapshot[comment.id] = comment.body end
  return snapshot
end

--- Delivery consumes only the version actually sent. Later edits stay pending.
function M.consume(snapshot)
  local ids = {}
  for _, comment in ipairs(M.comments()) do
    if snapshot[comment.id] == comment.body then ids[#ids + 1] = comment.id end
  end
  for _, id in ipairs(ids) do M.remove(id) end
end

--- @param id integer
--- @return weave.feedback.Comment|nil
function M.get(id)
  for _, c in ipairs(M.comments()) do
    if c.id == id then
      return c
    end
  end
  return nil
end

--- Attach a comment to a span of code, opening a draft if none is open.
--- @param opts { bufnr: integer, range: weave.feedback.Range, body?: string, source?: string, reply_to?: weave.feedback.ReplyTo }
--- @return weave.feedback.Comment|nil comment, string|nil err
function M.add(opts)
  opts = opts or {}
  local bufnr = opts.bufnr == 0 and vim.api.nvim_get_current_buf() or opts.bufnr
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "no valid buffer to comment on"
  end
  local range = opts.range
  if type(range) ~= "table" or type(range.lnum) ~= "number" then
    return nil, "a comment needs a line range"
  end
  range.end_lnum = range.end_lnum or range.lnum
  local capture, capture_err = require("weave.transcript_feedback").capture(bufnr, range)
  if capture_err then return nil, capture_err end

  install_autocmd()
  if not draft then
    draft = { id = next_item_id, comments = {}, created_at = os.time() }
    next_item_id = next_item_id + 1
  end

  --- @type weave.feedback.Comment
  local comment = {
    id = next_comment_id,
    source = opts.source or "weave",
    bufnr = bufnr,
    path = vim.api.nvim_buf_get_name(bufnr),
    anchor = not capture and Anchors.set(bufnr, range) or nil,
    quote = capture and capture.quote or Anchors.quote(bufnr, range),
    target = capture and capture.target, _owner = capture and capture.owner, _history = capture and capture.history,
    lnum = range.lnum,
    end_lnum = range.end_lnum,
    col = not capture and range.col or nil,
    end_col = not capture and range.end_col or nil,
    body = opts.body or "",
    reply_to = opts.reply_to,
    created_at = os.time(),
  }
  next_comment_id = next_comment_id + 1
  draft.comments[#draft.comments + 1] = comment
  if capture then require("weave.transcript_feedback").install(M.comments) end
  notify()
  return comment
end

--- @param id integer
--- @param body string
function M.update(id, body)
  local c = M.get(id)
  if not c then
    return
  end
  c.body = body
  notify()
end

--- Drop a comment and its highlight. Removing the last one closes the draft:
--- an empty feedback item is not a thing the user can send, and leaving it open
--- would keep an empty section in the sidebar.
--- @param id integer
function M.remove(id)
  if not draft then
    return
  end
  for i, c in ipairs(draft.comments) do
    if c.id == id then
      if c.bufnr and c.anchor then
        Anchors.clear(c.bufnr, c.anchor)
      end
      table.remove(draft.comments, i)
      if #draft.comments == 0 then
        draft = nil
      end
      notify()
      return
    end
  end
end

--- Discard the whole draft, clearing every highlight it placed.
function M.clear()
  for _, c in ipairs(M.comments()) do
    if c.bufnr and c.anchor then
      Anchors.clear(c.bufnr, c.anchor)
    end
  end
  draft = nil
  notify()
end

--- Where a comment's code sits NOW. Refreshes the cached position as a side
--- effect, so a comment that is later orphaned still reports where its code was
--- last seen rather than where it was originally written.
--- @param comment weave.feedback.Comment
--- @return { lnum: integer, end_lnum: integer, col: integer|nil, end_col: integer|nil, orphaned: boolean }
function M.resolve(comment)
  if comment.target then return require("weave.transcript_feedback").resolve(comment) end
  local live = comment.bufnr and comment.anchor and Anchors.range(comment.bufnr, comment.anchor) or nil
  if live then
    comment.lnum, comment.end_lnum = live.lnum, live.end_lnum
    return { lnum = live.lnum, end_lnum = live.end_lnum, col = live.col, end_col = live.end_col, orphaned = false }
  end
  return {
    lnum = comment.lnum,
    end_lnum = comment.end_lnum,
    col = comment.col,
    end_col = comment.end_col,
    orphaned = true,
  }
end

--- The comment covering `lnum` in `bufnr`, if any. Backs "edit the comment I am
--- sitting on".
--- @param bufnr integer
--- @param lnum integer 1-based
--- @return weave.feedback.Comment|nil
function M.at_cursor(bufnr, lnum)
  for _, comment in ipairs(M.comments()) do
    if comment.target then
      for _, loc in ipairs(M.resolve(comment).locations) do
        if loc.bufnr == bufnr and loc.row + 1 == lnum then return comment end
      end
    end
  end
  local ids = {}
  for _, id in ipairs(Anchors.at(bufnr, lnum)) do
    ids[id] = true
  end
  for _, c in ipairs(M.comments()) do
    if c.bufnr == bufnr and c.anchor and ids[c.anchor] then
      return c
    end
  end
  return nil
end

--- Re-place anchors for this buffer's comments after an unload or reload killed
--- their extmarks. Comments whose quoted code is no longer findable are left
--- alone, and stay orphaned.
--- @param bufnr integer
function M.reattach(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return
  end
  local changed = false
  for _, c in ipairs(M.comments()) do
    if not c.target and c.path == path and not (c.anchor and Anchors.range(bufnr, c.anchor)) then
      local at = Anchors.find(bufnr, c.quote)
      if at then
        c.bufnr = bufnr
        c.lnum, c.end_lnum = at, at + #c.quote - 1
        -- Columns described the ORIGINAL line's text; after a re-find the safe
        -- claim is the whole line span, not a column offset into it.
        c.col, c.end_col = nil, nil
        c.anchor = Anchors.set(bufnr, { lnum = c.lnum, end_lnum = c.end_lnum })
        changed = true
      end
    end
  end
  if changed then
    notify()
  end
end

--- @param fn fun() called on every draft change
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

-- test hook
function M._reset()
  local transcript = package.loaded["weave.transcript_feedback"]
  if transcript then transcript.refresh({}) end
  for _, c in ipairs(M.comments()) do
    if c.bufnr and c.anchor then
      Anchors.clear(c.bufnr, c.anchor)
    end
  end
  draft = nil
  subscribers = {}
  next_item_id, next_comment_id = 1, 1
end

return M
