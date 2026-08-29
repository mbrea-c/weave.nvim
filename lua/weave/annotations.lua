-- weave.annotations: the agent's notes ON the user's code — feedback flowing
-- the other way from weave.feedback, which carries the USER's comments to the
-- agent. Written by the `annotate` tool suite (weave.tools.annotate) and read
-- by whoever is looking at the file.
--
-- One extmark per annotation does all three jobs at once: it highlights the
-- span, it anchors the note as the user keeps typing around it, and its
-- virt_lines ARE the rendering. Its own namespace, never the comment layer's:
-- `at_cursor` is a reverse lookup, and a shared namespace would answer
-- "dismiss the annotation I am sitting on" with somebody else's comment.
--
-- ── Drift is the hard part ──────────────────────────────────────────────────
--
-- The agent names a span from the file as it last READ it, and in tutor mode
-- the user has very likely typed since. A line number alone is a guess, so the
-- tool also takes the text the agent EXPECTED to find there. If it is not at
-- the given line, the note is re-found by that text; if the text is nowhere,
-- the call is REFUSED rather than highlighting whatever moved into the spot.
-- Wrong feedback confidently attached to unrelated code is worse than none.
--
-- Annotations for a file nobody has open are held, not dropped: an agent
-- reviewing a diff can perfectly well have something to say about a file the
-- user has since closed, and it is placed the moment the buffer comes back.

local Anchors = require("weave.feedback_anchors")
local Theme = require("weave.view.theme")

local M = {}

--- Fallback wrap width when nothing better is known (no window shows the
--- buffer, e.g. an annotation placed from a tool call before the user looks).
M.DEFAULT_WIDTH = 80

--- How many virtual lines one annotation may take over the buffer before it
--- is summarised. virt_lines push the real code down, so an essay from the
--- agent would shove the thing it is talking about off the screen.
M.MAX_LINES = 10

local layer = Anchors.layer({ name = "weave_annotations", hl = Theme.ANNOTATION_HL })
M.NS = layer.NS
M.HL = layer.HL

--- @class weave.annotations.Annotation
--- @field id integer
--- @field path string absolute path ("" for a bufferless scratch)
--- @field bufnr integer|nil buffer it is placed in, nil while pending
--- @field anchor integer|nil extmark id
--- @field pending boolean true while it waits for its file to be opened
--- @field drifted boolean the span was re-found by text, not by line number
--- @field reply_pending boolean|nil a draft comment replying to this note awaits flush
--- @field message string
--- @field position "above"|"below"
--- @field expect string[]|nil the text the agent expected at the span
--- @field lnum integer last known 1-based start line
--- @field end_lnum integer last known 1-based end line
--- @field width integer|nil wrap width override (specs; normally the window's)
--- @field max_lines integer|nil cap override
--- @field created_at integer

--- @type weave.annotations.Annotation[]
local items = {}
local next_id = 1
local subscribers = {}
local autocmd_installed = false

local function notify()
  for _, fn in ipairs({ unpack(subscribers) }) do
    pcall(fn)
  end
end

local function valid(bufnr)
  return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr)
end

--- Place pending annotations when their file appears. Registered on the first
--- annotation rather than at load: a user whose agent never annotates anything
--- never pays for the autocmd.
local function install_autocmd()
  if autocmd_installed then
    return
  end
  autocmd_installed = true
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = vim.api.nvim_create_augroup("WeaveAnnotationsAttach", { clear = true }),
    callback = function(ev)
      M.reattach(ev.buf)
    end,
  })
end

