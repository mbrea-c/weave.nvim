-- weave.view.float: the chrome every weave popup shares.
--
-- A popup here is a float over a conversation you are reading, not a window
-- you arrange things around — so they all behave the same way: `q`/`<Esc>`
-- closes, and moving focus anywhere else closes too. That second half used to
-- be true of `peek` alone, which meant the settings window, the session
-- modal, the task list and the rest could be left hanging over the panel
-- while you worked behind them, showing state from minutes ago.
--
-- ── What counts as "anywhere else" ──────────────────────────────────────────
--
-- A popup's own windows do not. A fibrous mount puts its native controls (a
-- text input, a scrolling container, a dropdown) in SEPARATE floats, so
-- focusing the settings window's debounce field fires WinEnter for a window
-- that is not the root — and a naive check would dismiss the window the
-- moment you tried to use it. fibrous records the association on each
-- subwindow float (`w:fibrous_anchor` = the winid of its level's root), so
-- ownership is that chain walked up to the root: one hop for a control on the
-- root, more for controls nested inside a container.
--
-- WinEnter, not WinLeave: the question is where focus LANDED, and WinLeave
-- fires before there is an answer. And deliberately NOT FocusLost —
-- alt-tabbing to a browser is not a dismissal, and coming back to a
-- half-finished thing that closed itself would be worse than useless.

local Keys = require("weave.keys")

local M = {}

--- How far the anchor chain is walked before giving up. Nesting is a handful
--- of levels at most; the bound exists so a cycle (a bug in the anchoring, or
--- a window id reused between the var being set and read) cannot hang the
--- editor inside an autocmd.
local MAX_HOPS = 16

--- @param win integer
--- @return integer|nil anchor
local function anchor_of(win)
  local ok, anchor = pcall(vim.api.nvim_win_get_var, win, "fibrous_anchor")
  if not ok or type(anchor) ~= "number" then
    return nil
  end
  return anchor
end

--- Does `win` belong to the popup rooted at `root` — the root itself, or one
--- of the subwindow floats fibrous anchored (directly or through a nested
--- container) to it?
--- @param win integer|nil
--- @param root integer
--- @return boolean
function M.owns(root, win)
  local hops = 0
  while win and win ~= 0 and vim.api.nvim_win_is_valid(win) do
    if win == root then
      return true
    end
    if hops >= MAX_HOPS then
      return false
    end
    hops = hops + 1
    win = anchor_of(win)
  end
  return false
end

--- Dismiss the float rooted at `win` when focus lands outside it.
---
--- `keep_open` is the escape hatch for a popup that holds unsaved state: it is
--- asked on every blur, and a true answer leaves the float alone (see the
--- permission preset editor, where losing focus must never discard an edit).
--- @param win integer the float's root window
--- @param opts { on_unfocus: fun(), keep_open?: fun(): boolean }
--- @return fun() cancel stop watching (idempotent)
function M.dismiss_on_unfocus(win, opts)
  local group = vim.api.nvim_create_augroup("WeaveFloatDismiss_" .. win, { clear = true })
  local cancelled = false

  local function cancel()
    if cancelled then
      return
    end
    cancelled = true
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end

  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      if cancelled then
        return
      end
      -- Gone by another road (q, unmount, :q): stop watching rather than
      -- dismissing something that no longer exists.
      if not vim.api.nvim_win_is_valid(win) then
        return cancel()
      end
      if M.owns(win, vim.api.nvim_get_current_win()) then
        return
      end
      if opts.keep_open and opts.keep_open() then
        return
      end
      cancel()
      -- Scheduled: a window cannot be torn down from inside the autocmd that
      -- is still entering another one, and a fibrous unmount touches several.
      vim.schedule(opts.on_unfocus)
    end,
  })

  -- Closed from anywhere else: drop the watch with it.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = cancel,
  })

  return cancel
end

--- The standard popup chrome for a floating fibrous mount: the close key, the
--- blur dismissal, and focus. Every weave popup goes through here, so "how do
--- our popups behave" has one answer in one place.
--- @param app table InlineAppHandle (bufnr, winid, unmount, …)
--- @param opts { close: fun(), desc: string, on_unfocus?: fun(), keep_open?: fun(): boolean }
---   on_unfocus defaults to close — give it separately only when losing focus
---   means something different from closing (the comment editor saves).
--- @return table app the handle, unchanged
function M.chrome(app, opts)
  Keys.map(app.bufnr, "close_float", opts.close, { nowait = true, desc = opts.desc })
  M.dismiss_on_unfocus(app.winid, {
    on_unfocus = opts.on_unfocus or opts.close,
    keep_open = opts.keep_open,
  })
  app.focus()
  return app
end

return M
