-- The peek modal: show an entry's RAW source in a scrollable float. The
-- transcript is a rendered projection — markdown is concealed, code/table lines
-- are clipped to the viewport width — so anything wide (a long URL in a fence, a
-- table) can't be read or yanked in place. Peek (the `K` key over an entry, via
-- fibrous's on_key routing) drops the raw text into a plain, wrapping, read-only
-- float you can scroll, search and yank from, then dismiss with q / <Esc> — or
-- by simply focusing something else.
--
-- Over a TOOL CALL the raw source is the call itself, as indented JSON (see
-- weave.view.transcript): the rendered entry is a summary, and a summary is
-- exactly where a long command or a big payload goes missing.

local M = {}

--- Open the peek float over `text`. Plain nvim window (not a fibrous mount): it
--- shows raw text, so it wants native wrap + search, nothing reactive.
--- @param text string       the raw source to show
--- @param title? string     centred border title (default "peek")
--- @param filetype? string  buffer filetype for highlighting (default "markdown")
--- @return integer|nil winid
function M.open(text, title, filetype)
  if not text or text == "" then
    return nil
  end
  local lines = vim.split(text, "\n", { plain = true })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = filetype or "markdown"

  local width = math.min(math.floor(vim.o.columns * 0.8), 100)
  local height = math.max(1, math.min(math.floor(vim.o.lines * 0.8), #lines))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. (title or "peek") .. " ",
    title_pos = "center",
  })
  -- wrap + linebreak so a long URL/line is fully readable without scrolling right
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  require("weave.keys").map(buf, "close_float", close, { nowait = true, desc = "weave: close peek" })

  -- Leaving the float dismisses it. Peek is a glance at one entry, not a
  -- window you arrange things around: clicking back into the transcript to
  -- keep reading should not leave a stale copy of the old entry floating over
  -- the conversation. Scheduled because a window cannot close from inside the
  -- autocmd that is still leaving it.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
  return win
end

return M
