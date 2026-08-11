-- Toggling a running agent between sandbox modes (formerly
-- profile_transition; collapsed by design-agent-sandbox-v2.md phase F).
--
-- The mode is baked into the bwrap argv at spawn (acp_client.lua's
-- transport setup), so it cannot change on a live process. The on/off
-- toggle is therefore the ONE remaining restart in the sandbox design —
-- preset switches and elevation grants apply to the next tool spawn with no
-- restart — and this module exists to make that cost explicit before it is
-- paid rather than after.
--
-- Confinement is never reduced without an explicit, direction-specific
-- confirmation; a user who skims the tightening prompt loses a
-- conversation, a user who skims the loosening prompt loses the guarantee
-- they turned the sandbox on for.

local Permissions = require("weave.permissions")

local M = {}

-- What each mode actually gives the agent, said in the user's terms:
-- "reduces confinement" is a category, "your whole filesystem" is a
-- consequence.
local GRANTS = {
  off = "running unsandboxed, with your whole filesystem and nvim's own RPC socket",
  on = "no direct access to anything; every effect flows through the sandboxed weave tools",
}

--- Which way the mode has to move.
--- @param from string
--- @param to string
--- @return "tighten"|"loosen"|"none"
function M.direction(from, to)
  if from == to then
    return "none"
  end
  return to == "on" and "tighten" or "loosen"
end

--- The confirmation text for a transition. Built from the direction and the
--- provider's loadSession capability, never from a template: the two
--- decisions are different, and skimming either one costs something
--- different.
--- @param opts { from: string, to: string, load_session: boolean }
--- @return { title: string, prompt: string }
function M.confirmation(opts)
  local restart
  if opts.load_session then
    restart = "The agent will restart and this session will be restored."
  else
    restart = "The agent will restart. **This provider cannot restore sessions, "
      .. "so this conversation will be lost.**"
  end

  if M.direction(opts.from, opts.to) == "loosen" then
    return {
      title = "Turn the sandbox off?",
      prompt = ("This will REDUCE the agent's confinement: %s.\n\n%s"):format(GRANTS.off, restart),
    }
  end

  return {
    title = "Restart agent inside the sandbox?",
    prompt = ("%s\n\nThe agent then runs fully confined (%s)."):format(restart, GRANTS.on),
  }
end

--- ── Seams ───────────────────────────────────────────────────────────────────
--- Both are replaced wholesale in specs; the defaults are the real UI and the
--- real restart.

--- @param opts { title: string, prompt: string }
--- @param callback fun(accepted: boolean)
local function default_confirm(opts, callback)
  vim.ui.select({ "Yes", "No" }, { prompt = opts.title .. "\n" .. opts.prompt }, function(choice)
    callback(choice == "Yes")
  end)
end

--- Restart the selected session's agent under `mode`, restoring the
--- conversation when the provider can.
--- @param mode string
--- @param callback fun(ok: boolean)
local function default_restart(mode, callback)
  local Registry = require("weave.registry")
  local AgentInstance = require("weave.acp.agent_instance")
  local entry = Registry.selected() or Registry.list()[1]
  if not entry then
    -- Nothing running: the mode applies to whatever spawns next.
    AgentInstance.set_mode_override(nil, mode)
    return callback(true)
  end

  local restore = M.load_session_supported() and entry.session:session_id() or nil
  AgentInstance.set_mode_override(entry.provider, mode)

  -- No stop() here. Processes are keyed (provider, mode), so the new
  -- session lands on a new process by construction, and killing the old one
  -- would take down any OTHER session still sitting in it. reap() collects
  -- it afterwards, once closing this session has made it an orphan.
  local ok, err = pcall(function()
    local fresh = Registry.add({ provider = entry.provider, restore = restore })
    Registry.select(fresh.key)
    Registry.close(entry.key)
    AgentInstance.reap()
  end)
  if not ok then
    require("weave.utils.logger").notify("weave: agent restart failed — " .. tostring(err), vim.log.levels.ERROR)
  end
  callback(ok)
end

--- Restart the agent under `mode`, confirmed in the direction it moves.
--- This is the ONLY path that loosens confinement — never a preset
--- selection, never a grant. Someone reaching this has gone looking for it.
--- @param mode "on"|"off"
--- @param callback? fun(ok: boolean)
function M.request_mode(mode, callback)
  local from = Permissions.current_mode()
  if from == mode then
    return callback and callback(true)
  end
  M._confirm(M.confirmation({ from = from, to = mode, load_session = M.load_session_supported() }), function(ok)
    if not ok then
      return callback and callback(false)
    end
    M._restart(mode, function(restarted)
      if callback then
        callback(restarted)
      end
    end)
  end)
end

--- Whether the running provider can bring the conversation back across the
--- restart. Unknown means no: promising a restore we cannot deliver is the
--- one failure this whole flow exists to avoid.
--- @return boolean
function M.load_session_supported()
  local ok, Registry = pcall(require, "weave.registry")
  if not ok then
    return false
  end
  local entry = Registry.selected() or Registry.list()[1]
  local client = entry and entry.session and entry.session:client()
  local caps = client and client.agent_capabilities
  return (caps and caps.loadSession) == true
end

M._confirm = default_confirm
M._restart = default_restart

-- test hook: back to the real seams
function M._reset()
  M._confirm = default_confirm
  M._restart = default_restart
end

return M
