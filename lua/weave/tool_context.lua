-- Host-created transport capabilities. Tool arguments never establish identity.
local M = {}
local credentials = {}
local by_session = setmetatable({}, { __mode = "k" })

function M.bind(session)
  local old = by_session[session]
  if old and credentials[old] and credentials[old].valid() then return old end
  M.revoke(session)
  local config = session._config_session
  assert(config and not config.closed, "cannot bind a stopped conversation")
  local bytes = assert(vim.uv.random(32))
  local token = bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)
  local caller = { session = session }
  function caller.valid()
    return session._config_session == config and not config.closed and by_session[session] == token
  end
  credentials[token], by_session[session] = caller, token
  return token
end

function M.authenticate(token)
  if type(token) ~= "string" then return nil end
  local caller = credentials[token]
  if caller and caller.valid() then return caller end
end

function M.revoke(session)
  local tasks = package.loaded["weave.task_store"]
  if tasks then tasks.close_session(session) end
  local proxy = package.loaded["weave.mcp_proxy"]
  if proxy and proxy.close_session then proxy.close_session(session) end
  local token = by_session[session]
  if token then credentials[token] = nil; by_session[session] = nil end
end

function M.require_caller(ctx)
  local caller = ctx and ctx.caller
  if not caller or not caller.valid or not caller.valid() then
    error("this tool requires an authenticated live session connection", 0)
  end
  return caller.session
end

return M
