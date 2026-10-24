-- Read-only stream buffers: append new chunks, never rebuild old output.
-- Fibrous owns the subwindows; each pane owns its buffer and follow state.
local ui = require("fibrous.inline.components")
local C = require("weave.view.renderers.common")
local M = { MAX_ROWS = 10, HL = "WeaveTaskOutput", BORDER_HL = "WeaveTaskOutputBorder" }

local own_highlight
local function define_highlights()
  local current = vim.api.nvim_get_hl(0, { name = M.HL, link = true })
  if not next(current) or vim.deep_equal(current, own_highlight) then
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local bg
    if normal.bg then
      bg = 0
      for _, shift in ipairs({ 16, 8, 0 }) do
        local channel = bit.band(bit.rshift(normal.bg, shift), 0xff)
        bg = bit.bor(bg, bit.lshift(math.floor(channel * 0.9 + 0.5), shift))
      end
    end
    vim.api.nvim_set_hl(0, M.HL, { bg = bg, fg = normal.fg })
    own_highlight = vim.api.nvim_get_hl(0, { name = M.HL, link = true })
  end
  vim.api.nvim_set_hl(0, M.BORDER_HL, { link = "FloatBorder", default = true })
end
define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("WeaveTaskOutputHighlight", { clear = true }),
  callback = define_highlights,
})

local Stream = {}
Stream.__index = Stream

function Stream:line_count()
  local count = vim.api.nvim_buf_line_count(self.bufnr)
  local last = vim.api.nvim_buf_get_lines(self.bufnr, -2, -1, false)[1]
  return math.max(1, count - (last == "" and count > 1 and 1 or 0))
end

