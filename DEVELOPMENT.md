## Development

weave.nvim is an ACP (Agent Client Protocol) client for Neovim, built on the
**fibrous** reactive UI framework. It is developed with **red-green TDD**, with
no exceptions: every change starts from a failing spec (write it, watch it fail
for the reason you expect, then make it pass with the smallest change, then
refactor with the test as your safety net).

The ACP core (transport, session store, registry) is plain Lua with no Neovim
API dependency, so it is fully unit-testable. The view layer is fibrous, so the
same redraw caveat applies: **headless Neovim never redraws.** A `--headless -l`
run mutates buffers but paints nothing, so any bug in the redraw (scroll
position, cursor, highlight flicker) will false-pass a headless spec. Those
behaviors need a real PTY child; the terminal-draw benches below spawn one.

### fibrous, the UI framework

fibrous is a **peer plugin**, not vendored:

- In a nix build (`packages.weave`, `nix flake check`) it comes from the
  `fibrous` **flake input**, pinned in `flake.lock`. Changes in a sibling
  fibrous checkout are invisible until you commit, push, and `nix flake update
  fibrous`, OR you override the input for one command (see below).
- For the Lua entry points (`test`, `bench`, `demo`) fibrous is resolved at
  runtime from `FIBROUS_PATH`. The Makefile and the flake apps default it to the
  sibling checkout `../nui-reactive` (the flake apps fall back to the pinned
  input when `FIBROUS_PATH` is unset), so day-to-day `make test` already runs
  against the fibrous working tree.

To run a nix build or `nix flake check` against a work-in-progress fibrous tree,
override the input with a `path:` reference. A `path:` ref copies the directory
verbatim, so uncommitted AND untracked files come along (a plain or `git+file`
ref would drop untracked files):

```sh
nix flake check --override-input fibrous path:../nui-reactive
nix build .#weave --override-input fibrous path:../nui-reactive
```

For the Lua test and bench apps, an absolute `FIBROUS_PATH` is simpler and needs
no commit:

```sh
FIBROUS_PATH="$HOME/src/nui-reactive" nix run .#test
```

### Requirements

`nix` (the entry points below wrap everything). Without nix you need `nvim`
(0.12+) on `PATH` and a fibrous checkout, then use the `make` targets with
`FIBROUS_PATH` set.

### Running tests

Tests run inside a **fully isolated** headless Neovim (`-u NONE`): no user config
and no plugins, so a failure can only come from weave (or the fibrous it is
pointed at). Specs live in `tests/**/*_spec.lua` and use fibrous' busted-flavored
harness (`describe` / `it` / `assert.equal` / `.same` / `.is_true` / `.has_error`;
note there is no `assert.not_equal` or `assert.is_function`).

Preferred (nix, against the flake snapshot; `git add` your changes first):

```sh
nix run .#test                                # whole suite
nix run .#test -- tests/acp/load_spec.lua     # a single spec
```

Fast inner loop (make, against the working tree, fibrous from `FIBROUS_PATH`):

```sh
make test
make test-file FILE=tests/acp/load_spec.lua
```

A non-zero exit code means at least one test failed.

### Verifying the sandbox

`tests/sandbox_spec.lua` ends with an integration block that only runs when a
backend is actually present, and it spawns the wrapped argv for real — that is
the only part of the suite that proves the sandbox CONFINES rather than that
weave builds the argv it meant to. Everything above it (including all of
`tests/sandbox/seatbelt_spec.lua`) is string-level: it pins the profile, not
the kernel.

**The macOS backend has never been run against a real macOS kernel.** The SBPL
it generates is specced exhaustively, and the mapping from hull to rules is
argued in `lua/weave/sandbox/seatbelt.lua`, but nobody has confirmed that
Seatbelt enforces it. On a Mac, the first thing to do is run the suite and read
the `sandbox integration (seatbelt)` block: it asserts the three invariants
that matter (the project's contents unreachable, a write that never lands,
`$HOME` empty) plus that a network-denied hull cannot reach the internet. If
those pass, the backend does what it claims. If they fail, `mode = "on"` is
lying on that platform and the honest fix is to make `available()` return
false until it is fixed — a sandbox that claims confinement it does not deliver
is worse than an unsandboxed agent the user knows about.

