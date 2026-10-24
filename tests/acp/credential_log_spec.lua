local Config = require("weave.config")
local Logger = require("weave.utils.logger")

describe("session credential logging", function()
  local debug, open, written
  before_each(function()
    debug, open, written = Config.debug, io.open, {}
    Config.debug = true
    io.open = function()
      return { write = function(_, ...) for _, part in ipairs({ ... }) do written[#written + 1] = part end; return true end,
        close = function() return true end }
    end
  end)
  after_each(function() Config.debug, io.open = debug, open end)

  it("redacts MCP transport capabilities without mutating the request sent to the provider", function()
    local frame = { params = { mcpServers = { { name = "clankbox", env = {
      { name = "CLANKBOX_AUTH_TOKEN", value = "private-capability" },
      { name = "CLANKBOX_SOCKET", value = "/socket" },
    } } } } }
    Logger.debug_to_file("request", frame)
    local log = table.concat(written)
    assert.is_nil(log:find("private-capability", 1, true))
    assert.truthy(log:find("/socket", 1, true))
    assert.equal("private-capability", frame.params.mcpServers[1].env[1].value)
  end)
end)
