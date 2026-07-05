-- The session modal: a floating fibrous mount over the registry — the one
-- place that shows every active session in the editor (the registry is
-- global) and which one the current tab has selected (●). Rows are fibrous
-- buttons, so <CR> activation, hover, and <Tab> cycling come from the
-- framework: activating a row hands the entry to on_select; the row's ✕
-- closes (stops) that session everywhere. Bottom actions defer to init's
-- flows (provider pick / saved-session pick) via on_new / on_load_saved.
--
-- The modal is short-lived, not a live registry subscriber: it re-renders
-- (set_props) after the mutations IT causes and closes on selection.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local M = {}

local WIDTH = 72
local TITLE_CHARS = 32

--- A row's button label: provider · first-user-message (elided) · status.
--- The provider display name comes from the session's published meta when the
--- agent is up, falling back to the entry's provider key.
--- @param entry weave.registry.Entry
--- @return string
local function row_label(entry)
  local state = entry.session:get_store().state
  local provider = state.meta.provider or entry.provider
  local title = "(no messages yet)"
  for _, e in ipairs(state.entries) do
    if e.kind == "user" then
      title = (e.text:gsub("%s+", " "))
      break
    end
  end
  if vim.fn.strchars(title) > TITLE_CHARS then
    title = vim.fn.strcharpart(title, 0, TITLE_CHARS - 1) .. "…"
  end
  return ("%s · %s · %s"):format(provider, title, state.status)
end

local function Modal(_, props)
  local children = {
    { comp = ui.label, props = { text = { { "Active sessions", hl = "Title" } } } },
    { comp = ui.label, props = { text = "" } },
  }

  if #props.entries == 0 then
    children[#children + 1] = {
      comp = ui.label,
      props = { text = { { "  (no active sessions)", hl = "Comment" } } },
    }
  end

  for _, entry in ipairs(props.entries) do
    local marker = entry.key == props.selected_key and "● " or "  "
    children[#children + 1] = {
      comp = ui.row,
      props = {},
      children = {
        { comp = ui.label, props = { text = marker } },
        {
          comp = ui.button,
          props = {
            label = row_label(entry),
            on_press = function()
              props.on_select(entry)
            end,
          },
        },
        { comp = ui.label, props = { text = " " } },
        {
          comp = ui.button,
          props = {
            label = "✕",
            on_press = function()
              props.on_close_session(entry)
            end,
          },
        },
      },
    }
  end

  children[#children + 1] = { comp = ui.label, props = { text = "" } }
  children[#children + 1] = {
    comp = ui.row,
    props = {},
    children = {
      { comp = ui.button, props = { label = "+ new session", on_press = props.on_new } },
      { comp = ui.label, props = { text = "  " } },
      { comp = ui.button, props = { label = "↺ load saved…", on_press = props.on_load_saved } },
    },
  }
  children[#children + 1] = {
    comp = ui.label,
    props = { text = { { "<CR> select · <Tab> cycle · ✕ close session · q close", hl = "Comment" } } },
  }

  return { comp = ui.col, props = {}, children = children }
end

--- @class weave.view.SessionModalHandle
--- @field bufnr integer
--- @field winid integer
--- @field close fun()
--- @field refresh fun() Re-derive rows from the registry (after a mutation)
--- @field is_open fun(): boolean

--- Open the modal for the CURRENT tabpage.
--- @param opts { registry?: table, on_select: fun(entry: weave.registry.Entry), on_new?: fun(), on_load_saved?: fun() }
---   on_select/on_new/on_load_saved run AFTER the modal closes itself.
--- @return weave.view.SessionModalHandle handle
function M.open(opts)
  local registry = opts.registry or require("weave.registry")
  local tab = vim.api.nvim_get_current_tabpage()
  local open = true
  local app, refresh

  local function close()
    if not open then
      return
    end
    open = false
    app.unmount()
  end

  local function build_props()
    local selected = registry.selected(tab)
    return {
      entries = registry.list(),
      selected_key = selected and selected.key or nil,
      on_select = function(entry)
        close()
        opts.on_select(entry)
      end,
      on_close_session = function(entry)
        registry.close(entry.key)
        refresh()
      end,
      on_new = function()
        close()
        if opts.on_new then
          opts.on_new()
        end
      end,
      on_load_saved = function()
        close()
        if opts.on_load_saved then
          opts.on_load_saved()
        end
      end,
    }
  end

  -- title + blank + rows (or placeholder) + blank + actions + hint
  local height = math.max(#registry.list(), 1) + 5
  app = mount.floating(Modal, build_props(), {
    width = WIDTH,
    height = height,
    mode = "fixed",
    -- Modal chrome (fibrous float-mount opts): rounded border, and a dimming
    -- backdrop one z-level below. The float's default zindex (50) already
    -- clears the panel — pane-anchored mounts stack low (10, 11, …).
    border = "rounded",
    backdrop = true,
  })

  refresh = function()
    app.set_props(build_props())
  end

  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, close, { buffer = app.bufnr, nowait = true, desc = "weave: close session modal" })
  end
  app.focus()

  return {
    bufnr = app.bufnr,
    winid = app.winid,
    close = close,
    refresh = refresh,
    is_open = function()
      return open
    end,
  }
end

return M
