-- The live session tree and its actions share one scrolling popup.
local Float = require("weave.view.float")
local ui = require("fibrous.inline.components")
local Width = require("fibrous.inline.width")

local M = {}
local CURRENT = "●"
local FOLD_WIDTH = 3
local INSET = 1
local STATUS = {
  idle = { "Idle", "Comment" },
  thinking = { "Thinking", "DiagnosticInfo" },
  generating = { "Replying", "DiagnosticInfo" },
  busy = { "Working", "DiagnosticInfo" },
  running = { "Running", "DiagnosticInfo" },
  queued = { "Queued", "Comment" },
  provisioning = { "Starting", "DiagnosticInfo" },
  waiting_for_approval = { "Approval", "DiagnosticWarn" },
  completed = { "Done", "DiagnosticOk" },
  failed = { "Failed", "DiagnosticError" },
  cancelled = { "Cancelled", "Comment" },
}

local function one_line(text)
  return vim.trim(text:gsub("%s+", " "))
end

local function row_content(entry)
  local state = entry.session:get_store().state
  local title = one_line(entry.name or state.meta.title or "")
  if title == "" then
    for _, item in ipairs(state.entries) do
      if item.kind == "user" then
        title = one_line(item.text)
        if title ~= "" then break end
      end
    end
  end
  local status = require("weave.subagents").status(entry.session) or state.status
  if state.permission_count > 0 then status = "waiting_for_approval" end
  local display = STATUS[status] or { status:gsub("_", " "), "Comment" }
  return title ~= "" and title or "(no messages yet)",
    one_line(state.meta.provider or entry.provider), display[1], display[2]
end

local function ellipsis(text, cells)
  if Width.str(text) <= cells then return text end
  local room = cells - Width.str("…")
  if room < 0 then return "" end
  local bytes = 0
  for cluster in Width.clusters(text) do
    room = room - Width.char(cluster)
    if room < 0 then break end
    bytes = bytes + #cluster
  end
  return text:sub(1, bytes) .. "…"
end

local function label(text, hl, width)
  return { comp = ui.label, props = { text = text, width = width, style = hl and { text_hl = hl } or nil } }
end

local function button(text, press, hl, width, primary)
  return { comp = ui.button, props = {
    label = text, on_press = press, width = width, theme = false,
    style = {
      text_hl = hl,
      padding = primary and { x = 1 } or nil,
      hl = primary and "Pmenu" or nil,
      _hover = { hl = "FibrousButtonHover" },
    },
  } }
end

local function line(children, props)
  return { comp = ui.row, props = props or { gap = 1 }, children = children }
end

local function title_column()
  return Width.str(CURRENT) + FOLD_WIDTH + 2 -- marker, fold, and their gaps
end

local function columns(rows, cap, details)
  local title, provider = Width.str("Title"), Width.str("Provider")
  for _, row in ipairs(rows) do
    title = math.max(title, Width.str(row.guide) + Width.str(row.title))
    provider = math.max(provider, Width.str(row.provider))
  end
  -- Keep the title and actions visible when the editor is narrow. The full
  -- provider name and status remain available in Session details.
  provider = cap >= 54 and math.min(provider, 18) or 0
  local status = cap >= 35 and 9 or 0
  local actions = Width.str("✕") + (details and Width.str("ⓘ") + 1 or 0)
  local occupied = title_column() + actions + 1
    + (provider > 0 and provider + 1 or 0) + (status > 0 and status + 1 or 0)
  title = math.max(1, math.min(title, cap - occupied))
  return title, provider, status
end

