local mount = require("fibrous.inline.mount")
local Proxy = require("weave.mcp_proxy")
local Tools = require("weave.tools")

local function text(app)
  return table.concat(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false), "\n")
end

local function press(app, needle)
  vim.api.nvim_set_current_win(app.winid)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)) do
    local col = line:find(needle, 1, true)
    if col then
      vim.api.nvim_win_set_cursor(app.winid, { row, col - 1 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = app.bufnr })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
      return
    end
  end
  error("missing button: " .. needle)
end

describe("MCP browser", function()
  local saved_host, saved_preload, saved_list, apps
  before_each(function()
    saved_host, saved_preload, saved_list = package.loaded.clankbox, package.preload.clankbox, Proxy.list
    package.loaded.clankbox = nil
    Proxy.list = function() return {} end
    apps = {}
    Tools._reset()
  end)

  after_each(function()
    for _, app in ipairs(apps) do app.unmount() end
    Tools._reset()
    package.loaded.clankbox, package.preload.clankbox, Proxy.list = saved_host, saved_preload, saved_list
  end)

  local function hosted()
    local definitions = {
      { name = "weave_read", description = "Read a live buffer",
        inputSchema = { type = "object", properties = { path = { type = "string" } } } },
    }
    return {
      register_tool = function() end,
      handle = function(request)
        assert.equal("tools/list", request.method)
        return { jsonrpc = "2.0", id = request.id, result = { tools = definitions } }
      end,
    }
  end

  it("lists the internal clankbox host alongside managed external servers", function()
    package.loaded.clankbox = hosted()
    Proxy.list = function() return {
      { name = "external", command = "external-server", instances = {} },
    } end
    local app = mount.floating(require("weave.view.mcp").Section, {}, { width = 45, height = 8 })
    apps[#apps + 1] = app
    assert.truthy(text(app):find("clankbox", 1, true))
    assert.truthy(text(app):find("editor-hosted", 1, true))
    assert.truthy(text(app):find("external", 1, true))
    assert.falsy(text(app):find("no MCP servers", 1, true))
  end)

  it("shows the internal host's tool schemas without process metadata or controls", function()
    package.loaded.clankbox = hosted()
    local app = require("weave.view.mcp").open()
    apps[#apps + 1] = app
    press(app, "clankbox")
    local content = text(app)
    for _, needle in ipairs({ "Editor-hosted", "weave_read", "Read a live buffer", "inputSchema", "path" }) do
      assert.truthy(content:find(needle, 1, true))
    end
    for _, needle in ipairs({ "Command:", "Instance ", "Runtime:", "pid ", "Kill", "Restart", "Waiting for" }) do
      assert.is_nil(content:find(needle, 1, true))
    end
    assert.equal(1, #require("fibrous.targets").targets({ winid = app.winid }))
    press(app, "Back")
    assert.truthy(text(app):find("MCP servers", 1, true))
    assert.truthy(text(app):find("clankbox", 1, true))
  end)

  it("does not confuse the internal key with an external server name", function()
    package.loaded.clankbox = hosted()
    Proxy.list = function() return {
      { name = "internal:clankbox", command = "external-server", instances = {} },
    } end
    local app = require("weave.view.mcp").open("internal:clankbox")
    apps[#apps + 1] = app
    assert.truthy(text(app):find("Editor-hosted", 1, true))
    assert.is_nil(text(app):find("Command:", 1, true))
  end)

  it("refreshes an already open section when clankbox is registered later", function()
    local app = mount.floating(require("weave.view.mcp").Section, {}, { width = 45, height = 8 })
    apps[#apps + 1] = app
    assert.truthy(text(app):find("no MCP servers", 1, true))
    package.preload.clankbox = hosted
    assert.is_true(Tools.ensure_registered())
    assert.truthy(text(app):find("clankbox", 1, true))
    assert.is_nil(text(app):find("no MCP servers", 1, true))
  end)

  it("opens server pages, shows tool schemas, and controls processes", function()
    local View = require("weave.view.mcp")
    local saved = { list = Proxy.list, kill = Proxy.kill, restart = Proxy.restart }
    local killed, restarted
    Proxy.list = function() return {
      { name = "example", command = "example-server", instances = {
        { id = 7, pid = 42, status = "running", started_at = os.time() - 12, tools = {
          { name = "echo", description = "Echo a value", inputSchema = {
            type = "object", properties = { value = { type = "string" } },
          } },
        } },
      } },
    } end
    Proxy.kill = function(id) killed = id end
    Proxy.restart = function(id) restarted = id end
    local app
    local ok, err = pcall(function()
      app = View.open()
      assert.truthy(text(app):find("example", 1, true))
      press(app, "example")
      assert.truthy(text(app):find("Runtime:", 1, true))
      assert.truthy(text(app):find("42", 1, true))
      assert.truthy(text(app):find("Echo a value", 1, true))
      assert.truthy(text(app):find("inputSchema", 1, true))
      assert.truthy(text(app):find("value", 1, true))
      press(app, "Kill")
      assert.equal(7, killed)
      press(app, "Restart")
      assert.equal(7, restarted)
      press(app, "Back")
      assert.truthy(text(app):find("MCP servers", 1, true))
    end)
    if app then app.unmount() end
    Proxy.list, Proxy.kill, Proxy.restart = saved.list, saved.kill, saved.restart
    if not ok then error(err) end
  end)

  it("shows an empty state when no MCP server is available", function()
    local View = require("weave.view.mcp")
    local app = mount.floating(View.Section, {}, { width = 30, height = 8 })
    assert.truthy(text(app):find("MCP", 1, true))
    assert.truthy(text(app):find("no MCP servers", 1, true))
    app.unmount()
  end)
end)
