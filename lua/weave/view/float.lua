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

-- Leave room for the rounded border and a small margin. A narrow editor
-- uses its available columns; a wide editor gives the popup 80% of the grid.
function M.width()
  return math.max(1, math.min(vim.o.columns - 6, math.max(80, math.floor(vim.o.columns * 0.8))))
end

local function geometry(rows)
  local usable = vim.o.lines - vim.o.cmdheight
  local limit = math.max(1, math.min(vim.o.lines - 6, usable - 2))
  local height = math.max(1, math.min(rows or limit, limit))
  local width = M.width()
  return {
    width = width, height = height,
    row = math.max(0, math.floor((usable - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
  }
end

local function on_resize(win, callback)
  local group = vim.api.nvim_create_augroup("WeavePopupSize_" .. win, { clear = true })
  local function cleanup() vim.api.nvim_del_augroup_by_id(group) end
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = function()
    -- A close inside a non-nested autocmd can suppress WinClosed.
    if not vim.api.nvim_win_is_valid(win) then return cleanup() end
    callback()
  end })
  vim.api.nvim_create_autocmd("WinClosed", { group = group, pattern = tostring(win), callback = cleanup })
end

---@class weave.view.PopupPolicy
---@field stable? boolean Keep the viewport height steady when content changes.
---@field preferred_height? fun(props: table): integer Natural height for a fixed layout with a scrolling child.
---@field on_unmount? fun()

--- Mount a centered popup. Scroll layouts fit their rendered buffer rows.
--- A scrollable child in a fixed frame can supply its natural height via props.
---@param component function
---@param props table
---@param policy? weave.view.PopupPolicy
function M.mount(component, props, policy)
  policy = policy or {}
  local preferred = policy.preferred_height
  local rect = geometry(preferred and preferred(props))
  local opts = vim.tbl_extend("force", rect, {
    mode = preferred and "fixed" or "scroll", border = "rounded", backdrop = true,
    on_unmount = policy.on_unmount,
  })
  local app = require("fibrous.inline.mount").floating(component, props, opts)
  local function apply(rows)
    local next_rect = geometry(rows)
    if vim.deep_equal(rect, next_rect) then return end
    rect = next_rect
    for key, value in pairs(rect) do opts[key] = value end
    app.relayout()
  end
  local function fit()
    if policy.stable then apply(nil)
    elseif preferred then apply(preferred(props))
    else apply(vim.api.nvim_buf_line_count(app.bufnr)) end
  end

  local set_props = app.set_props
  app.set_props = function(next_props)
    props = next_props
    set_props(props)
    fit()
  end
  fit()
  if not policy.stable and not preferred then
    local pending = false
    vim.api.nvim_buf_attach(app.bufnr, false, { on_lines = function(_, _, _, _, old_end, new_end)
      if not vim.api.nvim_win_is_valid(app.winid) then return true end
      if pending or old_end == new_end then return end
      pending = true
      vim.schedule(function()
        pending = false
        if vim.api.nvim_win_is_valid(app.winid) then fit() end
      end)
    end })
  end
  on_resize(app.winid, function()
    -- Reflow at the new width before measuring. Components can also adapt
    -- their own controls and padding to the new editor dimensions.
    apply(not policy.stable and rect.height or nil)
    app.set_props(props)
  end)
  return app
end

--- Native buffer popup. Measure wrapped screen lines at the actual window
--- width. Editors use the stable viewport while the user is typing.
---@param buf integer
---@param config vim.api.keyset.win_config
---@param policy? { stable?: boolean, window_options?: table }
function M.open_buffer(buf, config, policy)
  policy = policy or {}
  local rect = geometry()
  local win = vim.api.nvim_open_win(buf, true, vim.tbl_extend("force", config, rect, {
    relative = "editor", border = "rounded",
  }))
  for key, value in pairs(policy.window_options or {}) do vim.wo[win][key] = value end
  local function apply(next_rect)
    if vim.deep_equal(rect, next_rect) then return end
    rect = next_rect
    vim.api.nvim_win_set_config(win, vim.tbl_extend("force", rect, { relative = "editor" }))
  end
  local function fit()
    local bounds = geometry()
    if policy.stable then
      apply(bounds)
      return
    end
    if rect.width ~= bounds.width then apply(geometry(rect.height)) end
    apply(geometry(vim.api.nvim_win_text_height(win, { max_height = bounds.height }).all))
  end
  fit()
  on_resize(win, fit)
  return win
end

return M
