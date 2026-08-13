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
--- @field sandbox? weave.SandboxConfig Per-provider override of the global `sandbox` (scalars win, path lists add)

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

--- @class weave.ToolsConfig weave's own MCP tool suite (read/write/edit, glob/grep, task_*), hosted by clankbox
--- @field enabled boolean Register the suite into clankbox and hand every agent the clankbox server automatically
--- @field clankbox_path? string Clankbox checkout root (the dir containing shim.lua); nil = auto-detect
--- @field ripgrep_path? string Absolute path to `rg` for the glob/grep tools; nil = look on PATH
--- @field curl_path? string Absolute path to `curl` for the web_fetch tool; nil = look on PATH

--- @class weave.TutorConfig Tutor mode (weave.tutor): the agent watches the USER's edits and gives feedback
--- @field debounce_ms integer Quiet time after an edit before the batch is sent
--- @field max_wait_ms integer Hard ceiling from the first unsent edit, so a continuously-typing user still gets sent
--- @field on_flush "interrupt"|"queue" Whether a debounced batch cancels the turn in flight or waits behind it
--- @field max_diff_bytes integer Cap on one batch's diff text (truncation is announced, never silent)
--- @field enabled_prompt string Sent to the agent when tutor mode goes on
--- @field disabled_prompt string Sent when it goes off
--- @field edits_prompt string Preamble ahead of each batch of user edits

--- @class weave.PermissionsConfig The client-side permission engine (weave.permissions)
--- @field preset? string Active preset at startup; unset = "ask", or its unsandboxed_* variant when the sandbox is off
--- @field presets? weave.permissions.Preset[] Additional presets (the setup source; shadow builtins by name)

--- @class weave.SandboxConfig Confinement for the spawned agent process (weave.sandbox; bwrap backend, Linux-only, degrades to "off" elsewhere)
--- @field mode? "on"|"off" Default "on" = the invariant maximal agent sandbox (design-agent-sandbox-v2.md): project absent, every effect flows through the sandboxed tool layer. "off" disables confinement entirely (rules still gate). (The v1 `profile` key errors loudly.)
--- @field state_paths? string[] Extra rw binds (agent state/auth dirs; known providers ship defaults), ~ ok, missing paths fine
--- @field ro_paths? string[] Extra ro binds, same rules
--- @field env_allowlist? string[] Keep only these inherited env vars (default: inherit everything, sandboxed or not)

