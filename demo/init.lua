-- Demo entry point: a clean Neovim (`nvim --clean -u demo/init.lua`, or
-- `make demo` / `nix run .#demo`) with weave and fibrous on the path.
--
-- Opens the real panel (roadmap R5) against a SCRIPTED agent: every prompt
-- you submit streams a thought + a prose reply, runs a tool call, and every
-- second prompt makes an edit that asks for permission. All the panel
-- machinery is live — try:
--   <CR>/<C-s> submit · <C-x> steer · <C-c> cancel · <CR>/za on a tool call
--   <C-Up>/<C-Down> recall/edit queued prompts (queue while a turn runs) ·
--   zR/zM expand/collapse all · ;;t ;;d ;;c ;;f view prefs · ;;p permission
--   mode · ;;1..;;9 answer permissions · ;;r restore a saved session ·
--   ;;s the session modal (multiple sessions, per-tab selection) ·
--   /new fresh conversation · :qa quits
--
-- A sample users.lua is opened beside the panel for INLINE CODE FEEDBACK:
--   ;;cc on a line (or over a visual selection) comments it — the span turns
--   yellow and an editor float opens for the comment body. ;;ce reopens the
--   comment under the cursor. Comments from anywhere collect into one draft in
--   the sidebar's "Code feedback" section; its send button (or ;;cs) hands the
--   whole bundle to the agent as one message, quoted code and all.
--   Comments are extmark-anchored: edit ABOVE one and it follows the code.

-- Resolve paths from this file's own location, not the cwd, so the nix app
-- (`-u /nix/store/...-source/demo/init.lua`) works from anywhere.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")
local fibrous = vim.env.FIBROUS_PATH or (root .. "/../nui-reactive")

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(fibrous)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  fibrous .. "/lua/?.lua",
  fibrous .. "/lua/?/init.lua",
  package.path,
}, ";")

local weave = require("weave")

-- ── The scripted agent ───────────────────────────────────────────────────────
-- A fake ACP client: create_session hands us the bridge handlers, and each
-- send_prompt plays a little timeline through them (thought, streamed prose,
-- tool calls, a permission request on every second turn), then ends the turn.

local REPLY = "Sure — I looked at the request and here is what I found. "
  .. "The store drives **every** component you see: this prose is streaming "
  .. "through the same code path a *real* ACP agent would use, one chunk per "
  .. "tick, coalesced into a single transcript entry.\n\n"
  .. "## Markdown, live\n\n"
  .. "Once the turn settles this entry parses as markdown (`;;c` toggles "
  .. "conceal):\n\n"
  .. "```lua\n"
  .. 'local spans = markdown.parse("**bold**")\n'
  .. "return spans\n"
  .. "```\n\n"
  .. "## Tables\n\n"
  .. "Claude emits ragged pipe-tables; on settle they align (alignment colons "
  .. "honored, `**markup**` measured by its visible width):\n\n"
  .. "| Component | Role | LOC |\n"
  .. "| :-- | :--: | --: |\n"
  .. "| store | single **source of truth** | 210 |\n"
  .. "| transcript | renders entries | 1400 |\n"
  .. "| markdown | tables & `code` | 570 |\n\n"
  .. "And a wide one, past the panel width, to exercise nowrap — the columns "
  .. "must stay put, not reflow:\n\n"
  .. "| Module | Responsibility | Lines | Owner | Notes |\n"
  .. "| --- | --- | ---: | --- | --- |\n"
  .. "| markdown_table.lua | GFM pipe-table alignment as a pure-text transform | 340 | weave | ported from agentic, plain-Lua testable |\n"
  .. "| markdown.lua | treesitter highlight + conceal + table wiring | 230 | weave | parse on settle, cached per (text, conceal) |\n"
  .. "| transcript.lua | per-entry components in a scroll container | 400 | weave | memoized entries, follow-scroll, nowrap tables |\n"
  .. "\n"
  .. "## Math\n"
  .. "Math renders inline, like $e^{i\\pi} + 1 = 0$, and in display mode. "
  .. "Environments become real grids with brackets grown to fit, and a "
  .. "piecewise brace that spans its rows:\n\n"
  .. "$$\n"
  .. "M = \\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}, \\quad \\det M = ad - bc\n"
  .. "$$\n\n"
  .. "$$\n"
  .. "|x| = \\begin{cases} x & x \\ge 0 \\\\ -x & x < 0 \\end{cases}\n"
  .. "$$\n\n"
  .. "A limit stacks its subscript below, a sum sizes to a fractional "
  .. "summand, and vectors carry wide arrows:\n\n"
  .. "$$\n"
  .. "f'(x) = \\lim_{h \\to 0} \\frac{f(x + h) - f(x)}{h}\n"
  .. "$$\n\n"
  .. "$$\n"
  .. "\\sum_{k=1}^{n} \\frac{1}{k^2} = \\frac{\\pi^2}{6}, \\quad \\nabla \\times \\overrightarrow{F}\n"
  .. "$$\n"

