-- Realistic full-panel terminal-draw benchmark. Runs the REAL weave panel
-- (transcript + sidebar + water indicator + prompt) against a scripted async
-- agent — the demo's exact shape — in a child nvim TUI, submits prompts on a
-- schedule, and measures the bytes nvim pushes at a real pty while each turn
-- streams. This is the true ssh+tmux cost of a live session: streaming
-- transcript commits, the water animation during generation, and every
-- subwindow-float redraw the composed screen triggers.
--
-- Where the other benches measure one piece in isolation — bench/term.lua the
-- water widget, transcript_bench.lua the transcript pipeline's CPU ms/op — this
-- measures the WHOLE screen under real streaming. That composition is where the
-- subwindow-redraw churn hid (an animating water sibling was redrawing the
-- still transcript float every frame); a per-turn byte number here is the guard
-- that keeps it from creeping back.
--
--   make bench-panel-term
--   BENCH_PROMPTS=5 BENCH_TURN_MS=3500 make bench-panel-term
--   BENCH_TRANSCRIPT=200 make bench-panel-term   # pre-grow the transcript first

local root = vim.fn.getcwd()
local fibrous = vim.env.FIBROUS_PATH or (root .. "/../nui-reactive")
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  fibrous .. "/lua/?.lua",
  fibrous .. "/lua/?/init.lua",
  package.path,
}, ";")

local termdraw = require("fibrous.bench.termdraw")

local COLS = tonumber(vim.env.BENCH_COLS) or 100
local ROWS = tonumber(vim.env.BENCH_ROWS) or 32
local PROMPTS = tonumber(vim.env.BENCH_PROMPTS) or 3
local TURN_MS = tonumber(vim.env.BENCH_TURN_MS) or 3000
-- Entries to seed the transcript with BEFORE measuring: the pathology this
-- bench exists to catch scales the per-turn cost with transcript length (a
-- still float redrawn every frame), so a big seed makes a regression loud.
local SEED = tonumber(vim.env.BENCH_TRANSCRIPT) or 0

-- The scene, run in the child: a scripted async agent (thought → streamed
-- markdown prose with a table + code block → tool call → end turn), the REAL
-- panel opened against it, an optional pre-seeded transcript, and a fixed
-- submit schedule so the parent's timed windows line up one-per-turn.
local INIT = ([[
local weave = require("weave")

local REPLY = table.concat({
  "Sure — here is a compact summary of what changed and why.\n\n",
  "## What changed\n\n",
  "The store drives every component; this prose streams through the same path a\n",
  "real ACP agent uses, one chunk per tick.\n\n",
  "```lua\n",
  "local spans = markdown.parse('**bold**')\n",
  "return spans\n",
  "```\n\n",
  "| Component | Role | LOC |\n",
  "| :-- | :--: | --: |\n",
  "| store | source of truth | 210 |\n",
  "| transcript | renders entries | 1400 |\n\n",
  "That's the gist.\n",
}, "")

local client = {
  state = "connected",
  agent_info = { name = "bench-agent", version = "0" },
  _turn = 0,
  _handlers = {},
}
function client:create_session(handlers, callback)
  local sid = "bench-session"
  self._handlers[sid] = handlers
  callback({
    sessionId = sid,
    modes = { currentModeId = "demo", availableModes = { { id = "demo", name = "Demo" } } },
    models = { currentModelId = "s", availableModels = { { modelId = "s", name = "Scripted" } } },
  }, nil)
end
function client:send_prompt(sid, _prompt, callback)
  self._turn = self._turn + 1
  local turn = self._turn
  local h = self._handlers[sid]
  local t = 0
  local function at(ms, fn) t = t + ms; vim.defer_fn(fn, t) end

  at(250, function()
    h.on_session_update({
      sessionUpdate = "agent_thought_chunk",
      content = { text = "Considering the request and staging a reply." },
    })
  end)
  for word in REPLY:gmatch("%%S+%%s*") do
    at(18, function()
      h.on_session_update({ sessionUpdate = "agent_message_chunk", content = { text = word } })
    end)
  end
  at(200, function()
    h.on_tool_call({
      tool_call_id = "exec-" .. turn,
      kind = "execute",
      argument = "ls -la",
      status = "in_progress",
      input = { command = "ls -la" },
    })
  end)
  at(300, function()
    h.on_tool_call_update({
      tool_call_id = "exec-" .. turn,
      status = "completed",
      output = { exit_code = 0 },
      body = { "init.lua", "panel.lua" },
    })
  end)
  at(400, function() callback({ stopReason = "end_turn" }, nil) end)
end
function client:cancel_turn() end
function client:cancel_session() end

weave.setup({})
weave.open({
  get_instance = function(_name, on_ready)
    on_ready(client)
    return client
  end,
})

-- Optional: pre-grow the transcript so the per-turn cost is measured against a
-- long session (the case that matters — 50MB multi-day transcripts). Seeded
-- straight into the store, no streaming, before the measured turns.
local SEED = %d
if SEED > 0 then
  local store = weave.get_session():get_store()
  for i = 1, SEED do
    if i %% 2 == 0 then
      store:append_entry({ kind = "user", text = "seed prompt " .. i })
    else
      store:append_entry({ kind = "agent", text = "Seed reply " .. i .. " with some **markdown** and `code`." })
    end
  end
end

-- Fixed submit schedule: one prompt per TURN_MS window, matching the parent's
-- steps. Each turn self-completes (no permission gate) so the next never queues.
local TURN_MS = %d
for i = 1, %d do
  vim.defer_fn(function()
    local s = weave.get_session()
    if s then s:submit("Prompt " .. i .. ": summarize the change and show a table.") end
  end, 300 + (i - 1) * TURN_MS)
end
]]):format(SEED, TURN_MS, PROMPTS)

local steps = {}
for i = 1, PROMPTS do
  steps[#steps + 1] = { label = ("turn %d (stream + settle)"):format(i), wait_ms = TURN_MS }
end
steps[#steps + 1] = { label = "idle tail (settled)", wait_ms = 1500 }

io.write(("full-panel terminal draw — %dx%d pty, %d prompts, %dms/turn, %d seed entries\n\n")
  :format(COLS, ROWS, PROMPTS, TURN_MS, SEED))

local r = termdraw.drive({
  rtp = { root, fibrous },
  cols = COLS,
  rows = ROWS,
  init = INIT,
  steps = steps,
})

for _, s in ipairs(r.steps) do
  io.write(("%-30s %10d bytes  %6d writes  %8.1f B/ms\n")
    :format(s.label, s.bytes, s.writes, s.bytes / math.max(TURN_MS, 1)))
end
io.write(("%-30s %10d bytes  %6d writes  %8.1f B/ms  (%.0f ms)\n")
  :format("TOTAL", r.bytes, r.writes, r.per_ms, r.ms))