--- @class weave.UserConfig
--- @field debug boolean Log to the debug file (utils/logger.lua)
--- @field provider string Default provider (a key of `acp_providers`)
--- @field acp_providers table<string, weave.acp.ACPProviderConfig|nil>
--- @field mcp_servers weave.acp.McpServer[] MCP servers handed to EVERY provider over ACP (session/new), unless a provider sets its own `mcpServers`. The agent spawns/connects them.
--- @field tools weave.ToolsConfig
--- @field permissions weave.PermissionsConfig
--- @field sandbox weave.SandboxConfig
--- @field tutor weave.TutorConfig
--- @field view weave.ViewConfig Default panel geometry (width / sidebar_width / prompt_height)
--- @field keys table<string, weave.UserConfig.KeymapValue> Key(s) per named action (see weave.keys ACTIONS); `false` disables one
--- @field tool_renderers weave.view.ToolRenderer[] Per-tool-call rendering overrides (see weave.view.tool_call)
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
      -- Kiro wraps itself in aim-sandbox; nesting user namespaces inside it
      -- is expected to fail, so it opts out of any global sandbox mode.
      sandbox = { mode = "off" },
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

  -- weave's own MCP tool suite (read/write/edit, glob/grep, task lifecycle),
  -- hosted by clankbox and appended to every agent's mcpServers automatically
  -- — see design-agent-sandbox.md in the superproject. `clankbox_path` (the
  -- checkout dir containing shim.lua) overrides auto-detection, and
  -- `ripgrep_path` does the same for the `rg` the search tools shell out to,
  -- and `curl_path` for the `curl` behind web_fetch. All three exist because
  -- under a Nix-wrapped Neovim the ambient PATH is not the user's PATH.
  tools = {
    enabled = true,
  },

  -- Per-tool-call rendering overrides: each entry is { name, match, render,
  -- priority? }, where `match` is a predicate over the tool-call block (ACP
  -- carries no tool name — see weave.view.tool_call) and `render` is a
  -- fibrous component. Highest priority wins, ties break newest-first, and no
  -- match falls through to the builtin rendering. External plugins use
  -- weave.view.tool_call.register directly instead, which works at any time.
  tool_renderers = {},

  -- The client-side permission engine (weave.permissions): `preset` picks the
  -- active preset at startup, `presets` adds saved rule configurations beside
  -- the builtin ask/read_only/edit/auto and their unsandboxed_* counterparts
  -- (same name = shadow the builtin).
  -- Rule shape: { tool = "<glob>", resource = "<glob>"|nil, decision =
  -- "allow"|"deny"|"ask" } — see lua/weave/permissions.lua for the action
  -- vocabulary (acp:<kind>, weave:<tool>, mcp:<tool>, <plugin>:<tool>).
  -- `preset` is deliberately UNSET here rather than defaulted to "ask": an
  -- absent value means "no preference", which is what lets the mode actually
  -- in force pick the matching variant (`ask` sandboxed, `unsandboxed_ask`
  -- with the sandbox off). Setting it pins the choice, and a preset written
  -- for the other mode is then a loud error rather than a silent swap.
  permissions = {
    presets = {},
  },

  -- Agent process confinement (weave.sandbox, design-agent-sandbox-v2.md):
  -- default ON. The agent runs in the one invariant maximal sandbox — the
  -- project absent (empty read-only tmpfs), every effect flowing through the
  -- weave tools, which run in their own per-invocation sandboxes under the
  -- active preset's hull. bwrap only; on platforms without it mode "on"
  -- degrades to "off" with a one-time warning, and the preset in force
  -- degrades with it (the unsandboxed_* counterpart), so the policy always
  -- matches the confinement that actually exists.
  sandbox = {
    mode = "on",
    state_paths = {},
    ro_paths = {},
  },

  -- Tutor mode (weave.tutor): per session, off by default. While it is on,
  -- weave collects the USER's edits (never the agent's — see
  -- weave.revision_log) and sends them to the agent as a squashed diff, so it
  -- can review work as it happens instead of being asked to. The three prompts
  -- are the whole agent-facing contract and are meant to be rewritten: they
  -- are what makes the agent behave like a tutor rather than an assistant.
  tutor = {
    debounce_ms = 15000,
    max_wait_ms = 60000,
    on_flush = "interrupt",
    max_diff_bytes = 100 * 1024,

    enabled_prompt = table.concat({
      "[weave] TUTOR MODE IS NOW ON.",
      "",
      "From now on you will periodically receive diffs of what the USER is writing,",
      "unprompted, as they write it. They are not asking you to make changes — they are",
      "asking you to teach. For each batch:",
      "",
      "  - Read what they did and why it might be wrong, fragile, or simply not the",
      "    clearest way to say it. Say so plainly, and say what you would do instead.",
      "  - Leave the feedback ON THE CODE with the `annotate` tool (a file, a line",
      "    range, and your message), not only in chat. That is what the user reads.",
      "  - Praise is cheap and unhelpful; if a batch is genuinely fine, say nothing or",
      "    say it in one line. Do not invent problems to have something to say.",
      "  - Do NOT edit their files. They are practising. Show them, do not do it.",
      "",
      "One caveat about the diffs: they are the user's edits as weave observed them, so",
      "changes made by shell commands YOU ran (a formatter, a codemod) can appear in",
      "them too. If a hunk looks like your own work, it probably is — say so rather",
      "than crediting it to the user.",
    }, "\n"),

    disabled_prompt = table.concat({
      "[weave] Tutor mode is now OFF. You will stop receiving the user's edits as they",
      "make them. Go back to answering what you are asked.",
    }, "\n"),

    edits_prompt = "[weave] The user has been editing. Everything they changed since your last"
      .. " update, squashed into one diff:",
  },
}

return ConfigDefault