local client = {
  state = "connected",
  agent_info = { name = "scripted-agent", version = "0.1" },
  _turn = 0,
  _session_n = 0,
  -- Handlers PER session id: the ;;s modal runs several sessions over this
  -- one client, and each reply must stream into the transcript that asked.
  _handlers = {},
}

function client:create_session(handlers, callback, _mcp)
  self._session_n = self._session_n + 1
  local sid = "demo-session-" .. self._session_n
  self._handlers[sid] = handlers
  callback({
    sessionId = sid,
    modes = { currentModeId = "demo", availableModes = { { id = "demo", name = "Demo" } } },
    models = { currentModelId = "scripted", availableModels = { { modelId = "scripted", name = "Scripted" } } },
  }, nil)
  vim.defer_fn(function()
    handlers.on_session_update({
      sessionUpdate = "available_commands_update",
      availableCommands = { { name = "plan", description = "Make a plan" } },
    })
  end, 100)
end

function client:send_prompt(sid, _prompt, callback)
  self._turn = self._turn + 1
  local turn = self._turn
  local h = self._handlers[sid]
  local t = 0
  local function at(ms, fn)
    t = t + ms
    vim.defer_fn(fn, t)
  end

  at(400, function()
    h.on_session_update({
      sessionUpdate = "agent_thought_chunk",
      content = { text = "The user asked something; let me stage a convincing demo response." },
    })
    -- Context usage arrives up front and grows each turn (config-plane → the
    -- sidebar's Usage bar, which fills and shifts green → amber → red as the
    -- window fills up).
    h.on_session_update({
      sessionUpdate = "usage_update",
      used = math.min(turn * 24000 + 8000, 200000),
      size = 200000,
      cost = { amount = turn * 0.021, currency = "USD" },
    })
  end)

  -- Stream the reply word by word, KEEPING the whitespace between chunks —
  -- the newlines are markdown block structure.
  for word in REPLY:gmatch("%S+%s*") do
    at(30, function()
      h.on_session_update({ sessionUpdate = "agent_message_chunk", content = { text = word } })
    end)
  end

  at(300, function()
    h.on_tool_call({
      tool_call_id = "exec-" .. turn,
      kind = "execute",
      argument = "ls -la src/",
      status = "in_progress",
      input = { command = "ls -la src/" },
    })
  end)
  at(700, function()
    h.on_tool_call_update({
      tool_call_id = "exec-" .. turn,
      status = "completed",
      output = { exit_code = 0 },
      body = { "init.lua", "store.lua", "panel.lua" },
    })
  end)

  local function end_turn()
    callback({ stopReason = "end_turn" }, nil)
  end

  if turn % 2 == 0 then
    -- Every second turn: an edit that needs permission. Like a real ACP
    -- provider, the agent BLOCKS on the request — the rest of the turn (the
    -- tool result, the closing note, the plan finish, and end_turn) only
    -- happens once the user answers. Firing end_turn on a fixed timer instead
    -- (not waiting) is what made the demo "keep going" through a pending
    -- permission and could strand the activity indicator at "generating" when
    -- a late answer completed the tool after the turn had already ended.
    at(300, function()
      h.on_tool_call({
        tool_call_id = "edit-" .. turn,
        kind = "edit",
        file_path = "src/panel.lua",
        status = "pending",
        diff = {
          old = { "local width = 80", "local height = 20" },
          new = { "local width = 100", "local height = 24" },
        },
      })
      h.on_session_update({
        sessionUpdate = "plan",
        entries = {
          { content = "inspect the request", status = "completed" },
          { content = "apply the edit", status = "in_progress" },
          { content = "report back", status = "pending" },
        },
      })
      h.on_request_permission({
        toolCall = { toolCallId = "edit-" .. turn, title = "Edit src/panel.lua", kind = "edit" },
        options = {
          { optionId = "allow", name = "Allow", kind = "allow_once" },
          { optionId = "always", name = "Always allow", kind = "allow_always" },
          { optionId = "reject", name = "Reject", kind = "reject_once" },
        },
      }, function(option_id)
        local allowed = option_id == "allow" or option_id == "always"
        h.on_tool_call_update({
          tool_call_id = "edit-" .. turn,
          status = allowed and "completed" or "failed",
        })
        -- The agent resumes only after the answer: a closing note, the plan
        -- finalised, then the turn ends.
        vim.defer_fn(function()
          h.on_session_update({
            sessionUpdate = "agent_message_chunk",
            content = {
              text = allowed and "\n\nDone — the edit is applied."
                or "\n\nUnderstood — I left that file untouched.",
            },
          })
          h.on_session_update({
            sessionUpdate = "plan",
            entries = {
              { content = "inspect the request", status = "completed" },
              { content = "apply the edit", status = allowed and "completed" or "failed" },
              { content = "report back", status = "completed" },
            },
          })
          vim.defer_fn(end_turn, 300)
        end, 250)
      end)
    end)
  else
    at(800, end_turn)
  end
