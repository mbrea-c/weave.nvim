-- weave.briefs: standing instruction profiles for a conversation — the
-- `brief` session setting made real on the agent side.
--
-- A brief is words, and words only exist in a CONVERSATION: switch mid-flight
-- and the agent must be told, /new and the fresh conversation has never heard
-- them. So this module tracks, per session, which brief the current
-- conversation has actually HEARD (delivery-confirmed, like edit_sync's
-- cursor), and closes the gap whenever the two drift: on a settings change,
-- and at every conversation start (session.lua calls on_conversation_ready
-- from its three ready sites — start, /new, restore). That construction is
-- what fixes the old tutor gap where /new silently forgot the mode.
--
-- The builtin default brief ("normal") is the silent baseline: a fresh
-- conversation is born normal, so there is nothing to announce — its prompt
-- exists only for the TRANSITION back from something else. A user-configured
-- default (Config.settings.defaults.brief) is not baseline: they changed what
-- a conversation should be, so every fresh conversation is told.

local Config = require("weave.config")
local Settings = require("weave.settings")

local M = {}

--- @class weave.briefs.State
--- @field announced string The brief the CURRENT conversation last heard

--- Per-session, weak-keyed like edit_sync's states.
--- @type table<table, weave.briefs.State>
local states = setmetatable({}, { __mode = "k" })
--- @type table<table, boolean>
local watched = setmetatable({}, { __mode = "k" })

--- @return table<string, weave.BriefConfig>
local function briefs_config()
  return (Config.settings or {}).briefs or {}
end

--- The silent baseline every fresh conversation starts at — the REGISTRY
--- default, deliberately not the config-overridden one (see header).
--- @return string
local function baseline()
  return Settings.spec("brief").default --[[@as string]]
end

--- @param session table
--- @return weave.briefs.State
local function state_of(session)
  local st = states[session]
  if not st then
    st = { announced = baseline() }
    states[session] = st
  end
  return st
end

--- Close the gap between the brief this session's settings want and the one
--- its conversation has heard. Delivery-confirmed: `announced` moves only in
--- on_sent, so a refusal (not ready yet) or a drop (steer queue wiped) leaves
--- the gap open for the next trigger — and a drop retries itself once the
--- wipe settles, since cancel is exactly the moment a parked announcement
--- dies.
--- @param session table
function M.ensure(session)
  if type(session.send_system) ~= "function" then
    return
  end
  local st = state_of(session)
  local want = Settings.for_session(session):get("brief")
  if st.announced == want then
    return
  end
  local brief = briefs_config()[want]
  local prompt = brief and brief.prompt
  if type(prompt) ~= "string" or prompt == "" then
    -- a brief with nothing to say costs nothing to have "heard"
    st.announced = want
    return
  end
  session:send_system({
    text = prompt,
    label = "brief: " .. want,
    interrupt = true,
    on_sent = function()
      st.announced = want
    end,
    on_dropped = function()
      vim.schedule(function()
        M.ensure(session)
      end)
    end,
  })
end

--- A conversation just (re)started — /new, restore, or first start. Whatever
--- the previous conversation heard, this one heard nothing: reset to the
--- baseline and re-announce if the settings want more.
--- @param session table
function M.on_conversation_ready(session)
  state_of(session).announced = baseline()
  M.ensure(session)
end

--- Follow this session's settings store (weak ref — see edit_sync.watch for
--- why a strong capture would pin the session). Idempotent.
--- @param session table
function M.watch(session)
  if watched[session] then
    return
  end
  watched[session] = true
  local store = Settings.for_session(session)
  local ref = setmetatable({ session }, { __mode = "v" })
  store:subscribe(function()
    local s = ref[1]
    if s then
      M.ensure(s)
    end
  end)
  M.ensure(session)
end

--- @param session table
--- @return string|nil
function M._announced(session)
  local st = states[session]
  return st and st.announced or nil
end

-- test hook
function M._reset()
  states = setmetatable({}, { __mode = "k" })
  watched = setmetatable({}, { __mode = "k" })
end

return M
