-- The keybinding surface: every key weave binds is a NAMED ACTION whose
-- key(s) come from Config.keys, so a user rebinds or disables any of them in
-- setup() without touching view code. View modules never call vim.keymap.set
-- for their own keys — they ask this module by action name, and a typo'd name
-- fails loudly instead of silently binding nothing.
--
-- A config value is one of (weave.UserConfig.KeymapValue):
--   ";;x"                       one binding, the action's default modes
--   { ";;x", "<F5>" }           several bindings
--   { { ";;x", mode = "i" } }   an entry carrying its own mode(s)
--   false (or {})               action disabled
-- An entry WITHOUT `mode` keeps the action's default modes — rebinding
-- `submit` must not silently drop its insert-mode half.

local BufHelpers = require("weave.utils.buf_helpers")
local Config = require("weave.config")

local M = {}

--- @class weave.keys.Entry a normalized binding
--- @field lhs string
--- @field mode string[]

--- @class weave.keys.Action
--- @field name string the Config.keys field
--- @field scope "panel"|"prompt"|"transcript"|"float"
--- @field desc string keymap description ("weave: " is prefixed)

--- Where an action's keys are bound (each with its default modes):
---   panel      every panel buffer (root canvas, transcript, prompt input); n
---   prompt     the prompt input buffer; n + i
---   transcript entries in the transcript, via fibrous on_key routing; n
---   float      weave's floating windows (modals, peek, task list); n
M.SCOPES = { panel = true, prompt = true, transcript = true, float = true }

local SCOPE_MODES = {
  panel = { "n" },
  prompt = { "n", "i" },
  transcript = { "n" },
  float = { "n" },
}

--- Every action weave binds, in documentation order. Defaults live in
--- Config.keys (config_default.lua), one field per name.
--- @type weave.keys.Action[]
M.ACTIONS = {
  -- panel chords (every panel buffer, so they work wherever the user is)
  { name = "toggle_thoughts", scope = "panel", desc = "toggle thinking" },
  { name = "toggle_diffs", scope = "panel", desc = "toggle edit diffs" },
  { name = "toggle_conceal", scope = "panel", desc = "toggle markdown conceal" },
  { name = "toggle_follow", scope = "panel", desc = "toggle follow streaming" },
  { name = "cycle_permission_mode", scope = "panel", desc = "cycle permission preset" },
  { name = "pick_model", scope = "panel", desc = "pick model" },
  { name = "pick_mode", scope = "panel", desc = "pick mode" },
  { name = "restore_session", scope = "panel", desc = "restore a saved session" },
  { name = "sessions", scope = "panel", desc = "open the session modal" },
  { name = "expand_all", scope = "panel", desc = "expand all tool calls" },
  { name = "collapse_all", scope = "panel", desc = "collapse all tool calls" },
  { name = "cancel", scope = "panel", desc = "cancel the running turn" },
  -- not a binding itself: <prefix>1 … <prefix>9 answer permission option N
  { name = "permission_prefix", scope = "panel", desc = "answer permission option" },

  -- the prompt input (insert AND normal mode by default)
  { name = "submit", scope = "prompt", desc = "submit" },
  { name = "steer", scope = "prompt", desc = "steer (interrupt + send)" },
  { name = "recall_older", scope = "prompt", desc = "recall previous prompt / edit queued" },
  { name = "recall_newer", scope = "prompt", desc = "recall next prompt" },

  -- transcript entries (fibrous on_key routing, not buffer keymaps)
  { name = "peek", scope = "transcript", desc = "peek raw source" },
  -- rebound to the activation <CR> performs (tool-call folds are store state)
  { name = "toggle_tool_call", scope = "transcript", desc = "toggle tool call" },

  -- weave's floating windows (session modal/details, peek, full task list)
  { name = "close_float", scope = "float", desc = "close window" },
}

--- @type table<string, weave.keys.Action>
local BY_NAME = {}
for _, action in ipairs(M.ACTIONS) do
  BY_NAME[action.name] = action
end

--- @param name string
--- @return weave.keys.Action
local function action_of(name)
  local action = BY_NAME[name]
  if not action then
    error(("weave.keys: unknown action %q"):format(name), 3)
  end
  return action
end

--- @param mode string|string[]|nil
--- @param fallback string[]
--- @return string[]
local function normalize_mode(mode, fallback)
  if mode == nil then
    mode = fallback
  elseif type(mode) == "string" then
    return { mode }
  end
  return vim.list_slice(mode) -- a copy: callers must not alias the defaults
end

--- The normalized bindings of `name` from Config.keys (read at call time, so
--- setup() overrides apply to everything bound afterwards). {} = disabled.
--- @param name string
--- @return weave.keys.Entry[]
function M.get(name)
  local action = action_of(name)
  local value = Config.keys[name]
  if value == false or value == nil then
    return {}
  end
  if type(value) == "string" or (type(value) == "table" and value.mode) then
    value = { value }
  end
  local fallback = SCOPE_MODES[action.scope]
  local out = {}
  for _, v in
    ipairs(value --[[@as (string|table)[] ]])
  do
    if type(v) == "string" then
      out[#out + 1] = { lhs = v, mode = normalize_mode(nil, fallback) }
    else
      out[#out + 1] = { lhs = v[1], mode = normalize_mode(v.mode, fallback) }
    end
  end
  return out
end

--- Bind `name` on `bufnr`: every configured lhs, in its modes. `rhs` is a
--- function or a mapping string (vim.keymap.set semantics); `opts` merges
--- over the action's desc (e.g. { nowait = true }, { remap = true }).
--- @param bufnr integer
--- @param name string
--- @param rhs string|fun()
--- @param opts vim.keymap.set.Opts|nil
function M.map(bufnr, name, rhs, opts)
  local action = action_of(name)
  for _, entry in ipairs(M.get(name)) do
    local o = vim.tbl_extend("force", { desc = "weave: " .. action.desc }, opts or {})
    BufHelpers.keymap_set(bufnr, entry.mode, entry.lhs, rhs, o)
  end
end

--- Bind the permission answers on `bufnr`: <prefix>N for N = 1..9, each
--- calling `fn(N)` — the sidebar numbers its options with this legend.
--- @param bufnr integer
--- @param fn fun(index: integer)
function M.map_permissions(bufnr, fn)
  for _, entry in ipairs(M.get("permission_prefix")) do
    for i = 1, 9 do
      BufHelpers.keymap_set(bufnr, entry.mode, entry.lhs .. i, function()
        fn(i)
      end, { desc = "weave: answer permission option " .. i })
    end
  end
end

--- Just the keys of `name`, for a fibrous mount's `keys` declaration (which
--- routes them to component on_key handlers).
--- @param name string
--- @return string[]
function M.lhs_list(name)
  local out = {}
  for _, entry in ipairs(M.get(name)) do
    out[#out + 1] = entry.lhs
  end
  return out
end

--- A fibrous `on_key` map: every configured key of `name` invoking `fn`.
--- @param name string
--- @param fn fun()
--- @return table<string, fun()>
function M.on_key(name, fn)
  local map = {}
  for _, entry in ipairs(M.get(name)) do
    map[entry.lhs] = fn
  end
  return map
end

return M
