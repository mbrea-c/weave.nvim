-- Per-panel view preferences: UI-only state, deliberately separate from the
-- SessionStore (which mirrors ACP — these are presentation choices). Same
-- contract as the session store — `.state` reassigned per mutation, keys
-- unchanged keep identity, subscribe/notify fires once per mutation — so the
-- view's use_store hook subscribes to either interchangeably.
--
--   show_thoughts    — render agent thought entries in the transcript
--   show_diffs       — render edit tool-call diff previews
--   conceal_markdown — hide markdown markers in settled agent prose (the
--                      markdown component omits the concealed bytes from its
--                      spans — no window conceallevel involved)
--   follow           — keep the transcript scrolled to the bottom while
--                      content streams in (panel-owned autoscroll)

--- @class clanker.view.PrefsState
--- @field show_thoughts boolean
--- @field show_diffs boolean
--- @field conceal_markdown boolean
--- @field follow boolean

--- @class clanker.view.Prefs
--- @field state clanker.view.PrefsState
--- @field _subscribers fun(state: clanker.view.PrefsState)[]
local Prefs = {}
Prefs.__index = Prefs

--- @return clanker.view.Prefs
function Prefs:new()
  return setmetatable({
    state = {
      show_thoughts = true,
      show_diffs = true,
      conceal_markdown = true,
      follow = true,
    },
    _subscribers = {},
  }, self)
end

--- Subscribe to preference changes; returns an unsubscribe function.
--- @param fn fun(state: clanker.view.PrefsState)
--- @return fun() unsubscribe
function Prefs:subscribe(fn)
  local subs = self._subscribers
  subs[#subs + 1] = fn
  return function()
    for i, f in ipairs(subs) do
      if f == fn then
        table.remove(subs, i)
        return
      end
    end
  end
end

--- Assign one preference (reassigning state) and notify.
--- @param key string One of the PrefsState keys
--- @param value boolean
function Prefs:set(key, value)
  if self.state[key] == nil then
    error("clanker: unknown view pref '" .. tostring(key) .. "'")
  end
  local draft = {}
  for k, v in pairs(self.state) do
    draft[k] = v
  end
  draft[key] = value
  self.state = draft
  for _, fn in ipairs({ unpack(self._subscribers) }) do
    fn(draft)
  end
end

--- Flip one preference.
--- @param key string One of the PrefsState keys
function Prefs:toggle(key)
  if self.state[key] == nil then
    error("clanker: unknown view pref '" .. tostring(key) .. "'")
  end
  self:set(key, not self.state[key])
end

return Prefs
