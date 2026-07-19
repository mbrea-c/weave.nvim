-- The stdio transport's env assembly: inherit-all by default (Nix, Bedrock,
-- proxies, CA bundles depend on it), filtered by the sandbox config's
-- env_allowlist, with the ACP defaults and config.env overrides on top.

local Transport = require("weave.acp.acp_transport")

local function to_map(env_list)
  local map = {}
  for _, pair in ipairs(env_list) do
    local k, v = pair:match("^([^=]+)=(.*)$")
    map[k] = v
  end
  return map
end

describe("acp_transport build_env", function()
  it("inherits the full parent environment plus the ACP defaults", function()
    local env = to_map(Transport.build_env({}))
    assert.equal(vim.env.HOME, env.HOME)
    assert.equal(vim.env.PATH, env.PATH)
    assert.equal("1", env.NODE_NO_WARNINGS)
    assert.equal("1", env.IS_AI_TERMINAL)
  end)

  it("env_allowlist drops everything not listed, keeping defaults and overrides", function()
    local env = to_map(Transport.build_env({
      env_allowlist = { "PATH" },
      env = { WEAVE_TEST_VAR = "yes" },
    }))
    assert.equal(vim.env.PATH, env.PATH)
    assert.is_nil(env.HOME)
    -- the defaults and explicit overrides survive the filter
    assert.equal("1", env.NODE_NO_WARNINGS)
    assert.equal("yes", env.WEAVE_TEST_VAR)
  end)
end)
