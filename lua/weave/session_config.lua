-- Config reconciliation for ONE ACP conversation. Only config writes are
-- serialized here; prompts and tools do not share this queue.
local SessionConfig = {}
SessionConfig.__index = SessionConfig

local function option(kind, value)
  for _, item in ipairs(kind and kind.available or {}) do
    if item.id == value then return item end
  end
end

local function finish(request, ok)
  if request and request.cb then
    local cb = request.cb
    request.cb = nil
    cb(ok)
  end
end

function SessionConfig.new(opts)
  local force_pending = {}
  if opts.force_defaults then
    for id in pairs(opts.defaults or {}) do force_pending[id] = true end
  end
  return setmetatable({
    defaults = vim.deepcopy(opts.defaults or {}),
    provider_defaults = vim.deepcopy(opts.provider_defaults or {}),
    session_defaults = vim.deepcopy(opts.session_defaults or {}),
    enabled = opts.enabled,
    force_pending = force_pending,
    on_snapshot = opts.on_snapshot,
    on_applied = opts.on_applied,
    on_error = opts.on_error,
    on_idle = opts.on_idle,
    kinds = {},
    order = {},
    manual = {},
    queue = {},
    attempts = {},
    version = 0,
    ready = false,
    closed = false,
  }, SessionConfig)
end

local function copy_map(values)
  local out = vim.empty_dict()
  for id, value in pairs(values) do out[id] = vim.deepcopy(value) end
  return out
end

local function request_snapshot(request)
  if not request then return vim.NIL end
  return {
    id = request.id, value = request.value,
    automatic = request.automatic == true, forced = request.force == true,
  }
end

