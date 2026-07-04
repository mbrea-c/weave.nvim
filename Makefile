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

# The demo UI in a clean interactive Neovim (q to quit)
.PHONY: demo
demo:
	$(NVIM_BIN) --clean -u demo/init.lua
