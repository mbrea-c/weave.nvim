-- Discovers restorable sessions for the current working directory.
--
-- Two strategies, both normalised to weave.acp.SessionInfo[] so the restore
-- picker and the load_session replay stay provider-agnostic:
--   * ACP `session/list` — for providers advertising sessionCapabilities.list.
--   * Kiro filesystem fallback — Kiro CLI supports loadSession but NOT list, so
--     we read its on-disk session index (~/.kiro/sessions/cli/<id>.json), which
--     records { session_id, cwd, title, updated_at }, and filter by cwd.
--
-- The fallback reaches into Kiro's private on-disk format: best-effort, version
-- coupled, and degrades to an empty list (never errors) if the layout changes.

local Logger = require("weave.utils.logger")

--- @class weave.SessionSource
local SessionSource = {}

--- Root of the Kiro CLI session index. Resolved from $HOME; the layout is
--- ~/.kiro/sessions/cli/<session-id>.json (a sibling .jsonl holds the transcript).
local function kiro_sessions_dir()
  return vim.fn.expand("~/.kiro/sessions/cli")
end

--- Read + parse the Kiro session index, returning entries whose cwd matches.
--- Pure filesystem; no provider process involved. Malformed/unreadable files
--- are skipped individually so one bad file can't break discovery.
--- @param cwd string
--- @param dir? string session index dir (defaults to ~/.kiro/sessions/cli; a test seam)
--- @return weave.acp.SessionInfo[] sessions
local function kiro_sessions_for_cwd(cwd, dir)
  dir = dir or kiro_sessions_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end

  local sessions = {}
  -- Only the .json index files (the .jsonl/.lock siblings are not metadata).
  for _, path in ipairs(vim.fn.globpath(dir, "*.json", false, true)) do
    local ok, content = pcall(vim.fn.readfile, path)
    if ok and content and #content > 0 then
      local decoded_ok, data = pcall(vim.json.decode, table.concat(content, "\n"))
      -- A real title means the session has at least one prompt; skip the
      -- empty just-created sessions (JSON null decodes to vim.NIL).
      local title = type(data) == "table" and data.title
      local has_title = type(title) == "string" and title ~= ""
      if decoded_ok and type(data) == "table" and data.cwd == cwd and data.session_id and has_title then
        --- @type weave.acp.SessionInfo
        sessions[#sessions + 1] = {
          sessionId = data.session_id,
          cwd = data.cwd,
          title = title,
          updatedAt = data.updated_at,
        }
      end
    end
  end

  return sessions
end

--- Sort sessions newest-first by updatedAt (ISO-8601 sorts lexically). Entries
--- without a timestamp sink to the bottom.
--- @param sessions weave.acp.SessionInfo[]
local function sort_recent_first(sessions)
  table.sort(sessions, function(a, b)
    return (a.updatedAt or "") > (b.updatedAt or "")
  end)
end

--- List restorable sessions for `cwd`, newest first. Uses ACP `session/list`
--- when the provider supports it; otherwise tries a provider-specific
--- filesystem fallback (currently Kiro). Returns an empty list (not an error)
--- when neither source yields anything.
--- @param client weave.acp.ACPClient
--- @param provider_name string
--- @param cwd string
--- @param callback fun(sessions: weave.acp.SessionInfo[]): nil
function SessionSource.list(client, provider_name, cwd, callback)
  local caps = client.agent_capabilities
  local supports_list = caps and caps.sessionCapabilities and caps.sessionCapabilities.list

  if supports_list then
    client:list_sessions(cwd, function(result, err)
      if err or not result then
        Logger.debug("session_source: list_sessions failed, " .. (err and err.message or "no result"))
        callback({})
        return
      end
      local sessions = result.sessions or {}
      sort_recent_first(sessions)
      callback(sessions)
    end)
    return
  end

  -- No ACP listing: try a provider-specific filesystem fallback.
  if provider_name == "kiro-acp" then
    local sessions = kiro_sessions_for_cwd(cwd)
    sort_recent_first(sessions)
    callback(sessions)
    return
  end

  Logger.debug("session_source: provider '" .. provider_name .. "' supports neither session/list nor a known fallback")
  callback({})
end

-- Test hook: the pure Kiro index reader, exposed with an injectable dir so its
-- cwd-filter / field-mapping / sort can be unit-tested against a temp fixture.
--- @param cwd string
--- @param dir string
--- @return weave.acp.SessionInfo[]
function SessionSource._kiro_sessions_for_cwd(cwd, dir)
  return kiro_sessions_for_cwd(cwd, dir)
end

return SessionSource