local function Modal(_, props)
  local cap = Float.width() - 2 * INSET
  local title_w, provider_w, status_w = columns(props.rows, cap, props.on_details ~= nil)
  local rows = {}
  local marker_w = Width.str(CURRENT)
  local function row_fields(marker, fold, title, provider, status, hl)
    local cells = { marker, fold, title }
    if provider_w > 0 then cells[#cells + 1] = label(ellipsis(provider, provider_w), "Comment", provider_w) end
    if status_w > 0 then cells[#cells + 1] = label(ellipsis(status, status_w), hl, status_w) end
    return cells
  end
  for _, row in ipairs(props.rows) do
    local entry = row.entry
    local current = entry.key == props.selected_key
    local guide = Width.str(row.guide) <= math.floor(title_w / 2) and row.guide or "… "
    local children = row_fields(
      label(current and CURRENT or "", "Special", marker_w),
      row.branch and button(row.collapsed and "[+]" or "[-]", function() props.on_toggle(entry.key) end, "Special")
        or label("", nil, FOLD_WIDTH),
      button(ellipsis(guide .. row.title, title_w), function() props.on_select(entry) end,
        current and "Title" or nil, title_w),
      row.provider, row.status, row.status_hl)
    if props.on_details then
      children[#children + 1] = button("ⓘ", function() props.on_details(entry) end, "Comment")
    end
    children[#children + 1] = button("✕", function() props.on_close_session(entry) end, "Comment")
    local item = line(children)
    item.key = entry.key
    rows[#rows + 1] = item
  end

  local headings = label("")
  if #rows == 0 then
    rows[1] = label("No active sessions", "Comment")
  else
    headings = line(row_fields(
      label("", nil, marker_w), label("", nil, FOLD_WIDTH), label("Title", "Comment", title_w),
      "Provider", "Status", "Comment"))
  end
  local actions = line({
    button(cap >= 32 and "a  New session" or "a  New", props.on_new, nil, nil, true),
    button(cap >= 23 and "o  Load saved" or "o  Load", props.on_load_saved, nil, nil, true),
  })
  local footer = { actions }
  if cap >= 41 then footer[2] = label("q close", "Comment") end
  return { comp = ui.col, props = { style = { padding = { x = INSET } } }, children = {
    line({ label("Sessions", "Title"), label(("%d active"):format(props.count), "Comment") },
      { justify = "space-between", gap = 2 }),
    headings,
    { comp = ui.col, children = rows },
    { comp = ui.label, props = { fill = function(width) return ("─"):rep(width) end, style = { text_hl = "FloatBorder" } } },
    line(footer, { justify = "space-between", gap = 2 }),
  } }
end


--- Open a live, collapsible session tree for the current tab.
--- Closing a parent requires confirmation and closes its entire subtree.
--- @param opts { registry?: table, on_select: fun(entry: weave.registry.Entry), on_details?: fun(entry: weave.registry.Entry), on_new?: fun(), on_load_saved?: fun() }
function M.open(opts)
  local registry = opts.registry or require("weave.registry")
  local tab = vim.api.nvim_get_current_tabpage()
  local open, scheduled, confirming = true, false, false
  local app, refresh, unsubscribe
  local collapsed = {}
  local last_selected

  local function cleanup()
    open = false
    if unsubscribe then unsubscribe(); unsubscribe = nil end
  end
  local function close()
    if not open then return end
    cleanup()
    if app then app.unmount() end
  end

  local function new_session()
    close()
    if opts.on_new then opts.on_new() end
  end
  local function load_saved()
    close()
    if opts.on_load_saved then opts.on_load_saved() end
  end

  local function rows()
    local entries, by_parent, result = registry.list(), {}, {}
    for _, entry in ipairs(entries) do
      local parent = entry.parent_key or 0
      by_parent[parent] = by_parent[parent] or {}
      table.insert(by_parent[parent], entry)
    end
    local function visit(parent, indent)
      local siblings = by_parent[parent] or {}
      for i, entry in ipairs(siblings) do
        local last = i == #siblings
        local title, provider, status, status_hl = row_content(entry)
        result[#result + 1] = {
          entry = entry, title = title, provider = provider, status = status, status_hl = status_hl,
          guide = parent == 0 and "" or indent .. (last and "└─ " or "├─ "),
          branch = by_parent[entry.key] ~= nil, collapsed = collapsed[entry.key] == true,
        }
        if not collapsed[entry.key] then
          visit(entry.key, parent == 0 and "" or indent .. (last and "   " or "│  "))
        end
      end
    end
    visit(0, "")
    return result, #entries
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
    local visible, count = rows()
    return {
      rows = visible, count = count, selected_key = last_selected,
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
      on_new = new_session, on_load_saved = load_saved,
    }
  end

  local initial = build_props()
  app = Float.mount(Modal, initial, { on_unmount = cleanup })
  refresh = function()
    if not open then return end
    app.set_props(build_props())
  end
  local function schedule_refresh()
    if not open or scheduled then return end
    scheduled = true
    vim.schedule(function() scheduled = false; refresh() end)
  end
  if registry.subscribe then unsubscribe = registry.subscribe(schedule_refresh) end
  Float.chrome(app, {
    close = close, desc = "weave: close session tree", keep_open = function() return confirming end,
  })
  vim.keymap.set("n", "a", new_session, { buffer = app.bufnr, nowait = true, desc = "weave: new session" })
  vim.keymap.set("n", "o", load_saved, { buffer = app.bufnr, nowait = true, desc = "weave: load saved session" })
  if #initial.rows > 0 then
    local index = 1
    for i, row in ipairs(initial.rows) do
      if row.entry.key == initial.selected_key then index = i; break end
    end
    local row = index + 2 -- the popup title and column headings precede the sessions
    local text = vim.api.nvim_buf_get_lines(app.bufnr, row - 1, row, false)[1]
    vim.api.nvim_win_set_cursor(app.winid, { row, Width.cell_to_byte(text, INSET + title_column()) })
  end
  return {
    bufnr = app.bufnr, winid = app.winid,
    tree = { bufnr = app.bufnr, winid = app.winid }, -- existing session-tree handle
    close = close, refresh = refresh, is_open = function() return open end,
  }
end

return M
