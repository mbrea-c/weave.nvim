-- The session registry: the editor-GLOBAL list of active sessions, plus the
-- per-tabpage pointer to the one the panel shows there. An "active" session
-- is a running conversation — its agent process may be shared with other
-- sessions of the same provider (AgentInstance), and different entries may
-- use DIFFERENT providers. Entries outlive panels and tabs: closing an entry
-- is the only thing that stops its conversation.
--
-- Each entry owns its Session AND its view Prefs — both live exactly as long
-- as the entry, so view toggles survive panel close/reopen. The registry has
-- no UI of its own; init.lua orchestrates panels, and the session modal
-- renders/list-manages what lives here.

local Config = require("weave.config")
local Prefs = require("weave.view.prefs")
local Session = require("weave.session")

--- @class weave.registry.Entry
--- @field key integer Stable handle (monotonic, never reused)
--- @field session weave.Session
--- @field prefs weave.view.Prefs
--- @field provider string Provider key the session was created with

local M = {}

--- @type weave.registry.Entry[]
local entries = {}
--- @type table<integer, integer> tabpage handle → entry key
local selections = {}
--- @type fun(entry: weave.registry.Entry)[]
local on_close_fns = {}
local next_key = 0

--- Create + start a session and register it. With `restore`, the new session
--- activates a saved conversation (session/load) instead of creating a fresh
--- one. Does NOT select it anywhere — callers pair add() with select().
--- @param opts { provider?: string, get_instance?: function, restore?: string }|nil
--- @return weave.registry.Entry entry
function M.add(opts)
  opts = opts or {}
  next_key = next_key + 1
  local entry = {
    key = next_key,
    session = Session:new({ provider = opts.provider, get_instance = opts.get_instance }),
    prefs = Prefs:new(),
    provider = opts.provider or Config.provider,
  }
  entries[#entries + 1] = entry
  entry.session:start(opts.restore and { restore = opts.restore } or nil)
  return entry
end

--- Snapshot of the active entries, in creation order.
--- @return weave.registry.Entry[]
function M.list()
  local out = {}
  for i, e in ipairs(entries) do
    out[i] = e
  end
  return out
end

--- @param key integer
--- @return weave.registry.Entry|nil
function M.get(key)
  for _, e in ipairs(entries) do
    if e.key == key then
      return e
    end
  end
  return nil
end

--- Select `key` for a tabpage (default: the current one); nil clears.
--- @param key integer|nil
--- @param tab integer|nil tabpage handle
function M.select(key, tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  selections[tab] = key
end

--- The entry selected in a tabpage (default: the current one), if any.
--- @param tab integer|nil tabpage handle
--- @return weave.registry.Entry|nil
function M.selected(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  local key = selections[tab]
  return key and M.get(key) or nil
end

--- Register a listener fired when an entry is closed (init tears down any
--- panel bound to it).
--- @param fn fun(entry: weave.registry.Entry)
--- @return fun() unsubscribe
function M.on_close(fn)
  on_close_fns[#on_close_fns + 1] = fn
  return function()
    for i, f in ipairs(on_close_fns) do
      if f == fn then
        table.remove(on_close_fns, i)
        return
      end
    end
  end
end

--- Close an entry: cancel any in-flight turn, cancel the ACP session, drop it
--- from the registry and from every tab's selection. Listeners run AFTER the
--- removal, so they observe consistent registry state.
--- @param key integer
function M.close(key)
  for i, e in ipairs(entries) do
    if e.key == key then
      table.remove(entries, i)
      for tab, k in pairs(selections) do
        if k == key then
          selections[tab] = nil
        end
      end
      e.session:cancel()
      e.session:stop()
      for _, fn in ipairs(on_close_fns) do
        fn(e)
      end
      return
    end
  end
end

--- Close everything (spec teardown). Listeners survive — init.lua registers
--- its panel-teardown hook once at load, and it must outlive any reset.
function M.reset()
  while entries[1] do
    M.close(entries[1].key)
  end
  selections = {}
end

return M
