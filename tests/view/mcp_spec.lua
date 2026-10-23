local mount = require("fibrous.inline.mount")
local Proxy = require("weave.mcp_proxy")

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
      assert.truthy(text(app):find("Managed MCP servers", 1, true))
    end)
    if app then app.unmount() end
    Proxy.list, Proxy.kill, Proxy.restart = saved.list, saved.kill, saved.restart
    if not ok then error(err) end
  end)

  it("shows managed servers in the sidebar section", function()
    local View = require("weave.view.mcp")
    local app = mount.floating(View.Section, {}, { width = 30, height = 8 })
    assert.truthy(text(app):find("MCP", 1, true))
    assert.truthy(text(app):find("no managed servers", 1, true))
    app.unmount()
  end)
end)
