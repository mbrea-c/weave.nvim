-- The session details window (requests.md): a floating fibrous modal showing
-- the full session metadata, with a ui.dropdown per selectable config kind
-- (model, mode, thinking effort, ...) that applies choices through
-- Session:set_config. Reached from the sidebar's Session section and from the
-- ;;s sessions list; opened for a non-current session it offers "Open in
-- panel".

local Session = require("weave.session")
local SessionDetails = require("weave.view.session_details")

local function pump()
  vim.wait(50, function()
    return false
  end, 5)
end

local function wait_for(cond)
  vim.wait(500, cond, 5)
  return cond()
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

--- Scripted ACP client (see session_spec): configOptions with a model AND a
--- thought_level category, the shape the details window exists for.
local function fake_client()
  local client = {
    state = "connected",
    agent_info = { name = "fake-agent", version = "2.0" },
    calls = { set_config = {} },
  }
  function client:create_session(_handlers, callback, _mcp)
    callback({
      sessionId = "sess-42",
      configOptions = {
        {
          id = "opt-model",
          category = "model",
          name = "Model",
          currentValue = "m1",
          options = { { value = "m1", name = "One" }, { value = "m2", name = "Two" } },
        },
        {
          id = "opt-effort",
          category = "thought_level",
          name = "Thinking effort",
          currentValue = "high",
          options = { { value = "low", name = "Low" }, { value = "high", name = "High" } },
        },
      },
    }, nil)
  end
  function client:set_config_option(_session_id, config_id, value, cb)
    self.calls.set_config[#self.calls.set_config + 1] = { config_id, value }
    cb({}, nil)
  end
  function client:cancel_session() end
  function client:cancel_turn() end
  function client:send_prompt() end
  return client
end

local function started()
  local client = fake_client()
  local session = Session:new({
    provider = "test-agent",
    get_instance = function(_name, on_ready)
      on_ready(client)
      return client
    end,
  })
  session:start()
  pump()
  return session, client
end

local function buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

--- The dropdown input floats anchored to the details window, keyed by the
--- committed value each field shows.
local function inputs_of(handle)
  local by_value = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].fibrous_anchor == handle.winid and vim.api.nvim_win_get_config(win).focusable ~= false then
      local buf = vim.api.nvim_win_get_buf(win)
      by_value[vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]] = { win = win, buf = buf }
    end
  end
  return by_value
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

local function activate(handle, needle)
  local row, col = locate(handle.bufnr, needle)
  vim.api.nvim_set_current_win(handle.winid)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
  press("<CR>")
end

describe("view.session_details", function()
  it("shows the session metadata and a dropdown per config kind", function()
    local session = started()
    local handle = SessionDetails.open({ session = session })

    local text = buffer_text(handle.bufnr)
    assert.truthy(text:find("Session details", 1, true))
    assert.truthy(text:find("test-agent", 1, true))
    assert.truthy(text:find("fake-agent v2.0", 1, true))
    assert.truthy(text:find("sess-42", 1, true))
    assert.truthy(text:find("Status:", 1, true))
    assert.truthy(text:find("Model", 1, true))
    assert.truthy(text:find("Thinking effort", 1, true))

    -- each kind's field shows the CURRENT option's label
    local inputs = inputs_of(handle)
    assert.is_not_nil(inputs["One"])
    assert.is_not_nil(inputs["High"])

    handle.close()
  end)

  it("status tracks the store live", function()
    local session = started()
    local handle = SessionDetails.open({ session = session })
    assert.truthy(buffer_text(handle.bufnr):find("Status: idle", 1, true))

    session:get_store():set_status("thinking")
    assert.truthy(buffer_text(handle.bufnr):find("Status: thinking", 1, true))
    handle.close()
  end)

  it("picking a dropdown option applies it through the session", function()
    local session, client = started()
    local handle = SessionDetails.open({ session = session })

    local input = inputs_of(handle)["One"]
    vim.api.nvim_set_current_win(input.win)
    assert.is_true(wait_for(function()
      -- focus opened the popup: the selection can be moved
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.w[win].fibrous_anchor == handle.winid and vim.api.nvim_win_get_config(win).focusable == false then
          return true
        end
      end
      return false
    end))
    press("<C-n>") -- One → Two
    press("<CR>")
    assert.is_true(wait_for(function()
      return #client.calls.set_config == 1
    end))
    assert.same({ { "opt-model", "m2" } }, client.calls.set_config)
    assert.is_true(wait_for(function()
      return session:get_store().state.meta.model == "Two"
    end))
    -- the field committed the new label
    assert.same({ "Two" }, vim.api.nvim_buf_get_lines(input.buf, 0, -1, false))

    handle.close()
  end)

  it("offers Open in panel only when a handler is given, and closes on it", function()
    local session = started()
    local handle = SessionDetails.open({ session = session })
    assert.is_nil(buffer_text(handle.bufnr):find("Open in panel", 1, true))
    handle.close()

    local opened = 0
    handle = SessionDetails.open({
      session = session,
      on_open = function()
        opened = opened + 1
      end,
    })
    activate(handle, "Open in panel")
    assert.equal(1, opened)
    assert.is_false(handle.is_open())
  end)

  it("q closes the modal", function()
    local session = started()
    local handle = SessionDetails.open({ session = session })
    vim.api.nvim_set_current_win(handle.winid)
    press("q")
    assert.is_false(handle.is_open())
    assert.is_false(vim.api.nvim_win_is_valid(handle.winid))
  end)
end)
