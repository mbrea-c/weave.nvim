-- Transcript pipeline benchmark: STORE mutation → subscriber → fibrous
-- commit, through the real SessionStore + Transcript view (unlike fibrous's
-- own bench/transcript.lua, which drives a synthetic list with use_state).
-- This is the number the 40ms streaming debounce budget is judged against.
-- BENCH_N = transcript length in entries (default 1000).

local uv = vim.uv or vim.loop

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")
local SessionStore = require("weave.session_store")
local Prefs = require("weave.view.prefs")
local transcript = require("weave.view.transcript")

local function bench(name, iters, fn)
  fn(0) -- warmup (JIT + caches)
  collectgarbage("collect")
  local t0 = uv.hrtime()
  for i = 1, iters do
    fn(i)
  end
  local per_op = (uv.hrtime() - t0) / iters / 1e6
  io.write(("%-52s %10.3f ms/op   (%d iters)\n"):format(name, per_op, iters))
end

local LOREM = "the quick brown fox jumps over the lazy dog and packs boxes "

local N = tonumber(vim.env.BENCH_N) or 1000

--- A store seeded like a long real session: alternating user prompts, agent
--- prose, thoughts, and tool calls (some expanded).
local function seeded_store()
  local store = SessionStore:new()
  for i = 1, N do
    local m = i % 4
    if m == 0 then
      store:append_entry({ kind = "user", text = "prompt " .. i })
    elseif m == 1 then
      store:append_entry({ kind = "agent", text = LOREM:rep(3) })
    elseif m == 2 then
      store:append_entry({ kind = "thought", text = LOREM })
    else
      store:upsert_tool_call({
        tool_call_id = "t" .. i,
        kind = "execute",
        argument = "tool " .. i,
        status = "completed",
      })
    end
  end
  return store
end

io.write(("transcript pipeline benchmarks — N = %d entries\n\n"):format(N))

local host = inline_host.new({
  get_size = function()
    return { width = 100 }
  end,
})
local store = seeded_store()

do
  local t0 = uv.hrtime()
  local root = runtime.create_root(transcript.Transcript, { store = store, prefs = Prefs:new() }, { host = host })
  root:render()
  io.write(("%-52s %10.3f ms (one-time)\n"):format("mount", (uv.hrtime() - t0) / 1e6))

  bench("append agent entry", 20, function(i)
    store:append_entry({ kind = "agent", text = "appended " .. i })
  end)

  bench("stream tick (grow last entry)", 50, function()
    store:append_streaming_text("agent", "x")
  end)

  local mid_id = "t" .. (math.floor(N / 2 / 4) * 4 + 3) -- a seeded tool call near the middle
  bench("tool status flip mid-transcript", 50, function(i)
    store:upsert_tool_call({ tool_call_id = mid_id, status = i % 2 == 0 and "completed" or "in_progress" })
  end)

  bench("toggle mid-transcript tool call", 50, function()
    store:toggle_tool_call(mid_id)
  end)

  root:unmount()
end
