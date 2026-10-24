-- Read scopes for editor queries. Buffer references are resolved before the
-- outer tool gate, and every returned file is checked again before disclosure.
local Gate = require("weave.tools.gate")

local M = {}

function M.error(message)
  return { isError = true, content = { { type = "text", text = message } } }
end

function M.integer(value, default, min, max, label)
  if value == nil then return default end
  if type(value) ~= "number" or value ~= math.floor(value) or value < min or value > max then
    error(("%s must be an integer from %d to %d"):format(label, min, max), 0)
  end
  return value
end

function M.absolute(path, base)
  if type(path) ~= "string" or path == "" then error("path must be a nonempty string", 0) end
  if path:sub(1, 1) ~= "/" then path = base .. "/" .. path end
  return vim.fs.normalize(path)
end

-- Resolve existing parents too, so an absent file behind a symlink does not
-- acquire workspace authority merely because the final component is absent.
function M.canonical(path)
  local rest, current = {}, path
  while current and current ~= "" do
    local resolved = vim.uv.fs_realpath(current)
    if resolved then
      if #rest == 0 then return resolved end
      return resolved .. "/" .. table.concat(rest, "/")
    end
    table.insert(rest, 1, vim.fs.basename(current))
    local parent = vim.fs.dirname(current)
    if parent == current then break end
    current = parent
  end
  return path
end

function M.within(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/" or root == "/"
end

function M.buffer_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return nil end
  -- Non-file buffers have their own namespace, not a cwd-relative filename.
  if name:match("^%a[%w+.-]*://") then return nil end
  return vim.fs.normalize(name)
end

function M.find_buffer(path, loaded)
  local canonical, alias = M.canonical(path), nil
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not loaded or vim.api.nvim_buf_is_loaded(buf) then
      local name = M.buffer_path(buf)
      if name == path then return buf end
      if name and M.canonical(name) == canonical then alias = alias or buf end
    end
  end
  return alias
end

local function resolve_buffer(ref)
  if type(ref) == "number" then
    M.integer(ref, nil, 1, 2147483647, "buffer")
    if not vim.api.nvim_buf_is_valid(ref) then error("unknown buffer", 0) end
    return ref
  end
  if type(ref) ~= "string" or ref == "" then error("buffer must be an id or nonempty name", 0) end
  local found
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and (name == ref or name:sub(-#ref) == ref) then
      -- Do not enumerate other buffers in an error before authorization.
      if found then error("ambiguous buffer name; pass an exact path or buffer id", 0) end
      found = buf
    end
  end
  if not found then error("no matching buffer", 0) end
  return found
end

function M.target(args, ctx, aggregate)
  if args.path ~= nil and args.buffer ~= nil then error("pass path or buffer, not both", 0) end
  if args.root ~= nil and (args.path ~= nil or args.buffer ~= nil) then
    error("root cannot be combined with path or buffer", 0)
  end
  local base = Gate.policy(ctx).project_root()
  if args.buffer ~= nil then
    local buf = resolve_buffer(args.buffer)
    return { buffer = buf, path = M.buffer_path(buf), resource = M.buffer_path(buf) or ("buffer:" .. buf) }
  end
  if args.path ~= nil then
    local path = M.absolute(args.path, base)
    return { path = path, buffer = M.find_buffer(path), resource = path }
  end
  if not aggregate then error("pass path or buffer; no implicit current-buffer target", 0) end
  local root = M.absolute(args.root or base, base)
  return { root = root, resource = root == "/" and root or (root .. "/") }
end

function M.metadata(target)
  local buf = target.buffer
  local loaded = buf ~= nil and vim.api.nvim_buf_is_loaded(buf)
  return {
    path = target.path or vim.NIL, buffer = buf or vim.NIL, loaded = loaded,
    loaded_by_tool = target.loaded_by_tool == true,
    modified = loaded and vim.bo[buf].modified or false,
    changedtick = loaded and vim.api.nvim_buf_get_changedtick(buf) or vim.NIL,
  }
end

-- The outer gate has authorized this tool on the primary resource. A read
-- restriction is independent: a tool-specific allow must not bypass it.
-- An ask-once decision can cover the same rule within its approved scope,
-- but never a different ask rule, a deny, or an unrelated file.
function M.open(name, args, ctx, aggregate, respond, run)
  if not Gate.valid(ctx) then return respond(M.error("stale session context")) end
  local target = M.target(args, ctx, aggregate)
  local policy, action = Gate.policy(ctx), "weave:" .. name
  local resource = target.resource
  local _, tool_rule = policy.resolve({ tool = action, resource = resource })
  local _, read_rule = policy.resolve({ tool = "weave:read", resource = resource })
  local scope = { target = target, filtered = false }
  local real_root = target.root and M.canonical(target.root)
  local approved_aliases = { [resource] = { [action] = tool_rule, ["weave:read"] = read_rule } }
  local function covered(path)
    return approved_aliases[path] or (target.root and M.within(M.canonical(path), real_root))
  end
  local function permits(tool, path, approved_rule)
    local decision, rule = policy.resolve({ tool = tool, resource = path })
    if decision == "allow" then return true end
    if decision ~= "ask" then return false end
    if covered(path) and rule == approved_rule then return true end
    for alias, rules in pairs(approved_aliases) do
      if rule == rules[tool] and (path == alias
        or (target.root and M.within(M.canonical(path), M.canonical(alias)))) then return true end
    end
    return false
  end
  function scope.allows(path)
    if not Gate.valid(ctx) then return false end
    local real = path:sub(1, 7) == "buffer:" and path or M.canonical(path)
    for _, candidate in ipairs(real == path and { path } or { path, real }) do
      if not permits(action, candidate, tool_rule) or not permits("weave:read", candidate, read_rule) then
        scope.filtered = true
        return false
      end
    end
    return true
  end
  function scope.in_root(path)
    if not target.root then return true end
    local ok = M.within(M.canonical(path), real_root)
    if not ok then scope.filtered = true end
    return ok
  end
  local function ready()
    if not Gate.valid(ctx) then return respond(M.error("stale session context")) end
    run(scope)
  end
  local function authorize_read()
    local decision, rule = policy.resolve({ tool = "weave:read", resource = resource })
    read_rule = rule
    approved_aliases[resource]["weave:read"] = rule
    if decision == "allow" or (decision == "ask" and rule == tool_rule) then return ready() end
    Gate.mediate({ tool = "weave:read", resource = resource }, "Read editor query scope", "read", ready, respond, ctx)
  end
  local real = target.path and M.canonical(target.path) or target.root and M.canonical(target.root)
  if real and real ~= (target.path or target.root) then
    local canonical_resource = target.root and (real == "/" and real or real .. "/") or real
    -- Canonical aliases receive their own gates. They cannot inherit an
    -- ask-once grant on the lexical workspace path.
    return Gate.mediate({ tool = action, resource = canonical_resource }, "Read resolved editor query scope", "read", function()
      Gate.mediate({ tool = "weave:read", resource = canonical_resource }, "Read resolved editor query scope", "read",
        function()
          local _, canonical_tool_rule = policy.resolve({ tool = action, resource = canonical_resource })
          local _, canonical_read_rule = policy.resolve({ tool = "weave:read", resource = canonical_resource })
          approved_aliases[canonical_resource] = { [action] = canonical_tool_rule, ["weave:read"] = canonical_read_rule }
          authorize_read()
        end, respond, ctx)
    end, respond, ctx)
  end
  authorize_read()
end

return M
