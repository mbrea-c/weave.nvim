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
end)
