-- Default configuration: the ACP-relevant subset carried over from agentic
-- (the provider table is protocol plumbing, not UI). Everything view-related
-- is deliberately absent — the fibrous UI reads its own options once it
-- exists, and starting minimal keeps the config surface honest.

--- @class weave.acp.ACPProviderConfig
--- @field name string Display name
--- @field command string Executable that speaks ACP over stdio
--- @field args? string[]
--- @field env? table<string, string>
--- @field mcpServers? weave.acp.McpServer[] Per-provider override of `mcp_servers`

--- @class weave.UserConfig
--- @field debug boolean Log to the debug file (utils/logger.lua)
--- @field provider string Default provider (a key of `acp_providers`)
--- @field acp_providers table<string, weave.acp.ACPProviderConfig|nil>
--- @field mcp_servers weave.acp.McpServer[] MCP servers handed to EVERY provider over ACP (session/new), unless a provider sets its own `mcpServers`. The agent spawns/connects them.
local ConfigDefault = {
  debug = false,

  provider = "claude-agent-acp",

  acp_providers = {
    ["claude-agent-acp"] = {
      name = "Claude Agent ACP",
      command = "claude-agent-acp",
      env = {},
    },

    ["claude-acp"] = {
      name = "Claude ACP",
      command = "claude-code-acp",
      env = {},
    },

    ["gemini-acp"] = {
      name = "Gemini ACP",
      command = "gemini",
      args = { "--acp" },
      env = {},
    },

    ["codex-acp"] = {
      name = "Codex ACP",
      -- https://github.com/zed-industries/codex-acp/releases
      -- xattr -dr com.apple.quarantine ~/.local/bin/codex-acp
      command = "codex-acp",
      args = {
        -- "-c",
        -- "features.web_search_request=true", -- disabled as it doesn't send proper tool call messages
      },
      env = {},
    },

    ["opencode-acp"] = {
      name = "OpenCode ACP",
      command = "opencode",
      args = { "acp" },
      env = {},
    },

    ["cursor-acp"] = {
      name = "Cursor Agent ACP",
      command = "cursor-agent",
      args = {
        "acp",
      },
      env = {},
    },

    ["copilot-acp"] = {
      name = "Copilot ACP",
      command = "copilot",
      args = {
        "--acp",
        "--stdio",
      },
      env = {},
    },

    ["auggie-acp"] = {
      name = "Auggie ACP",
      command = "auggie",
      args = {
        "--acp",
      },
      env = {},
    },

    ["mistral-vibe-acp"] = {
      name = "Mistral Vibe ACP",
      command = "vibe-acp",
      args = {},
      env = {},
    },

    ["cline-acp"] = {
      name = "Cline ACP",
      command = "cline",
      args = { "--acp" },
      env = {},
    },

    ["goose-acp"] = {
      name = "Goose ACP",
      command = "goose",
      args = { "acp" },
      env = {},
    },

    ["kiro-acp"] = {
      name = "Kiro ACP",
      command = "kiro-cli",
      args = { "acp" },
      env = {},
    },

    ["pi-acp"] = {
      name = "Pi ACP",
      command = "pi-acp",
      env = {},
    },
  },

  -- MCP servers handed to every ACP provider at session creation (session/new
  -- mcpServers), unless a provider entry sets its own `mcpServers` (which
  -- overrides this). The AGENT spawns/connects these subprocesses — this is not
  -- our own Neovim MCP connection. Shape per entry: { name, command, args, env }
  -- where env is a list of { name, value }. Empty by default.
  mcp_servers = {},
}

return ConfigDefault
