-- Headless benchmark runner. Invoked as:
--   make bench            (nvim --headless -u NONE -i NONE -l bench/run.lua)
--   nix run .#bench       (same, against the flake snapshot + pinned fibrous)
--
-- Discovers and runs every bench/*_bench.lua with weave and fibrous on the
-- module path. Scenario files own their measurement loops (mirror fibrous's
-- bench(name, iters, fn) shape); BENCH_N is the conventional size knob.

local root = vim.fn.getcwd()

local fibrous = vim.env.FIBROUS_PATH or (root .. "/../nui-reactive")
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  fibrous .. "/lua/?.lua",
  fibrous .. "/lua/?/init.lua",
  package.path,
}, ";")

local files = vim.fn.glob(root .. "/bench/*_bench.lua", false, true)
table.sort(files)

if #files == 0 then
  io.write("no benchmarks yet — the first ones land with the transcript view (roadmap R4)\n")
  return
end

for _, file in ipairs(files) do
  io.write(("== %s ==\n"):format(vim.fn.fnamemodify(file, ":t")))
  dofile(file)
  io.write("\n")
end
