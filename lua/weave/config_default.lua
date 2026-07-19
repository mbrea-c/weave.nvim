-- Default configuration: the ACP-relevant subset carried over from agentic
-- (the provider table is protocol plumbing, not UI), plus a small `view` table
-- the panel reads for its default geometry. The rest of the view still reads
-- its own options where it lives; the config surface stays minimal on purpose.

--- @class weave.acp.ACPProviderConfig
--- @field name string Display name
--- @field command string Executable that speaks ACP over stdio
--- @field args? string[]
--- @field env? table<string, string>
--- @field mcpServers? weave.acp.McpServer[] Per-provider override of `mcp_servers`

--- @class weave.ViewConfig Default panel geometry; a per-open opts value overrides.
--- @field width integer Total docked panel width (columns)
--- @field sidebar_width integer Sidebar column width (clamped to at most half the panel)
--- @field prompt_height integer Prompt input height (rows)

--- One keybinding entry: the lhs, optionally with its own mode(s). Without
--- `mode` the action's default modes apply (see weave.keys SCOPES).
--- @alias weave.UserConfig.KeymapEntry { [1]: string, mode?: string|string[] }

--- A `keys` field value: one lhs, a list of lhs/entries, or `false` to
--- disable the action entirely.
--- @alias weave.UserConfig.KeymapValue string|false|(string|weave.UserConfig.KeymapEntry)[]

--- @class weave.UserConfig
--- @field debug boolean Log to the debug file (utils/logger.lua)
--- @field provider string Default provider (a key of `acp_providers`)
--- @field acp_providers table<string, weave.acp.ACPProviderConfig|nil>
--- @field mcp_servers weave.acp.McpServer[] MCP servers handed to EVERY provider over ACP (session/new), unless a provider sets its own `mcpServers`. The agent spawns/connects them.
--- @field view weave.ViewConfig Default panel geometry (width / sidebar_width / prompt_height)
--- @field keys table<string, weave.UserConfig.KeymapValue> Key(s) per named action (see weave.keys ACTIONS); `false` disables one
local ConfigDefault = {
  debug = false,

  provider = "claude-agent-acp",

  -- Panel geometry defaults, read by view/panel.lua at open time; each field is
  -- overridable per call via open()/toggle() opts.
  view = {
    width = 100,
    sidebar_width = 30,
    prompt_height = 6,
  },

  -- Every key weave binds, by action name — the SINGLE source the view layer
  -- reads (through weave.keys, which owns each action's modes and scope).
  -- Value shapes and the disable path: see weave.UserConfig.KeymapValue.
  keys = {
    -- panel chords (normal mode, every panel buffer)
    toggle_thoughts = ";;t",
    toggle_diffs = ";;d",
    toggle_conceal = ";;c",
    toggle_follow = ";;f",
    cycle_permission_mode = ";;p",
    pick_model = ";;m",
    pick_mode = ";;M",
    restore_session = ";;r",
    sessions = ";;s",
    expand_all = "zR",
    collapse_all = "zM",
    cancel = "<C-c>",
    -- <prefix>1 … <prefix>9 answer permission option N
    permission_prefix = ";;",
    -- the prompt input (insert + normal mode)
    submit = "<C-s>",
    steer = "<C-x>",
    recall_older = "<C-Up>",
    recall_newer = "<C-Down>",
    -- transcript entries (fibrous on_key routing)
    peek = "K",
    toggle_tool_call = "za",
    -- weave's floating windows (modals, peek, the full task list)
    close_float = { "q", "<Esc>" },
  },

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
