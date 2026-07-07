# Note: avoid the name NVIM — Neovim sets $NVIM to its server socket in child
# processes, which would shadow a `NVIM ?= nvim` default.
NVIM_BIN ?= nvim

# Where fibrous lives during development (the flake pins its own copy; the
# runners fall back to this sibling checkout when FIBROUS_PATH is unset).
FIBROUS_PATH ?= ../nui-reactive
export FIBROUS_PATH

# Run the full suite in a fully isolated headless Neovim: `-u NONE` loads no
# user config and no plugins, so failures can only come from our own code.
.PHONY: test
test:
	$(NVIM_BIN) --headless -u NONE -i NONE -l tests/run.lua

# Run a single spec file for focused red-green TDD:
#   make test-file FILE=tests/acp/load_spec.lua
.PHONY: test-file
test-file:
	$(NVIM_BIN) --headless -u NONE -i NONE -l tests/run.lua $(FILE)

# Benchmarks (bench/*_bench.lua; BENCH_N sizes the workload)
.PHONY: bench
bench:
	BENCH_N=$(BENCH_N) $(NVIM_BIN) --headless -u NONE -i NONE -l bench/run.lua

# Terminal-draw throughput on fibrous's shared harness: bytes nvim's TUI pushes
# at a real pty per frame (the tmux+ssh cost, highlight repaints included) — the
# number behind the water-indicator flicker. Separate target: it spawns child
# nvim TUIs and is slower than the CPU benches.
#   make bench-term            # 80x24 pty, 60 frames
#   make bench-term BENCH_FRAMES=120
.PHONY: bench-term
bench-term:
	$(NVIM_BIN) --headless -u NONE -i NONE -l bench/term.lua

# Realistic FULL-PANEL pty draw: the real panel (transcript + sidebar + water +
# prompt) against a scripted async agent, submitting prompts while streaming.
# The composed-screen number the isolated benches miss; BENCH_TRANSCRIPT seeds a
# long session so the per-turn cost is measured at scale.
#   make bench-panel-term
#   BENCH_PROMPTS=5 BENCH_TURN_MS=3500 BENCH_TRANSCRIPT=400 make bench-panel-term
.PHONY: bench-panel-term
bench-panel-term:
	$(NVIM_BIN) --headless -u NONE -i NONE -l bench/panel_term.lua

# The demo UI in a clean interactive Neovim (q to quit)
.PHONY: demo
demo:
	$(NVIM_BIN) --clean -u demo/init.lua
