-- The session details window (requests.md): a floating fibrous modal over ONE
-- session — the full metadata the sidebar summarises, plus a ui.dropdown per
-- selectable config kind (model, mode, thinking effort, ... whatever the
-- agent advertised) that applies choices through Session:set_config. Reached
-- by activating the sidebar's Session section, or a row's ⓘ in the ;;s
-- sessions list; opened for a session that is not the tab's current one it
-- offers "Open in panel" (the caller supplies what opening means).
--
-- The read-only rows are live store projections (use_store); the dropdowns
-- own their field state, so a successful set needs no re-render — the commit
-- already shows in the field, and the meta row updates through the store.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")
local use_permissions = require("weave.view.use_permissions")
local use_store = require("weave.view.use_store")

local M = {}

local FIELD_MIN_W = 16
local FIELD_MAX_W = 28

local function dim(text)
  return { comp = ui.label, props = { text = { { text, hl = "@comment" } } } }
end

local function blank()
  return { comp = ui.label, props = { text = "" } }
end

--- One config kind as an aligned "Label:  [dropdown]" row. The dropdown works
--- on option LABELS (what a human picks); the row maps the pick back to the
--- option id for Session:set_config.
--- @param kind weave.session.ConfigKind
--- @param label_w integer widest kind label, for column alignment
--- @param on_set fun(key: string, id: string)
local function kind_row(kind, label_w, on_set)
  local options, id_of, current_label = {}, {}, kind.current
  for _, o in ipairs(kind.available) do
    options[#options + 1] = o.label
    id_of[o.label] = o.id
    if o.id == kind.current then
      current_label = o.label
    end
  end
  local field_w = FIELD_MIN_W
  for _, label in ipairs(options) do
    field_w = math.max(field_w, vim.api.nvim_strwidth(label) + 2)
  end
  return {
    comp = ui.row,
    props = { gap = 1 },
    children = {
      {
        comp = ui.label,
        props = { text = kind.label .. ":" .. (" "):rep(label_w - vim.api.nvim_strwidth(kind.label)) },
      },
      {
        comp = ui.dropdown,
        props = {
          options = options,
          value = current_label or "",
          width = math.min(field_w, FIELD_MAX_W),
          on_select = function(label)
            local id = id_of[label]
            if id then
              on_set(kind.key, id)
            end
          end,
        },
      },
    },
  }
end

--- @param ctx table
--- @param props { store: weave.store.SessionStore, kinds: weave.session.ConfigKind[], on_set: fun(key: string, id: string), on_open?: fun() }
local function Details(ctx, props)
  local state = use_store(ctx, props.store)
  local preset = use_permissions(ctx)
  local meta = state.meta

  local rows = {
    { comp = ui.label, props = { text = { { "Session details", hl = "Title" } } } },
    blank(),
  }
  local facts = {
    { "Provider", meta.provider },
    { "Agent", meta.agent },
    { "Session", meta.session_id },
    { "Status", state.status },
    { "Permissions", preset.label or preset.name },
  }
  for _, pair in ipairs(facts) do
    if pair[2] then
      rows[#rows + 1] = { comp = ui.label, props = { text = pair[1] .. ": " .. pair[2] } }
    end
  end
  local usage = state.usage
  if usage and usage.used then
    local line = "Context: " .. usage.used .. (usage.size and (" / " .. usage.size) or "") .. " tokens"
    rows[#rows + 1] = { comp = ui.label, props = { text = line } }
  end

  rows[#rows + 1] = blank()
  if #props.kinds == 0 then
    rows[#rows + 1] = dim("(nothing configurable for this session)")
  else
    local label_w = 0
    for _, kind in ipairs(props.kinds) do
      label_w = math.max(label_w, vim.api.nvim_strwidth(kind.label))
    end
    for _, kind in ipairs(props.kinds) do
      rows[#rows + 1] = kind_row(kind, label_w, props.on_set)
    end
  end

  if props.on_open then
    rows[#rows + 1] = blank()
    rows[#rows + 1] = { comp = ui.button, props = { label = "Open in panel", on_press = props.on_open } }
  end
  rows[#rows + 1] = blank()
  rows[#rows + 1] = dim("<C-n>/<C-p> move · <CR>/<C-y> pick · q close")

  return { comp = ui.col, props = {}, children = rows }
end

--- @class weave.view.SessionDetailsHandle
--- @field bufnr integer
--- @field winid integer
--- @field close fun()
--- @field is_open fun(): boolean

--- Open the details modal for `opts.session`.
--- @param opts { session: weave.Session, on_open?: fun() } on_open, when
---   given, adds an "Open in panel" action; it runs AFTER the modal closes.
--- @return weave.view.SessionDetailsHandle handle
function M.open(opts)
  local session = opts.session
  local store = session:get_store()
  local kinds = session:config_kinds()
  local open = true
  local app

  local function close()
    if not open then
      return
    end
    open = false
    app.unmount()
  end

  -- title + blank + ≤6 fact rows + blank + kinds + actions + hint, with two
  -- rows of slack for facts (usage) that appear while the modal is up
  local height = 8 + math.max(#kinds, 1) + (opts.on_open and 2 or 0) + 2
  app = mount.floating(Details, {
    store = store,
    kinds = kinds,
    on_set = function(key, id)
      session:set_config(key, id)
    end,
    on_open = opts.on_open and function()
      close()
      opts.on_open()
    end or nil,
  }, {
    width = 56,
    height = height,
    mode = "fixed",
    border = "rounded",
    backdrop = true,
  })

  require("weave.keys").map(app.bufnr, "close_float", close, { nowait = true, desc = "weave: close session details" })
  app.focus()

  return {
    bufnr = app.bufnr,
    winid = app.winid,
    close = close,
    is_open = function()
      return open
    end,
  }
end

return M
