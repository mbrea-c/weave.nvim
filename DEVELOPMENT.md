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

Input is not throttled (the slow direction of a remote session is the
downlink). The make target needs util-linux `script` and `pv` on `PATH`; the
nix app brings its own.

### Types

Source is annotated with [LuaCATS](https://luals.github.io/wiki/annotations/) so
a Lua language server can type-check the codebase.
