-- Read-only, active-session introspection. MCP does not carry the calling ACP
-- session's identity, so an implicit target follows the editor's selection.
local Config = require("weave.config")
local Registry = require("weave.registry")
local Settings = require("weave.settings")

local M = {}

local function resolve(args)
  if args.session_id ~= nil and args.session_key ~= nil then
    error("pass session_id or session_key, not both", 0)
  end
  if args.session_id ~= nil then
    if type(args.session_id) ~= "string" or args.session_id == "" then
      error("session_id must be a nonempty ACP session ID", 0)
    end
    local found
    for _, entry in ipairs(Registry.list()) do
      if entry.session:session_id() == args.session_id then
        if found then error("ambiguous ACP session ID; pass session_key instead", 0) end
        found = entry
      end
    end
    if not found then error("no active session with that session_id", 0) end
    return found
  end
  if args.session_key ~= nil then
    local key = args.session_key
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      error("session_key must be a positive integer registry key", 0)
    end
    local entry = Registry.get(key)
    if not entry then error("no active session with that session_key", 0) end
    return entry
  end
  local selected = Registry.selected()
  if selected then return selected end
  local entries = Registry.list()
  if #entries == 1 then return entries[1] end
  if #entries == 0 then error("no active session to introspect", 0) end
  error("no current session selected; pass session_id or session_key", 0)
end

local function runtime_settings(entry)
  local stores = {
    global = Settings.global(),
    session = Settings.for_session(entry.session),
    view = entry.prefs,
  }
  local out = { global = {}, session = {}, view = {} }
  local overrides = (Config.settings or {}).defaults or {}
  for _, spec in ipairs(Settings.SPECS) do
    local default = spec.default
    if overrides[spec.key] ~= nil then
      local value = Settings.coerce(spec, overrides[spec.key])
      if value ~= nil then default = value end
    end
    local available = vim.NIL
    if spec.type == "boolean" then
      available = { false, true }
    elseif spec.type == "enum" then
      available = Settings.enum_options(spec.key)
    end
    local scope = out[spec.scope]
    scope[#scope + 1] = {
      key = spec.key, scope = spec.scope, label = spec.label, type = spec.type,
      current = stores[spec.scope]:get(spec.key),
      default = default, builtin_default = spec.default,
      available = available, min = spec.min,
    }
  end
  return out
end

M.introspect = {
  description = table.concat({
    "Inspect an active Weave session's configuration without changing it.",
    "Returns provider fields with current values, available choices, descriptions,",
    "configured provider/session/effective defaults and their validity, manual overrides,",
    "pending config writes, and scoped runtime settings with defaults and constraints.",
    "Omit selectors for the current editor tab's selected session (or the sole active session).",
    "MCP does not identify the caller's session; use session_id to target your own explicitly.",
    "Alternatively pass the stable registry session_key, including for sessions still starting.",
    "Pass at most one selector. Never creates, loads or switches sessions.",
    "Does not expose transcripts, prompts, launch arguments or environment variables.",
  }, " "),
  inputSchema = {
    type = "object",
    properties = {
      session_id = { type = "string", description = "Active ACP session ID; omit for the current selected session" },
      session_key = { type = "integer", description = "Stable active-session registry key, instead of session_id" },
    },
  },
  handler = function(args)
    local entry = resolve(args or {})
    local session = entry.session
    local state = session:get_store().state
    return vim.json.encode({
      session_id = session:session_id() or vim.NIL,
      session_key = entry.key,
      provider = entry.provider,
      ready = session:is_ready(),
      status = state.status,
      title = state.meta.title or vim.NIL,
      config = session:config_snapshot() or vim.NIL,
      settings = runtime_settings(entry),
    })
  end,
}

return M