end

function client:cancel_turn(_sid) end
function client:cancel_session(_sid) end

-- Two canned saved sessions so ;;r has something to pick from; loading one
-- replays a short history through the normal handlers, like session/load.
function client:list_sessions(_cwd, callback)
  callback({
    sessions = {
      { sessionId = "saved-1", title = "Refactor the panel shell", updatedAt = "2026-07-04T18:12:00Z" },
      { sessionId = "saved-2", title = "Chase the wheel-scroll bug", updatedAt = "2026-07-03T09:40:00Z" },
    },
  }, nil)
end

function client:load_session(session_id, _cwd, _mcp, handlers, on_complete)
  self._handlers[session_id] = handlers
  handlers.on_session_update({
    sessionUpdate = "user_message_chunk",
    content = { type = "text", text = "What did we do in '" .. session_id .. "'?" },
  })
  handlers.on_session_update({
    sessionUpdate = "agent_message_chunk",
    content = {
      text = "This conversation was restored from disk — the provider replayed its history through the ordinary session updates, and the panel rendered it without spinning up the activity status.",
    },
  })
  on_complete(nil, {
    models = { currentModelId = "scripted", availableModels = { { modelId = "scripted", name = "Scripted" } } },
  })
end

-- ── Something to comment on ──────────────────────────────────────────────────
-- Inline code feedback needs real code in a real buffer. The sample is written
-- into a fresh temp dir (NOT read out of the nix store) and made the cwd, so
-- it is writable and the paths weave shows are short relative ones rather than
-- a /nix/store/... mouthful.

local SAMPLE = [[
local M = {}

local cache = {}

--- Look up a user by id, memoized.
function M.get_user(id)
  if cache[id] then
    return cache[id]
  end
  local row = M.db:query("SELECT * FROM users WHERE id = " .. id)
  cache[id] = row
  return row
end

--- Everyone in a team. Fans out one query per member.
function M.team_members(team_id)
  local ids = M.db:query("SELECT user_id FROM teams WHERE id = " .. team_id)
  local out = {}
  for _, id in ipairs(ids) do
    out[#out + 1] = M.get_user(id)
  end
  return out
end

function M.invalidate()
  cache = {}
end

return M
]]

local demo_dir = vim.fn.tempname()
vim.fn.mkdir(demo_dir, "p")
local sample = demo_dir .. "/users.lua"
vim.fn.writefile(vim.split(SAMPLE, "\n"), sample)
vim.cmd.cd(demo_dir)
vim.cmd.edit(sample)

-- weave binds nothing globally by design (see README), so the demo does it —
-- which doubles as the copy-pasteable example.
local feedback = require("weave.feedback")
vim.keymap.set("n", ";;cc", feedback.comment_line, { desc = "weave: comment this line" })
vim.keymap.set("x", ";;cc", feedback.comment_selection, { desc = "weave: comment this selection" })
vim.keymap.set("n", ";;ce", feedback.edit_comment, { desc = "weave: edit the comment here" })
vim.keymap.set("n", ";;cs", function()
  feedback.send()
end, { desc = "weave: send the code feedback" })

-- ── Open it ──────────────────────────────────────────────────────────────────

weave.setup({})
weave.open({
  get_instance = function(_name, on_ready)
    on_ready(client)
    return client
  end,
})
