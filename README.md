# weave.nvim

*(name TBD — placeholder)*

A Neovim client for coding agents that speak the
[Agent Client Protocol](https://agentclientprotocol.com) (ACP) — Claude,
Gemini, Codex, Copilot, and others. It gives you a docked panel with a live
transcript, streaming markdown, tool-call and diff previews, permission
prompts, and multiple concurrent sessions.

The UI is built on [fibrous.nvim](https://github.com/mbrea-c/fibrous.nvim), a reactive UI framework:
ACP events mutate a plain-Lua store and the whole panel — transcript, sidebar,
prompt — is a pure `state → render` projection of it.

---

## Requirements

- **Neovim** — developed and tested on 0.12.x. Older versions may work but
  aren't tested.
- **[fibrous.nvim](https://github.com/mbrea-c/fibrous.nvim)** — the UI framework. It is a *peer*
  plugin (not vendored), so it must be on your `runtimepath` alongside this
  plugin.
- **An ACP agent binary on your `PATH`** — e.g. `claude-agent-acp`, `gemini`,
  `codex-acp`. You install these separately (see [Providers](#providers)); the
  plugin only launches and talks to them.
- **Treesitter parsers `markdown` and `markdown_inline`** (recommended) — for
  the rendered markdown in agent replies.

---

## Installation

Because fibrous is a peer plugin, you always install **both** it and this
plugin.

### Nix flake (supported path)

The flake exposes the plugin as `packages.weave`. Add both this repo and
`github:mbrea-c/fibrous.nvim` as inputs and put both on the runtimepath in
your Neovim configuration (e.g. via home-manager's `programs.neovim.plugins`,
or your own `buildVimPlugin` wiring).

```nix
# flake inputs
weave.url = "github:…/weave.nvim";  # repo URL TBD
fibrous.url = "github:mbrea-c/fibrous.nvim";
```

### lazy.nvim (or any plugin manager)

Add both plugins and call `setup`. (Repo slug is a placeholder until the
plugin is published.)

```lua
{
  "your-org/weave.nvim",          -- placeholder URL
  dependencies = { "mbrea-c/fibrous.nvim" },
  config = function()
    require("weave").setup({})
  end,
}
```

### Manual

Clone both repos onto your `runtimepath` (`:set rtp+=…`) and call
`require("weave").setup({})` from your config.

---

## Setup

```lua
require("weave").setup()          -- defaults
-- or with overrides:
require("weave").setup({
  provider = "claude-agent-acp",    -- which agent to start by default
})
```

`setup()` registers the `:Weave` command. Call it once, from your config.

---

## Usage

Open the panel with `:Weave` (or `require("weave").toggle()`), type in the
prompt at the bottom, and press `<CR>` to send. The agent's reply streams into
the transcript above.

The panel is **one docked pane** with three regions:

- **Transcript** — the conversation: your messages, streamed markdown replies,
  thinking blocks, tool calls (with inline diff previews), and permission
  requests. It scrolls independently. It's a fibrous *container*: `<CR>` steps
  into it, `h/j/k/l` at its edges step back out, `<C-d>/<C-u>` page inside.
- **Sidebar** — session metadata, view toggles, the current permission mode,
  the task list, and any pending permission request.
- **Prompt** — the input box. Its border colour reflects the active permission
  mode; an animated indicator shows when the agent is working.

Closing the pane (`:q` / `<C-w>q`) closes the panel but **leaves the session
running** — reopen with `:Weave`.

### Keymaps (inside the panel)

| Key | Action |
| --- | --- |
| `<CR>` | Submit the prompt (send to the agent) |
| `<C-x>` | Steer — interrupt the running turn and send this instead |
| `<C-c>` | Cancel the running turn |
| `<CR>` / `za` | On a tool-call header: expand/collapse it |
| `zR` / `zM` | Expand / collapse all tool calls |
| `;;t` | Toggle thinking blocks |
| `;;d` | Toggle edit diffs |
| `;;c` | Toggle markdown prettifying (conceal) |
| `;;f` | Toggle follow-streaming (auto-scroll) |
| `;;p` | Cycle permission mode |
| `;;m` / `;;M` | Pick model / pick mode |
| `;;1` … `;;9` | Answer a permission request with option N |
| `;;r` | Restore a saved session in place |
| `;;s` | Open the session modal (also `:Weave sessions`) |

Type `/` at the start of the prompt for slash-command completion. `/new`
(always available) starts a fresh conversation; agents may advertise more.

### Permissions

When an agent wants to run a tool that needs approval, a permission request
appears in the transcript and sidebar with numbered options — answer with
`;;1`…`;;9`. The **permission mode** (`;;p` to cycle) controls how much is
auto-approved; the prompt border colour is an ambient reminder of the current
mode.

### Sessions

Sessions are **editor-global** (they keep running in the background) but
**selected per tabpage** — each tab's panel shows that tab's selected session.
Different sessions can run on different providers at the same time.

Open the **session modal** with `;;s` or `:Weave sessions`:

- Each row is a button — `<CR>` selects that session for the current tab.
- `✕` on a row closes that session everywhere (it stops running).
- **+ new session** starts a fresh session on any configured provider.
- **↺ load saved…** activates a previously saved session (from the provider's
  history) into a new entry.

`;;r` instead restores a saved session *in place*, over the current
conversation in the panel.

---

## Configuration

`setup(opts)` deep-merges `opts` over the defaults. All fields are optional.

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `provider` | `string` | `"claude-agent-acp"` | Key of the `acp_providers` entry to start by default |
| `acp_providers` | `table` | 13 built-ins | Agent launch definitions (see below) |
| `mcp_servers` | `list` | `{}` | MCP servers handed to **every** provider at session start |
| `debug` | `boolean` | `false` | Write a debug log (via the bundled logger) |

### Providers

`acp_providers` maps a key to a launch definition:

```lua
require("weave").setup({
  provider = "gemini-acp",
  acp_providers = {
    ["my-agent"] = {
      name = "My Agent",              -- display name in the picker
      command = "my-acp-binary",      -- executable on $PATH, speaks ACP over stdio
      args = { "--acp" },             -- optional
      env = { API_KEY = "…" },        -- optional
      -- mcpServers = { … },          -- optional per-provider MCP override
    },
  },
})
```

Built-in provider keys (you still need the corresponding binary on `PATH`):
`claude-agent-acp`, `claude-acp`, `gemini-acp`, `codex-acp`, `opencode-acp`,
`cursor-acp`, `copilot-acp`, `auggie-acp`, `mistral-vibe-acp`, `cline-acp`,
`goose-acp`, `kiro-acp`, `pi-acp`. See `lua/weave/config_default.lua` for
their exact commands.

### MCP servers

`mcp_servers` is a list of servers the **agent** spawns and connects at session
creation (this is not Neovim's own MCP connection). A provider entry's own
`mcpServers` overrides the global list for that provider. Each entry is
`{ name, command, args, env }` where `env` is a list of `{ name, value }`.

---

## Lua API

```lua
local weave = require("weave")

weave.setup(opts)      -- merge config, register :Weave (call once)

weave.toggle(opts)     -- open/close the current tab's panel
weave.open(opts)       -- open (or focus the prompt if already open)
weave.close()          -- close the panel; the session keeps running
weave.is_open()        -- boolean: does the current tab have a panel?

weave.sessions(opts)   -- open the session modal; returns its handle
weave.get_session()    -- the current tab's selected Session (or nil)
weave.stop()           -- close every session (and all their panels)
```

`open`/`toggle` accept `{ provider?, width?, sidebar_width?, prompt_height? }`
— `provider` chooses the agent when a session is created; the others size the
panel.

### Commands

| Command | Action |
| --- | --- |
| `:Weave` | Toggle the panel |
| `:Weave sessions` | Open the session modal |

---

## Project layout

    lua/weave/acp/       ACP protocol: transport (stdio JSON-RPC), client,
                           payload builders, typed protocol surface, one agent
                           process per provider (sessions multiplex over it)
    lua/weave/utils/     logger, fs helpers, list helpers (carried over)
    lua/weave/config*    config: providers + mcp servers + debug flag
    lua/weave/
      session_store.lua    plain-Lua state snapshots + subscribers (the SSOT)
      acp_bridge.lua       ACP callbacks → store mutations
      session.lua          one conversation: client, turns, queue/steer/cancel
      registry.lua         active sessions (editor-global) + per-tab selection
      init.lua             setup() + :Weave, panels per tabpage
    lua/weave/view/      fibrous components: transcript, sidebar, prompt,
                           panel (one docked pane, one mount; the transcript
                           is a fibrous ui.container), session_modal, wave
                           (thinking indicator), prefs, theme, use_store

## Development

Against the working tree (fibrous from the sibling checkout, or set
`FIBROUS_PATH`):

    make test        # the suite
    make test-file FILE=tests/acp/load_spec.lua
    make bench       # benchmarks (BENCH_N=… sizes the workload)
    make demo        # the UI in a clean interactive nvim, against a scripted
                     # agent — streaming, tool calls, permissions (:qa quits)

Against the flake's snapshot of the source (staged/committed files, fibrous
from the PINNED input — `nix flake update fibrous` to bump it):

    nix run .#test   # also: nix flake check
    nix run .#bench
    nix run .#demo   # also the default: nix run .

`nix develop` gives a shell with neovim, make, lua-language-server, and stylua.

## Attribution

`lua/weave/acp/` and `lua/weave/utils/` are carried over (namespace-
renamed) from [agentic.nvim](https://github.com/carlos-algms/agentic.nvim)
by Carlos Gomes, MIT-licensed — see `LICENSE-agentic.txt`.
