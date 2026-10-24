-- Lifecycle/readiness for editor tools. Protocol initialization, request
-- support, and diagnostic publication are deliberately separate facts.
local Scope = require("weave.tools.editor_scope")
local Gate = require("weave.tools.gate")
local M = {}
local reports, wrappers, group = {}, {}, nil
local dispatching

local function now() return vim.uv.hrtime() / 1000000 end
local function version(buf) return vim.lsp.util.buf_versions[buf] end

function M.record_diagnostics(id, buf, reported_version, count, kind)
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  reports[buf] = reports[buf] or {}
  reports[buf][id] = {
    version = type(reported_version) == "number" and reported_version or nil,
    count = count, tick = vim.api.nvim_buf_get_changedtick(buf),
    name = vim.api.nvim_buf_get_name(buf), kind = kind or "push",
  }
end

function M.setup()
  if not group then
    group = vim.api.nvim_create_augroup("weave_lsp_observation", { clear = true })
    vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
      group = group, callback = function(event) reports[event.buf] = nil end,
    })
    vim.api.nvim_create_autocmd("LspDetach", {
      group = group, callback = function(event)
        if reports[event.buf] and event.data then reports[event.buf][event.data.client_id] = nil end
      end,
    })
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
      group = group, callback = function(event)
        if dispatching and dispatching.buf == event.buf then dispatching.applied = true end
      end,
    })
  end
  for _, method in ipairs({ "textDocument/publishDiagnostics", "textDocument/diagnostic" }) do
    local current = vim.lsp.handlers[method]
    if type(current) == "function" and current ~= wrappers[method] then
      local wrapped = function(err, result, ctx, config)
        local buf = ctx and ctx.bufnr
        if method == "textDocument/publishDiagnostics" and type(result) == "table" and type(result.uri) == "string" then
          local ok, path = pcall(vim.uri_to_fname, result.uri)
          buf = ok and Scope.find_buffer(path, true) or nil
        end
        local previous = dispatching
        local observation = { buf = buf, applied = false }
        dispatching = observation
        local ok, ret = pcall(current, err, result, ctx, config)
        dispatching = previous
        -- Observing the handler alone is insufficient: stale reports can be
        -- rejected by it. Record only if the diagnostic cache actually changed,
        -- including a publication of an empty list.
        if ok and not err and observation.applied and buf and ctx and ctx.client_id and type(result) == "table" then
          local list = result.diagnostics or result.items
          if type(list) == "table" then
            M.record_diagnostics(ctx.client_id, buf, result.version or ctx.version, #list,
              method == "textDocument/publishDiagnostics" and "push" or "pull")
          end
        end
        if not ok then error(ret) end
        return ret
      end
      wrappers[method] = wrapped
      vim.lsp.handlers[method] = wrapped
    end
  end
end

local function supports(client, method, buf)
  local ok, value = pcall(client.supports_method, client, method, buf)
  return ok and value == true
end

function M.diagnostics(client, buf)
  local report = reports[buf] and reports[buf][client.id]
  local state = "not_received"
  if report then
    if report.tick ~= vim.api.nvim_buf_get_changedtick(buf) or report.name ~= vim.api.nvim_buf_get_name(buf)
      or (report.version ~= nil and report.version ~= version(buf)) then state = "stale"
    elseif report.version == nil then state = "version_unknown"
    else state = "current_version" end
  end
  return {
    state = state, report_received = report ~= nil,
    report_count = report and report.count or vim.NIL,
    report_version = report and report.version or vim.NIL,
    current_version = version(buf) or vim.NIL,
    current_version_confirmed = state == "current_version", buffer = buf,
    push_support = report and report.kind == "push" and "observed" or "unknown",
    pull_support = client.initialized == false and vim.NIL or supports(client, "textDocument/diagnostic", buf),
  }
end

