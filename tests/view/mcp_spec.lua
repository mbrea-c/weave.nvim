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
    assert.truthy(text(app):find("hosted", 1, true))
    assert.truthy(text(app):find("external", 1, true))
    assert.falsy(text(app):find("no MCP servers", 1, true))
  end)

  it("shows the internal host's tool schemas without process metadata or controls", function()
    package.loaded.clankbox = hosted()
    local app = require("weave.view.mcp").open()
    apps[#apps + 1] = app
    press(app, "clankbox")
    local content = text(app)
    for _, needle in ipairs({ "Editor-hosted", "weave_read", "Read a live buffer", "Tools (1)" }) do
      assert.truthy(content:find(needle, 1, true))
    end
    for _, needle in ipairs({ "Command", "Connection #", "Runtime", "Uptime", "PID ", "[ Kill ]", "[ Restart ]", "Waiting for" }) do
      assert.is_nil(content:find(needle, 1, true))
    end
    assert.is_nil(content:find("inputSchema", 1, true))
    press(app, "weave_read")
    assert.truthy(text(app):find("Input schema", 1, true))
    assert.truthy(text(app):find('"path"', 1, true))
    press(app, "Back")
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
    assert.is_nil(text(app):find("Command", 1, true))
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
      assert.truthy(text(app):find("Uptime", 1, true))
      assert.truthy(text(app):find("42", 1, true))
      assert.truthy(text(app):find("Echo a value", 1, true))
      assert.is_nil(text(app):find("inputSchema", 1, true))
      press(app, "echo")
      assert.truthy(text(app):find("Input schema", 1, true))
      assert.truthy(text(app):find('"value"', 1, true))
      press(app, "Back")
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
  it("keeps sidebar rows compact and gives status its own highlighted column", function()
    package.loaded.clankbox = hosted()
    Proxy.list = function() return {
      { name = "external-with-a-very-long-name", command = "external-server", instances = {
        { id = 1, status = "failed", exit_code = 1, tools = {} },
      } },
    } end
    local app = mount.floating(require("weave.view.mcp").Section, {}, { width = 28, height = 8, mode = "scroll" })
    apps[#apps + 1] = app
    local lines = vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)
    assert.equal(3, #lines)
    assert.truthy(lines[2]:find("hosted", 1, true))
    assert.truthy(lines[3]:find("failed", 1, true))
    assert.truthy(lines[3]:find("…", 1, true))
    assert.is_nil(text(app):find("instances", 1, true))
    local failed_hl = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(app.bufnr, -1, 0, -1, { details = true })) do
      if mark[2] == 2 and mark[4].hl_group == "DiagnosticError" then failed_hl = true end
    end
    assert.is_true(failed_hl)
  end)

  it("presents a padded server list with readable summaries and a distinct empty state", function()
    package.loaded.clankbox = hosted()
    local app = require("weave.view.mcp").open()
    apps[#apps + 1] = app
    local content = text(app)
    assert.truthy(content:find("1 server", 1, true))
    assert.truthy(content:find("Editor-hosted", 1, true))
    assert.truthy(content:find("1 tool", 1, true))
    local lines = vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)
    assert.truthy(lines[2]:match("^  MCP servers"))
    assert.truthy(content:find("Tab", 1, true))
    app.unmount()
    package.loaded.clankbox = nil
    app = require("weave.view.mcp").open()
    apps[#apps + 1] = app
    assert.truthy(text(app):find("No MCP servers available", 1, true))
  end)

  it("renders tool details separately, preserves JSON indentation, and reveals all advertised fields", function()
    local tool = {
      name = "weave_read", title = "Read a file", description = "Read a live buffer",
      inputSchema = { type = "object", properties = { path = { type = "string" } }, required = { "path" } },
      outputSchema = { type = "string" }, annotations = { readOnlyHint = true },
      _meta = { vendor = { custom = "preserved" } },
    }
    package.loaded.clankbox = {
      handle = function(request) return { id = request.id, result = { tools = { tool } } } end,
    }
    local app = require("weave.view.mcp").open("internal:clankbox")
    apps[#apps + 1] = app
    assert.is_nil(text(app):find('"properties"', 1, true))
    press(app, "weave_read")
    local content = text(app)
    for _, needle in ipairs({ "Read a file", "Read a live buffer", "Input schema", "Output schema", "Annotations" }) do
      assert.truthy(content:find(needle, 1, true), needle)
    end
    assert.truthy(content:find('"path": {', 1, true))
    assert.is_nil(content:find("preserved", 1, true))
    press(app, "Full definition")
    assert.truthy(text(app):find('"custom": "preserved"', 1, true))
    assert.truthy(text(app):find('"inputSchema": {', 1, true))
    press(app, "Full definition")
    assert.is_nil(text(app):find("preserved", 1, true))
    press(app, "Back")
    assert.truthy(text(app):find("Tools (1)", 1, true))
    assert.is_nil(text(app):find('"properties"', 1, true))
  end)

  it("groups each connection's tools and uses button chrome for process actions", function()
    Proxy.list = function() return {
      { name = "example", command = "/long/path/example-server --long-argument", instances = {
        { id = 7, status = "running", pid = 42, started_at = os.time() - 125, tools = {
          { name = "active_tool", description = "From the running connection", inputSchema = {} },
        } },
        { id = 8, status = "disconnected", tools = {
          { name = "old_tool", description = "From a disconnected connection", inputSchema = {} },
        } },
      } },
    } end
    local app = require("weave.view.mcp").open("example")
    apps[#apps + 1] = app
    local content = text(app)
    for _, needle in ipairs({ "Connection #7", "Connection #8", "Uptime", "2m", "[ Restart ]", "[ Kill ]",
      "active_tool", "old_tool" }) do assert.truthy(content:find(needle, 1, true), needle) end
    -- The disconnected connection is read-only, but its last tool catalogue remains inspectable.
    local _, restarts = content:gsub("%[ Restart %]", "")
    assert.equal(1, restarts)
    press(app, "old_tool")
    assert.truthy(text(app):find("From a disconnected connection", 1, true))
    assert.truthy(text(app):find("Connection #8", 1, true))
  end)

  it("wraps long schema strings instead of silently clipping them", function()
    local long = ("schema-detail-"):rep(12) .. "visible-end"
    package.loaded.clankbox = {
      handle = function(request) return { id = request.id, result = { tools = {
        { name = "wide", description = "A wide schema", inputSchema = { description = long } },
      } } } end,
    }
    local app = require("weave.view.mcp").open("internal:clankbox")
    apps[#apps + 1] = app
    press(app, "wide")
    assert.truthy(text(app):find("visible-end", 1, true))
    for _, line in ipairs(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)) do
      assert.is_true(vim.api.nvim_strwidth(line) <= vim.api.nvim_win_get_width(app.winid))
    end
  end)

  it("fits a very small editor instead of enforcing an oversized minimum", function()
    local columns, lines = vim.o.columns, vim.o.lines
    local ok, err = pcall(function()
      vim.o.columns, vim.o.lines = 22, 10
      local app = require("weave.view.mcp").open()
      apps[#apps + 1] = app
      assert.is_true(vim.api.nvim_win_get_width(app.winid) <= 16)
      assert.is_true(vim.api.nvim_win_get_height(app.winid) <= 4)
    end)
    vim.o.columns, vim.o.lines = columns, lines
    if not ok then error(err) end
  end)

  it("sizes the popup to its page and stays within the editor after a resize", function()
    package.loaded.clankbox = hosted()
    local columns, lines = vim.o.columns, vim.o.lines
    local app
    local ok, err = pcall(function()
      app = require("weave.view.mcp").open()
      apps[#apps + 1] = app
      local height = vim.api.nvim_win_get_height(app.winid)
      assert.equal(vim.api.nvim_buf_line_count(app.bufnr), height)
      press(app, "clankbox")
      assert.is_true(vim.wait(200, function()
        return vim.api.nvim_win_get_height(app.winid) > height
      end, 10))
      press(app, "Back")
      assert.is_true(vim.wait(200, function()
        return vim.api.nvim_win_get_height(app.winid) == height
      end, 10))
      vim.o.columns, vim.o.lines = 36, 14
      vim.api.nvim_exec_autocmds("VimResized", {})
      local fitted = vim.wait(200, function()
        return vim.api.nvim_win_get_width(app.winid) <= 30 and vim.api.nvim_win_get_height(app.winid) <= 8
      end, 10)
      if not fitted then
        error(("popup did not fit resized editor: %dx%d in %dx%d"):format(
          vim.api.nvim_win_get_width(app.winid), vim.api.nvim_win_get_height(app.winid), vim.o.columns, vim.o.lines))
      end
    end)
    if app then app.unmount() end
    vim.o.columns, vim.o.lines = columns, lines
    if not ok then error(err) end
  end)

  it("does not let a disconnected historical failure override a healthy connection", function()
    Proxy.list = function() return {
      { name = "example", command = "example-server", instances = {
        { id = 1, status = "disconnected", exit_code = 1, tools = {} },
        { id = 2, status = "running", tools = {} },
      } },
    } end
    local app = require("weave.view.mcp").open()
    apps[#apps + 1] = app
    assert.truthy(text(app):find("running", 1, true))
    assert.is_nil(text(app):find("degraded", 1, true))
    press(app, "example")
    assert.truthy(text(app):find("disconnected", 1, true))
  end)

end)
