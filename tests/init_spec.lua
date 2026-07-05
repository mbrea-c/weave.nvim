-- The public entrypoint: setup() merges user config (in place — modules hold
-- references to the live Config table) and defines :Clanker; toggle()/open()/
-- close() manage ONE session + panel. The session outlives the panel: closing
-- the dock doesn't kill the conversation, reopening shows the same store.

local clanker = require("clanker")
local Config = require("clanker.config")

local function fake_client()
  local client = { state = "connected", agent_info = { name = "fake" }, calls = { prompts = {} } }
  function client:create_session(handlers, callback, _mcp)
    self.handlers = handlers
    callback({ sessionId = "s1" }, nil)
  end
  function client:send_prompt(_sid, prompt, _cb)
    self.calls.prompts[#self.calls.prompts + 1] = prompt[1].text
  end
  function client:cancel_turn() end
  function client:cancel_session() end
  --- session/list + session/load, scripted via client.saved_sessions (see
  --- session_spec's full double).
  function client:list_sessions(_cwd, callback)
    callback({ sessions = self.saved_sessions or {} }, nil)
  end
  function client:load_session(session_id, _cwd, _mcp, _handlers, on_complete)
    self.calls.loads = self.calls.loads or {}
    self.calls.loads[#self.calls.loads + 1] = session_id
    on_complete(nil, {})
  end
  return client
end

local function pump()
  vim.wait(50, function()
    return false
  end, 5)
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

-- Find "needle" in the buffer; returns 1-based row and 0-based col.
local function locate(bufnr, needle)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local col = l:find(needle, 1, true)
    if col then
      return i, col - 1
    end
  end
  error("not found in buffer: " .. needle)
end

--- Put the cursor on a modal row and press <CR> (fibrous button activation).
local function activate(handle, row, col)
  vim.api.nvim_set_current_win(handle.winid)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
  press("<CR>")
end

describe("clanker entrypoint", function()
  it("setup merges config in place and defines :Clanker", function()
    local before = Config
    clanker.setup({ debug = true })
    assert.rawequal(before, Config)
    assert.is_true(Config.debug)
    Config.debug = false
    assert.equal(2, vim.fn.exists(":Clanker"))
  end)

  it("toggle opens and closes the panel; the session survives", function()
    local client = fake_client()
    local before = #vim.api.nvim_list_wins()

    clanker.toggle({ get_instance = function(_n, on_ready)
      on_ready(client)
      return client
    end, width = 45 })
    pump()
    assert.is_true(clanker.is_open())

    local store = clanker.get_session():get_store()
    store:append_entry({ kind = "agent", text = "persists" })

    clanker.toggle()
    pump()
    assert.is_false(clanker.is_open())
    assert.equal(before, #vim.api.nvim_list_wins())

    -- reopen: same session, same store, transcript still there
    clanker.toggle({ width = 45 })
    pump()
    assert.is_true(clanker.is_open())
    assert.rawequal(store, clanker.get_session():get_store())

    -- stop() is the full shutdown: panel closed AND session dropped
    clanker.stop()
    pump()
    assert.is_false(clanker.is_open())
    assert.is_nil(clanker.get_session())
  end)

  it("panels and selected sessions are per tabpage; stop closes everything", function()
    local Registry = require("clanker.registry")
    local get_instance = function(_n, on_ready)
      local c = fake_client()
      on_ready(c)
      return c
    end

    clanker.open({ get_instance = get_instance, width = 45 })
    pump()
    local first = clanker.get_session()
    assert.is_true(clanker.is_open())

    -- a fresh tab has no panel and no selected session
    vim.cmd.tabnew()
    assert.is_false(clanker.is_open())
    assert.is_nil(clanker.get_session())

    -- opening here starts a SECOND session, selected for this tab only
    clanker.open({ get_instance = get_instance, width = 45 })
    pump()
    local second = clanker.get_session()
    assert.is_true(second ~= nil)
    assert.is_true(second ~= first)
    assert.equal(2, #Registry.list())

    -- back in tab 1: its panel is still open, bound to the original session
    vim.cmd.tabnext(1)
    assert.is_true(clanker.is_open())
    assert.rawequal(first, clanker.get_session())

    -- stop() closes every session and every panel, in every tab
    clanker.stop()
    pump()
    assert.is_false(clanker.is_open())
    assert.same({}, Registry.list())
    assert.is_nil(clanker.get_session())
    vim.cmd.tabonly()
    pump()
  end)

  it("a prompt submitted in the panel reaches the agent", function()
    local client = fake_client()
    clanker.open({ get_instance = function(_n, on_ready)
      on_ready(client)
      return client
    end, width = 45 })
    pump()

    press("iship it")
    press("<Esc><CR>")
    assert.same({ "ship it" }, client.calls.prompts)
    clanker.stop()
    pump()
  end)

  it("the session modal swaps the tab's panel to the picked session", function()
    local Registry = require("clanker.registry")
    local get = function(_n, on_ready)
      local c = fake_client()
      on_ready(c)
      return c
    end

    clanker.open({ get_instance = get, width = 45 })
    pump()
    local first = clanker.get_session()
    first:submit("alpha question")

    local b = Registry.add({ get_instance = get })
    pump()

    local modal = clanker.sessions()
    activate(modal, locate(modal.bufnr, "(no messages yet)"))
    pump()

    assert.rawequal(b.session, clanker.get_session())
    assert.is_true(clanker.is_open())
    clanker.stop()
    pump()
  end)

  it("closing the panel-bound session from the modal keeps the modal focused", function()
    local Registry = require("clanker.registry")
    local get = function(_n, on_ready)
      local c = fake_client()
      on_ready(c)
      return c
    end

    clanker.open({ get_instance = get, width = 45 })
    pump()
    clanker.get_session():submit("alpha question")
    Registry.add({ get_instance = get })
    pump()

    local modal = clanker.sessions()
    local row = locate(modal.bufnr, "alpha question")
    local line = vim.api.nvim_buf_get_lines(modal.bufnr, row - 1, row, false)[1]
    activate(modal, row, line:find("✕", 1, true) - 1)
    pump()

    -- the session (and its panel) are gone, but the modal kept the focus
    assert.equal(1, #Registry.list())
    assert.is_false(clanker.is_open())
    assert.is_true(modal.is_open())
    assert.equal(modal.winid, vim.api.nvim_get_current_win())

    modal.close()
    clanker.stop()
    pump()
  end)

  it("the new-session flow starts a session on the picked provider", function()
    local Registry = require("clanker.registry")
    local get = function(_n, on_ready)
      local c = fake_client()
      on_ready(c)
      return c
    end
    clanker.open({ get_instance = get, width = 45 })
    pump()

    local real_select = vim.ui.select
    vim.ui.select = function(items, _opts, cb)
      for _, item in ipairs(items) do
        if item == "gemini-acp" then
          return cb(item)
        end
      end
      cb(nil)
    end

    -- No injection here: sessions() must reuse the get_instance that open()
    -- was given (the demo relies on this — its agent is fully scripted).
    local modal = clanker.sessions()
    activate(modal, locate(modal.bufnr, "new session"))
    pump()
    vim.ui.select = real_select

    assert.equal(2, #Registry.list())
    local entry = Registry.selected()
    assert.equal("gemini-acp", entry.provider)
    assert.is_true(entry.session:is_ready())
    assert.rawequal(entry.session, clanker.get_session())
    assert.is_true(clanker.is_open())
    clanker.stop()
    pump()
  end)

  it("the load-saved flow activates a saved session on the picked provider", function()
    local Registry = require("clanker.registry")
    local client = fake_client()
    client.saved_sessions = {
      { sessionId = "old-9", title = "Old work", updatedAt = "2026-07-01T10:00:00Z" },
    }
    local get = function(_n, on_ready)
      on_ready(client)
      return client
    end

    local real_select = vim.ui.select
    local answers = { "codex-acp", 1 }
    vim.ui.select = function(items, _opts, cb)
      local a = table.remove(answers, 1)
      if type(a) == "number" then
        return cb(items[a])
      end
      for _, item in ipairs(items) do
        if item == a then
          return cb(item)
        end
      end
      cb(nil)
    end

    local modal = clanker.sessions({ get_instance = get })
    activate(modal, locate(modal.bufnr, "load saved"))
    pump()
    vim.ui.select = real_select

    local entry = Registry.selected()
    assert.is_not_nil(entry)
    assert.equal("codex-acp", entry.provider)
    assert.same({ "old-9" }, client.calls.loads)
    assert.is_true(clanker.is_open())
    clanker.stop()
    pump()
  end)
end)