--- Wrap `text` to `width`, hard-breaking words longer than a line. Returns the
--- virt_lines chunk structure nvim wants.
--- @param text string
--- @param width integer
--- @param max_lines integer
--- @return table[] virt_lines
function M._virt_lines(text, width, max_lines)
  width = math.max(8, width)
  local lines = {}
  for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
    local current = ""
    local function flush()
      lines[#lines + 1] = current
      current = ""
    end
    for word in paragraph:gmatch("%S+") do
      while #word > width do
        if current ~= "" then
          flush()
        end
        lines[#lines + 1] = word:sub(1, width)
        word = word:sub(width + 1)
      end
      if current == "" then
        current = word
      elseif #current + 1 + #word <= width then
        current = current .. " " .. word
      else
        flush()
        current = word
      end
    end
    flush()
  end

  -- Truncation is stated: a note that just stops reads as a complete thought
  -- the agent never finished.
  if #lines > max_lines then
    local dropped = #lines - (max_lines - 1)
    for _ = max_lines, #lines do
      lines[#lines] = nil
    end
    lines[#lines + 1] = ("… %d more lines (K to read it all)"):format(dropped)
  end

  local out = {}
  for i, line in ipairs(lines) do
    out[i] = { { line, Theme.ANNOTATION_TEXT_HL } }
  end
  return out
end

--- The width to wrap at: whatever window is showing this buffer, else the
--- fallback. Computed when the mark is placed, so a later resize does not
--- reflow an existing note.
--- @param bufnr integer
--- @return integer
local function width_for(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return math.max(20, vim.api.nvim_win_get_width(win) - 4)
    end
  end
  return M.DEFAULT_WIDTH
end

--- Whether a draft comment replying to annotation `id` is pending flush.
--- @param id integer
--- @return boolean
local function reply_pending(id)
  for _, c in ipairs(require("weave.feedback_store").comments()) do
    if c.reply_to and c.reply_to.id == id then
      return true
    end
  end
  return false
end

--- (Re)place the extmark for an annotation at `lnum..end_lnum`.
--- @param ann weave.annotations.Annotation
--- @param lnum integer
--- @param end_lnum integer
local function place(ann, lnum, end_lnum)
  if ann.anchor and ann.bufnr then
    layer.clear(ann.bufnr, ann.anchor)
  end
  ann.lnum, ann.end_lnum = lnum, end_lnum
  local virt = M._virt_lines(ann.message, ann.width or width_for(ann.bufnr), ann.max_lines or M.MAX_LINES)
  if ann.reply_pending then
    -- So the user can see which notes they have already answered without
    -- opening the draft. Dimmed: it is bookkeeping, not part of the message.
    virt[#virt + 1] = { { "↩ reply pending", "@comment" } }
  end
  ann.anchor = layer.set(ann.bufnr, { lnum = lnum, end_lnum = end_lnum }, {
    virt_lines = virt,
    virt_lines_above = ann.position == "above",
  })
end

--- Where the agent's span actually is in this buffer, honouring `expect`.
--- @param bufnr integer
--- @param lnum integer
--- @param expect string[]|nil
--- @return integer|nil lnum, boolean drifted
local function locate(bufnr, lnum, expect)
  local count = vim.api.nvim_buf_line_count(bufnr)
  if not expect or #expect == 0 then
    -- Nothing to check against: take the agent at its word, clamped.
    return math.max(1, math.min(lnum, count)), false
  end
  local at = math.max(1, math.min(lnum, count))
  local here = vim.api.nvim_buf_get_lines(bufnr, at - 1, at - 1 + #expect, false)
  local same = #here == #expect
  for i = 1, #expect do
    same = same and here[i] == expect[i]
  end
  if same then
    return at, false
  end
  local found = Anchors.find(bufnr, expect)
  if found then
    return found, true
  end
  return nil, false
end

--- Attach an annotation to a span of code.
---
--- Either `bufnr` or `path`; with a path whose buffer is not loaded, the
--- annotation is held and placed on the next BufReadPost.
--- @param opts { bufnr?: integer, path?: string, lnum: integer, end_lnum?: integer, message: string, position?: "above"|"below", expect?: string[], width?: integer, max_lines?: integer }
--- @return weave.annotations.Annotation|nil annotation, string|nil err
function M.add(opts)
  opts = opts or {}
  if type(opts.message) ~= "string" or opts.message == "" then
    return nil, "an annotation needs a message"
  end
  if type(opts.lnum) ~= "number" then
    return nil, "an annotation needs a line"
  end

  local bufnr = opts.bufnr
  local path = opts.path and vim.fn.fnamemodify(opts.path, ":p") or nil
  if not bufnr and path then
    local existing = vim.fn.bufnr(path)
    if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
      bufnr = existing
    elseif vim.fn.filereadable(path) ~= 1 then
      return nil, "no such file: " .. path
    end
  end
  if not bufnr and not path then
    return nil, "an annotation needs a buffer or a path"
  end
  if bufnr and not valid(bufnr) then
    return nil, "no such buffer"
  end

  install_autocmd()

  --- @type weave.annotations.Annotation
  local ann = {
    id = next_id,
    path = path or (bufnr and vim.api.nvim_buf_get_name(bufnr)) or "",
    bufnr = bufnr,
    anchor = nil,
    pending = bufnr == nil,
    drifted = false,
    message = opts.message,
    position = opts.position == "above" and "above" or "below",
    expect = opts.expect,
    lnum = opts.lnum,
    end_lnum = opts.end_lnum or opts.lnum,
    width = opts.width,
    max_lines = opts.max_lines,
    created_at = os.time(),
  }

  if bufnr then
    local at, drifted = locate(bufnr, ann.lnum, ann.expect)
    if not at then
      -- Refuse rather than point at whatever moved in. In tutor mode the user
      -- is editing while the agent reviews, so this is the common case, not a
      -- corner one, and a note confidently attached to unrelated code is
      -- worse than a note that never landed.
      return nil, "the code you annotated is no longer there (it may have been edited since you read it)"
    end
    ann.drifted = drifted
    local span = ann.end_lnum - ann.lnum
    place(ann, at, math.min(at + span, vim.api.nvim_buf_line_count(bufnr)))
  end

  next_id = next_id + 1
  items[#items + 1] = ann
  notify()
  return ann
end

--- @param id integer
--- @return weave.annotations.Annotation|nil
function M.get(id)
  for _, ann in ipairs(items) do
    if ann.id == id then
      return ann
    end
  end
  return nil
end

--- Where an annotation's code sits NOW. Refreshes the cached position as a
--- side effect, so an orphaned note still reports where its code was last
--- seen rather than where it was first written.
--- @param ann weave.annotations.Annotation
--- @return { lnum: integer, end_lnum: integer, orphaned: boolean }
function M.resolve(ann)
  local live = ann.bufnr and ann.anchor and layer.range(ann.bufnr, ann.anchor) or nil
  if live then
    ann.lnum, ann.end_lnum = live.lnum, live.end_lnum
    return { lnum = live.lnum, end_lnum = live.end_lnum, orphaned = false }
  end
  return { lnum = ann.lnum, end_lnum = ann.end_lnum, orphaned = not ann.pending }
end

--- Everything outstanding, each resolved to where it sits now.
--- @param filter { path?: string }|nil
--- @return weave.annotations.Annotation[]
function M.list(filter)
  filter = filter or {}
  local want = filter.path and vim.fn.fnamemodify(filter.path, ":p") or nil
  local out = {}
  for _, ann in ipairs(items) do
    if not want or ann.path == want then
      M.resolve(ann)
      out[#out + 1] = ann
    end
  end
  return out
end

--- Change an annotation's message or where its lines sit relative to the code.
--- @param id integer
--- @param opts { message?: string, position?: "above"|"below" }
--- @return boolean ok
function M.update(id, opts)
  local ann = M.get(id)
  if not ann then
    return false
  end
  if type(opts.message) == "string" and opts.message ~= "" then
    ann.message = opts.message
  end
  if opts.position == "above" or opts.position == "below" then
    ann.position = opts.position
  end
  if ann.bufnr and ann.anchor then
    -- The mark carries the rendering, so a changed message means a new mark.
    local at = M.resolve(ann)
    place(ann, at.lnum, at.end_lnum)
  end
  notify()
  return true
end

--- @param id integer
--- @return boolean ok
function M.dismiss(id)
  for i, ann in ipairs(items) do
    if ann.id == id then
      if ann.bufnr and ann.anchor then
        layer.clear(ann.bufnr, ann.anchor)
      end
      table.remove(items, i)
      notify()
      return true
    end
  end
  return false
end

--- The annotation covering `lnum` in `bufnr`, if any. Backs "dismiss the note
--- I am sitting on".
--- @param bufnr integer
--- @param lnum integer 1-based
--- @return weave.annotations.Annotation|nil
function M.at_cursor(bufnr, lnum)
  local ids = {}
  for _, id in ipairs(layer.at(bufnr, lnum)) do
    ids[id] = true
  end
  for _, ann in ipairs(items) do
    if ann.bufnr == bufnr and ann.anchor and ids[ann.anchor] then
      return ann
    end
  end
  return nil
end

--- @param bufnr integer
--- @param lnum integer
--- @return boolean ok
function M.dismiss_at(bufnr, lnum)
  local ann = M.at_cursor(bufnr, lnum)
  return ann ~= nil and M.dismiss(ann.id)
end

--- Drop every annotation, or every one for a path.
--- @param filter { path?: string }|nil
function M.clear(filter)
  for _, ann in ipairs(M.list(filter)) do
    M.dismiss(ann.id)
  end
end

--- Place (or re-place) this buffer's annotations: the pending ones waiting for
--- the file to open, and any whose extmark died with a previous unload.
--- @param bufnr integer
function M.reattach(bufnr)
  if not valid(bufnr) then
    return
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return
  end
  local changed = false
  for _, ann in ipairs(items) do
    if ann.path == path and not (ann.bufnr and ann.anchor and layer.range(ann.bufnr, ann.anchor)) then
      local at, drifted = locate(bufnr, ann.lnum, ann.expect)
      if at then
        ann.bufnr = bufnr
        ann.pending = false
        ann.drifted = ann.drifted or drifted
        ann.anchor = nil
        place(ann, at, math.min(at + (ann.end_lnum - ann.lnum), vim.api.nvim_buf_line_count(bufnr)))
        changed = true
      end
    end
  end
  if changed then
    notify()
  end
end

--- Recompute each annotation's reply-pending marker from the feedback draft.
--- Derived, not stored: "a reply is pending" MEANS "a draft comment with
--- reply_to = this id exists", so scanning the draft can never disagree with
--- the truth the way create/clear bookkeeping could. Driven by the store's
--- change feed (see the link at the bottom of the module).
function M.refresh_reply_markers()
  local changed = false
  for _, ann in ipairs(items) do
    local pending = reply_pending(ann.id)
    if (ann.reply_pending or false) ~= pending then
      ann.reply_pending = pending
      changed = true
      if ann.bufnr and ann.anchor then
        local at = M.resolve(ann)
        place(ann, at.lnum, at.end_lnum)
      end
    end
  end
  if changed then
    notify()
  end
end

--- @param fn fun() called on every change
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

--- Follow the feedback store so reply markers track the draft. Module-local
--- handle: the store's test hook wipes its subscribers, so _reset re-links to
--- keep specs order-independent (unlinking a wiped subscription is a no-op).
local unlink
local function link_store()
  if unlink then
    unlink()
  end
  unlink = require("weave.feedback_store").subscribe(function()
    M.refresh_reply_markers()
  end)
end

-- test hook
function M._reset()
  for _, ann in ipairs(items) do
    if ann.bufnr and ann.anchor then
      layer.clear(ann.bufnr, ann.anchor)
    end
  end
  items = {}
  next_id = 1
  subscribers = {}
  link_store()
end

link_store()

return M
