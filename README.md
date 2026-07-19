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
- **[ripgrep](https://github.com/BurntSushi/ripgrep)** (optional) — the
  `glob`/`grep` MCP tools shell out to it. Without it `grep` errors and `glob`
  falls back to a slower walk.
- **[bubblewrap](https://github.com/containers/bubblewrap)** (optional, Linux)
  — the [Sandbox](#sandbox) backend. Without it every configured profile
  degrades to `off` with a warning.

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

The two optional runtime binaries are exposed as
`packages.weave.passthru.runtimeDeps` (`ripgrep`, `bubblewrap`). A vim plugin
has no wrapper of its own to put programs on `PATH`, so splice them into
whatever does — home-manager's `programs.neovim.extraPackages`, nixvim's
`extraPackages`, or `environment.systemPackages`:

```nix
programs.neovim.extraPackages = weave.packages.${system}.weave.passthru.runtimeDeps;
```

Alternatively point `tools.ripgrep_path` at an absolute store path; a
Nix-wrapped Neovim's `PATH` is not your shell's `PATH`, which is exactly why
that option exists.

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
prompt at the bottom, and press `<C-s>` (or `<CR>` from normal mode) to send —
insert-mode `<CR>` is a newline, so multi-line prompts compose naturally. The
agent's reply streams into the transcript above.

The panel is **one docked pane** with three regions:

- **Transcript** — the conversation: your messages, streamed markdown replies,
  thinking blocks, tool calls (with inline diff previews), and permission
  requests. It scrolls independently. It's a fibrous *container*: `<CR>` steps
  into it, `h/j/k/l` at its edges step back out, `<C-d>/<C-u>` page inside.
- **Sidebar** — session metadata, view toggles, the active permission preset,
  the task list, running terminal tasks, and any pending permission request.
- **Prompt** — the input box. Its border colour reflects the active permission
  preset; an animated indicator shows when the agent is working.

Closing the pane (`:q` / `<C-w>q`) closes the panel but **leaves the session
running** — reopen with `:Weave`.

### Keymaps (inside the panel)

Every key below is a **named action** — the name in the second column is its
field in the `keys` config table, so any of them can be rebound or disabled
(see [Keybinds](#keybinds)). Defaults:

| Key | Action name | Effect |
| --- | --- | --- |
| `<C-s>` | `submit` | Submit the prompt (send to the agent) — works from insert **and** normal |
| `<C-x>` | `steer` | Steer — interrupt the running turn and send this instead (insert or normal). While editing a queued prompt, sends *that* now, skipping the rest of the queue |
| `<C-c>` | `cancel` | Cancel the running turn — **keeps** the queue (moves straight on to the next queued prompt) |
| `<C-Up>` | `recall_older` | In the prompt: recall previous prompt. Walks up through queued prompts (edit them in place) then sent history (recalled as a fresh copy); your draft is preserved |
| `<C-Down>` | `recall_newer` | In the prompt: back down towards your draft |
| `za` | `toggle_tool_call` | On a tool-call header: expand/collapse it (same as `<CR>` activation) |
| `zR` / `zM` | `expand_all` / `collapse_all` | Expand / collapse all tool calls |
| `K` | `peek` | Over a transcript entry: its raw source in a scrollable float (yank/search-friendly) |
| `;;t` | `toggle_thoughts` | Toggle thinking blocks |
| `;;d` | `toggle_diffs` | Toggle edit diffs |
| `;;c` | `toggle_conceal` | Toggle markdown prettifying (conceal) |
| `;;f` | `toggle_follow` | Toggle follow-streaming (auto-scroll) |
| `;;p` | `cycle_permission_mode` | Cycle permission preset |
| `;;m` / `;;M` | `pick_model` / `pick_mode` | Pick model / pick mode |
| `;;1` … `;;9` | `permission_prefix` + digit | Answer a permission request with option N |
| `;;r` | `restore_session` | Restore a saved session in place |
| `;;s` | `sessions` | Open the session modal (also `:Weave sessions`) |
| `q` / `<Esc>` | `close_float` | Close a weave floating window (modals, peek, the full task list) |

Two keys are **not** weave's to rebind, they come with the fibrous widgets:
normal-mode `<CR>` in the prompt submits (insert-mode `<CR>` is a newline, so
prompts compose multi-line), and `<Esc>` leaves a focused region (prompt /
transcript) back to the panel.

Type `/` at the start of the prompt for slash-command completion. `/new`
(always available) starts a fresh conversation; agents may advertise more.

### Prompt queue & history

A prompt sent while a turn is running is **queued** — queued prompts stack just
above the prompt box (between the water indicator and the box) and are sent in
order as the turn ends. The prompt box is a movable edit-cursor over that stack:

- `<C-Up>`/`<C-Down>` walk it up and down — onto a **queued** prompt it moves
  there to edit it in place (earlier queued above, later below), and past the
  queue it recalls your **sent** prompts as a fresh copy to compose. Your
  in-progress draft is kept as you navigate.
- `<C-s>`/`<CR>` while editing a queued prompt **saves the edit in place**;
  a `✕` on any queued row (or clearing it and submitting) removes it.
- `<C-c>` cancels the running turn but **keeps** the queue (so it moves straight
  to the next queued prompt); `<C-x>` sends the box's current text now, jumping
  the queue.

### Permissions

When an agent wants to run a tool that needs approval, a permission request
appears in the transcript and sidebar with numbered options — answer with
`;;1`…`;;9`. How much is auto-answered is decided by the **client-side
permission engine** (`weave.permissions`): editor-global, generic **rules**
of the form *(tool glob, optional resource glob, decision allow/deny/ask)*,
grouped into named **presets**. The first matching rule of the active preset
wins; both ACP permission requests (as `acp:<kind>` with the file path or
command line as the resource) and weave's own MCP tools (as `weave:<tool>`)
resolve through the same rule set — a denied MCP call returns an error the
agent can read, an `ask` surfaces in the same sidebar queue as an ACP
request.

In a prompt, the two **always** options are highlighted: answering one writes
a rule into weave's permission store, so it decides every future call of that
kind rather than just the one in front of you. The **once** options are not
highlighted, and neither are the always options on an agent-side ACP request,
whose bookkeeping is the agent's own and leaves weave's store untouched.

`;;p` cycles the active preset; the prompt border colour is an ambient
reminder. Six builtin presets ship. Three re-encode the historical modes:
**normal** (every ACP request asks), **auto** (allow everything), **allow
edits** (ACP edit calls auto-allow, the rest ask); client-side tools default
to allow in all three. Three **sandboxed** variants mirror them for use with
a [sandbox profile](#sandbox) — same shapes, but weave's own tools are no
longer exempt: reads and searches inside the project are allowed, everything
else `weave:*` asks. When a profile is configured and you have not set
`permissions.preset`, the matching sandboxed variant is selected for you.

Resource globs may contain `${project}`, which expands to the session's cwd,
so "inside the project" is expressible in a static preset table.

Answering an `ask` for a weave tool offers four options: allow/reject once,
and allow/reject **for project**. The "always" pair records a **session
grant** — a rule consulted ahead of the active preset, listed with a per-row
`[revoke]` in the configuration window, and discarded on exit. Grants never
rewrite the preset, so `normal` keeps meaning what it means everywhere else.
Inside the project a grant covers the project; outside it, only that exact
path.

Activating the sidebar's **Permissions** header opens the **preset
configuration window**: every preset (builtin / setup / runtime) with the
active one marked — a row activates it — plus the active preset's rules, any
session grants, and the running agent's sandbox profile. `[edit]` opens the
active preset as a Lua table in a scratch float (`:w` applies it as a
*runtime* preset, shadowing a builtin of the same name; `[delete]` reverts to
the shadowed definition), `[new]` starts from a template. Runtime presets
live in memory for now.

### Sessions

Sessions are **editor-global** (they keep running in the background) but
**selected per tabpage** — each tab's panel shows that tab's selected session.
Different sessions can run on different providers at the same time.

Open the **session modal** with `;;s` or `:Weave sessions`:

- Each row is a button — `<CR>` selects that session for the current tab.
- `ⓘ` on a row opens that session's **details window** (below).
- `✕` on a row closes that session everywhere (it stops running).
- **+ new session** starts a fresh session on any configured provider.
- **↺ load saved…** activates a previously saved session (from the provider's
  history) into a new entry.

`;;r` instead restores a saved session *in place*, over the current
conversation in the panel.

### Session details

Activating the sidebar's **Session** section (`<CR>` on the metadata block),
or a row's `ⓘ` in the session modal, opens the **session details window**:
the full metadata (provider, agent, session id, status, permission preset,
context usage) plus a dropdown for every config the agent lets you change —
model, mode, thinking effort, whatever the provider advertises (ACP
`configOptions`, or the legacy models/modes shape). Dropdowns filter as you
type; `<C-n>`/`<C-p>` move the selection, `<CR>`/`<C-y>` apply it. Opened
from the modal for a session that is not the tab's current one, an **Open in
panel** button makes it the tab's selection. `q`/`<Esc>` closes.

---

## Configuration

`setup(opts)` deep-merges `opts` over the defaults. All fields are optional.

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `provider` | `string` | `"claude-agent-acp"` | Key of the `acp_providers` entry to start by default |
| `acp_providers` | `table` | 13 built-ins | Agent launch definitions (see below) |
| `mcp_servers` | `list` | `{}` | MCP servers handed to **every** provider at session start |
| `tools` | `table` | `{ enabled = true }` | weave's own MCP tool suite (read/write/edit, glob/grep, task lifecycle) via clankbox; `clankbox_path` and `ripgrep_path` override binary/checkout auto-detection |
| `permissions` | `table` | `{ presets = {} }` | The permission engine: startup preset + setup-time presets (see [Permission presets](#permission-presets)) |
| `sandbox` | `table` | `{ profile = "off" }` | Agent process confinement via bubblewrap (see [Sandbox](#sandbox)) |
| `debug` | `boolean` | `false` | Write a debug log (via the bundled logger) |
| `view` | `table` | see below | Default panel geometry |
| `keys` | `table` | see [Keybinds](#keybinds) | Key(s) per named action |

`view` sets the panel's default geometry; a per-call `open`/`toggle` opt (below)
overrides it for that panel.

| `view` field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `width` | `integer` | `100` | Total docked panel width (columns) |
| `sidebar_width` | `integer` | `30` | Sidebar column width (clamped to at most half the panel) |
| `prompt_height` | `integer` | `5` | Prompt input height (rows) |

```lua
require("weave").setup({
  view = { sidebar_width = 40 },   -- a wider sidebar by default
})
```

### Keybinds

Every key weave binds is a **named action** (the names are in the
[keymaps table](#keymaps-inside-the-panel); the machine-readable list is
`require("weave.keys").ACTIONS`). `keys` maps action names to their key(s):

```lua
require("weave").setup({
  keys = {
    sessions = ";S",                        -- rebind (the default is gone)
    peek = { "K", "gp" },                   -- several keys for one action
    submit = { { "<C-CR>", mode = "i" } },  -- an entry with its own mode(s)
    cancel = false,                         -- disable an action entirely
  },
})
```

A value is one key (string), a list of keys, or a list of entries
`{ lhs, mode = ... }`; `false` disables the action. An entry **without**
`mode` keeps the action's default modes — so rebinding `submit` keeps its
insert-mode half unless you say otherwise. Where an action binds, and its
default modes, follow from its scope:

| Scope | Bound where | Default modes |
| --- | --- | --- |
| panel | every panel buffer (root canvas, transcript, prompt input) | `n` |
| prompt | the prompt input buffer | `n`, `i` |
| transcript | transcript entries (fibrous on_key routing) | `n` |
| float | weave's floating windows (modals, peek, task list) | `n` |

`permission_prefix` is special: it is not bound itself — `<prefix>1` …
`<prefix>9` answer permission option N.

Rebinds apply to panels/floats opened **after** `setup()` (in practice: put
`setup()` in your config and never think about it again).

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

With `tools.enabled` (the default) weave also appends a **clankbox** entry —
the stdio shim run by this very nvim — carrying weave's own tool suite:

- `read`/`write`/`edit`, with live-buffer awareness: a file open in the
  editor is read as you currently see it and written *through* the buffer.
- `glob`/`grep`, discovery over [ripgrep](https://github.com/BurntSushi/ripgrep)
  with Claude-compatible parameters (`output_mode`, `-i`, `-n`, `-A`/`-B`/`-C`,
  `glob`, `type`, `multiline`, `head_limit`). Files with unsaved edits are
  searched as they stand in the buffer — through a second `rg` on stdin, so a
  file's results cannot change flavour just because it happens to be open.
  Pass `buffers = "off"` for pure disk. Needs `rg` on Neovim's `PATH` or
  `tools.ripgrep_path` set; without it `grep` errors and `glob` falls back to
  a slower `vim.fn.glob` walk.
- `task_start`/`task_status`/`task_wait`/`task_kill`, a lifecycle over managed
  shell tasks (surfaced in the sidebar's *Terminal tasks* section).

Every call is gated by the permission engine as `weave:<tool>` (see below).
For `glob`/`grep` the gated resource is the search **root**, not the files
matched: a deny rule on `*/secrets/*` blocks a search rooted inside that
directory, but not a cwd-rooted search that surfaces content from within it.
Gating per result would mean one prompt per file; content-level exclusion
belongs in rg's own filters.

### Tool call rendering

Every tool call in the transcript is drawn by `weave.view.tool_call.Entry`,
which is parameterized by three subrenderers you can swap individually:

| prop | what it draws |
| --- | --- |
| `render_header` | the chevron / status glyph / kind tag / title row; pressing it toggles expansion |
| `render_body` | directly under the header, **always visible** — the call's primary display (the builtin draws the edit diff here) |
| `render_metadata` | the `<CR>`-toggleable detail: kind, file, status, raw input/output, content body |

Register an override with a **match predicate** and a `render` component:

```lua
local ToolCall = require("weave.view.tool_call")

ToolCall.register({
  name = "my.plugin:tests",           -- unique; re-registering replaces
  priority = 10,                      -- optional, default 0
  match = function(block)
    return block.input ~= nil and block.input.command == "make test"
  end,
  render = function(_, props)
    -- swap ONE part, keep the rest of the entry
    return {
      comp = ToolCall.Entry,
      props = vim.tbl_extend("force", props, { render_body = MyTestResults }),
    }
  end,
})
```

To own the **entire** entry, header included, simply don't delegate to
`ToolCall.Entry` — return whatever component tree you like. There is no flag
for this; it falls out of `render` being an ordinary fibrous component. Being
a real component is also what lets a renderer hold `use_state` and
`use_effect`, which is how the builtin task renderer streams live output.

`render` and every subrenderer receive the same props: `block` (the normalized
tool call), `store`, `expanded`, `awaiting`, `show_diff`.

The same registry is reachable from `setup` for config-file use, though
plugins should call `register` directly since it works at any time:

```lua
require("weave").setup({ tool_renderers = { spec, ... } })
```

**Matching is a predicate, not a name.** ACP tool calls carry no tool name —
the wire fields are `toolCallId`, `title`, `kind`, `status`, `content`,
`locations`, `rawInput`, `rawOutput`. `kind` is a coarse enum shared by every
tool of that shape and `title` is agent-authored prose that providers word
differently, so neither is a stable key. Matchers get the whole block and
duck-type it, usually on `rawInput` shape. ACP's `_meta` extension slot is
carried through as `block.meta` for the day a provider puts a real name there.

**Precedence is priority-first, highest wins, ties broken by most recently
registered.** Priority exists because registration order is decided by plugin
load order, which nobody controls: without it two plugins that both match
`kind == "execute"` would silently fight, and the winner could change between
restarts. Weave's own renderers register at the default `0`, so a plugin at
`10` reliably outranks them and one at `-10` reliably yields.

No match — or a matcher that throws — falls through to the builtin rendering
silently. A renderer that throws is contained to its own entry: the rest of
the conversation keeps drawing and that entry shows the error.

The builtin task renderer (`weave.view.renderers.task`, opt-in via
`require("weave.view.renderers.task").install()`) is a worked example: it
swaps `render_body` for a live view of the task's output, and identifies
which task a call belongs to by reading the `task <id>` prefix out of the
call's own result — the id weave's own task store minted. Nothing identifies
the task on the way *in*: `rawInput` is exactly the arguments the tool
declared, with no ACP or MCP correlation id anywhere in it.

`weave.view.renderers.fs_diff` is the other builtin, registered automatically
by `setup`, and it exists for the same reason: weave's `read`/`write`/`edit`
reach the agent over MCP, so the tool call arrives with no tool name and no
`kind = "edit"` — which is exactly what the builtin diff rendering keys on. It
duck-types `rawInput` instead, and both its renderers draw through
`weave.view.diff`, the same component the native ACP edit path uses.

An `edit` call needs nothing else: `old_string` and `new_string` are both in
`rawInput`. A `write` call carries only the new content, and by the time the
transcript draws, the write has landed — reading the file back would just
return that same content and diff to nothing. So the old side is captured
*before* the handler runs (`weave.tools.write_snapshots`) and looked up by
`(path, content)`, the pair both ends agree on. Snapshots are bounded and
lookup is non-consuming, since a transcript entry re-renders on every flush;
when one has been evicted the renderer declines the block rather than diffing
against an empty file and claiming the agent wrote it from scratch.

### Permission presets

`permissions` seeds the engine at `setup` time:

```lua
require("weave").setup({
  permissions = {
    preset = "normal",           -- active at startup (unset = normal, or its sandboxed variant under a profile)
    presets = {                  -- the "setup" preset source
      {
        name = "docs-only",
        label = "Docs only",
        rules = {
          { tool = "weave:write", resource = "*.md", decision = "allow" },
          { tool = "weave:write", decision = "deny" },
          { tool = "acp:*", decision = "ask" },
          { tool = "*", decision = "allow" },
        },
      },
    },
  },
})
```

Rules are evaluated in order, first match wins; no match resolves `ask`.
Globs are whole-string, `*` matching any run (across `/`, so `"/etc/*"`
covers the subtree and `"git *"` is a command prefix) and `?` one character.
Action names are namespaced: `acp:<kind>` (an ACP permission request — kind
`edit`, `execute`, `read`, …, resource = first location path or the command
line), `weave:<tool>` (the tool suite above — resource = absolute path,
buffer ref, or command line), `mcp:<tool>` (any OTHER tool reachable over the
shared clankbox host — its own built-ins like `exec_lua`, plus other plugins'
registrations — gated through clankbox's middleware chain, with no resource,
since a foreign tool's arguments have no schema weave can read one out of),
and `<plugin>:<tool>` for a plugin that resolves its own clankbox tools
through `require("weave.permissions").resolve`.

The `mcp:*` rules are what keep a sandbox profile meaningful: `exec_lua` runs
arbitrary Lua in the **unsandboxed** editor, so left ungated it can read the
project the sandbox masked. The `sandboxed_*` presets therefore `ask` on
`mcp:*`; set it to `deny` if you would rather it not be offered at all.
Presets from `setup` shadow builtins by name; presets saved in the
configuration window (runtime) shadow both, reversibly.

A preset may declare what confinement its rules assume:

```lua
{
  name = "audit",
  sandbox = { profile = "readonly", mode = "or_stricter" },
  rules = { ... },
}
```

`mode` is `or_stricter` (the default: that profile or anything more
confining), `exact`, or `or_looser`. Profiles are totally ordered by
confinement: `off < workspace < readonly < blackbox`. A preset with no
`sandbox` field fits every profile.

The requirement is declarative — the engine compares, it never applies a
profile. `;;p` silently skips presets the running profile does not satisfy
(cycling is cheap and must never restart anything); they still appear in the
configuration window, greyed with their reason, and selecting one offers the
agent restart needed to satisfy it. The confirmation text depends on the
direction and on whether the provider supports `session/load` — without it,
restarting loses the conversation, and the prompt says so.

### Sandbox

`sandbox` confines the **agent process itself** (and every MCP server it
spawns, weave's tool shim included) with
[bubblewrap](https://github.com/containers/bubblewrap). It is the enforcement
half of the permission engine: with the project read-only at the filesystem
level, the agent's builtin write/execute tools hit the wall and edits must
flow through the `weave:*` MCP tools — where your permission rules apply.

```lua
require("weave").setup({
  sandbox = {
    profile = "readonly",            -- "off" (default) | "workspace" | "readonly" | "blackbox"
    state_paths = { "~/.myagent" },  -- extra rw binds on top of shipped per-provider defaults
    ro_paths = {},                   -- extra ro binds
    env_allowlist = nil,             -- nil = inherit the full environment (default)
  },
  acp_providers = {
    ["codex-acp"] = { sandbox = { profile = "off" } },  -- per-provider override
  },
})
```

Profiles, by what the project directory looks like from inside:

| Profile | Project dir | Meaning |
| --- | --- | --- |
| `off` | untouched | No wrapping (the default) |
| `workspace` | read-write | Pure containment: the rest of `$HOME` is hidden behind a tmpfs (except `state_paths`), the rest of the filesystem is read-only |
| `readonly` | read-only | Same, plus writes inside the project fail — edits and commands must flow through the weave MCP tools |
| `blackbox` | absent | Even reads go through weave, so the transcript shows every file the agent ever saw |

In every sandboxed profile `/tmp`, `/dev` and `/proc` are private, the rest
of the filesystem is bound read-only (`/nix/store`, `/etc/ssl`,
`resolv.conf` keep working), and the **network is shared** — this is
guardrails and tool-forcing, not an exfiltration boundary. Known providers
ship rw grants for their state/auth dirs (`~/.claude` + `~/.claude.json`,
`~/.gemini`, `~/.codex`, …) plus the XDG dirs matching the binary name;
anything else goes in `state_paths` (all binds tolerate missing paths). The
`$NVIM` socket and the clankbox checkout are bound automatically so the tool
suite keeps working inside.

The per-provider `sandbox` table overrides scalars (`profile`,
`env_allowlist`) and **adds** its `state_paths`/`ro_paths` to the global
ones. `kiro-acp` ships `profile = "off"`: Kiro self-sandboxes via
aim-sandbox, and nesting user namespaces inside it is expected to fail.

Backend support: Linux with `bwrap` on `PATH`. Anywhere else a configured
profile degrades to `off` with a one-time warning — nothing breaks, the
tools are offered rather than forced. The degradation is applied when the
profile is *resolved*, so everything downstream (the permissions window, the
sandboxed presets, the sidebar) reports `off` too, rather than vouching for a
confinement that is not there.

#### Choosing a profile

The bwrap argv is built once, at spawn, so a profile cannot change on a
running agent. Two places to choose one:

- **+ new session** asks for a profile after the provider. Nothing has
  spawned yet, so this choice is free.
- The permissions window's **Sandbox profile** row shows the running agent's
  profile as session state, with `[restart with profile…]` beside it. This
  is the only path that *reduces* confinement, and it always confirms first.

Agent processes are pooled per **(provider, profile)** pair, not per provider:
sessions of the same provider at the same profile share one process (which is
what ACP intends), and asking for a different profile spawns a second one
rather than silently joining the first at a confinement you did not ask for.
A process is stopped once no session is left using it.

One caveat worth knowing before it looks like a bug: a session restored into
a different profile comes back without knowledge of any tasks that were
running, and may carry history referencing paths it can no longer reach.

Note that weave's own MCP tools run host-side, in Neovim, outside bwrap.
Under `blackbox` they are a deliberate read channel out of the sandbox and
the agent's only route to the project. The profile confines the agent
*process*; what it plus the permission engine buys is that every such read is
mediated and visible.

Support matrix (what has actually been exercised, not what is expected to
work):

| Provider | Spawns sandboxed | Notes |
| --- | --- | --- |
| `claude-agent-acp` | verified, all three profiles | ACP handshake completes under `workspace`/`readonly`/`blackbox` |
| `kiro-acp` | opted out | Ships `profile = "off"`: self-sandboxes via aim-sandbox, nested user namespaces are expected to fail |
| everything else | untested | No reason to expect failure; the wrapper is provider-agnostic |

Spawning is only half of it: whether an agent **recovers** into the weave
MCP tools when its builtin write/execute tools hit the read-only wall is
provider- and model-dependent, and is not something this plugin can
guarantee. Try `readonly` with your provider before relying on it, and use
`workspace` where you only want containment without tool redirection.

---

## Lua API

The public surface is three layers: the `require("weave")` module, the
**Session** object it hands out, and the session's **store** (a read-only
snapshot you can subscribe to). Everything else under `lua/weave/` — the view
components, the ACP plumbing, the registry — is internal.

### The module

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

### The Session

`weave.get_session()` returns the current tab's Session — everything the
panel's keys do is a method on it, so all of it can be scripted:

```lua
local session = require("weave").get_session()

session:submit(text)             -- send (queued while a turn is running)
session:steer(text)              -- interrupt the running turn and send NOW
session:cancel()                 -- cancel the running turn (keeps the queue)
session:respond_permission(n)    -- answer the pending permission, option n
session:cycle_permission_mode()  -- next permission preset (editor-global)

session:config_kinds()           -- what the agent lets you change: a list of
                                 -- { key, label, current, available = { { id, label }, … } }
session:set_config(key, id, cb)  -- apply one (e.g. "model", "claude-…"); cb(ok)

session:new_conversation()       -- same as the /new slash command
session:restore(session_id)      -- restore a saved conversation in place

session:is_ready()               -- agent connected + ACP session created?
session:get_store()              -- the state snapshot + subscription (below)
```

### The store

The store is the single source of truth the whole view renders from. Read it,
subscribe to it — but treat snapshots as **read-only** (they are immutable;
all mutation goes through Session methods):

```lua
local store = session:get_store()

store.state                -- the current snapshot
local unsub = store:subscribe(function(state)
  -- called synchronously after every mutation
end)
```

The snapshot's main fields: `entries` (the transcript timeline), `tool_calls`
(by id), `status` (`"idle" | "busy" | …`), `plan` (the task list), `queued` +
`history` (prompt queue and sent prompts), `permission` (the pending request's
head), `usage` (context tokens), `meta` (provider / agent / model / mode /
session id), `commands` (advertised slash commands). The permission preset is
NOT store state — it lives in the editor-global engine,
`require("weave.permissions")` (`active()`, `set_active(name)`, `cycle()`,
`resolve(action)`, `save_preset(p)`, `subscribe(fn)`). Snapshots
are reference-stable: a field's table is reassigned only when it changed, so
`old.entries ~= new.entries` is a cheap "did content change" test.

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
    lua/weave/config*    config: providers + mcp servers + keys + debug flag
    lua/weave/keys.lua   the named-action keybinding surface (Config.keys →
                           buffer maps / fibrous on_key), see Keybinds above
    lua/weave/
      session_store.lua    plain-Lua state snapshots + subscribers (the SSOT)
      acp_bridge.lua       ACP callbacks → store mutations (+ permission
                             resolution through the engine)
      permissions.lua      the client-side permission engine: rules, presets
                             (builtin/setup/runtime), the active preset
      sandbox.lua          bwrap argv rewrite for the agent spawn (profiles
                             off/workspace/readonly/blackbox)
      session.lua          one conversation: client, turns, queue/steer/cancel
      registry.lua         active sessions (editor-global) + per-tab selection
      task_store.lua       managed shell tasks (the task_* tool lifecycle)
      init.lua             setup() + :Weave, panels per tabpage
    lua/weave/tools/     the MCP tool suite hosted by clankbox: fs (read/
                           write/edit, buffer-aware), search (glob/grep over
                           ripgrep, buffer-aware), tasks (task lifecycle),
                           gate (the permission wrap over every def)
    lua/weave/view/      fibrous components: transcript, sidebar, prompt,
                           panel (one docked pane, one mount; the transcript
                           is a fibrous ui.container), session_modal,
                           session_details (metadata + config dropdowns),
                           permissions_window (preset config + Lua editing),
                           terminal_tasks (running tasks, live task views),
                           tool_call (tool-call rendering + the override
                             registry), renderers/ (builtin overrides),
                           wave (thinking indicator), prefs, theme, use_store

## Development

Against the working tree (fibrous from the sibling checkout, or set
`FIBROUS_PATH`):

    make test        # the suite
    make test-file FILE=tests/acp/load_spec.lua
    make bench       # benchmarks (BENCH_N=… sizes the workload)
    make demo        # the UI in a clean interactive nvim, against a scripted
                     # agent — streaming, tool calls, permissions (:qa quits)
    make demo-constrained  # same, through a pty throttled to DEMO_BPS
                           # bytes/sec (default 9600): draw cost as felt lag

Against the flake's snapshot of the source (staged/committed files, fibrous
from the PINNED input — `nix flake update fibrous` to bump it):

    nix run .#test   # also: nix flake check
    nix run .#bench
    nix run .#demo   # also the default: nix run .
    nix run .#demo-constrained -- 2400   # the demo over a simulated slow link

`nix develop` gives a shell with neovim, make, lua-language-server, and stylua.

## Attribution

`lua/weave/acp/` and `lua/weave/utils/` are carried over (namespace-
renamed) from [agentic.nvim](https://github.com/carlos-algms/agentic.nvim)
by Carlos Gomes, MIT-licensed — see `LICENSE-agentic.txt`.
