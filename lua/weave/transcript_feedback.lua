-- Semantic transcript anchors. Extmarks are a disposable projection, not identity.
local Content = require("weave.transcript_content")
local ok, Sources = pcall(require, "fibrous.sources")
local M = {}
local namespace = vim.api.nvim_create_namespace("WeaveTranscriptFeedback")
local painted, installed = {}, false

function M.source(store, record, part, read, offset)
  if not ok or not store or not record then return nil end
  return { id = record.id .. "/" .. part, text = read or Content.part(record, part), offset = offset or 0,
    data = { weave = true, store = store, history = store:transcript(), entry_id = record.id,
      part = part, revision = record.revision, read = read } }
end

function M.capture(buf, range)
  if not ok then
    if vim.b[buf].weave_transcript then return nil, "transcript feedback requires updated Fibrous source mapping" end
    return nil
  end
  local matches = Sources.resolve(buf, range)
  for _, match in ipairs(matches) do
    local data = match.source.data
    if data and data.weave and not data.store.state.transcript_sources then
      -- Mapping changes no geometry. Re-resolve the same visual selection after
      -- the synchronous rerender, now against exact Markdown provenance.
      data.store:enable_transcript_sources()
      return M.capture(buf, range)
    end
  end
  local spans, quotes = {}, {}
  --- @type weave.store.SessionStore|nil
  local owner
  --- @type weave.transcript.History|nil
  local history
  for _, match in ipairs(matches) do
    local data = match.source.data
    if data and data.weave then
      if owner and (owner ~= data.store or history ~= data.history) then return nil, "selection crosses conversations" end
      owner, history = data.store, data.history
      local record = history:get(data.entry_id)
      if not record then return nil, "captured transcript entry is no longer available" end
      local text = data.read and data.read() or Content.part(record, data.part)
      if type(text) ~= "string" then return nil, "this transcript content is not addressable" end
      local start, finish = match.start_byte, match.end_byte
      local quote = match.quote
      if match.precision == "entry" then
        start, finish = 0, #text
        if quote == "" then quote = text end
      end
      spans[#spans + 1] = { entry_id = data.entry_id, part = data.part, revision = data.revision,
        source_id = match.source.id, start_byte = start, end_byte = finish, precision = match.precision,
        original = text:sub(start + 1, finish), quote = quote, _read = data.read }
      quotes[#quotes + 1] = quote
    end
  end
  if #spans == 0 then
    if vim.b[buf].weave_transcript then return nil, "select message content or a tool call, not transcript controls" end
    return nil
  end
  assert(owner and history, "transcript source is missing its conversation")
  local session_key
  for _, entry in ipairs(require("weave.registry").list()) do
    if entry.session:get_store() == owner then session_key = entry.key; break end
  end
  return { target = { kind = "transcript", conversation_id = history.id, session_key = session_key,
      title = owner.state.meta.title, spans = spans },
    owner = owner, history = history, quote = vim.split(table.concat(quotes, "\n"), "\n", { plain = true }) }
end

local function available(comment)
  if not comment._owner or comment._owner:transcript() ~= comment._history then return false end
  if comment.target.session_key then
    local entry = require("weave.registry").get(comment.target.session_key)
    if not entry or entry.session:get_store() ~= comment._owner then return false end
  end
  return true
end

function M.resolve(comment)
  local locations, state = {}, "hidden"
  local history = comment._history
  if not available(comment) then state = "unavailable"
  else
    for _, span in ipairs(comment.target.spans) do
      local record = history:get(span.entry_id)
      local text = record and Content.part(record, span.part)
      if record and span._read and (record.revision == span.revision or text == nil) then text = span._read() end
      if not record or type(text) ~= "string" then state = "unavailable"; break end
      if text:sub(span.start_byte + 1, span.end_byte) ~= span.original then state = "changed"; break end
      local projected = span.precision == "entry" and Sources.entry_locations(span.entry_id)
        or Sources.project(span.source_id, span.start_byte, span.end_byte)
      for _, loc in ipairs(projected) do locations[#locations + 1] = loc end
    end
    if state == "hidden" and #locations > 0 then state = "visible" end
  end
  if state == "changed" or state == "unavailable" then locations = {} end
  local first = locations[1]
  return { state = state, orphaned = state == "changed" or state == "unavailable", locations = locations,
    lnum = first and first.row + 1 or comment.lnum, end_lnum = first and first.row + 1 or comment.end_lnum,
    col = first and first.start_col + 1 or nil, end_col = first and first.end_col or nil }
end

function M.refresh(comments)
  for buf in pairs(painted) do
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1) end
  end
  painted = {}
  for _, comment in ipairs(comments) do
    if comment.target and comment.target.kind == "transcript" then
      for _, loc in ipairs(M.resolve(comment).locations) do
        if loc.end_col > loc.start_col then
          vim.api.nvim_buf_set_extmark(loc.bufnr, namespace, loc.row, loc.start_col, {
            end_row = loc.row, end_col = loc.end_col, hl_group = require("weave.view.theme").CODE_FEEDBACK_HL,
            priority = 200,
          })
          painted[loc.bufnr] = true
        end
      end
    end
  end
end

function M.install(get_comments)
  if installed or not ok then return end
  installed = true
  Sources.subscribe(function() M.refresh(get_comments()) end)
end

function M.label(comment)
  local first = comment.target.spans[1]
  local record = comment._history:get(first.entry_id)
  local title = comment._owner:transcript() == comment._history and comment._owner.state.meta.title or comment.target.title
  if not title or title == "" then title = "Transcript " .. (comment._history.id:match("conversation%-(%d+)$") or "") end
  return title .. " / " .. (record and record.entry.kind or "message") .. " #" .. (record and record.sequence or "?")
end

local function focus(locations)
  for _, loc in ipairs(locations) do
    for _, win in ipairs(vim.fn.win_findbuf(loc.bufnr)) do
      if vim.api.nvim_win_is_valid(win) and not vim.api.nvim_win_get_config(win).hide then
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { loc.row + 1, loc.start_col })
        vim.cmd("normal! zz")
        return true
      end
    end
  end
  return false
end

function M.goto_comment(comment)
  if not available(comment) then return false end
  local store, first = comment._owner, comment.target.spans[1]
  local record = comment._history:get(first.entry_id)
  if not record then return false end
  local owner
  for _, entry in ipairs(require("weave.registry").list()) do
    if entry.session:get_store() == store then owner = entry; entry.prefs:set("follow", false); break end
  end
  store:reveal_entry(record.sequence)
  if record.tool and first.part ~= "entry" and not store.state.expanded[record.tool.tool_call_id] then
    store:toggle_tool_call(record.tool.tool_call_id)
  end
  if owner then require("weave").open_session(owner.key) end
  if focus(M.resolve(comment).locations) then return true end
  local found = focus(Sources.entry_locations(first.entry_id))
  if found then vim.schedule(function() focus(M.resolve(comment).locations) end) end
  return found
end

return M
