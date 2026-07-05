# remote-clanker.nvim

*(name TBD — placeholder)*

An [ACP](https://agentclientprotocol.com) (Agent Client Protocol) client for
Neovim with a declarative UI built on
[fibrous.nvim](../nui-reactive). A ground-up rewrite of the reactive panel
from the `agentic` plugin: ACP callbacks mutate a plain-Lua store, and the
whole panel — transcript, sidebar, prompt — is a pure `state → render`
projection of it.

## Status

Working panel. The protocol layer (`lua/clanker/acp/`) is carried over from
agentic (working, battle-tested); store, bridge, view, and the panel shell
are built test-first and green, including session restore, treesitter
markdown/diff rendering, and multi-session support (several sessions, on
possibly different providers, selected per tabpage). See
`open_tasks_and_issues.md`.

## Usage

```lua
require("clanker").setup({ --[[ config overrides ]] })
-- :Clanker (or require("clanker").toggle()) opens the panel
```

In the panel: `<CR>`/`<C-s>` submit, `<C-x>` steer (interrupt + send),
`<C-c>` cancel, `<CR>`/`za` on a tool call toggles it, `zR`/`zM` all,
`;;t`/`;;d`/`;;c`/`;;f` view prefs, `;;p` permission mode, `;;m`/`;;M`
model/mode pickers, `;;1`..`;;9` answer permissions, `;;r` restore a saved
session in place, `;;s` (or `:Clanker sessions`) the session modal, `/new`
fresh session. Sessions are editor-global and selected per tabpage: the
modal lists every active session (rows are buttons — `<CR>` selects for
this tab, `✕` closes the session everywhere), starts new ones on any
configured provider, and activates saved sessions into fresh entries.
The panel is ONE docked pane, one fibrous mount: the transcript is a
`ui.container` (its own buffer in a natively-scrolling subwindow — `<CR>`
enters it, `h/j/k/l` at the edges step back out, `<C-d>/<C-u>` page inside),
prompt and sidebar render inline. Closing the pane closes the panel (the
session keeps running; toggle reopens it).

## Layout

    lua/clanker/acp/       ACP protocol: transport (stdio JSON-RPC), client,
                           payload builders, typed protocol surface, one agent
                           process per provider (sessions multiplex over it)
    lua/clanker/utils/     logger, fs helpers, list helpers (carried over)
    lua/clanker/config*    minimal config: providers + debug flag
    lua/clanker/
      session_store.lua    plain-Lua state snapshots + subscribers (the SSOT)
      acp_bridge.lua       ACP callbacks → store mutations
      session.lua          one conversation: client, turns, queue/steer/cancel
      registry.lua         active sessions (editor-global) + per-tab selection
      init.lua             setup() + :Clanker toggle, panels per tabpage
    lua/clanker/view/      fibrous components: transcript, sidebar, prompt,
                           panel (one docked pane, one mount; the transcript
                           is a fibrous ui.container), session_modal (;;s),
                           prefs, theme, use_store
    tests/                 headless specs — `make test`, or
                           `make test-file FILE=tests/acp/load_spec.lua`
    bench/                 headless benchmarks (`bench/*_bench.lua`)
    demo/                  `nvim --clean` demo: the panel against a scripted
                           agent (streaming, tool calls, permissions)

## Development

Against the working tree (fibrous from the sibling checkout, or set
`FIBROUS_PATH`):

    make test        # the suite
    make bench       # benchmarks (BENCH_N=… sizes the workload)
    make demo        # the UI in a clean interactive nvim (q quits)

Against the flake's snapshot of the source (staged/committed files, fibrous
from the PINNED input — `nix flake update fibrous` to bump it):

    nix run .#test   # also: nix flake check
    nix run .#bench
    nix run .#demo   # also the default: nix run .

## Attribution

`lua/clanker/acp/` and `lua/clanker/utils/` are carried over (namespace-
renamed) from [agentic.nvim](https://github.com/carlos-algms/agentic.nvim)
by Carlos Gomes, MIT-licensed — see `LICENSE-agentic.txt`.
