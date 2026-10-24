-- Editor-global session ownership forest, indexed by stable registry keys.
-- UI selection is independent of ownership and never establishes authority.
local Config = require("weave.config")
local Session = require("weave.session")
local Settings = require("weave.settings")
local M = {}
local entries, selections, on_close_fns, subscribers = {}, {}, {}, {}
local next_key = 0

local function notify()
  for _, fn in ipairs({ unpack(subscribers) }) do fn() end
end

-- Explicit runtime changes (for example a provisioning failure) have no store mutation.
M.changed = notify

function M.subscribe(fn)
  subscribers[#subscribers + 1] = fn
  return function()
    for i, value in ipairs(subscribers) do
      if value == fn then table.remove(subscribers, i); break end
    end
  end
end

function M.list()
  return { unpack(entries) }
end

function M.get(key)
  for _, entry in ipairs(entries) do if entry.key == key then return entry end end
end

function M.entry_for(session)
  for _, entry in ipairs(entries) do if entry.session == session then return entry end end
end

function M.is_descendant(key, parent_key)
  local entry, seen = M.get(key), {}
  while entry and entry.parent_key and not seen[entry.key] do
    seen[entry.key] = true
    if entry.parent_key == parent_key then return true end
    entry = M.get(entry.parent_key)
  end
  return false
end

function M.children(key, recursive)
  local out = {}
  for _, entry in ipairs(entries) do
    if entry.parent_key == key or (recursive and M.is_descendant(entry.key, key)) then
      out[#out + 1] = entry
    end
  end
  return out
end

function M.roots()
  local out = {}
  for _, entry in ipairs(entries) do if not entry.parent_key then out[#out + 1] = entry end end
  return out
end

local function check_limits(parent)
  local limits = Config.subagents or {}
  local depth, root = 1, parent
  while root.parent_key do depth = depth + 1; root = assert(M.get(root.parent_key)) end
  if depth > (limits.max_depth or 4) then error("subagent maximum depth exceeded", 0) end
  if #M.children(parent.key) >= (limits.max_children or 8) then error("subagent child limit exceeded", 0) end
  if #M.children(root.key, true) + 1 >= (limits.max_sessions or 32) then error("subagent session limit exceeded", 0) end
end

--- Create and start a managed session. This trusted Lua API may name a parent;
--- agent-facing creation derives the parent from authenticated call context.
function M.add(opts)
  opts = opts or {}
  local parent
  if opts.parent_key ~= nil then
    parent = M.get(opts.parent_key)
    if not parent or parent.closing then error("unknown or closing parent session", 0) end
    check_limits(parent)
  end
  next_key = next_key + 1
  local entry = {
    key = next_key, parent_key = parent and parent.key,
    session = Session:new({
      provider = opts.provider or parent and parent.provider,
      config_defaults = opts.config_defaults, get_instance = opts.get_instance,
      permissions = opts.permissions, permission_base = opts.permission_base or parent and parent.session:permissions(),
      agent_sandbox_mode = opts.agent_sandbox_mode or parent and parent.session:permissions().current_mode(),
    }),
    prefs = Settings.new_view(),
    provider = opts.provider or parent and parent.provider or Config.provider,
  }
  entries[#entries + 1] = entry
  entry._unsubscribe = entry.session:get_store():subscribe(notify)
  entry.session._on_registry_reset = function()
    for _, child in ipairs(M.children(entry.key)) do M.close(child.key) end
  end
  require("weave.edit_sync").watch(entry.session)
  require("weave.briefs").watch(entry.session)
  notify()
  local ok, err = pcall(entry.session.start, entry.session, opts.restore and { restore = opts.restore } or nil)
  if not ok then M.close(entry.key); error(err, 0) end
  return entry
end

function M.select(key, tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  selections[tab] = key
  notify()
end

function M.selected(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  return M.get(selections[tab])
end

function M.on_close(fn)
  on_close_fns[#on_close_fns + 1] = fn
  return function()
    for i, value in ipairs(on_close_fns) do
      if value == fn then table.remove(on_close_fns, i); break end
    end
  end
end

--- Explicit close removes a whole subtree, deepest children first.
function M.close(key)
  local entry = M.get(key)
  if not entry or entry.closing then return end
  entry.closing = true
  for _, child in ipairs(M.children(key)) do M.close(child.key) end
  for i, value in ipairs(entries) do
    if value == entry then table.remove(entries, i); break end
  end
  for tab, selected in pairs(selections) do if selected == key then selections[tab] = nil end end
  if entry._unsubscribe then entry._unsubscribe() end
  entry.session._on_registry_reset = nil
  entry.session:cancel()
  entry.session:stop()
  for _, fn in ipairs({ unpack(on_close_fns) }) do fn(entry) end
  notify()
end

function M.reset()
  while entries[1] do M.close(entries[1].key) end
  selections = {}
end

return M
