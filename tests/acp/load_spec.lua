-- The ACP layer carried over from agentic (namespace-renamed): this spec pins
-- that the dependency closure is complete — every module loads in a bare
-- headless nvim — and smoke-tests the pure payload builders. Protocol-level
-- specs arrive with the store/bridge work.

describe("weave.acp module closure", function()
  it("every copied module loads", function()
    for _, mod in ipairs({
      "weave.config_default",
      "weave.config",
      "weave.utils.logger",
      "weave.utils.file_system",
      "weave.utils.list",
      "weave.utils.buf_helpers",
      "weave.acp.acp_client_types",
      "weave.acp.acp_payloads",
      "weave.acp.acp_transport",
      "weave.acp.acp_client",
      "weave.acp.agent_instance",
      "weave.acp.agent_models",
      "weave.acp.agent_modes",
    }) do
      local ok, err = pcall(require, mod)
      assert.is_true(ok, mod .. ": " .. tostring(err))
    end
  end)

  it("the default config names a provider that exists in acp_providers", function()
    local config = require("weave.config")
    assert.equal("string", type(config.provider))
    assert.equal("table", type(config.acp_providers[config.provider]))
    assert.equal("string", type(config.acp_providers[config.provider].command))
  end)

  it("payload builders produce ACP message chunks", function()
    local payloads = require("weave.acp.acp_payloads")
    local msg = payloads.generate_user_message("hello")
    assert.equal("user_message_chunk", msg.sessionUpdate)
    assert.equal("text", msg.content.type)
    assert.equal("hello", msg.content.text)
  end)
end)
