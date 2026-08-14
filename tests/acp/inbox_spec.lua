-- Wire messages cross from the transport's libuv read callback (a fast event
-- context) to the main loop on ONE coalesced drain, not one vim.schedule
-- each.
--
-- Handling a message re-renders the panel, so the per-message crossing made a
-- session/load replay — an entire conversation delivered as fast as the pipe
-- allows — thousands of back-to-back renders with no repaint between them.
-- The editor looked hung until a keystroke forced a frame through.

local ACPClient = require("weave.acp.acp_client")

--- A client stripped to the inbox machinery: no transport, no session, with
--- _dispatch_message swapped for a recorder.
local function fake(on_dispatch)
  return setmetatable({
    _inbox = {},
    _draining = false,
    _dispatch_message = function(_, message)
      on_dispatch(message)
    end,
  }, { __index = ACPClient })
end

--- Let the scheduled drain run.
local function pump(done)
  vim.wait(500, done, 5)
end

describe("acp client inbox", function()
  it("never dispatches inside the read callback — that context cannot touch a buffer", function()
    local seen = {}
    local client = fake(function(m)
      seen[#seen + 1] = m.id
    end)
    client:_handle_message({ id = 1 })
    assert.same({}, seen)
  end)

  it("drains every queued message once, in wire order", function()
    local seen = {}
    local client = fake(function(m)
      seen[#seen + 1] = m.id
    end)
    for i = 1, 5 do
      client:_handle_message({ id = i })
    end
    pump(function()
      return #seen == 5
    end)
    assert.same({ 1, 2, 3, 4, 5 }, seen)
  end)

  -- The point of the change: N messages arriving together cost ONE trip
  -- through the main loop, so the renders they trigger collapse into one
  -- batch instead of one frame apiece.
  it("schedules a single drain for a burst", function()
    local drains, seen = 0, 0
    local client = fake(function()
      seen = seen + 1
    end)
    client._drain_inbox = function(self)
      drains = drains + 1
      return ACPClient._drain_inbox(self)
    end
    for i = 1, 20 do
      client:_handle_message({ id = i })
    end
    pump(function()
      return seen == 20
    end)
    assert.equal(20, seen)
    assert.equal(1, drains)
  end)

  -- On a restore the rest of the queue is the rest of the conversation, so one
  -- provider's malformed frame must not swallow it.
  it("keeps draining past a handler that throws", function()
    local seen = {}
    local client = fake(function(m)
      if m.id == 2 then
        error("boom")
      end
      seen[#seen + 1] = m.id
    end)
    for i = 1, 3 do
      client:_handle_message({ id = i })
    end
    pump(function()
      return #seen == 2
    end)
    assert.same({ 1, 3 }, seen)
  end)

  -- A handler that pumps the loop can let new frames land mid-drain; they
  -- queue behind the one running and need a drain of their own.
  it("picks up messages that arrive while it is draining", function()
    local seen = {}
    local client
    client = fake(function(m)
      seen[#seen + 1] = m.id
      if m.id == 1 then
        client:_handle_message({ id = 2 })
      end
    end)
    client:_handle_message({ id = 1 })
    pump(function()
      return #seen == 2
    end)
    assert.same({ 1, 2 }, seen)
  end)
end)
