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
local function default_restart(mode, callback, session)
  local Registry = require("weave.registry")
  local AgentInstance = require("weave.acp.agent_instance")
  if not session then
    AgentInstance.set_mode_override(nil, mode)
    return callback(true)
  end
  if not Registry.entry_for(session) then return callback(false) end
  local restore = M.load_session_supported(session) and session:session_id() or nil
  local ok, err = pcall(function()
    -- Retain the registry key, parent, configuration and policy. Stop only this
    -- ACP conversation, never the process serving its siblings.
    session:cancel()
    session:stop()
    session:get_store():reset()
    session._agent_sandbox_mode = mode
    session:start({ restore = restore })
    AgentInstance.reap()
  end)
  if not ok then
    require("weave.utils.logger").notify("weave: agent restart failed: " .. tostring(err), vim.log.levels.ERROR)
  end
  callback(ok)
end

--- Restart the agent under `mode`, confirmed in the direction it moves.
--- This is the ONLY path that loosens confinement — never a preset
--- selection, never a grant. Someone reaching this has gone looking for it.
--- @param mode "on"|"off"
--- @param callback? fun(ok: boolean)
function M.request_mode(mode, callback, session)
  if mode ~= "on" and mode ~= "off" then error("invalid agent sandbox mode", 0) end
  local Registry = require("weave.registry")
  if session and not Registry.entry_for(session) then return callback and callback(false) end
  local entry = session and Registry.entry_for(session) or Registry.selected()
  session = entry and entry.session
  local generation = session and session._config_session
  local policy = session and session:permissions() or Permissions
  local from = policy.current_mode()
  if from == mode then return callback and callback(true) end
  local answered = false
  M._confirm(M.confirmation({ from = from, to = mode, load_session = M.load_session_supported(session) }), function(ok)
    if answered then return end
    answered = true
    if not ok or session and (Registry.entry_for(session) ~= entry or session._config_session ~= generation) then
      return callback and callback(false)
    end
    M._restart(mode, function(restarted)
      if callback then callback(restarted) end
    end, session)
  end)
end

--- Whether the running provider can bring the conversation back across the
--- restart. Unknown means no: promising a restore we cannot deliver is the
--- one failure this whole flow exists to avoid.
--- @return boolean
function M.load_session_supported(session)
  local ok, Registry = pcall(require, "weave.registry")
  if not ok then return false end
  local entry = not session and Registry.selected() or nil
  session = session or entry and entry.session
  local client = session and session:client()
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
