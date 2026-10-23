-- Editor-hosted MCP tools, managed process instances, and tool definitions.
local ui = require("fibrous.inline.components")
local Proxy = require("weave.mcp_proxy")
local Tools = require("weave.tools")
local M = {}

local function label(text)
  return { comp = ui.label, props = { text = text } }
end

local function button(text, action)
  return { comp = ui.button, props = {
    label = text, theme = false,
    style = { _hover = { hl = "FibrousHover" } }, on_press = action,
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
    local function changed() version.set(version.get() + 1) end
    local unsubscribe = Proxy.subscribe(changed)
    local unsubscribe_tools = Tools.subscribe(changed)
    local timer
    if tick then
      timer = vim.uv.new_timer()
      timer:start(1000, 1000, vim.schedule_wrap(function() version.set(version.get() + 1) end))
    end
    return function()
      unsubscribe()
      unsubscribe_tools()
      if timer then timer:stop(); timer:close() end
    end
  end, { tick == true })
  version.get()
  return list_servers()
end

local function status(server)
  if server.kind == "internal" then return "editor-hosted" end
  local running = 0
  for _, instance in ipairs(server.instances) do
    if instance.status == "running" then running = running + 1 end
  end
  return ("%d running / %d instances"):format(running, #server.instances)
end

function M.Section(ctx)
  local servers = use_servers(ctx)
  local rows = { button("MCP", function() M.open() end) }
  rows[1].props.style.text_hl = "Title"
  for _, server in ipairs(servers) do
    local key = server.key
    rows[#rows + 1] = button(server.name .. " (" .. status(server) .. ")", function() M.open(key) end)
  end
  if #servers == 0 then rows[#rows + 1] = label("(no MCP servers)") end
  return { comp = ui.col, props = {}, children = rows }
end

local function append_tools(rows, definitions, empty_label)
  rows[#rows + 1] = label("Tools")
  if #definitions == 0 then rows[#rows + 1] = label(empty_label) end
  for _, tool in ipairs(definitions) do
    rows[#rows + 1] = label("")
    rows[#rows + 1] = label(tool.name)
    -- Preserve every advertised field, including schemas and extensions.
    rows[#rows + 1] = { comp = ui.paragraph, props = { text = vim.inspect(tool) } }
  end
end

function M.open(name)
  local function Browser(ctx)
    local servers = use_servers(ctx, true)
    local selected = ctx.use_state(name or "")
    local rows = {}
    local server
    for _, candidate in ipairs(servers) do
      if candidate.key == selected.get() then server = candidate; break end
      if candidate.name == selected.get() then server = candidate end
    end
    if not server then
      rows[#rows + 1] = label("MCP servers")
      if #servers == 0 then rows[#rows + 1] = label("(no MCP servers)") end
      for _, item in ipairs(servers) do
        local key = item.key
        rows[#rows + 1] = button(item.name .. " - " .. status(item), function() selected.set(key) end)
      end
    else
      rows[#rows + 1] = button("Back to MCP list", function() selected.set("") end)
      rows[#rows + 1] = label("MCP: " .. server.name)
      if server.kind == "internal" then
        rows[#rows + 1] = label("Editor-hosted in Neovim (Weave/clankbox)")
        rows[#rows + 1] = label("No standalone process")
        rows[#rows + 1] = { comp = ui.paragraph, props = {
          text = "This is the shared host registry. Scoped agent connections may expose a subset of these tools.",
        } }
        if server.error then rows[#rows + 1] = label("Error: " .. server.error) end
        append_tools(rows, server.tools, "(no tools registered)")
      else
        rows[#rows + 1] = label("Command: " .. server.command)
        if #server.instances == 0 then
          rows[#rows + 1] = label("Waiting for an agent connection")
        end
        for _, instance in ipairs(server.instances) do
          local id = instance.id
          local runtime = instance.started_at
            and math.max(0, (instance.finished_at or os.time()) - instance.started_at) or 0
          rows[#rows + 1] = label("")
          rows[#rows + 1] = label(("Instance %d: %s (pid %s)"):format(id, instance.status, instance.pid or "?"))
          rows[#rows + 1] = label(("Runtime: %ds"):format(runtime))
          if instance.exit_code then rows[#rows + 1] = label("Exit code: " .. instance.exit_code) end
          if instance.error then rows[#rows + 1] = label("Error: " .. instance.error) end
          if instance.status ~= "disconnected" then
            rows[#rows + 1] = { comp = ui.row, props = { gap = 2 }, children = {
              button("Kill", function() Proxy.kill(id) end),
              button("Restart", function() Proxy.restart(id) end),
            } }
          end
          append_tools(rows, instance.tools, "(no tools discovered yet)")
        end
      end
    end
    return { comp = ui.col, props = {}, children = rows }
  end
  local app = require("fibrous.inline.mount").floating(Browser, {}, {
    width = math.min(90, math.max(20, vim.o.columns - 6)),
    height = math.min(32, math.max(8, vim.o.lines - 6)),
    mode = "scroll", border = "rounded", backdrop = true,
  })
  return require("weave.view.float").chrome(app, {
    close = app.unmount, desc = "weave: close MCP browser",
  })
end

return M
