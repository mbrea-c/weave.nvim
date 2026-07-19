-- Moving a running agent between sandbox profiles (design-permission-presets.md,
-- parts 3 and 4).
--
-- The profile is baked into the bwrap argv at spawn (acp_client.lua's
-- transport setup), so it cannot be relaxed or tightened on a live process.
-- Every transition is therefore a RESTART, and this module exists to make
-- that cost explicit before it is paid rather than after.
--
-- Two invariants it holds:
--
--   * Selection is STAGED, never applied and reverted. If the active preset
--     changed first, an MCP call landing in the confirmation window would
--     resolve against rules the user has not agreed to.
--   * Confinement is never reduced without an explicit, direction-specific
--     confirmation. Not by ;;p (which skips incompatible presets silently),
--     not by a preset selection, not by a grant.

local Permissions = require("weave.permissions")

local M = {}

-- What each profile actually gives the agent, said in the user's terms. Used
-- to make a loosening warning concrete: "reduces confinement" is a category,
-- "direct read and write access to the project" is a consequence.
local GRANTS = {
  off = "running unsandboxed, with your whole filesystem",
  workspace = "direct read and write access to the project",
  readonly = "direct read access to the project",
  blackbox = "no direct access to the project at all",
}

--- Which way the profile has to move.
--- @param from string
--- @param to string
--- @return "tighten"|"loosen"|"none"
function M.direction(from, to)
  local a, b = Permissions.profile_rank(from), Permissions.profile_rank(to)
  if b > a then
    return "tighten"
  elseif b < a then
    return "loosen"
  end
  return "none"
end

--- The profile this preset needs, or nil when `current` already satisfies it.
--- A requirement names exactly one profile, so an unmet requirement in any
--- mode resolves to that one.
--- @param preset weave.permissions.Preset
--- @param current? string
--- @return string|nil
function M.target_for(preset, current)
  current = current or Permissions.current_profile()
  if Permissions.preset_compatible(preset, current) then
    return nil
  end
  return preset.sandbox.profile
end

--- The confirmation text for a transition. Built from the direction and the
--- provider's loadSession capability, never from a template: the two
--- decisions are different, and skimming either one costs something
--- different. A user who skims the tightening prompt loses a conversation; a
--- user who skims the loosening prompt loses the guarantee they turned the
--- sandbox on for.
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
      title = "Reduce sandbox confinement?",
      prompt = ("This will REDUCE the agent's confinement from `%s` to `%s`, giving it %s.\n\n%s"):format(
        opts.from,
        opts.to,
        GRANTS[opts.to] or "more access",
        restart
      ),
    }
  end

  return {
    title = "Restart agent under a stricter sandbox?",
    prompt = ("%s\n\nThe agent's confinement goes from `%s` to `%s` (%s)."):format(
      restart,
      opts.from,
      opts.to,
      GRANTS[opts.to] or "stricter"
    ),
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

--- Restart the selected session's agent under `profile`, restoring the
--- conversation when the provider can.
--- @param profile string
--- @param callback fun(ok: boolean)
local function default_restart(profile, callback)
  local Registry = require("weave.registry")
  local AgentInstance = require("weave.acp.agent_instance")
  local entry = Registry.selected() or Registry.list()[1]
  if not entry then
    -- Nothing running: the profile applies to whatever spawns next.
    AgentInstance.set_profile_override(nil, profile)
    return callback(true)
  end

  local restore = M.load_session_supported() and entry.session:session_id() or nil
  AgentInstance.set_profile_override(entry.provider, profile)
  AgentInstance.stop(entry.provider)

  local ok, err = pcall(function()
    local fresh = Registry.add({ provider = entry.provider, restore = restore })
    Registry.select(fresh.key)
    Registry.close(entry.key)
  end)
  if not ok then
    require("weave.utils.logger").notify("weave: agent restart failed — " .. tostring(err), vim.log.levels.ERROR)
  end
  callback(ok)
end

--- Make `name` active, going through a confirmed restart first when its
--- sandbox requirement is unmet. This is what a row activation in the
--- permissions window calls.
--- @param name string
function M.select_preset(name)
  local preset = Permissions.get(name)
  if not preset then
    error(("weave.profile_transition: unknown preset %q"):format(name), 0)
  end
  local target = M.target_for(preset)
  if not target then
    return Permissions.set_active(name)
  end

  local from = Permissions.current_profile()
  M._confirm(M.confirmation({ from = from, to = target, load_session = M.load_session_supported() }), function(ok)
    if not ok then
      return -- staged, never applied
    end
    M._restart(target, function(restarted)
      if restarted then
        Permissions.set_active(name)
      end
    end)
  end)
end

--- Restart the agent under `profile`, confirmed in the direction it moves.
--- This is the ONLY path that loosens confinement: never `;;p`, never a
--- preset selection under or_stricter (the mode almost every preset uses),
--- never a grant. Someone reaching this has gone looking for it.
--- @param profile string
--- @param callback? fun(ok: boolean)
function M.request_profile(profile, callback)
  local from = Permissions.current_profile()
  if from == profile then
    return callback and callback(true)
  end
  M._confirm(M.confirmation({ from = from, to = profile, load_session = M.load_session_supported() }), function(ok)
    if not ok then
      return callback and callback(false)
    end
    M._restart(profile, function(restarted)
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
