-- Delegated runs over ordinary registry sessions. Ownership checks are shared
-- by every operation; UI selection is deliberately irrelevant.
local Registry = require("weave.registry")
local Config = require("weave.config")
local M = {}
local states, next_run = {}, 0
local schedule, pump, cancel_run

local function integer(value, default, minimum, maximum, name)
  value = value == nil and default or value
  if type(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < minimum or value > maximum then
    error(name .. " is outside its allowed integer range", 0)
  end
  return value
end

local function limits(key, default)
  return integer((Config.subagents or {})[key], default, 1, 1000000, "subagents." .. key)
end

local function parent_entry(session)
  local entry = Registry.entry_for(session)
  if not entry or entry.closing then error("caller session is not active", 0) end
  return entry
end

function M.target(session, key)
  local parent = parent_entry(session)
  local entry = Registry.get(key)
  if not entry or entry.closing or not Registry.is_descendant(key, parent.key) then
    error("unknown or inaccessible subagent", 0)
  end
  return entry
end

local function terminal(run)
  return run.status == "completed" or run.status == "failed" or run.status == "cancelled"
end

local function output(run)
  if run.final_output then return run.final_output end
  if not run.start_index then return "" end
  local entries = run.entry.session:get_store().state.entries
  local chunks = {}
  for i = run.start_index, run.end_index or #entries do
    local item = entries[i]
    if item and item.kind == "agent" and item.text then chunks[#chunks + 1] = item.text end
  end
  return table.concat(chunks, "\n\n")
end

local function snapshot(run)
  local status = run.status
  if status == "running" and run.entry.session:get_store().state.permission_count > 0 then
    status = "waiting_for_approval"
  end
  return { subagent_id = run.entry.key, run_id = run.id, status = status,
    error = run.error, created_at = run.created_at, finished_at = run.finished_at }
end

local function settle(state, run, status, err)
  if terminal(run) then return end
  run.status, run.error, run.finished_at = status, err, os.time()
  run.end_index = #run.entry.session:get_store().state.entries
  run.final_output = output(run)
  if state.active == run then state.active = nil end
  local waiters = run.waiters
  run.waiters = {}
  for _, waiter in ipairs(waiters) do pcall(waiter) end
  Registry.changed()
  for _, other in pairs(states) do schedule(other) end
end

schedule = function(state)
  if state.scheduled then return end
  state.scheduled = true
  vim.schedule(function()
    state.scheduled = false
    if Registry.get(state.entry.key) == state.entry then pump(state) end
  end)
end

local function state_for(entry)
  if states[entry.key] then return states[entry.key] end
  local state = { entry = entry, runs = {}, by_id = {}, queue = {} }
  states[entry.key] = state
  state.unsubscribe = entry.session:subscribe_events(function(event)
    if event.kind == "turn_finished" and state.active then
      local run, matched = state.active, false
      for _, message in ipairs(event.messages or {}) do
        if message.run_id == run.id then matched = true; break end
      end
      if not matched then return end
      local reason = event.response and event.response.stopReason
      if event.cancelled or reason == "cancelled" then
        settle(state, run, "cancelled")
      elseif event.error or (reason and reason ~= "end_turn") then
        settle(state, run, "failed", event.error and event.error.message or ("turn ended: " .. tostring(reason)))
      else
        settle(state, run, "completed")
      end
    elseif event.kind == "cancel_requested" and state.active then
      cancel_run(state, state.active)
    elseif event.kind == "stopped" or event.kind == "reset" then
      for _, run in ipairs(state.runs) do settle(state, run, "cancelled", "conversation ended") end
    end
    schedule(state)
  end)
  return state
end

local function config_ready(session)
  if not session:is_ready() then return false end
  local config = session:config_snapshot()
  if not config or config.in_flight ~= vim.NIL then return false end
  local fields = {}
  for _, field in ipairs(config.fields) do fields[field.id] = field end
  for id, value in pairs(config.defaults.effective) do
    if not fields[id] or not fields[id].default_valid or fields[id].current ~= value then return false end
  end
  return true
end

pump = function(state)
  if state.active or state.entry.session._turn_active then return end
  while state.queue[1] and terminal(state.queue[1]) do table.remove(state.queue, 1) end
  local run = state.queue[1]
  if not run then return end
  if not config_ready(state.entry.session) then
    run.status = "provisioning"
    if not run.provision_started then
      run.provision_started = true
      vim.defer_fn(function()
        if not terminal(run) and run.status == "provisioning" then
          settle(state, run, "failed", "session startup or requested configuration did not become ready before timeout")
        end
      end, limits("provision_timeout_ms", 30000))
    end
    return
  end
  run.status = "queued"
  local running = 0
  for _, other in pairs(states) do if other.active then running = running + 1 end end
  if running >= limits("max_running", 8) then return end
  table.remove(state.queue, 1)
  state.active, run.status = run, "running"
  run.start_index = #state.entry.session:get_store().state.entries + 1
  local accepted = state.entry.session:send_system({
    text = run.prompt, label = "Delegated task #" .. run.id, run_id = run.id,
  })
  if not accepted then settle(state, run, "failed", "session refused delegated prompt") end
end

local function enqueue(entry, text, owner)
  if type(text) ~= "string" or text == "" then error("prompt must be a nonempty string", 0) end
  local state = state_for(entry)
  if #state.runs >= limits("max_runs_per_session", 100) then error("subagent retained-run limit exceeded; close this child to release it", 0) end
  next_run = next_run + 1
  local run = { id = next_run, entry = entry, prompt = text, status = "queued",
    owner = owner, owner_run_id = M.active_run_id(owner), created_at = os.time(), waiters = {} }
  state.runs[#state.runs + 1], state.by_id[run.id], state.queue[#state.queue + 1] = run, run, run
  schedule(state)
  return run
end

function M.active_run_id(session)
  local entry = Registry.entry_for(session)
  local state = entry and states[entry.key]
  return state and state.active and state.active.id
end

function M.create(parent, opts)
  opts = opts or {}
  local owner = parent_entry(parent)
  local provider = opts.provider or owner.provider
  if not Config.acp_providers[provider] then error("unknown configured provider", 0) end
  if type(opts.prompt) ~= "string" or opts.prompt == "" then error("prompt must be a nonempty string", 0) end
  local entry = Registry.add({
    parent_key = owner.key, provider = provider, config_defaults = opts.config_defaults,
    permissions = opts.permissions, get_instance = opts.get_instance,
  })
  entry.name, entry.owner_run_id = opts.name, M.active_run_id(parent)
  local ok, run = pcall(enqueue, entry, opts.prompt, parent)
  if not ok then Registry.close(entry.key); error(run, 0) end
  return entry, run
end

function M.send(parent, key, text)
  return enqueue(M.target(parent, key), text, parent)
end

local function find_run(entry, id)
  local state = states[entry.key]
  local run = state and (id and state.by_id[id] or state.active or state.runs[#state.runs])
  if not run then error("unknown delegated run", 0) end
  return state, run
end

local function read_run(run, opts)
  opts = opts or {}
  local text = output(run)
  local cursor = integer(opts.cursor, 0, 0, 2147483647, "cursor")
  local count = integer(opts.max_chars, 16384, 1, 65536, "max_chars")
  local total = vim.fn.strchars(text)
  if cursor > total then error("cursor is beyond the current output", 0) end
  local out = snapshot(run)
  out.output = vim.fn.strcharpart(text, cursor, count)
  out.next_cursor = cursor + vim.fn.strchars(out.output)
  out.has_more = out.next_cursor < total
  return out
end

function M.read(parent, key, opts)
  local entry = M.target(parent, key)
  local _, run = find_run(entry, opts and opts.run_id)
  return read_run(run, opts)
end

function M.wait(parent, key, id, timeout_ms, callback)
  local entry = M.target(parent, key)
  local _, run = find_run(entry, id)
  timeout_ms = integer(timeout_ms, 30000, 0, 120000, "timeout_ms")
  local done, timer = false, nil
  local function finish(timed_out)
    if done then return end
    done = true
    if timer and not timer:is_closing() then timer:stop(); timer:close() end
    local out = read_run(run)
    out.timed_out = timed_out == true
    callback(out)
  end
  if terminal(run) then vim.schedule(function() finish(false) end); return end
  run.waiters[#run.waiters + 1] = function() finish(false) end
  timer = vim.defer_fn(function() finish(true) end, timeout_ms)
end

cancel_run = function(state, run)
  if terminal(run) then return end
  local active, session = state.active == run, state.entry.session
  settle(state, run, "cancelled")
  local tasks = package.loaded["weave.task_store"]
  if tasks then tasks.cancel_run(session, run.id) end
  if active then session:cancel() end
  for _, descendant in pairs(states) do
    for _, child_run in ipairs(descendant.runs) do
      if child_run.owner == session and child_run.owner_run_id == run.id then
        cancel_run(descendant, child_run)
      end
    end
  end
end

function M.cancel(parent, key, id)
  local state, run = find_run(M.target(parent, key), id)
  cancel_run(state, run)
  return snapshot(run)
end

function M.close(parent, key)
  Registry.close(M.target(parent, key).key)
end

function M.list(parent, opts)
  local owner = parent_entry(parent)
  opts = opts or {}
  local limit = integer(opts.limit, 10, 1, 1000, "limit")
  local filter = opts.status or "all"
  if not vim.tbl_contains({ "all", "running", "completed", "failed", "cancelled", "idle" }, filter) then
    error("invalid subagent status filter", 0)
  end
  local out = {}
  for _, entry in ipairs(Registry.children(owner.key, opts.recursive == true)) do
    local state = states[entry.key]
    local run = state and (state.active or state.runs[#state.runs])
    local row = run and snapshot(run) or { subagent_id = entry.key, status = "idle" }
    row.parent_id, row.provider, row.session_id = entry.parent_key, entry.provider, entry.session:session_id() or vim.NIL
    row.name = entry.name or entry.session:get_store().state.meta.title
    local active = run and not terminal(run)
    if filter == "all" or filter == row.status or (filter == "running" and active) then
      if #out < limit then out[#out + 1] = row end
    end
  end
  return out
end

function M.status(session)
  local entry = Registry.entry_for(session)
  local state = entry and states[entry.key]
  local run = state and (state.active or state.runs[#state.runs])
  return run and snapshot(run).status
end

Registry.on_close(function(entry)
  local state = states[entry.key]
  if state then
    for _, run in ipairs(state.runs) do settle(state, run, "cancelled", "session closed") end
    state.unsubscribe()
    states[entry.key] = nil
  end
end)

return M
