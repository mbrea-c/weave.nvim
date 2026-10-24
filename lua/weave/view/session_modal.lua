-- Live registry forest. Only the tree scrolls; new/load actions stay pinned.
local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")
local Keys = require("weave.keys")
local M = {}

local function row_label(entry)
  local state = entry.session:get_store().state
  local title = entry.name or state.meta.title
  if not title or title == "" then
    title = "(no messages yet)"
    for _, item in ipairs(state.entries) do
      if item.kind == "user" then title = item.text:gsub("%s+", " "); break end
    end
  end
  if vim.fn.strchars(title) > 32 then title = vim.fn.strcharpart(title, 0, 31) .. "…" end
  local status = require("weave.subagents").status(entry.session) or state.status
  if state.permission_count > 0 then status = "waiting for approval" end
  return ("%s · %s · %s"):format(state.meta.provider or entry.provider, title, status:gsub("_", " "))
end

local function Modal(_, props)
  local rows = {}
  for _, row in ipairs(props.rows) do
    local entry = row.entry
    rows[#rows + 1] = {
      comp = ui.row, key = entry.key, props = {},
      children = {
        { comp = ui.label, props = { text = string.rep("  ", row.depth)
          .. (entry.key == props.selected_key and "● " or "  ") } },
        row.branch and {
          comp = ui.button,
          props = { label = row.collapsed and "[+]" or "[-]",
            on_press = function() props.on_toggle(entry.key) end },
        } or { comp = ui.label, props = { text = "   " } },
        { comp = ui.label, props = { text = " " } },
        { comp = ui.button, props = { label = row_label(entry),
          on_press = function() props.on_select(entry) end } },
        { comp = ui.label, props = { text = " " } },
        props.on_details and { comp = ui.button, props = { label = "ⓘ",
          on_press = function() props.on_details(entry) end } }
          or { comp = ui.label, props = { text = "" } },
        { comp = ui.button, props = { label = "✕",
          on_press = function() props.on_close_session(entry) end } },
      },
    }
  end
  if #rows == 0 then
    rows[1] = { comp = ui.label, props = { text = { { "  (no active sessions)", hl = "Comment" } } } }
  end
  return { comp = ui.col, props = {}, children = {
    { comp = ui.label, props = { text = { { "Sessions", hl = "Title" } } } },
    { comp = ui.label, props = { text = "" } },
    { comp = ui.container, props = { grow = 1, scroll_x = false, on_create = props.on_tree_create },
      children = rows },
    { comp = ui.label, props = { text = "" } },
    { comp = ui.row, props = {}, children = {
      { comp = ui.button, props = { label = "+ new session", on_press = props.on_new } },
      { comp = ui.label, props = { text = "  " } },
      { comp = ui.button, props = { label = "↺ load saved…", on_press = props.on_load_saved } },
    } },
    { comp = ui.label, props = { text = { { "<CR> select · [+]/[-] fold · ✕ close · q dismiss", hl = "Comment" } } } },
  } }
end

--- Open a live, collapsible session tree for the current tab.
--- Closing a parent requires confirmation and closes its entire subtree.
--- @param opts { registry?: table, on_select: fun(entry: weave.registry.Entry), on_details?: fun(entry: weave.registry.Entry), on_new?: fun(), on_load_saved?: fun() }
function M.open(opts)
  local registry = opts.registry or require("weave.registry")
  local tab = vim.api.nvim_get_current_tabpage()
  local open, scheduled, confirming = true, false, false
  local app, refresh, unsubscribe, resize_group
  local tree, collapsed = {}, {}
  local last_selected
  local geometry = { mode = "fixed", border = "rounded", backdrop = true }

  local function cleanup()
    open = false
    if unsubscribe then unsubscribe(); unsubscribe = nil end
    if resize_group then pcall(vim.api.nvim_del_augroup_by_id, resize_group); resize_group = nil end
  end
  local function close()
    if not open then return end
    cleanup()
    if app then app.unmount() end
  end
  geometry.on_unmount = cleanup

  local function rows()
    local entries, by_parent, result = registry.list(), {}, {}
    for _, entry in ipairs(entries) do
      local parent = entry.parent_key or 0
      by_parent[parent] = by_parent[parent] or {}
      table.insert(by_parent[parent], entry)
    end
    local function visit(parent, depth)
      for _, entry in ipairs(by_parent[parent] or {}) do
        result[#result + 1] = { entry = entry, depth = depth,
          branch = by_parent[entry.key] ~= nil, collapsed = collapsed[entry.key] == true }
        if not collapsed[entry.key] then visit(entry.key, depth + 1) end
      end
    end
    visit(0, 0)
    return result
  end

  local function build_props()
    local selected = registry.selected(tab)
    if selected and selected.key ~= last_selected then
      local ancestor = selected
      while ancestor and ancestor.parent_key do
        collapsed[ancestor.parent_key] = nil
        ancestor = registry.get(ancestor.parent_key)
      end
    end
    last_selected = selected and selected.key
    return {
      rows = rows(), selected_key = last_selected,
      on_tree_create = function(bufnr, winid)
        tree.bufnr, tree.winid = bufnr, winid
        Keys.map(bufnr, "close_float", close, { nowait = true, desc = "weave: close session tree" })
      end,
      on_toggle = function(key) collapsed[key] = not collapsed[key]; refresh() end,
      on_select = function(entry) close(); opts.on_select(entry) end,
      on_close_session = function(entry)
        local function remove()
          if open and registry.get(entry.key) == entry then registry.close(entry.key); refresh() end
        end
        local descendants = registry.children(entry.key, true)
        if #descendants == 0 then return remove() end
        confirming = true
        vim.ui.select({ "Cancel", "Close subtree" },
          { prompt = ("Close session and its %d descendant(s)?"):format(#descendants) },
          function(choice)
            confirming = false
            if choice == "Close subtree" then remove() end
          end)
      end,
      on_details = opts.on_details and function(entry) close(); opts.on_details(entry) end or nil,
      on_new = function() close(); if opts.on_new then opts.on_new() end end,
      on_load_saved = function() close(); if opts.on_load_saved then opts.on_load_saved() end end,
    }
  end

  local function size()
    geometry.width = math.max(1, math.min(86, vim.o.columns - 4))
    geometry.height = math.max(1, math.min(math.max(#rows(), 1) + 5, vim.o.lines - 4))
  end
  size()
  app = mount.floating(Modal, build_props(), geometry)
  refresh = function()
    if not open then return end
    size()
    app.set_props(build_props())
    app.relayout()
  end
  local function schedule_refresh()
    if not open or scheduled then return end
    scheduled = true
    vim.schedule(function() scheduled = false; refresh() end)
  end
  if registry.subscribe then unsubscribe = registry.subscribe(schedule_refresh) end
  resize_group = vim.api.nvim_create_augroup("WeaveSessionTree_" .. app.winid, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", { group = resize_group, callback = refresh })
  require("weave.view.float").chrome(app, {
    close = close, desc = "weave: close session tree", keep_open = function() return confirming end,
  })
  return {
    bufnr = app.bufnr, winid = app.winid, tree = tree,
    close = close, refresh = refresh, is_open = function() return open end,
  }
end

return M
