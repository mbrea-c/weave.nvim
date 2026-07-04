-- The ACP layer carried over from agentic (namespace-renamed): this spec pins
-- that the dependency closure is complete — every module loads in a bare
-- headless nvim — and smoke-tests the pure payload builders. Protocol-level
-- specs arrive with the store/bridge work.

describe("clanker.acp module closure", function()
  it("every copied module loads", function()
    for _, mod in ipairs({
      "clanker.config_default",
      "clanker.config",
      "clanker.utils.logger",
      "clanker.utils.file_system",
      "clanker.utils.list",
      "clanker.utils.buf_helpers",
      "clanker.acp.acp_client_types",
      "clanker.acp.acp_payloads",
      "clanker.acp.acp_transport",
      "clanker.acp.acp_client",
      "clanker.acp.agent_instance",
      "clanker.acp.agent_models",
      "clanker.acp.agent_modes",
    }) do
      local ok, err = pcall(require, mod)
      assert.is_true(ok, mod .. ": " .. tostring(err))
    end
  end)

  it("the default config names a provider that exists in acp_providers", function()
    local config = require("clanker.config")
    assert.equal("string", type(config.provider))
    assert.equal("table", type(config.acp_providers[config.provider]))
    assert.equal("string", type(config.acp_providers[config.provider].command))
  end)

  it("payload builders produce ACP message chunks", function()
    local payloads = require("clanker.acp.acp_payloads")
    local msg = payloads.generate_user_message("hello")
    assert.equal("user_message_chunk", msg.sessionUpdate)
    assert.equal("text", msg.content.type)
    assert.equal("hello", msg.content.text)
  end)
end)
