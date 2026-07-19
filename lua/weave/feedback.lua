-- The public API for inline code feedback. This is the surface users bind and
-- other plugins call; everything below it (store, anchors, formatting, sinks)
-- is internal.
--
-- weave deliberately sets NO keymaps here. These are global normal/visual-mode
-- bindings over every buffer in the editor, which is further than a chat plugin
-- should reach on its own, so the README documents them and the user binds:
--
--   vim.keymap.set("n", ";;cc", require("weave.feedback").comment_line)
--   vim.keymap.set("x", ";;cc", require("weave.feedback").comment_selection)
--   vim.keymap.set("n", ";;ce", require("weave.feedback").edit_comment)
--
-- The flow: commenting creates the comment in the store immediately (so the
-- highlight lands right away) and then opens the editor on it. Backing out of
-- the editor removes an unwritten comment, so nothing is stranded.

local Format = require("weave.feedback_format")
local Sinks = require("weave.feedback_sinks")
local Store = require("weave.feedback_store")

local M = {}

--- @param expr string a getpos() expression
--- @return { lnum: integer, col: integer }
local function pos(expr)
  local p = vim.fn.getpos(expr)
  return { lnum = p[2], col = p[3] }
end

--- @param bufnr integer
--- @param lnum integer
--- @param col integer
--- @return integer
local function clamp_col(bufnr, lnum, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  -- `$` in visual mode reports a sentinel column past the end of the line.
  return math.max(1, math.min(col, math.max(#line, 1)))
end

--- Normalise a visual selection into a comment range.
---
--- Blockwise selections collapse to whole lines: a block's columns do not
--- describe one contiguous span of text, so quoting it as a column range would
--- misrepresent what the user selected.
--- @param mode string the visual mode ("v", "V", or a blockwise CTRL-V)
--- @param a { lnum: integer, col: integer }
--- @param b { lnum: integer, col: integer }
--- @return weave.feedback.Range
function M._visual_range(mode, a, b)
  local first, last = a, b
  if a.lnum > b.lnum or (a.lnum == b.lnum and a.col > b.col) then
    first, last = b, a
  end
  if mode == "V" or mode == "\22" then
    return { lnum = first.lnum, end_lnum = last.lnum }
  end
  return { lnum = first.lnum, end_lnum = last.lnum, col = first.col, end_col = last.col }
end

--- @param opts table|nil
--- @return fun(id: integer)
local function opener(opts)
  return (opts or {}).open or function(id)
    require("weave.view.feedback").open_editor(id)
  end
end

--- Attach a comment WITHOUT opening the editor. This is the entry point for
--- other plugins: perijove and friends call it with their own source name and
--- their own body, and the comment joins whatever draft is open.
--- @param opts { bufnr: integer, range: weave.feedback.Range, body?: string, source?: string }
--- @return weave.feedback.Comment|nil comment, string|nil err
function M.add(opts)
  return Store.add(opts)
end

--- Comment the current line, then open the editor on it.
--- @param opts { source?: string, open?: fun(id: integer) }|nil
--- @return weave.feedback.Comment|nil
function M.comment_line(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local comment, err = Store.add({ bufnr = bufnr, range = { lnum = lnum, end_lnum = lnum }, source = opts.source })
  if not comment then
    vim.notify("weave: " .. tostring(err), vim.log.levels.WARN)
    return nil
  end
  opener(opts)(comment.id)
  return comment
end

--- Comment the visual selection, then open the editor on it. Safe to bind with
--- or without a leading `:<C-u>`: a live visual selection is read from the `v`
--- and `.` positions, and a mapping that has already left visual mode falls
--- back to the '< and '> marks.
--- @param opts { source?: string, open?: fun(id: integer) }|nil
--- @return weave.feedback.Comment|nil
function M.comment_selection(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local a, b
  if mode == "v" or mode == "V" or mode == "\22" then
    a, b = pos("v"), pos(".")
    -- Leave visual mode before the editor takes focus, or the selection is
    -- still live under the float.
    vim.cmd.normal({ "\27", bang = true })
  else
    mode = vim.fn.visualmode()
    a, b = pos("'<"), pos("'>")
  end
  if a.lnum == 0 or b.lnum == 0 then
    return M.comment_line(opts)
  end

  local range = M._visual_range(mode, a, b)
  if range.col then
    range.col = clamp_col(bufnr, range.lnum, range.col)
    range.end_col = clamp_col(bufnr, range.end_lnum, range.end_col)
  end
  local comment, err = Store.add({ bufnr = bufnr, range = range, source = opts.source })
  if not comment then
    vim.notify("weave: " .. tostring(err), vim.log.levels.WARN)
    return nil
  end
  opener(opts)(comment.id)
  return comment
end

--- Reopen the comment under the cursor.
--- @param opts { open?: fun(id: integer) }|nil
--- @return weave.feedback.Comment|nil
function M.edit_comment(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local comment = Store.at_cursor(bufnr, lnum)
  if not comment then
    vim.notify("weave: no code feedback comment here", vim.log.levels.INFO)
    return nil
  end
  opener(opts)(comment.id)
  return comment
end

--- Pick a window to jump into for `bufnr`.
---
--- Preference order: a window already showing that buffer, then the current
--- window, then any other. Floats and non-file panes are never targets — the
--- caller is typically a button inside a float, and retargeting weave's own
--- transcript pane at a source file would be worse than not moving at all.
--- @param bufnr integer|nil
--- @return integer|nil winid
function M._target_win(bufnr)
  local function ordinary(win)
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      return false
    end
    return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
  end

  local wins = vim.api.nvim_tabpage_list_wins(0)
  if bufnr then
    for _, win in ipairs(wins) do
      if ordinary(win) and vim.api.nvim_win_get_buf(win) == bufnr then
        return win
      end
    end
  end
  local cur = vim.api.nvim_get_current_win()
  if ordinary(cur) then
    return cur
  end
  for _, win in ipairs(wins) do
    if ordinary(win) then
      return win
    end
  end
  return nil
end

--- Jump to a comment's code: focus an ordinary window on its buffer (opening
--- the file if nothing shows it) and put the cursor on its first line.
---
--- An orphaned comment still jumps, to the line its code was LAST seen at:
--- that is where the user was looking when they wrote it, and refusing to move
--- would strand the only route back to it.
--- @param id integer
--- @return boolean ok
function M.goto_comment(id)
  local comment = Store.get(id)
  if not comment then
    return false
  end
  local at = Store.resolve(comment)
  local win = M._target_win(comment.bufnr)
  if not win then
    return false
  end
  vim.api.nvim_set_current_win(win)

  local bufnr = comment.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    if comment.path == "" then
      return false
    end
    vim.cmd.edit(vim.fn.fnameescape(comment.path))
    bufnr = vim.api.nvim_get_current_buf()
  elseif vim.api.nvim_win_get_buf(win) ~= bufnr then
    vim.api.nvim_win_set_buf(win, bufnr)
  end

  local lnum = math.max(1, math.min(at.lnum, vim.api.nvim_buf_line_count(bufnr)))
  vim.api.nvim_win_set_cursor(win, { lnum, math.max((at.col or 1) - 1, 0) })
  pcall(vim.cmd.normal, { "zz", bang = true })
  return true
end

--- Format the open draft and hand it to a sink. The draft is cleared (and its
--- highlights with it) only on a successful send, so a failure leaves the
--- user's comments intact to retry.
--- @param opts { sink?: string }|nil
--- @return boolean|nil ok, string|nil err
function M.send(opts)
  opts = opts or {}
  local item = Store.draft()
  if not item or #item.comments == 0 then
    vim.notify("weave: no code feedback to send", vim.log.levels.INFO)
    return nil, "no code feedback to send"
  end
  local sink = opts.sink or Sinks.default().name
  local ok, err = Sinks.dispatch(sink, Format.format(item), item)
  if not ok then
    vim.notify("weave: " .. tostring(err), vim.log.levels.WARN)
    return nil, err
  end
  Store.clear()
  return true
end

--- Drop the open draft and every highlight it placed.
function M.discard()
  Store.clear()
end

--- Register a destination for sent feedback. See weave.feedback_sinks.
--- @param spec weave.feedback.Sink
function M.register_sink(spec)
  return Sinks.register(spec)
end

--- The open draft, or nil.
--- @return weave.feedback.Item|nil
function M.draft()
  return Store.draft()
end

--- Subscribe to draft changes.
--- @param fn fun()
--- @return fun() unsubscribe
function M.subscribe(fn)
  return Store.subscribe(fn)
end

return M