local function at_bottom(win, last)
  local info = vim.fn.getwininfo(win)[1]
  if not info or info.botline < last then return false end
  -- botline alone cannot distinguish a partly visible wrapped last line.
  local buf = vim.api.nvim_win_get_buf(win)
  local text = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
  return vim.fn.screenpos(win, last, math.max(#text, 1)).row > 0
end

function Stream:windows()
  return vim.fn.win_findbuf(self.bufnr)
end

function Stream:sync()
  if self.dead then return end
  for _, win in ipairs(self:windows()) do
    if vim.api.nvim_win_is_valid(win) then
      local mappings = {}
      for pair in vim.wo[win].winhighlight:gmatch("[^,]+") do
        local name = pair:match("^([^:]+):")
        if name ~= "Normal" and name ~= "NormalFloat" and name ~= "EndOfBuffer" then mappings[#mappings + 1] = pair end
      end
      for _, name in ipairs({ "Normal", "NormalFloat", "EndOfBuffer" }) do mappings[#mappings + 1] = name .. ":" .. M.HL end
      local highlight = table.concat(mappings, ",")
      if vim.wo[win].winhighlight ~= highlight then vim.wo[win].winhighlight = highlight end
      -- Native scrolling must also work within a single long wrapped line.
      if not vim.wo[win].smoothscroll then vim.wo[win].smoothscroll = true end
      if self.follow and not vim.api.nvim_win_get_config(win).hide then
        self.adjusting = true
        vim.api.nvim_win_set_cursor(win, { self:line_count(), 0 })
        vim.api.nvim_win_call(win, function() vim.cmd("normal! $zb") end)
        self.adjusting = false
      end
    end
  end
end

function Stream:schedule_sync()
  if self.pending_sync or self.dead then return end
  self.pending_sync = true
  vim.schedule(function()
    self.pending_sync = false
    if not self.dead and vim.api.nvim_buf_is_valid(self.bufnr) then self:sync() end
  end)
end

-- CSI and UTF-8 can straddle pipe callbacks. Keep only an unfinished suffix;
-- already rendered output is never re-decoded. This is a text log, not a TTY.
function Stream:decode(text)
  text = self.pending .. text
  self.pending = ""
  local cut = text:match("()\27%[[0-?]*[ -/]*$") or text:match("()\27$")
  if not cut then
    local start = #text
    while start > 0 and text:byte(start) >= 128 and text:byte(start) < 192 do start = start - 1 end
    local lead = text:byte(start) or 0
    local size = lead >= 240 and lead <= 244 and 4 or lead >= 224 and lead <= 239 and 3
      or lead >= 194 and lead <= 223 and 2
    if size and #text - start + 1 < size then cut = start end
  end
  if cut then
    self.pending, text = text:sub(cut), text:sub(1, cut - 1)
    -- CSI parameters are discarded anyway; do not retain an unbounded prefix.
    if self.pending:sub(1, 2) == "\27[" then self.pending = "\27[" end
  end
  return C.clean(text, nil, true)
end

function Stream:append(chunks)
  if self.dead then return end
  local reset = self.source ~= chunks or #chunks < self.consumed
  if not reset and #chunks == self.consumed then return end
  local views = {}
  for _, win in ipairs(self:windows()) do
    if vim.api.nvim_win_is_valid(win) then
      if vim.api.nvim_get_current_win() == win and not self.adjusting then
        self.follow = at_bottom(win, self:line_count()) == true
      end
      views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end
  end
  vim.bo[self.bufnr].readonly, vim.bo[self.bufnr].modifiable = false, true
  if reset then
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, { "" })
    self.source, self.consumed, self.pending = chunks, 0, ""
  end
  local fresh = {}
  for i = self.consumed + 1, #chunks do fresh[#fresh + 1] = chunks[i] end
  local text = self:decode(table.concat(fresh))
  if text ~= "" then
    local row = vim.api.nvim_buf_line_count(self.bufnr) - 1
    local last = vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)[1]
    vim.api.nvim_buf_set_text(self.bufnr, row, #last, row, #last, vim.split(text, "\n", { plain = true }))
  end
  self.consumed = #chunks
  vim.bo[self.bufnr].modifiable, vim.bo[self.bufnr].readonly = false, true
  if not self.follow then
    for win, view in pairs(views) do
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_call(win, function() vim.fn.winrestview(view) end) end
    end
  end
  self:schedule_sync()
end

function Stream:destroy()
  if self.dead then return end
  self.dead = true
  vim.api.nvim_del_augroup_by_id(self.group)
  for _, win in ipairs(self:windows()) do
    if vim.api.nvim_get_current_win() == win then
      local parent = vim.w[win].fibrous_anchor
      if parent and vim.api.nvim_win_is_valid(parent) then vim.api.nvim_set_current_win(parent) end
    end
  end
  if vim.api.nvim_buf_is_valid(self.bufnr) then vim.api.nvim_buf_delete(self.bufnr, { force = true }) end
end

function M.new(stream)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].modeline = "hide", false, false
  vim.bo[buf].undolevels, vim.bo[buf].modifiable, vim.bo[buf].readonly = -1, false, true
  vim.b[buf].weave_task_stream = stream
  local self = setmetatable({ bufnr = buf, consumed = 0, pending = "", follow = true }, Stream)
  self.group = vim.api.nvim_create_augroup("WeaveTaskOutput_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = self.group, buffer = buf, callback = function() self:schedule_sync() end,
  })
  local function track(win)
    win = win or vim.api.nvim_get_current_win()
    if self.dead or self.adjusting or vim.api.nvim_win_get_buf(win) ~= buf
      or vim.api.nvim_win_get_config(win).hide then return end
    self.follow = at_bottom(win, self:line_count()) == true
  end
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinLeave" }, {
    group = self.group, buffer = buf, callback = function() track() end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", { group = self.group, callback = function(ev)
    for _, win in ipairs(self:windows()) do
      local event, ancestor_changed = vim.v.event, false
      local parent = vim.w[win].fibrous_anchor
      while parent and vim.api.nvim_win_is_valid(parent) do
        if event[tostring(parent)] or ev.match == tostring(parent) then ancestor_changed = true; break end
        parent = vim.w[parent].fibrous_anchor
      end
      local own = event[tostring(win)]
      -- Wheel scrolling need not focus the window. Distinguish it from a
      -- parent clipping/repositioning the pane or resizing its viewport.
      if own and not ancestor_changed and ((own.topline or 0) ~= 0 or (own.skipcol or 0) ~= 0)
        and (own.height or 0) == 0 and (own.width or 0) == 0 then track(win) end
      if own or ancestor_changed then self:schedule_sync() end
    end
  end })
  return self
end

function M.Pane(ctx, props)
  local ref = ctx.use_ref()
  local chunks = props.chunks or {}
  if #chunks > 0 and not ref.current then ref.current = M.new(props.stream) end
  local stream = ref.current
  if stream then stream:append(chunks) end
  ctx.use_effect(function()
    if stream then
      stream:schedule_sync()
      return function() stream:destroy() end
    end
  end, { stream or false })
  ctx.use_effect(function()
    if stream and props.block then
      local block = props.block
      require("weave.keys").map(stream.bufnr, "peek", function()
        require("weave.view.peek").open(require("weave.utils.json").pretty(block),
          require("weave.view.tool_call").tool_tag(block), "json")
      end)
    end
  end, { stream or false, props.block or false })
  if not stream or #chunks == 0 then return nil end
  return { comp = ui.raw_buffer, props = {
    bufnr = stream.bufnr, render = "always", wrap = true, capture_cursor = true, insert_on_click = false,
    height = math.min(M.MAX_ROWS, stream:line_count()) + 2,
    style = { hl = M.HL, border = { "rounded", hl = M.BORDER_HL, title = props.stream } },
  } }
end

return M
