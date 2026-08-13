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
  — the preferred [Sandbox](#sandbox) backend. On macOS weave falls back to
  Seatbelt (`sandbox-exec`, part of the OS), which confines less — see
  [Backends](#backends). With neither, a configured `mode = "on"` degrades to
  `off` with a warning.

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
`packages.weave.passthru.runtimeDeps` (`ripgrep`, `bubblewrap` — the latter on
Linux only, so the list is just `ripgrep` on darwin, where the sandbox backend
is the OS's own `sandbox-exec`). A vim plugin
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
| `K` | `peek` | Over a transcript entry: its raw source in a scrollable float (yank/search-friendly). Over a **tool call**: the whole call as indented JSON. Dismissed with `q`/`<Esc>` — or by focusing anything else |
| `;;t` | `toggle_thoughts` | Toggle thinking blocks |
| `;;d` | `toggle_diffs` | Toggle edit diffs |
| `;;c` | `toggle_conceal` | Toggle markdown prettifying (conceal) |
| `;;f` | `toggle_follow` | Toggle follow-streaming (auto-scroll) |
| `;;T` | `toggle_tutor` | Toggle [tutor mode](#tutor-mode) for this session |
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
reminder. Eight builtins ship: four shapes, once per [sandbox mode](#sandbox).

| | with the sandbox **on** (default) | with it **off** |
|---|---|---|
| **Ask** | every tool call inside the workspace asks | every ACP request asks |
| **Read-only** | reads and searches run; writes and commands are denied, and the workspace is mounted read-only | ACP reads allowed, edits/deletes/commands denied |
| **Edit** | reads and writes run unprompted; commands still ask | ACP reads and edits allowed, the rest asks |
| **Auto** | every weave tool runs unprompted inside the workspace | everything allowed |

Two rules hold across all four sandboxed presets. `acp:*` is **denied** —
under mode on the agent's builtin tools only reach an empty read-only
stand-in for the project, so letting them through buys a confusing failure at
best and a confident wrong answer at worst; the deny carries a message
pointing at weave's tools, which stay reachable (`acp:mcp`). And the
**workspace is the whole world**: anything outside it is denied with a
message naming `request_access`, the tool the agent uses to ask you for a
path. An approved grant lands in the overlay, which is consulted first, so it
out-votes that deny without editing the preset.

Even **Auto** keeps two things on a leash: sandbox grants (`request_access`
always asks — it is the user's call by construction) and tools weave does not
own (`mcp:*`, e.g. clankbox's `exec_lua`, which runs in the *unsandboxed*
editor).

Presets are **mode-scoped**: each builtin is tagged for the mode it was
written against, and only presets for the mode you are in are offered —
`;;p` cannot cycle into one from the other world, and selecting one is an
error rather than a silent mismatch. Your own presets are untagged (usable
in both) unless you set `for_mode = "on" | "off"`. Switching modes carries
the active preset to its counterpart, so `edit` becomes `unsandboxed_edit`
and back. The sandboxed four hold the plain names because the sandbox is the
default: a half-remembered name lands on the confined preset.

Resource globs may contain `${project}`, which expands to the session's cwd,
so "inside the project" is expressible in a static preset table, and
`${attachments}`, which expands to the directory weave stages
[attachments](#attachments) into — the one place under mode on where the
agent's own read tool reaches something real.

Answering an `ask` for a weave tool offers four options: allow/reject once,
and allow/reject **for project**. The "always" pair records a **session
grant** — a rule consulted ahead of the active preset, listed with a per-row
`[revoke]` in the configuration window, and discarded on exit. Grants never
rewrite the preset, so `ask` keeps meaning what it means everywhere else.
Inside the project a grant covers the project; outside it, only that exact
path.

Activating the sidebar's **Permissions** header opens the **preset
configuration window**: every preset (builtin / setup / runtime) with the
active one marked — a row activates it — plus the active preset's rules, any
session grants, and the running agent's sandbox mode. `[edit]` opens the
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

### Inline code feedback

Review code where it lives. Comment a line (or a visual selection) directly in
the source buffer, and the comments collect into one **code feedback** draft
that is sent to the agent as a single message.

weave sets **no keymaps** for this. They would be global normal- and
visual-mode bindings over every buffer in the editor, which is further than a
chat plugin should reach on its own, so bind them yourself:

```lua
local feedback = require("weave.feedback")
vim.keymap.set("n", ";;cc", feedback.comment_line, { desc = "weave: comment this line" })
vim.keymap.set("x", ";;cc", feedback.comment_selection, { desc = "weave: comment this selection" })
vim.keymap.set("n", ";;ce", feedback.edit_comment, { desc = "weave: edit the comment here" })
```

Commenting highlights the span (`WeaveCodeFeedback`, a yellow background by
default — `:highlight` it to taste) and opens a small editor float for the
comment body, with **save** / **delete** / **cancel** buttons; `<CR>` in normal
mode saves. Backing out of a comment you never wrote removes it, so no
highlight is stranded. Saving an empty body deletes the comment too, which
makes "clear the box and save" a working way to drop one.

The open draft appears in the sidebar below **Terminal tasks**, summarised as
`N comment(s) pending` plus **send feedback** and **discard** buttons. The
**Code feedback** header is itself the way in: activating it opens the full
list, one row per comment (`file:line  body`). Activating a row **jumps to that
comment's code** and opens its editor there.

Comments are anchored with **extmarks**, not line numbers, so they follow the
code as it moves — including when the agent edits above them. A comment whose
code is deleted outright is counted as `⚠ N stale` in the sidebar, marked in
the list, and sent labelled *stale*, rather than silently pointing at whatever
moved into its place. Jumping to a stale comment still works: it lands on the
line its code was last seen at.
Extmarks die when a buffer unloads, so on reload weave re-finds each comment by
searching for the text it quoted; comments whose code is genuinely gone stay
orphaned rather than being dropped.

What the agent receives is the file and line range, the quoted code (fenced,
with the buffer's filetype), and your comment:

````text
Inline code feedback (1 comment):

1. lua/weave/session.lua:461
```lua
function Session:submit(text)
```
why is this queued rather than steered?
````

#### Extending it

Two separate extension points.

**Producing comments.** Anything can add to the open draft — this is how a
plugin like perijove contributes comments from its own UI. No registration
needed:

```lua
require("weave.feedback").add({
  bufnr = 0,
  range = { lnum = 12, end_lnum = 14 },  -- optional col/end_col for a partial span
  body = "this cell reruns on every render",
  source = "perijove",                   -- attributed in the sent message
})
```

Comments from every source bundle into the **same** draft and are sent
together.

**Receiving a sent draft.** A *sink* is where "send" delivers to. weave ships
one named `weave` (prompts the current session, queued behind an in-flight turn
like anything you type) and it is the default. Register your own to become a
target:

```lua
require("weave.feedback").register_sink({
  name = "perijove",
  label = "the notebook kernel",
  send = function(text, item)
    -- return true on success, or nil + an error message
    return do_something(text)
  end,
})

require("weave.feedback").send({ sink = "perijove" })
```

Registering an existing name replaces it rather than stacking. A sink that
returns an error or throws is reported and **the draft is kept**, so a failed
send never loses hand-written comments.

### Tutor mode

The same idea pointed the other way: instead of you reviewing the agent's code,
the agent reviews **yours**, as you write it. Turn it on for a session and
weave starts sending it what you change, unprompted, and asks it to teach
rather than to do.

Three doors onto the same switch — the **Tutor mode** checkbox in the sidebar
(below *Follow streaming*), `;;T` in the panel, or the command:

```vim
:Weave tutor        " toggle for the session selected in this tab
:Weave tutor on
:Weave tutor off
```

The checkbox sits with the view prefs because that is where you look for a
switch, but it is not one of them: the four above it are pure display state,
while this one sends prompts to the agent and interrupts the turn in flight.
It reads the session store rather than the panel's prefs, so all three doors
always agree.

It is **per session** — a tutor in one panel and an ordinary assistant in
another is a normal thing to want. Collection is editor-global and runs
whenever *any* session has it on; each session tracks what it has already sent,
so two of them never eat each other's window.

What the agent receives is one **squashed diff** of everything you changed
since its last update — not a replay of every keystroke. A line you typed and
retyped five times arrives as whatever it finally says, and a change you made
and then undid does not arrive at all. File creations and deletions are in
there too.

By default a batch goes out after **7 seconds of quiet**, or after **60
seconds** regardless if you never stop typing, and it **interrupts** the turn in
flight (the same thing `<C-x>` does). For the impatient, send now:

```lua
vim.keymap.set("n", ";;F", require("weave.tutor").flush_now, { desc = "weave: flush my edits now" })
```

Sends appear in the transcript as a single quiet line (`⇅ sent 2 files you
changed`) rather than as prose you appear to have written; `K` on it shows the
diff that went out. They do not join your `<C-Up>` prompt history either.

**Only your edits are sent.** Anything weave's own `w:write`/`w:edit` tools do
is excluded, and so is a reload from disk. The one gap is a shell command the
agent runs itself — a formatter, a codemod — which weave cannot see the writes
of; the shipped tutor prompt tells the agent that a hunk may be its own work.

#### What the agent sends back

Feedback lands **on the code**, through the `annotate` tool: a highlighted span
(`WeaveAnnotation`, teal by default) with the message rendered beside it as
virtual lines. That is the point — chat scrolls away, an annotation sits on the
line it is about.

```lua
-- read it, done with it
vim.keymap.set("n", ";;x", require("weave").dismiss_annotation, { desc = "weave: dismiss annotation here" })
-- clear the lot
vim.keymap.set("n", ";;X", require("weave").dismiss_annotations, { desc = "weave: dismiss all annotations" })
```

The agent can also list, rewrite and dismiss its own annotations
(`annotate_list` / `annotate_update` / `annotate_dismiss`), and `annotate` with
no span is a plain `vim.notify` for something that has no one line to point at.

Annotations are anchored with extmarks, like your comments are, so they follow
the code while you keep typing. Because in tutor mode you are *always* typing,
the tool also takes the text the agent expected to find at that line: if it has
moved, the note is re-found by that text, and if the text is nowhere the call
is **refused** rather than highlighting whatever moved into the spot. An
annotation on a file you have since closed waits for you to open it again.

Every builtin preset allows annotating, **read-only included** — that is the
preset tutor mode normally runs under, and an agent that can review but not
speak would be useless. It is still workspace-scoped like every other weave
tool. Both directions of feedback are documented together under [Inline code
feedback](#inline-code-feedback); they share the anchoring layer but not their
namespaces, so `;;x` never dismisses one of your own comments.

Everything about the mode is configurable — see `tutor` under
[Configuration](#configuration). The three prompts especially: they are the
whole agent-facing contract, and rewriting them is how you get the tutor you
actually want.

---

## Configuration

`setup(opts)` deep-merges `opts` over the defaults. All fields are optional.

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `provider` | `string` | `"claude-agent-acp"` | Key of the `acp_providers` entry to start by default |
| `acp_providers` | `table` | 13 built-ins | Agent launch definitions (see below) |
| `mcp_servers` | `list` | `{}` | MCP servers handed to **every** provider at session start |
| `tools` | `table` | `{ enabled = true }` | weave's own MCP tool suite (read/write/edit, glob/grep, task lifecycle, web_fetch) via clankbox; `clankbox_path`, `ripgrep_path` and `curl_path` override binary/checkout auto-detection |
| `permissions` | `table` | `{ presets = {} }` | The permission engine: startup preset + setup-time presets (see [Permission presets](#permission-presets)) |
| `sandbox` | `table` | `{ mode = "on" }` | Agent process confinement (bubblewrap on Linux, Seatbelt on macOS — see [Sandbox](#sandbox)) |
| `tutor` | `table` | see below | [Tutor mode](#tutor-mode): timing, and the three prompts that make the agent a tutor |
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

`tutor` configures [tutor mode](#tutor-mode). The three prompts are the entire
agent-facing contract — the defaults ask for annotations over chat, press for
**brevity** (you are mid-flow, and every annotation pushes your code down the
screen), discourage empty praise, and forbid it from doing the work for you.
But a tutor for learning Rust and a tutor for reviewing a colleague's style
want different words. The rest is timing.

| `tutor` field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `debounce_ms` | `integer` | `7000` | Quiet time after an edit before the batch goes out |
| `max_wait_ms` | `integer` | `60000` | Ceiling from the first unsent edit, so continuous typing still gets sent |
| `on_flush` | `string` | `"interrupt"` | `"interrupt"` cancels the turn in flight (like `<C-x>`); `"queue"` waits behind it. `flush_now()` always interrupts |
| `max_diff_bytes` | `integer` | `102400` | Cap on one batch's diff; truncation is announced, never silent |
| `enabled_prompt` | `string` | see source | Sent when tutor mode goes on — what makes the agent a tutor |
| `disabled_prompt` | `string` | see source | Sent when it goes off |
| `edits_prompt` | `string` | see source | Preamble ahead of each batch of edits |

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
- `web_fetch`, written for parity with Claude's own WebFetch: same `url` +
  `prompt` parameters, `http://` upgraded to `https://`, HTML converted to
  markdown, a 15-minute cache, and a redirect to a **different host** reported
  rather than followed (the URL is what your permission rule matched — quietly
  following would make the rule a lie). It needs `curl` on Neovim's `PATH` or
  `tools.curl_path` set. One difference, stated rather than faked: Claude's
  tool answers `prompt` using a second small model; weave has none to call, so
  it returns the page whole for the agent to apply the prompt to itself.
  Because the gated resource is the URL, rules can scope by host:
  `{ tool = "weave:web_fetch", resource = "https://docs.example.com/**",
  decision = "allow" }`.

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
| `render_header` | the chevron / status glyph / tag / title row; pressing it toggles expansion |
| `render_body` | directly under the header, **always visible** — the call's primary display (the builtin draws the edit diff here) |
| `render_metadata` | the `<CR>`-toggleable detail: kind, file, status, raw input/output, content body |

The header's bracketed tag is normally the ACP **kind** (`[edit]`, `[execute]`,
…), but a call that went through weave's **own** clankbox tool suite is tagged
`[w:<tool>]` instead — `[w:edit]`, `[w:grep]`, `[w:task_start]` — so weave's
tools read apart from the agent's builtins at a glance. ACP tool calls carry no
tool name, so weave recognises its own by the call arguments: the gate records
`args → tool` (`weave.tool_ident`) when it mediates a call, and the header looks
the block up by the same key. Builtin agent tools never reach the gate, so they
are never tagged.

The header **title** beside the tag follows the same recognition. Weave's tools
arrive over MCP, so their agent-supplied title is only the bare endpoint name
(`mcp__clankbox__read`) — which says nothing the `[w:read]` tag doesn't — so the
header shows the call's meaningful argument instead: the file path for
`read`/`write`/`edit`/`glob`, the pattern for `grep`, the command for
`task_start`, the URL for `web_fetch`, the task id for the other `task_*`
tools. Everything else keeps
its normal title (the agent's title, else the file path, else an id label).

Those titles are routinely wider than the panel, so the header **wraps** rather
than clipping at the edge, and so do the expanded raw input/output and content
lines (character wrap, which keeps a dump's indentation intact). For the whole
call at once — every field, uncapped — press `K` over it: the peek float shows
the block weave received as indented JSON. That works over an overridden
rendering too, since the key rides on the entry rather than on what drew it.

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
    preset = "ask",              -- active at startup (unset = ask, or unsandboxed_ask with the sandbox off)
                                 -- a pinned preset must suit the configured mode, or setup errors
    presets = {                  -- the "setup" preset source
      {
        name = "docs-only",
        label = "Docs only",
        -- for_mode = "on",      -- optional: restrict to one sandbox mode (unset = both)
        rules = {
          { tool = "weave:write", resource = "*.md", decision = "allow" },
          { tool = "weave:write", decision = "deny", message = "only markdown is editable here" },
          { tool = "acp:*", decision = "ask" },
          { tool = "*", decision = "allow" },
        },
      },
    },
  },
})
```

A rule may also carry `message = "..."`, said to the agent when that rule
refuses a client-side tool call (the refusal text is a deny's only channel
back, so it can redirect rather than merely block) and shown to you when it
refuses an ACP request, where the protocol carries no text.

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

The `mcp:*` rules are what keep the sandbox meaningful: `exec_lua` runs
arbitrary Lua in the **unsandboxed** editor, so left ungated it can read the
project the sandbox masked. The `sandboxed_*` presets therefore `ask` on
`mcp:*`; set it to `deny` if you would rather it not be offered at all.
Presets from `setup` shadow builtins by name; presets saved in the
configuration window (runtime) shadow both, reversibly.

A preset may also carry a `sandbox` section — the kernel hull TOOL
invocations run under, deliberately **orthogonal** to the rules:

```lua
{
  name = "audit",
  rules = { ... },                       -- the fine-grained gate (globs, per call, can ask)
  sandbox = {                            -- the coarse hull (directories, kernel-enforced)
    binds = { { path = "${project}" },   -- mode defaults to "rw"
              { path = "/data", mode = "ro" } },
    network = false,                     -- default: tool sandboxes get no network
    tools = {                            -- per-tool overrides (exact tool names, no globs)
      ["weave:task_start"] = { network = true },
    },
  },
}
```

Rules speak globs, binds speak directories; neither is derived from the
other. A preset without a section means project-rw/no-network, but the
sandboxed builtins spell that out rather than leaning on it, so `[edit]` on
one hands you a working template; explicit binds REPLACE the default (a
preset binding only `/data` really does exclude the project). The
`for_mode` tag and the whole `sandbox` section survive a round trip through
the config window's editor — what you save is what you wrote.
The one confusing combination — a non-deny rule
whose resource no bind can reach (the gate says yes, the tool then dies at
the kernel wall) — is flagged with a warning when the preset is saved or
loaded.

`sandbox.tools` is the escape hatch for one tool needing something the rest
should not have: keys present in an override replace the global value, keys
absent inherit it (above, tasks get the network while their binds stay the
preset's). The builtin sandboxed presets use it for exactly one tool —
`weave:web_fetch` runs with `network = true, binds = {}`, since fetching is
the one job that needs the network and no filesystem at all, and nobody should
have to grant the whole session network access to read a doc page. Session **elevation grants** — what `request_access` writes when
you approve it — are deliberately global: they widen every tool's hull,
overridden ones included, since granting access answers "may we reach this
at all". The `sandbox` section is orthogonal to the sandbox MODE in a second
sense too: with the mode off, nothing is wrapped at all and the section is
inert; the rules still gate every call.

### Attachments

`:Weave attach <file>` (or `require("weave").attach(path)`) hands a file — an
image, usually — to the **next** prompt. It shows up above the prompt box with
a `✕` to drop it, rides that one message, and is echoed on the sent entry so
the transcript records what went over.

The interesting part is where the file goes. Weave **copies** it into a staging
directory outside `$HOME` and binds that directory **read-only** into the agent
sandbox, so the `file://` URI in the prompt is a path the agent can actually
open. Copying rather than binding the original is deliberate: your file may
live anywhere, and binding arbitrary user paths into the sandbox would be a far
larger grant than "look at this picture". The agent sees exactly what you
attached.

Each attachment contributes up to two content blocks: an `image`/`audio` block
with the bytes when the provider's `promptCapabilities` say it takes them, and
a `resource_link` to the staged path always — the second is what makes a model
that prefers to *read the file itself* work at all under the sandbox. The
sandboxed presets allow exactly that read (`${attachments}` in a resource
glob), while the agent's builtin read stays denied everywhere else.

Staged copies are deleted when the editor exits.

### Sandbox

`sandbox` (design doc: `design-agent-sandbox-v2.md` in the superproject) has
two modes, and **on is the default**. **Off** is the old unsandboxed
behavior. **On** runs the agent process inside the one invariant maximal
sandbox — there is nothing to configure on it, because the agent process is
not a policy surface; all capability lives at the tool layer:

- The **agent process** sees: its own state/auth dirs, the network (the
  model API is non-negotiable), the scoped clankbox broker socket — and
  nothing else. The project directory is unreachable — under bubblewrap an
  **empty read-only tmpfs**, so its builtin write tools fail loudly (EROFS)
  instead of writing into a void — and the weave `w:*` tools are the only
  paths that persist. `$NVIM` (nvim's raw RPC socket — `nvim_exec_lua`, a
  full escape) never enters the sandbox; the broker socket speaks scoped MCP
  and nothing else.
- **Tool invocations** (tasks, searches) each run in their own sandbox
  derived from the active preset's `sandbox` section on EVERY
  spawn: only the listed binds, **network off by default**. A preset switch
  or a granted elevation applies to the very next task — no restarts.
- **Agentside permission requests are denied** by the sandboxed presets
  (`acp:* deny`), not auto-approved: the tools they gate cannot reach the
  real project anyway, and a denial on the first attempt redirects the
  agent to the `weave:*` tools, which is where the effects actually happen.
  Weave says why once in the transcript — ACP's permission response has no
  text channel to say it to the agent.
- **The agent is told once, up front.** The first prompt of a mode-on
  conversation carries a short steering note explaining that the visible
  working directory is an empty stand-in and the weave tools are the way
  out. This is not politeness: under bubblewrap builtin *writes* fail loudly
  (EROFS), but builtin *reads* succeed against the emptiness, so an unsteered
  agent will report the project as empty and mean it.

Mode **off** disables the sandbox entirely — the agent process and every
tool invocation run unwrapped. The permission engine still gates every
call; what mode off removes is kernel enforcement, not policy. Where no
backend is available, mode on degrades to off with a one-time warning, and
the active preset degrades with it (to its `unsandboxed_*` counterpart) so
the policy never vouches for confinement that isn't there.

```lua
require("weave").setup({
  sandbox = {
    mode = "on",                     -- "on" (default) | "off"
    state_paths = { "~/.myagent" },  -- extra rw binds on top of shipped per-provider defaults
    ro_paths = {},                   -- extra ro binds
    env_allowlist = nil,             -- nil = inherit the full environment (default)
  },
  acp_providers = {
    ["codex-acp"] = { sandbox = { mode = "off" } },  -- per-provider override
  },
})
```

Known providers ship rw grants for their state/auth dirs (`~/.claude` +
`~/.claude.json`, `~/.gemini`, `~/.codex`, …) plus the XDG dirs matching
the binary name; anything else goes in `state_paths` (all binds tolerate
missing paths). The per-provider `sandbox` table overrides scalars (`mode`,
`env_allowlist`) and **adds** its `state_paths`/`ro_paths` to the global
ones. `kiro-acp` ships `mode = "off"`: Kiro self-sandboxes via aim-sandbox,
and nesting user namespaces inside it is expected to fail.

#### Backends

Weave builds the hull — what the process may see and reach — and hands it to
whichever backend the machine has, first match winning:

| | Linux | macOS | elsewhere |
|---|---|---|---|
| backend | `bwrap` on `PATH` | `sandbox-exec` (ships with the OS) | none |
| mechanism | mount namespace | Seatbelt syscall filter (SBPL) | — |
| confines | files **and** network | **writes** and network — **reads are not confined** | — |
| mode `on` | enforced | partially enforced (below) | degrades to `off` |

> **On macOS, mode `on` does not stop the agent reading anything.** It stops it
> *writing* outside its grants, and stops its tools reaching the network. It
> can read the project, `$HOME`, and the rest of the disk. The permissions
> window says so beside the mode rather than reporting a bare `on`.

That is a limitation of the mechanism, not a shortcut. Seatbelt has no mount
namespace, so a subtree cannot be swapped for an empty one — it can only be
denied — and denying reads on the agent's **cwd**, or any ancestor of it, stops
the process from starting at all: `getcwd` walks that path to the root, and node
dies in bootstrap with `EPERM ... uv_cwd`. Two narrower attempts (denying
`file-read*`, then only `file-read-data`) both died the same way on a real
kernel. Read confinement here would mean enumerating and re-allowing every
ancestor of the cwd, and getting that subtly wrong fails *quietly* — in the
direction where weave claims a confinement it is not delivering. An honest
"writes and network" beats a read rule nobody can verify.

The permission engine is unaffected and still gates every call, so the
`read_only` preset still refuses writes on both platforms. What macOS loses is
the kernel backstop underneath the reads.

Two smaller differences:

- **`/tmp` is the host's**, not a private one, so scratch space is shared.
- **No pid/ipc/uts isolation and mach lookups stay open**, and a denied write
  is `EPERM` where bubblewrap gives `EROFS`.

Anywhere else mode `on` degrades to `off` with a one-time warning — nothing
breaks; the permission rules still apply, only kernel enforcement and
tool-forcing are lost. The degradation is applied when the mode is
*resolved*, so everything downstream (the permissions window, the sidebar,
which presets are offered) reports `off` too, rather than vouching for a
confinement that is not there.

#### Choosing the mode

The sandbox argv is built once, at spawn, so the mode cannot change on a
running agent — the on/off toggle is the ONE remaining restart in the
design. Two places to choose:

- **+ new session** asks after the provider. Nothing has spawned yet, so
  this choice is free.
- The permissions window's **Sandbox** row shows the running agent's mode
  as session state, with a restart button beside it. This is the only path
  that *reduces* confinement, and it always confirms first — the text
  depends on the direction and on whether the provider supports
  `session/load` (without it, restarting loses the conversation, and the
  prompt says so).

Agent processes are pooled per **(provider, mode)** pair, not per provider:
sessions at the same mode share one process (which is what ACP intends),
and asking for the other mode spawns a second one rather than silently
joining the first at a confinement you did not ask for. A process is
stopped once no session is left using it.

One caveat worth knowing before it looks like a bug: a session restored
into a different mode comes back without knowledge of any tasks that were
running, and may carry history referencing paths it can no longer reach.

Whether an agent **recovers** into the weave MCP tools is provider- and
model-dependent. Weave gives it two pushes — the steering note on the first
prompt and the `acp:*` denials thereafter — and with opencode that is
enough. It is still not something this plugin can guarantee: try mode `on`
with your provider on a scratch project before relying on it.

---

## Lua API

The public surface is three layers: the `require("weave")` module, the
**Session** object it hands out, and the session's **store** (a read-only
snapshot you can subscribe to), plus `require("weave.feedback")` for inline
code feedback. Everything else under `lua/weave/` — the view components, the
ACP plumbing, the registry — is internal.

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

weave.attach(path)     -- attach a file to the next prompt (asks if omitted)
weave.tutor(arg)       -- tutor mode for this tab's session: "on"/"off"/nil to toggle

weave.dismiss_annotation()   -- drop the agent's annotation under the cursor
weave.dismiss_annotations()  -- drop them all ({ buffer = true } for this file only)
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

### Inline code feedback

```lua
local feedback = require("weave.feedback")

feedback.comment_line(opts)       -- comment the cursor line, open the editor
feedback.comment_selection(opts)  -- comment the visual selection, open the editor
feedback.edit_comment(opts)       -- reopen the comment under the cursor
feedback.add(opts)                -- attach a comment with NO editor (for plugins)
feedback.goto_comment(id)         -- jump to a comment's code; false if it is gone

feedback.send(opts)               -- format the draft and hand it to a sink
feedback.discard()                -- drop the draft and its highlights
feedback.draft()                  -- the open item, or nil
feedback.subscribe(fn)            -- called on every draft change; returns unsubscribe

feedback.register_sink(spec)      -- add a send target
```

`add` takes `{ bufnr, range = { lnum, end_lnum, col?, end_col? }, body?, source? }`
and returns the comment (or `nil, err`). `comment_line` / `comment_selection` /
`edit_comment` accept `{ source?, open? }`, where `open(id)` replaces the editor
float — useful in tests. `send` accepts `{ sink? }`, defaulting to `"weave"`.
See [Inline code feedback](#inline-code-feedback) above for the full picture.

### Tutor mode and annotations

```lua
local tutor = require("weave.tutor")

tutor.enable(session)     -- session defaults to this tab's selected one
tutor.disable(session)
tutor.toggle(session)
tutor.is_on(session)      -- boolean
tutor.flush_now(session)  -- send pending edits NOW, interrupting
```

```lua
local annotations = require("weave.annotations")

annotations.add(opts)              -- { path|bufnr, lnum, end_lnum?, message, position?, expect? }
annotations.list(filter)           -- every outstanding one, resolved to where it sits now
annotations.get(id)
annotations.update(id, opts)       -- { message?, position? }
annotations.dismiss(id)
annotations.at_cursor(bufnr, lnum) -- the one under a position, or nil
annotations.dismiss_at(bufnr, lnum)
annotations.clear(filter)          -- { path? }
annotations.subscribe(fn)          -- called on every change; returns unsubscribe
```

`add` returns the annotation, or `nil, err` — notably when the code it points
at is gone, which is a refusal rather than a guess. See [Tutor
mode](#tutor-mode) for the whole picture.

### Commands

| Command | Action |
| --- | --- |
| `:Weave` | Toggle the panel |
| `:Weave sessions` | Open the session modal |
| `:Weave attach <file>` | Attach a file to the next prompt |
| `:Weave tutor [on\|off]` | Tutor mode for this tab's session (no argument toggles) |

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
      sandbox.lua          hull POLICY: the invariant agent sandbox (mode
                             on/off) and per-invocation tool hulls
      sandbox/             hull MECHANISM: bwrap.lua (Linux), seatbelt.lua
                             (macOS SBPL); first available one wins
      session.lua          one conversation: client, turns, queue/steer/cancel
      registry.lua         active sessions (editor-global) + per-tab selection
      task_store.lua       managed shell tasks (the task_* tool lifecycle)
      feedback.lua         inline code feedback: the PUBLIC API users bind
      feedback_store.lua   the one open draft — comments from every source
      feedback_anchors.lua extmark anchoring + highlight, parameterized over
                             namespace: the SAME layer serves the user's
                             comments and the agent's annotations
      feedback_format.lua  draft → the message the agent reads
      feedback_sinks.lua   where a sent draft goes (registry + the weave sink)
      annotations.lua      the agent's notes ON the user's code (tutor mode's
                             output channel): anchor + virt_lines in one mark
      revision.lua         a user edit as before/after CONTENT per file; merge
                             is what makes squashing a burst exact
      revision_log.lua     collection: bursts, per-session cursors, and the
                             attribution that keeps the agent's writes out
      tutor.lua            the mode itself: per-session, debounced sends
      init.lua             setup() + :Weave, panels per tabpage
    lua/weave/tools/     the MCP tool suite hosted by clankbox: fs (read/
                           write/edit, buffer-aware), search (glob/grep over
                           ripgrep, buffer-aware), tasks (task lifecycle),
                           annotate (feedback on the user's code),
                           gate (the permission wrap over every def)
    lua/weave/view/      fibrous components: transcript, sidebar, prompt,
                           panel (one docked pane, one mount; the transcript
                           is a fibrous ui.container), session_modal,
                           session_details (metadata + config dropdowns),
                           permissions_window (preset config + Lua editing),
                           terminal_tasks (running tasks, live task views),
                           feedback (code feedback section + comment editor),
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
