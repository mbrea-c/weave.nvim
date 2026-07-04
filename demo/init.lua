-- Demo entry point: a clean Neovim (`nvim --clean -u demo/init.lua`, or
-- `make demo` / `nix run .#demo`) with clanker and fibrous on the path.
--
-- Opens the real panel (roadmap R5) against a SCRIPTED agent: every prompt
-- you submit streams a thought + a prose reply, runs a tool call, and every
-- second prompt makes an edit that asks for permission. All the panel
-- machinery is live — try:
--   <CR>/<C-s> submit · <C-x> steer · <C-c> cancel · <CR>/za on a tool call
--   zR/zM expand/collapse all · ;;t ;;d ;;c ;;f view prefs · ;;p permission
--   mode · ;;1..;;9 answer permissions · /new fresh conversation · :qa quits

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

local clanker = require("clanker")

-- ── The scripted agent ───────────────────────────────────────────────────────
-- A fake ACP client: create_session hands us the bridge handlers, and each
-- send_prompt plays a little timeline through them (thought, streamed prose,
-- tool calls, a permission request on every second turn), then ends the turn.

local REPLY = "Sure — I looked at the request and here is what I found. "
  .. "The store drives every component you see: this prose is streaming "
  .. "through the same code path a real ACP agent would use, one chunk per "
  .. "tick, coalesced into a single transcript entry."

local client = {
  state = "connected",
  agent_info = { name = "scripted-agent", version = "0.1" },
  _turn = 0,
}

function client:create_session(handlers, callback, _mcp)
  self.handlers = handlers
  callback({
    sessionId = "demo-session",
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

function client:send_prompt(_sid, _prompt, callback)
  self._turn = self._turn + 1
  local turn = self._turn
  local h = self.handlers
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
  end)

  -- Stream the reply word by word.
  for word in REPLY:gmatch("%S+ ?") do
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

  if turn % 2 == 0 then
    -- Every second turn: an edit that needs permission.
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
      end)
    end)
    at(200, function()
      h.on_session_update({
        sessionUpdate = "plan",
        entries = {
          { content = "inspect the request", status = "completed" },
          { content = "apply the edit", status = "in_progress" },
          { content = "report back", status = "pending" },
        },
      })
    end)
  end

  at(800, function()
    callback({ stopReason = "end_turn" }, nil)
  end)
end

function client:cancel_turn(_sid) end
function client:cancel_session(_sid) end

-- ── Open it ──────────────────────────────────────────────────────────────────

clanker.setup({})
clanker.open({
  get_instance = function(_name, on_ready)
    on_ready(client)
    return client
  end,
})