--- A detached, JSON-safe view of config state. Never drains or changes intent.
--- @return table
function SessionConfig:snapshot()
  local fields, seen = {}, {}
  local function append(id, kind)
    seen[id] = true
    local default = self.defaults[id]
    local source = vim.NIL
    if self.session_defaults[id] ~= nil then
      source = "session"
    elseif self.provider_defaults[id] ~= nil then
      source = "provider"
    end
    local available = {}
    for _, item in ipairs(kind and kind.available or {}) do
      available[#available + 1] = { id = item.id, label = item.label, description = item.description }
    end
    fields[#fields + 1] = {
      id = id, key = kind and kind.key or id,
      label = kind and kind.label or id,
      category = kind and kind.category or nil,
      description = kind and kind.description or nil,
      advertised = kind ~= nil,
      current = kind and kind.current or vim.NIL,
      available = available,
      default = default == nil and vim.NIL or default,
      default_source = source,
      default_valid = default ~= nil and option(kind, default) ~= nil,
      manual = self.manual[id] == true,
      force_pending = self.force_pending[id] == true,
    }
  end
  for _, kind in ipairs(self.order) do append(kind.id, kind) end
  -- Defaults and manual intent survive a field disappearing. Keep them
  -- visible until the provider advertises the field again.
  local missing = {}
  for id in pairs(vim.tbl_extend("force", {}, self.defaults, self.manual)) do
    if not seen[id] then missing[#missing + 1] = id end
  end
  table.sort(missing)
  for _, id in ipairs(missing) do append(id) end
  local queued = {}
  for _, request in ipairs(self.queue) do queued[#queued + 1] = request_snapshot(request) end
  return {
    defaults = {
      provider = copy_map(self.provider_defaults),
      session = copy_map(self.session_defaults),
      effective = copy_map(self.defaults),
    },
    defaults_enabled = self.enabled == true,
    fields = fields,
    in_flight = request_snapshot(self.pending),
    queued_manual = queued,
  }
end

-- Called only for provider snapshots, not optimistic acknowledgements.
function SessionConfig:update(kinds)
  self.kinds, self.order = {}, kinds
  self.version = self.version + 1
  for _, kind in ipairs(kinds) do
    self.kinds[kind.id] = kind
    if kind.current == self.defaults[kind.id] then
      self.attempts[kind.id] = nil
    end
  end
  self:_drain()
end

function SessionConfig:activate()
  self.ready = true
  self:_drain()
end

function SessionConfig:close()
  self.closed = true
  local pending, queue = self.pending, self.queue
  self.pending, self.queue = nil, {}
  finish(pending, false)
  for _, request in ipairs(queue) do finish(request, false) end
end

-- Record intent BEFORE waiting for any in-flight default. Even choosing the
-- current value is an explicit override for the rest of this conversation.
function SessionConfig:set(id, value, cb)
  if self.closed or not option(self.kinds[id], value) then
    if cb then cb(false) end
    return
  end
  self.manual[id] = true
  self.queue[#self.queue + 1] = { id = id, value = value, cb = cb }
  self:_drain()
end

local function priority(kind)
  local category = kind.category or kind.key
  if category == "model" then return 1 end
  if category == "mode" then return 2 end
  return 3
end

-- Suppress retry/notification loops for the same effective configuration.
-- A changed model, mode, current value or value set permits another attempt.
function SessionConfig:_signature(kind, value)
  local values, dependencies = {}, {}
  for _, item in ipairs(kind.available) do values[#values + 1] = item.id end
  table.sort(values)
  for _, other in ipairs(self.order) do
    if priority(other) < priority(kind) then
      dependencies[#dependencies + 1] = { other.id, other.current or "" }
    end
  end
  return vim.json.encode({ value, kind.current or "", values, dependencies })
end

function SessionConfig:_next_default()
  if not self.enabled then return end
  local candidates = {}
  for index, kind in ipairs(self.order) do
    candidates[#candidates + 1] = { kind = kind, index = index }
  end
  table.sort(candidates, function(a, b)
    local pa, pb = priority(a.kind), priority(b.kind)
    return pa < pb or (pa == pb and a.index < b.index)
  end)
  for _, candidate in ipairs(candidates) do
    local kind = candidate.kind
    local value = self.defaults[kind.id]
    local force = self.force_pending[kind.id]
    if type(value) == "string" and not self.manual[kind.id]
        and (force or value ~= kind.current) and option(kind, value) then
      local signature = self:_signature(kind, value)
      if self.attempts[kind.id] ~= signature then
        self.attempts[kind.id] = signature
        return { id = kind.id, value = value, automatic = true, force = force }
      end
    end
  end
end

function SessionConfig:_drain()
  if self.closed or not self.ready or self.pending then return end
  local request = table.remove(self.queue, 1) or self:_next_default()
  if not request then
    if self.on_idle then self.on_idle() end
    return
  end
  local kind = self.kinds[request.id]
  if not option(kind, request.value) then
    finish(request, false)
    return self:_drain()
  end
  if kind.current == request.value and not request.force then
    finish(request, true)
    return self:_drain()
  end

  -- A restore owes one explicit write per configured field, even if its
  -- reported value matches. Consume that obligation only when sending, and
  -- never recreate it on notifications or failures.
  if request.automatic then self.force_pending[request.id] = nil end
  self.pending = request
  local before = kind.current
  local answered = false
  local function complete(ok, response)
    if answered then return end
    answered = true
    -- Notifications received after this acknowledgement are newer than its
    -- snapshot, including those arriving before the scheduled callback runs.
    local version = self.version
    vim.schedule(function()
      if self.closed then return end
      if ok then
        local has_snapshot = type(response) == "table"
          and (response.configOptions ~= nil or response.models ~= nil or response.modes ~= nil)
        if has_snapshot and self.version == version then
          self.on_snapshot(response)
        elseif not has_snapshot and self.version == version then
          -- Empty acknowledgements are common. Update the live kind, never the
          -- captured object that a notification may already have replaced.
          local live = self.kinds[request.id]
          if live and live.current == before and option(live, request.value) then
            live.current = request.value
          end
        end
        local live = self.kinds[request.id]
        local selected = option(live, request.value)
        if selected and live.current == request.value then self.on_applied(live, selected) end
      else
        self.on_error(kind, request.automatic)
      end
      self.pending = nil
      finish(request, ok)
      self:_drain()
    end)
  end
  local ok = pcall(kind.set, request.value, complete)
  if not ok then complete(false) end
end

return SessionConfig
