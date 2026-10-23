-- MCP browser: compact sidebar status, server connections, then tool details.
local ui = require("fibrous.inline.components")
local Proxy = require("weave.mcp_proxy")
local Tools = require("weave.tools")
local M = {}

local function label(text, hl)
  return { comp = ui.label, props = { text = text, style = hl and { text_hl = hl } or nil } }
end

-- The full value is on the next page; previews signal truncation explicitly.
local function preview(text, hl)
  local node = label(text, hl)
  node.props.fill = function(width)
    if width < 1 then return "" end
    if vim.api.nvim_strwidth(text) <= width then return text end
    local shown = vim.fn.strcharpart(text, 0, width - 1)
    while vim.api.nvim_strwidth(shown) >= width do
      shown = vim.fn.strcharpart(shown, 0, vim.fn.strchars(shown) - 1)
    end
    return shown .. "…"
  end
  return node
end

local function paragraph(text, hl)
  return { comp = ui.paragraph, props = { text = text, style = hl and { text_hl = hl } or nil } }
end

local function link(text, action, hl)
  return { comp = ui.button, props = {
    label = text, theme = false,
    style = { text_hl = hl, _hover = { hl = "FibrousHover" } }, on_press = action,
  } }
end

local function list_servers()
  local servers = Proxy.list()
  for _, server in ipairs(servers) do server.key = "external:" .. server.name end
  local internal = Tools.hosted_server()
  if internal then servers[#servers + 1] = internal end
  table.sort(servers, function(a, b)
    if a.name == b.name then return a.key < b.key end
    return a.name < b.name
  end)
  return servers
end

local function use_servers(ctx, tick)
  local version = ctx.use_state(0)
  ctx.use_effect(function()
    local disposed = false
    local function changed()
      if not disposed then version.set(version.get() + 1) end
    end
    local unsubscribe = Proxy.subscribe(changed)
    local unsubscribe_tools = Tools.subscribe(changed)
    local timer
    if tick then
      timer = vim.uv.new_timer()
      timer:start(1000, 1000, vim.schedule_wrap(changed))
    end
    return function()
      disposed = true
      unsubscribe()
      unsubscribe_tools()
      if timer then timer:stop(); timer:close() end
    end
  end, { tick == true })
  version.get()
  return list_servers()
end

local function instance_failed(instance)
  if instance.status == "disconnected" then return false end
  return instance.status == "failed" or instance.error ~= nil
    or (instance.exit_code ~= nil and instance.exit_code ~= 0)
end

local function instance_status(instance)
  if instance_failed(instance) then return "failed", "DiagnosticError" end
  if instance.status == "running" then return "running", "DiagnosticOk" end
  if instance.status == "starting" then return "starting", "DiagnosticWarn" end
  return instance.status, "Comment"
end

local function status(server, compact)
  if server.error then return "error", "DiagnosticError" end
  if server.kind == "internal" then return compact and "hosted" or "ready", "Special" end
  local running, starting, failed = 0, 0, 0
  for _, instance in ipairs(server.instances) do
    if instance_failed(instance) then failed = failed + 1
    elseif instance.status == "running" then running = running + 1
    elseif instance.status == "starting" then starting = starting + 1 end
  end
  if failed > 0 then return running > 0 and "degraded" or "failed", "DiagnosticError" end
  if starting > 0 then return "starting", "DiagnosticWarn" end
  if running > 0 then return "running", "DiagnosticOk" end
  return #server.instances == 0 and "waiting" or "offline", "Comment"
end

-- A growable name keeps status aligned even when the name must be clipped.
local function title_row(title, state, state_hl, title_hl)
  local name = preview(title, title_hl)
  name.props.grow = 1
  return { comp = ui.row, props = { gap = 1 }, children = { name, label(state, state_hl) } }
end

function M.Section(ctx)
  local servers = use_servers(ctx)
  local rows = { link({ "MCP", { "  " .. #servers, hl = "Comment" } }, function() M.open() end, "Title") }
  for _, server in ipairs(servers) do
    local key = server.key
    local state, hl = status(server, true)
    local row = title_row(server.name, state, hl)
    row.props.role = "button"
    row.props.on_press = function() M.open(key) end
    row.props.style = { _hover = { hl = "FibrousHover" } }
    table.insert(row.children, 1, label("●", hl))
    rows[#rows + 1] = row
  end
  if #servers == 0 then rows[#rows + 1] = label("(no MCP servers)", "Comment") end
  return { comp = ui.col, props = {}, children = rows }
end

-- One full-width navigation target, with secondary information quiet at rest.
local function item(title, subtitle, action, state, state_hl)
  return { comp = ui.col, props = {
    role = "button", on_press = action,
    style = { padding = { left = 1 }, border = { left = "│", hl = "FloatBorder" },
      _hover = { hl = "FibrousHover", border_hl = "DiagnosticInfo" } },
  }, children = {
    title_row(title, state or "", state_hl, "Function"),
    preview(subtitle, "Comment"),
  } }
end

local function server_summary(server)
  if server.kind == "internal" then
    return ("Editor-hosted · %d %s"):format(#server.tools, #server.tools == 1 and "tool" or "tools")
  end
  return ("Managed process · %d %s"):format(#server.instances, #server.instances == 1 and "connection" or "connections")
end

local function append_tools(rows, definitions, open_tool)
  local section = { label(("Tools (%d)"):format(#definitions), "Title") }
  if #definitions == 0 then
    section[#section + 1] = label("No tools advertised yet.", "Comment")
    rows[#rows + 1] = { comp = ui.col, props = {}, children = section }
    return
  end
  local tools = vim.list_extend({}, definitions)
  table.sort(tools, function(a, b) return a.name < b.name end)
  local items = {}
  for _, tool in ipairs(tools) do
    local name = tool.name
    local description = (tool.description or "No description provided."):gsub("%s+", " ")
    items[#items + 1] = item(name, description, function() open_tool(name) end)
  end
  section[#section + 1] = { comp = ui.col, props = { gap = 1 }, children = items }
  rows[#rows + 1] = { comp = ui.col, props = {}, children = section }
end

local function duration(seconds)
  if seconds < 60 then return ("%ds"):format(seconds) end
  if seconds < 3600 then return ("%dm %02ds"):format(math.floor(seconds / 60), seconds % 60) end
  return ("%dh %02dm"):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60)
end

local function connection(instance, open_tool)
  local id = instance.id
  local state, hl = instance_status(instance)
  local summary = { title_row("Connection #" .. id, state, hl, "Title") }
  local rows = { { comp = ui.col, props = {}, children = summary } }
  local facts = {}
  if instance.pid then facts[#facts + 1] = "PID " .. instance.pid end
  if instance.started_at then
    local runtime = math.max(0, (instance.finished_at or os.time()) - instance.started_at)
    facts[#facts + 1] = (instance.finished_at and "Runtime " or "Uptime ") .. duration(runtime)
  end
  if instance.exit_code ~= nil then facts[#facts + 1] = "Exit " .. instance.exit_code end
  if #facts > 0 then summary[#summary + 1] = paragraph(table.concat(facts, " · "), "Comment") end
  if instance.error then rows[#rows + 1] = paragraph(instance.error, "DiagnosticError") end
  if instance.status ~= "disconnected" then
    local actions = {
      { comp = ui.button, props = { label = "Restart", on_press = function() Proxy.restart(id) end } },
    }
    if instance.status == "running" or instance.status == "starting" then
      actions[#actions + 1] = { comp = ui.button, props = {
        label = "Kill", style = { text_hl = "DiagnosticError" }, on_press = function() Proxy.kill(id) end,
      } }
    end
    rows[#rows + 1] = { comp = ui.row, props = { gap = 1 }, children = actions }
  end
  append_tools(rows, instance.tools, function(name) open_tool(name, id) end)
  return { comp = ui.col, props = {
    gap = 1, style = { padding = { left = 1 }, border = { left = "│", hl = "FloatBorder" } },
  }, children = rows }
end

-- Unlike a paragraph or a clipped code snippet, char wrapping preserves JSON
-- indentation and makes the end of even a very long schema string readable.
local function Json(ctx, props)
  local memo = ctx.use_ref()
  if not memo.current or not vim.deep_equal(memo.current.value, props.value) then
    local text = require("weave.utils.json").pretty(props.value)
    memo.current = { value = vim.deepcopy(props.value),
      text = require("fibrous.doc.highlight").code(text, "json") or text }
  end
  return { comp = ui.text, props = {
    text = memo.current.text, wrap = "char",
    style = { text_hl = "@markup.raw", padding = { left = 1 }, border = { left = "│", hl = "FloatBorder" } },
  } }
end

local function Tool(ctx, props)
  local tool = props.tool
  local full = ctx.use_state(false)
  local title = tool.title or (tool.annotations and tool.annotations.title) or tool.name
  local heading = { label(title, "Title") }
  if title ~= tool.name then heading[#heading + 1] = label(tool.name, "Function") end
  heading[#heading + 1] = paragraph(props.source, "Comment")
  local rows = { { comp = ui.col, props = {}, children = heading } }
  rows[#rows + 1] = tool.description
    and { comp = ui.markdown, props = { text = tool.description } }
    or label("No description provided.", "Comment")
  for _, field in ipairs({
    { "inputSchema", "Input schema" }, { "outputSchema", "Output schema" }, { "annotations", "Annotations" },
  }) do
    if tool[field[1]] ~= nil then
      rows[#rows + 1] = { comp = ui.col, props = {}, children = {
        label(field[2], "Title"), { comp = Json, key = field[1], props = { value = tool[field[1]] } },
      } }
    end
  end
  rows[#rows + 1] = link((full.get() and "- " or "+ ") .. "Full definition", function()
    full.set(not full.get())
  end, "Comment")
  if full.get() then rows[#rows + 1] = { comp = Json, key = "full", props = { value = tool } } end
  return { comp = ui.col, props = { gap = 1 }, children = rows }
end

local function find_server(servers, name)
  for _, server in ipairs(servers) do if server.key == name then return server end end
  for _, server in ipairs(servers) do if server.name == name then return server end end
end

local function find_tool(server, page)
  local tools = server.tools
  if server.kind ~= "internal" then
    tools = {}
    for _, instance in ipairs(server.instances) do
      if instance.id == page.instance then tools = instance.tools; break end
    end
  end
  for _, tool in ipairs(tools) do if tool.name == page.tool then return tool end end
end

function M.open(name)
  local app, go_back, resize_group
  local closed, fit_pending = false, false
  local options = {
    width = math.min(88, math.max(1, vim.o.columns - 6)),
    height = math.min(30, math.max(1, vim.o.lines - 6)),
    mode = "scroll", border = "rounded", backdrop = true,
    on_unmount = function()
      closed = true
      if resize_group then vim.api.nvim_del_augroup_by_id(resize_group) end
    end,
  }
  local function fit()
    if closed or not app or not vim.api.nvim_win_is_valid(app.winid) then return end
    local width = math.min(88, math.max(1, vim.o.columns - 6))
    if options.width ~= width then options.width = width; app.relayout() end
    local height = math.min(30, math.max(1, vim.o.lines - 6), vim.api.nvim_buf_line_count(app.bufnr))
    if options.height ~= height then options.height = height; app.relayout() end
  end
  local function schedule_fit()
    if closed or fit_pending then return end
    fit_pending = true
    vim.schedule(function() fit_pending = false; fit() end)
  end
  local function Browser(ctx)
    local servers = use_servers(ctx, true)
    local selected = ctx.use_state({ server = name })
    local page = selected.get()
    local function navigate(next_page, back)
      if app and vim.api.nvim_win_is_valid(app.winid) then
        page.view = vim.api.nvim_win_call(app.winid, vim.fn.winsaveview)
      end
      if not back then next_page.previous = page end
      selected.set(next_page)
      fit()
      if app and vim.api.nvim_win_is_valid(app.winid) then
        vim.api.nvim_win_call(app.winid, function()
          vim.fn.winrestview(next_page.view or { lnum = 1, col = 0, topline = 1, leftcol = 0, skipcol = 0 })
        end)
      end
    end
    go_back = function() navigate(page.previous or {}, true) end
    local server = find_server(servers, page.server)
    local rows = {}
    if not server then
      rows[#rows + 1] = title_row("MCP servers",
        ("%d %s"):format(#servers, #servers == 1 and "server" or "servers"), "Comment", "Title")
      if #servers == 0 then
        rows[#rows + 1] = label("No MCP servers available", "Comment")
        rows[#rows + 1] = paragraph("Configured servers appear when an agent connects. The editor-hosted registry appears when clankbox is loaded.", "Comment")
      else
        for _, entry in ipairs(servers) do
          local key = entry.key
          local state, hl = status(entry)
          rows[#rows + 1] = item(entry.name, server_summary(entry), function()
            navigate({ server = key })
          end, state, hl)
        end
      end
    else
      rows[#rows + 1] = link(page.tool and ("Back to " .. server.name) or "Back to MCP list", go_back, "Comment")
      if page.tool then
        local tool = find_tool(server, page)
        rows[#rows + 1] = tool
          and { comp = Tool, key = page.tool, props = {
            tool = tool, source = server.name .. (page.instance and (" / Connection #" .. page.instance) or " / Editor-hosted"),
          } }
          or paragraph("This tool is no longer advertised by the connection.", "DiagnosticWarn")
      else
        local state, hl = status(server)
        local heading = { title_row(server.name, state, hl, "Title") }
        rows[#rows + 1] = { comp = ui.col, props = {}, children = heading }
        local function open_tool(tool, instance)
          navigate({ server = server.key, tool = tool, instance = instance })
        end
        if server.kind == "internal" then
          heading[#heading + 1] = label("Editor-hosted in Neovim", "Comment")
          if server.error then rows[#rows + 1] = paragraph(server.error, "DiagnosticError") end
          append_tools(rows, server.tools, open_tool)
          rows[#rows + 1] = paragraph("Shared host registry. Scoped agent connections may expose a subset of these tools.", "Comment")
        else
          rows[#rows + 1] = { comp = ui.col, props = {}, children = {
            label("Command", "Comment"),
            { comp = ui.text, props = { text = server.command, wrap = "char", style = { text_hl = "@markup.raw" } } },
          } }
          rows[#rows + 1] = label(("Connections (%d)"):format(#server.instances), "Title")
          if #server.instances == 0 then
            rows[#rows + 1] = paragraph("Waiting for an agent connection.", "Comment")
          end
          for _, instance in ipairs(server.instances) do rows[#rows + 1] = connection(instance, open_tool) end
        end
      end
    end
    rows[#rows + 1] = paragraph("Tab / S-Tab  navigate · Enter  select · Backspace  back", "Comment")
    return { comp = ui.col, props = { gap = 1, style = {
      padding = { x = 2, y = vim.o.lines < 20 and 0 or 1 },
    } }, children = rows }
  end
  app = require("fibrous.inline.mount").floating(Browser, {}, options)
  fit()
  -- Buffer changes include live discovery and expanding a full definition.
  -- Defer resizing out of on_lines (textlock), and detach with the app.
  vim.api.nvim_buf_attach(app.bufnr, false, { on_lines = function()
    if closed then return true end
    schedule_fit()
  end })
  resize_group = vim.api.nvim_create_augroup("WeaveMcpBrowser_" .. app.winid, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", { group = resize_group, callback = function()
    app.set_props({}) -- Re-evaluate compact vertical padding as well as width.
    schedule_fit()
  end })
  vim.keymap.set("n", "<BS>", function() go_back() end, { buffer = app.bufnr, nowait = true, desc = "weave: back in MCP browser" })
  return require("weave.view.float").chrome(app, {
    close = app.unmount, desc = "weave: close MCP browser",
  })
end

return M
