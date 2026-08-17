-- A failed request must surface everything the agent left behind. Adapters
-- answer session/new with a stock JSON-RPC "Internal error" and hide the real
-- cause in the error's `data` slot and/or on stderr; a report built from
-- `err.message` alone ("Session creation failed: Internal error") is
-- undiagnosable. _describe_error folds all three sources into one string,
-- and create_session attaches it as err.detail for the sidebar entry.

local ACPClient = require("weave.acp.acp_client")
local Transport = require("weave.acp.acp_transport")

--- A client stripped to the error-reporting machinery: a stub transport with
--- a canned stderr tail, no process anywhere.
--- @param stderr string[]|nil
local function fake(stderr)
  return setmetatable({
    transport = {
      stderr_tail = function()
        return stderr or {}
      end,
    },
  }, { __index = ACPClient })
end

describe("acp error reports", function()
  it("keeps a plain message as-is when there is nothing more to tell", function()
    assert.equal("boom", fake():_describe_error({ code = -32603, message = "boom" }))
  end)

  it("appends the error's data payload — string verbatim, table inspected", function()
    local detail = fake():_describe_error({ code = -32603, message = "Internal error", data = "spawn claude ENOENT" })
    assert.equal("Internal error\nspawn claude ENOENT", detail)

    detail = fake():_describe_error({ code = -32603, message = "Internal error", data = { details = "no cwd" } })
    assert.truthy(detail:find("no cwd", 1, true))
  end)

  it("appends the agent's recent stderr when the process is still alive", function()
    local client = fake({ "Error: something real", "    at newSession (…)" })
    local detail = client:_describe_error({ code = -32603, message = "Internal error" })
    assert.truthy(detail:find("agent stderr:", 1, true))
    assert.truthy(detail:find("something real", 1, true))
  end)

  it("create_session hands the callback an err carrying the full detail", function()
    local client = fake({ "adapter stack trace" })
    function client:_send_request(_method, _params, callback)
      callback(nil, { code = -32603, message = "Internal error", data = "cause" })
    end

    local got
    client:create_session({}, function(_result, err)
      got = err
    end)

    assert.truthy(got)
    assert.truthy(got.detail:find("Internal error", 1, true))
    assert.truthy(got.detail:find("cause", 1, true))
    assert.truthy(got.detail:find("adapter stack trace", 1, true))
  end)
end)

describe("transport stderr_tail", function()
  it("returns the last lines, default 8, without a live process", function()
    local transport = Transport.create_stdio_transport({ command = "true" }, {
      on_state_change = function() end,
      on_message = function() end,
      on_reconnect = function() end,
    })

    -- nothing captured yet: an empty tail, not an error
    assert.same({}, transport:stderr_tail())

    local lines = {}
    for i = 1, 12 do
      lines[i] = "line " .. i
    end
    transport._stderr_buffer = lines
    assert.same({ "line 11", "line 12" }, transport:stderr_tail(2))
    assert.equal(8, #transport:stderr_tail())
    assert.equal("line 5", transport:stderr_tail()[1])
  end)
end)
