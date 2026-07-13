# AGENTS.md

Working agreement for changes to **weave.nvim**, an ACP client built on
fibrous. Every change, whether a fix, a feature, or a refactor, completes the
checklist below before it is considered done. All of it is mandatory, not "when
it seems worth it."

## Read DEVELOPMENT.md first

Before writing any code, read [DEVELOPMENT.md](DEVELOPMENT.md). It is the source
of truth for how weave is built and tested, how it consumes fibrous, and how to
develop against a work-in-progress fibrous tree.

## Use red-green TDD, always

All development here uses **red-green TDD**, with no exceptions:

1. Write the spec that describes the new behavior.
2. Run it and watch it fail, for the reason you expect.
3. Implement the smallest change that makes it pass.
4. Refactor with the test as your safety net.

A spec that passes before you touch the implementation is not testing your
change. Weave is a fibrous app, so the same caveat applies: **headless Neovim
never redraws**, and any bug that lives in the redraw (scroll, cursor position,
highlight flicker) will false-pass a headless spec and needs a real PTY
reproduction. See DEVELOPMENT.md.

> **Snapshot caveat (read first).** The `nix run` / `nix flake check` entry
> points build from the flake's own snapshot of the source, which is what is
> **committed or staged**, not your dirty working tree. Run `git add` on your
> changes before a `nix run` sign-off, or it silently tests the old code. During
> iteration you may use the `make` targets against the working tree, but the
> sign-off runs are the `nix run` entry points, so they match CI and `nix flake
> check`.

## 1. Run the full test suite

```sh
nix run .#test                                # the whole suite
nix run .#test -- tests/acp/load_spec.lua     # a single spec, while narrowing
```

The suite must be green before sign-off. `nix flake check` runs the same suite
in the build sandbox against the **pinned** fibrous.

Both entry points honor `FIBROUS_PATH`. When your change depends on a fibrous
change that is not yet committed and locked, point it at your checkout so the
suite runs against the working tree (uncommitted and untracked files included):

```sh
FIBROUS_PATH="$HOME/src/nui-reactive" nix run .#test
```

## 2. Check for regressions (benches)

Weave draws a full live panel, so a change can be free on CPU and still make a
remote (tmux + ssh) session flicker. Run the relevant bench and compare against
the state before your change:

```sh
nix run .#bench                # CPU benches (BENCH_N sizes the workload)
nix run .#bench-term           # bytes nvim's TUI pushes at a REAL pty per frame
nix run .#bench-panel-term     # the full panel against a scripted async agent
```

`bench-term` and `bench-panel-term` are the draw-cost numbers (highlight
repaints and escape overhead included), which the CPU benches cannot see. Any
regression must be understood and either justified or fixed before sign-off.

## 3. Update the docs

Weave's user-facing docs are its `README.md` (there is no separate docs site).
Any behavioral or API-visible change (public `weave.*` functions, config keys,
default keybinds, the ACP provider table) must be mirrored there in the same
change. If you notice anything else wrong in the README while you are in it, fix
it if it is in scope and low-risk, otherwise raise it with the user. Never
silently walk past a docs problem you saw.

---

### Notes

- Indentation: 2 spaces throughout `lua/`, `tests/`, and `bench/`. There is no
  stylua or editorconfig config, so don't run a bare `stylua` across the tree.
- fibrous is a **peer plugin**, pinned in `flake.lock`, not vendored. For a nix
  build against a WIP fibrous tree (packages, `nix flake check`), override the
  input with a `path:` ref so untracked files come along:
  `nix flake check --override-input fibrous path:../nui-reactive`. For the Lua
  test and bench entry points, `FIBROUS_PATH` (above) is simpler and needs no
  commit.
- A manual/interactive weave run needs BOTH working trees on the runtimepath
  (weave and fibrous), or it loads a baked copy of one of them. The nix entry
  points and `tests/run.lua` handle this for you; prefer them.