Two failure modes to expect first: a profile so strict the child never starts
(loud, harmless), and a path rule that silently never fires because macOS
resolved the path somewhere else (quiet, dangerous — see `M.normalize` and the
firmlink handling).

The first one has already happened once, and it is worth knowing the shape.
Denying `file-read*` on the project killed the agent in node's bootstrap:

    shell-init: error retrieving current directory: getcwd: ... not permitted
    Error: EPERM: process.cwd failed with error operation not permitted, uv_cwd

The project is the agent's **cwd**, `getcwd` walks that path to the root, and
`file-read*` takes `file-read-metadata` with it, so the process could not stat
the directory it was standing in. bwrap never meets this: its hidden project is
an empty tmpfs, which still stats fine. The fix is `DENY_CONTENT` in
`seatbelt.lua` — deny `file-read-data` (file contents AND directory listing)
and every write, leave metadata alone. Anything else that needs "hide this
subtree" must use the same shape.

To iterate without going through weave, print the profile a spawn would use and
run `sandbox-exec` by hand:

```lua
:lua local _, a = require("weave.sandbox").wrap("claude-agent-acp", {}, { mode = "on" })
     vim.fn.writefile(vim.split(a[2], "\n"), "/tmp/weave.sbpl")
```

```sh
# does anything start at all?
sandbox-exec -f /tmp/weave.sbpl /bin/sh -c 'pwd && echo booted'
# ...and is it still confined? both of these must fail
sandbox-exec -f /tmp/weave.sbpl /bin/sh -c 'ls'
sandbox-exec -f /tmp/weave.sbpl /bin/sh -c 'cat some-project-file'
```

Both halves matter. A profile that boots but lists the project is worse than
one that refuses to boot, because only the second kind announces itself.

### Benchmarks

Weave reuses fibrous' bench harnesses, so the numbers sit on the same ruler as
fibrous' own (the library under test is loaded from the working tree, the harness
is pinned). Two axes, both matter: latency (CPU ms/op) and draw cost (bytes the
TUI pushes at a real pty, the tmux + ssh bottleneck).

| entry point                 | make target             | what it measures                                                                                      |
| --------------------------- | ----------------------- | ----------------------------------------------------------------------------------------------------- |
| `nix run .#bench`           | `make bench`            | CPU benches over the store/registry/view (`BENCH_N` sizes the workload).                              |
| `nix run .#bench-term`      | `make bench-term`       | Bytes nvim's TUI pushes at a real pty per frame, via fibrous' shared `termdraw` harness.              |
| `nix run .#bench-panel-term`| `make bench-panel-term` | The real full panel against a scripted async agent, prompts streaming: the composed-screen draw cost. |

`bench-panel-term` seeds a long session with `BENCH_TRANSCRIPT` so the per-turn
cost is measured at scale.

### The demo

```sh
nix run .#demo      # the weave UI in a clean interactive Neovim (q to quit)
make demo           # same, against the working tree
```

`demo` honors `FIBROUS_PATH` as well, so it is also the quickest way to eyeball a
fibrous change through weave's UI.

A local terminal swallows even a full-screen repaint in microseconds, so
per-keystroke redraw storms (the tmux + ssh flicker class of bug) are
invisible in the plain demo. The constrained variant runs the same demo inside
a pty whose output is throttled to a fixed byte rate, so excessive draw cost
shows up as lag you can feel:

```sh
nix run .#demo-constrained            # 9600 bytes/sec, a shabby remote link
nix run .#demo-constrained -- 2400    # harsher
make demo-constrained DEMO_BPS=2400   # same, against the working tree
```

The throttle is `demo/slowpty.py`, a pty relay that only reads from nvim at
the link rate, so the small kernel pty buffer gives nvim real backpressure
(like a true 9600-baud serial line) and lag stays bounded at a few KB. A
naive `script | pv` pipeline buffers hundreds of KB in between, which lets
nvim paint ahead into a queue and shows you frames that are tens of seconds
stale. Input is not throttled (the slow direction of a remote session is the
downlink). The make target needs `python3` on `PATH`; the nix app brings its
own.

### Types

Source is annotated with [LuaCATS](https://luals.github.io/wiki/annotations/) so
a Lua language server can type-check the codebase.
