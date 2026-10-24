-- The session modal: a floating fibrous mount over the registry — every
-- active session in the editor, the current tab's selection marked, per-row ✕
-- to close a session, and new/load-saved actions. Rows are fibrous buttons,
-- so <CR> activation, hover, and <Tab> cycling all come from the framework.

local Registry = require("weave.registry")
local SessionModal = require("weave.view.session_modal")

local function pump()
  vim.wait(50, function()
    return false
  end, 5)
end

--- Minimal scripted client (see session_spec for the full double).
local function fake_client()
  local client = { state = "connected", agent_info = { name = "fake-agent" }, _n = 0 }
  function client:create_session(_handlers, callback, _mcp)
    self._n = self._n + 1
    callback({ sessionId = "s" .. self._n }, nil)
  end
  function client:cancel_session() end
  function client:cancel_turn() end
  function client:send_prompt(_sid, _prompt, _cb) end
  return client
end

local function get_instance(_name, on_ready)
  local client = fake_client()
  on_ready(client)
  return client
end

local function buffers(handle)
  return { { bufnr = handle.bufnr, winid = handle.winid },
    { bufnr = handle.tree.bufnr, winid = handle.tree.winid } }
end
local function buffer_text(handle)
  local chunks = {}
  for _, target in ipairs(buffers(handle)) do
    chunks[#chunks + 1] = table.concat(vim.api.nvim_buf_get_lines(target.bufnr, 0, -1, false), "\n")
  end
  return table.concat(chunks, "\n")
end
local function locate(handle, needle, from)
  for _, target in ipairs(buffers(handle)) do
    for row, line in ipairs(vim.api.nvim_buf_get_lines(target.bufnr, 0, -1, false)) do
      if not from or target.bufnr == from.bufnr and row >= from.row then
        local col = line:find(needle, 1, true)
        if col then return { row = row, col = col - 1, bufnr = target.bufnr, winid = target.winid } end
      end
    end
  end
  error("not found in popup: " .. needle)
end
local function activate(_, target)
  vim.api.nvim_set_current_win(target.winid)
  vim.api.nvim_win_set_cursor(target.winid, { target.row, target.col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = target.bufnr })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
end

describe("view.session_modal", function()
  after_each(function()
    Registry.reset()
    pump()
  end)

  it("shows every active session; the tab's selection is marked", function()
    local a = Registry.add({ provider = "prov-a", get_instance = get_instance })
    local b = Registry.add({ provider = "prov-b", get_instance = get_instance })
    pump()
    a.session:submit("fix the panel bug please")
    b.session:get_store():set_meta({ title = "Agent-provided title" })
    Registry.select(a.key)

    local handle = SessionModal.open({ on_select = function() end })
    local text = buffer_text(handle)
    assert.truthy(text:find("prov%-a"))
    assert.truthy(text:find("prov%-b"))
    assert.truthy(text:find("fix the panel bug please", 1, true))
    assert.truthy(text:find("Agent-provided title", 1, true))
    assert.falsy(text:find("(no messages yet)", 1, true))

    -- the ● marker sits on the selected session's row, and only there
    local marked_row = locate(handle, "●")
    local a_row = locate(handle, "prov-a")
    assert.equal(a_row.row, marked_row.row)
    handle.close()
  end)

  it("activating a row selects that session and closes the modal", function()
    local get = get_instance
    Registry.add({ provider = "prov-a", get_instance = get })
    local b = Registry.add({ provider = "prov-b", get_instance = get })
    pump()

    local picked
    local handle = SessionModal.open({
      on_select = function(entry)
        picked = entry
      end,
    })
    activate(handle, locate(handle, "prov-b"))
    assert.rawequal(b, picked)
    assert.is_false(handle.is_open())
  end)

  it("the row's ✕ closes the session and the modal re-renders", function()
    Registry.add({ provider = "prov-a", get_instance = get_instance })
    Registry.add({ provider = "prov-b", get_instance = get_instance })
    pump()

    local handle = SessionModal.open({ on_select = function() end })
    local row = locate(handle, "prov-b")
    activate(handle, locate(handle, "✕", row))

    assert.equal(1, #Registry.list())
    assert.equal("prov-a", Registry.list()[1].provider)
    assert.is_nil(buffer_text(handle):find("prov%-b"))
    assert.is_true(handle.is_open())
    handle.close()
  end)

  it("a row's ⓘ hands the entry to on_details and closes the modal (requests.md)", function()
    Registry.add({ provider = "prov-a", get_instance = get_instance })
    local b = Registry.add({ provider = "prov-b", get_instance = get_instance })
    pump()

    local detailed
    local handle = SessionModal.open({
      on_select = function() end,
      on_details = function(entry)
        detailed = entry
      end,
    })
    local row = locate(handle, "prov-b")
    activate(handle, locate(handle, "ⓘ", row))
    assert.rawequal(b, detailed)
    assert.is_false(handle.is_open())
  end)

  it("without on_details the rows carry no ⓘ", function()
    Registry.add({ provider = "prov-a", get_instance = get_instance })
    pump()
    local handle = SessionModal.open({ on_select = function() end })
    assert.is_nil(buffer_text(handle):find("ⓘ", 1, true))
    handle.close()
  end)

  it("new-session and load-saved actions reach their callbacks", function()
    Registry.add({ provider = "prov-a", get_instance = get_instance })
    pump()

    local called = {}
    local handle = SessionModal.open({
      on_select = function() end,
      on_new = function()
        called[#called + 1] = "new"
      end,
      on_load_saved = function()
        called[#called + 1] = "load"
      end,
    })
    activate(handle, locate(handle, "new session"))
    assert.same({ "new" }, called)
    assert.is_false(handle.is_open())

    handle = SessionModal.open({
      on_select = function() end,
      on_load_saved = function()
        called[#called + 1] = "load"
      end,
    })
    activate(handle, locate(handle, "load saved"))
    assert.same({ "new", "load" }, called)
    assert.is_false(handle.is_open())
  end)

  it("renders as a modal: bordered, backdropped, above the panel stack", function()
    local handle = SessionModal.open({ on_select = function() end })
    local cfg = vim.api.nvim_win_get_config(handle.winid)
    assert.is_true(type(cfg.border) == "table")
    -- floats at nvim's float default (50): above the panel's pane-anchored
    -- stack (10, 11, …), level with any other plugin's popups
    assert.equal(50, cfg.zindex)

    -- the backdrop sits one z-level below the modal, obscuring the panel
    -- (the compositor hides floats under a winblend float rather than
    -- dimming them — accepted; user decision), and leaves with the modal
    local backdrop
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).zindex == 49 then
        backdrop = w
      end
    end
    assert.is_not_nil(backdrop)
    handle.close()
    assert.is_false(vim.api.nvim_win_is_valid(backdrop))
  end)

  it("q closes; an empty registry shows the placeholder", function()
    local handle = SessionModal.open({ on_select = function() end })
    assert.truthy(buffer_text(handle):find("(no active sessions)", 1, true))

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_feedkeys("q", "xt", false)
    assert.is_false(handle.is_open())
    assert.is_false(vim.api.nvim_win_is_valid(handle.winid))
  end)
end)