function M.observe(scope, method, previous)
  local target, entries, seen = scope.target, {}, {}
  for _, client in ipairs(vim.lsp.get_clients(target.root and nil or { bufnr = target.buffer })) do
    local buf = target.buffer
    if target.root then
      local candidates = {}
      for b, attached in pairs(client.attached_buffers or {}) do
        if attached and vim.api.nvim_buf_is_loaded(b) then candidates[#candidates + 1] = b end
      end
      table.sort(candidates)
      for _, b in ipairs(candidates) do
        local path = Scope.buffer_path(b)
        if path and scope.in_root(path) and scope.allows(path) then buf = b; break end
      end
    end
    if buf and vim.api.nvim_buf_is_loaded(buf) then
      local stopped = client:is_stopped()
      local attached = not stopped and not not client.attached_buffers[buf]
      local initialized = client.initialized ~= false
      local supported = vim.NIL
      if initialized and method then supported = supports(client, method, buf) end
      local state = stopped and "stopped" or not attached and "detached"
        or not initialized and "initializing" or (not method or supported == true) and "ready" or "unsupported"
      local info = { id = client.id, name = vim.fn.strcharpart(client.name or "", 0, 256),
        state = state, attached = attached, initialized = initialized and not stopped,
        supports_method = supported, indexing = "unknown", status = "not_requested",
        diagnostics = M.diagnostics(client, buf) }
      entries[#entries + 1] = { client = client, buffer = buf, info = info }
      seen[client.id] = true
    end
  end
  for _, entry in ipairs(previous or {}) do
    if not seen[entry.client.id] then
      local info = vim.deepcopy(entry.info)
      info.state, info.attached, info.status = entry.client:is_stopped() and "stopped" or "detached", false, "not_requested"
      entries[#entries + 1] = { client = entry.client, buffer = entry.buffer, info = info }
    end
  end
  table.sort(entries, function(a, b) return a.client.id < b.client.id end)
  return entries
end

function M.infos(entries)
  local out = {}
  for _, entry in ipairs(entries) do out[#out + 1] = entry.info end
  return out
end

function M.failure(status, message, scope, entries, extra)
  local out = extra or {}
  out.status, out.message = status, message
  out.items, out.clients = {}, M.infos(entries or {})
  out.analysis_complete, out.can_conclude_clean = false, false
  out.target = not scope.target.root and Scope.metadata(scope.target) or nil
  out.next_action = status == "buffer_not_loaded" and { action = "retry", argument = "load", value = true }
    or status == "load_failed" and { action = "inspect_file_and_editor_setup" }
    or status == "target_changed" and { action = "retry_with_explicit_target" }
    or status == "unsupported" and { action = "configure_server_or_use_another_operation" }
    or status == "no_server" and { action = "configure_or_retry", argument = "startup_timeout_ms", value = 120000 }
    or { action = "retry", argument = "startup_timeout_ms", value = 120000 }
  return { isError = true, content = { { type = "text", text = vim.json.encode(out) } } }
end

function M.prepare(scope, args, respond, ctx)
  local target = scope.target
  if target.root then return true end
  target.loaded_by_tool = false
  if target.buffer and vim.api.nvim_buf_is_loaded(target.buffer) then return true end
  if not args.load then
    respond(M.failure("buffer_not_loaded", "File is not loaded. No file was opened or checked. Retry with load=true to explicitly load a hidden buffer and run normal filetype/LSP setup.", scope))
    return false
  end
  local stat = target.path and vim.uv.fs_stat(target.path)
  if not stat or stat.type ~= "file" then
    respond(M.failure("load_failed", "Only an existing regular file can be loaded; no file was created.", scope))
    return false
  end
  if not Gate.valid(ctx) or not scope.allows(target.resource) then
    respond(M.failure("permission_denied", "Read permission was revoked before buffer loading.", scope))
    return false
  end
  local ok = pcall(function()
    target.buffer = target.buffer or vim.fn.bufadd(target.path)
    if not Gate.valid(ctx) or not scope.allows(target.resource) then error("revoked") end
    vim.fn.bufload(target.buffer)
    if not vim.api.nvim_buf_is_loaded(target.buffer) then error("not loaded") end
    if vim.bo[target.buffer].filetype == "" then
      local ft, on_detect = vim.filetype.match({ buf = target.buffer })
      if on_detect then on_detect(target.buffer) end
      if ft then vim.bo[target.buffer].filetype = ft end
    end
  end)
  if not ok then
    respond(M.failure("load_failed", "Buffer loading or configured filetype setup failed; the buffer may remain loaded. No save was requested.", scope))
    return false
  end
  target.loaded_by_tool = true
  local actual = Scope.buffer_path(target.buffer)
  if not Gate.valid(ctx) or not actual or Scope.canonical(actual) ~= Scope.canonical(target.path)
    or not scope.allows(actual) then
    respond(M.failure("target_changed", "Filetype setup redirected or revoked the target. No LSP query was sent. Retry with the actual file explicitly.", scope))
    return false
  end
  return true
end

-- Non-blocking waits share lifecycle, policy and buffer-version checks.
local function await(scope, ctx, deadline, inspect, done, respond)
  local started, finished, timer, unsubscribe = now(), false, nil, nil
  local buf = scope.target.buffer
  local tick = buf and vim.api.nvim_buf_get_changedtick(buf)
  local name = buf and vim.api.nvim_buf_get_name(buf)
  local function cleanup()
    if timer then timer:stop(); timer:close(); timer = nil end
    if unsubscribe then unsubscribe(); unsubscribe = nil end
  end
  local function abort(status, message)
    if finished then return end
    finished = true
    cleanup()
    respond(M.failure(status, message, scope))
  end
  local function step()
    if finished then return end
    if not Gate.valid(ctx) then return abort("stale_session", "Session context was revoked; no results are disclosed.") end
    if not scope.allows(scope.target.resource) then return abort("permission_denied", "Read permission was revoked during the wait.") end
    if buf and (not vim.api.nvim_buf_is_loaded(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick
      or vim.api.nvim_buf_get_name(buf) ~= name) then
      return abort("buffer_changed", "Buffer changed while waiting. Retry against the current contents.")
    end
    local elapsed = math.floor(now() - started)
    local ok, ready, state = pcall(inspect)
    if not ok then return abort("query_failed", "Could not inspect language-server readiness.") end
    if ready or elapsed >= deadline then
      finished = true
      cleanup()
      local called = pcall(done, state, { waited_ms = elapsed, timeout_ms = deadline, timed_out = not ready and deadline > 0 })
      if not called then respond(M.failure("query_failed", "Could not start or finish the requested query; no successful empty result is implied.", scope)) end
      return
    end
  end
  step()
  if not finished then
    if ctx and ctx.caller then
      unsubscribe = ctx.caller.session:subscribe_events(function(event)
        if event.kind == "reset" or event.kind == "stopped" or event.kind == "cancel_requested" then
          abort("cancelled", "Session ended or cancelled the editor query.")
        end
      end)
    end
    timer = assert(vim.uv.new_timer())
    timer:start(20, 20, function() vim.schedule(step) end)
  end
end

function M.await_start(scope, args, opts, ctx, respond, done, method)
  local entries = M.observe(scope, method)
  local waiting = false
  for _, entry in ipairs(entries) do waiting = waiting or entry.info.state == "initializing" end
  local deadline = opts.startup_timeout_ms
  if deadline == nil then deadline = (args.load or waiting) and 120000 or 0 end
  await(scope, ctx, deadline, function()
    entries = M.observe(scope, method, entries)
    local initializing = false
    for _, entry in ipairs(entries) do initializing = initializing or entry.info.state == "initializing" end
    return #entries > 0 and not initializing, entries
  end, function(current, timing)
    local ready, state = {}, #current == 0 and "no_server" or current[1].info.state
    for _, entry in ipairs(current) do
      if entry.info.state == "ready" then ready[#ready + 1] = entry end
      if entry.info.state == "initializing" then state = "initializing" end
    end
    if #ready > 0 then state = state == "initializing" and "partial" or "ready" end
    timing.state = state
    done(current, ready, timing)
  end, respond)
end

function M.await_diagnostics(scope, args, opts, ctx, respond, entries, done)
  local deadline = opts.diagnostic_timeout_ms
  if deadline == nil then deadline = args.load and 30000 or 0 end
  if scope.target.root then deadline = 0 end -- workspace caches do not prove per-file reporting coverage
  await(scope, ctx, deadline, function()
    entries = M.observe(scope, nil, entries)
    local complete = #entries > 0
    for _, entry in ipairs(entries) do
      complete = complete and entry.info.state == "ready" and entry.info.diagnostics.state == "current_version"
    end
    return complete, entries
  end, done, respond)
end

function M._reset()
  reports = {}
end

return M
