local ui = require("fibrous.inline.components")
local Width = require("fibrous.inline.width")
local Theme = require("weave.view.theme")

local TITLE = "Last prompt: "

-- Cut by display cells, not bytes, using the same clusters as the painter.
local function fits(text, columns)
  local bytes, cells = 0, 0
  for cluster in Width.clusters(text) do
    cells = cells + Width.char(cluster)
    if cells > columns then break end
    bytes = bytes + #cluster
  end
  return bytes
end

local function preview(text, columns)
  if columns == 0 then return "" end
  local title = columns >= #TITLE + 4 and TITLE or (columns >= 6 and "❯ " or "")
  local cut = fits(text, columns - Width.str(title))
  local first = text:sub(1, cut)
  if cut < #text and text:sub(cut + 1, cut + 1) ~= " " then
    -- Prefer breaking at a word boundary; hard-cut an unbroken path or word.
    local space = first:match(".*() ")
    if space then cut, first = space - 1, first:sub(1, space - 1) end
  end
  local rest = text:sub(cut + 1):gsub("^ +", "")
  local tail = fits(rest, columns)
  if tail < #rest then
    local ellipsis = Width.str("…") <= columns and "…" or "."
    rest = rest:sub(1, fits(rest, columns - Width.str(ellipsis))):gsub(" +$", "") .. ellipsis
  end
  return { { title, hl = Theme.USER_MARKER_HL }, first:gsub(" +$", "") .. "\n" .. rest }
end

-- Use entry ownership, not the text in a rendered row: borders, wrapped
-- Markdown and identical messages must all have the same boundary semantics.
local has_sources, Sources = pcall(require, "fibrous.sources")
local function reading_prompt(props, buf, top)
  local store = props.store
  local history = store:transcript()
  if #history.prompts == 0 then return nil end
  -- One gap and at most one history control can precede the next entry.
  for row = top, math.min(top + 2, vim.api.nvim_buf_line_count(buf)) do
    for _, match in ipairs(Sources.resolve(buf, { lnum = row, col = 1, end_col = 1 })) do
      local data = match.source.data
      local record = data and data.history == history and history:get(data.entry_id)
      if record then
        if row == top and record.prompt then return nil end
        return history:prompt_before(record.sequence)
      end
    end
  end
  if props.visibility and top <= props.visibility:offset(#history.records) then
    -- The viewport just jumped to an unpainted band. Its next paint will
    -- supply the actual boundary; never guess with a newer prompt.
    return nil
  end
  -- Trailing controls have no entry owner. In button mode the visible
  -- slice can end before the newest entry in the canonical transcript.
  local last = not props.visibility and store.state.window_end or #history.records
  return history:prompt_before(last + 1)
end

return function(ctx, props)
  local transcript = props.transcript
  local prompt = ctx.use_state(nil)
  ctx.use_effect(function()
    if not has_sources then return end
    local alive, pending = true, false
    local function refresh()
      pending = false
      local win, buf = transcript.winid, transcript.bufnr
      if not alive or not win or not vim.api.nvim_win_is_valid(win) then return end
      vim.api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        local text = reading_prompt(props, buf, view.topline)
        local previous = prompt.get()
        if previous == text then return end
        prompt.set(text)
        if (not previous) ~= (not text) and vim.fn.winsaveview().topline ~= view.topline then
          view.lnum = math.min(view.lnum, view.topline + vim.api.nvim_win_get_height(win) - 1)
          vim.fn.winrestview(view)
        end
      end)
    end
    local function schedule()
      if alive and not pending then
        pending = true
        vim.schedule(refresh)
      end
    end
    local scroll = vim.api.nvim_create_autocmd("WinScrolled", { callback = function(ev)
      local id = tostring(transcript.winid)
      if ev.match == id or vim.v.event[id] then schedule() end
    end })
    local unsubscribe = Sources.subscribe(function(buf)
      if buf == transcript.bufnr then schedule() end
    end)
    schedule()
    return function()
      alive = false
      unsubscribe()
      vim.api.nvim_del_autocmd(scroll)
    end
  end, { transcript })
  local text = prompt.get()
  if not text then return nil end
  text = vim.trim((text:gsub("[%c%s]+", " ")))
  return {
    comp = ui.label,
    props = {
      height = 2,
      fill = function(columns) return preview(text, columns) end,
      style = { hl = Theme.USER_BUBBLE_HL, text_hl = Theme.USER_MSG_HL, padding = { x = 1 } },
    },
  }
end
