local mount = require("fibrous.inline.mount")
local Sidebar = require("weave.view.sidebar")
local Panel = require("weave.view.panel")
local SessionStore = require("weave.session_store")
local Prefs = require("weave.view.prefs")
local Settings = require("weave.settings")
local Config = require("weave.config")

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
  error("missing control: " .. needle)
end

describe("sidebar overview", function()
  local apps, panels, saved_open, saved_key

  before_each(function()
    apps, panels = {}, {}
    saved_open, saved_key = Sidebar.open_overview, Config.keys.open_overview
  end)

  after_each(function()
    for _, app in ipairs(apps) do app.unmount() end
    for _, panel in ipairs(panels) do panel.close() end
    Sidebar.open_overview, Config.keys.open_overview = saved_open, saved_key
  end)

  local function props()
    return { store = SessionStore:new(), prefs = Prefs:new(),
      session_settings = Settings.for_session({}), sidebar_width = 30 }
  end

  it("pins Overview to the last row when content grows, even at one row high", function()
    for _, height in ipairs({ 1, 8, 16 }) do
      local p = props()
      local app = mount.floating(Sidebar.Sidebar, p, { width = 30, height = height })
      apps[#apps + 1] = app
      local function check()
        local lines = vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)
        assert.equal(height, #lines)
        assert.truthy(lines[height]:find("Overview", 1, true))
      end
      check()
      p.store:set_meta({ title = "A long session", provider = "Kiro", agent = "kiro",
        model = "model", mode = "development" })
      local plan = {}
      for i = 1, 30 do plan[i] = { content = "task " .. i, status = "pending" } end
      p.store:set_plan(plan, "acp")
      check()
      if height == 1 then
        local targets = require("fibrous.targets").targets({ winid = app.winid })
        assert.equal(1, #targets)
      end
      app.unmount()
    end
  end)

  it("opens the overview from the pinned button with this panel's stores", function()
    local p, opened = props(), nil
    Sidebar.open_overview = function(opts) opened = opts end
    local app = mount.floating(Sidebar.Sidebar, p, { width = 30, height = 5 })
    apps[#apps + 1] = app
    press(app, "Overview")
    assert.is_not_nil(opened)
    assert.equal(p.store, opened.store)
    assert.equal(p.prefs, opened.prefs)
    assert.equal(p.session_settings, opened.session_settings)
  end)

  it("shows every section in a live scrollable popup with the same controls", function()
    local p = props()
    p.store:set_meta({ title = "Overview session" })
    p.store:set_plan({ { content = "review this plan", status = "pending" } }, "acp")
    local app = Sidebar.open_overview(p)
    apps[#apps + 1] = app
    local content = text(app)
    for _, section in ipairs({ "Overview", "Session", "Usage", "Settings", "Hint", "Tasks",
      "Terminal tasks", "MCP", "Pending flush", "Permissions", "review this plan" }) do
      assert.truthy(content:find(section, 1, true), section .. " is present")
    end
    assert.is_true(vim.api.nvim_buf_line_count(app.bufnr) > vim.api.nvim_win_get_height(app.winid))
    press(app, "Show thinking")
    assert.is_false(p.prefs.state.show_thoughts)
    assert.truthy(text(app):find("[ ] Show thinking", 1, true))
    p.store:set_meta({ title = "Updated session" })
    assert.truthy(text(app):find("Updated session", 1, true))
    assert.is_nil(text(app):find("Overview session", 1, true))
    vim.api.nvim_set_current_win(app.winid)
    vim.api.nvim_feedkeys("q", "xt", false)
    assert.is_false(vim.api.nvim_win_is_valid(app.winid))
  end)

  it("opens from the normal-mode panel shortcut in every panel buffer", function()
    local p = props()
    local opened = {}
    Sidebar.open_overview = function(opts) opened[#opened + 1] = opts end
    assert.equal(";;o", Config.keys.open_overview)
    local panel = Panel.open({ store = p.store, prefs = p.prefs,
      session_settings = p.session_settings, width = 60 })
    panels[#panels + 1] = panel
    local input
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].completefunc == "v:lua.require'weave.view.prompt'.slash_complete" then input = buf end
    end
    assert.is_not_nil(input)
    for _, buf in ipairs({ panel.bufnr, panel.transcript.bufnr, input }) do
      local found = false
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if map.lhs == ";;o" then map.callback(); found = true; break end
      end
      assert.is_true(found)
    end
    assert.equal(3, #opened)
    for _, opts in ipairs(opened) do
      assert.equal(p.store, opts.store)
      assert.equal(p.prefs, opts.prefs)
      assert.equal(p.session_settings, opts.session_settings)
    end
  end)

  it("honors a rebound or disabled overview shortcut without removing the button", function()
    for _, key in ipairs({ "go", false }) do
      Config.keys.open_overview = key
      local p = props()
      local panel = Panel.open({ store = p.store, prefs = p.prefs, width = 60 })
      panels[#panels + 1] = panel
      local found = false
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.bufnr, "n")) do
        assert.is_true(map.lhs ~= ";;o")
        if map.lhs == "go" then found = true end
      end
      assert.equal(key ~= false, found)
      assert.truthy(text(panel):find("Overview", 1, true))
      panel.close()
    end
  end)
end)
