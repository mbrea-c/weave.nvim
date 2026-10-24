-- Editor diagnostic cache and LSP queries, with explicit opt-in background
-- buffer loading. Never navigate, save, or execute arbitrary LSP commands.
local Scope = require("weave.tools.editor_scope")
local Gate = require("weave.tools.gate")
local Runtime = require("weave.tools.lsp_runtime")

local M = {}
M.names = { "diagnostics", "document_symbols", "workspace_symbols", "definition", "references", "hover" }
local methods = {
  document_symbols = "textDocument/documentSymbol", workspace_symbols = "workspace/symbol",
  definition = "textDocument/definition", references = "textDocument/references", hover = "textDocument/hover",
}
local severity_names = { "error", "warning", "information", "hint" }
local SCAN_LIMIT = 10000

local function clip(text, max)
  text = tostring(text or "")
  if vim.fn.strchars(text) <= max then return text, false end
  return vim.fn.strcharpart(text, 0, max), true
end

local function options(name, args)
  local out = {
    limit = Scope.integer(args.limit, 100, 1, 1000, "limit"),
    offset = Scope.integer(args.offset, 0, 0, 2147483647, "offset"),
    timeout_ms = Scope.integer(args.timeout_ms, 3000, 1, 30000, "timeout_ms"),
    max_chars = Scope.integer(args.max_chars, 16000, 1, 64000, "max_chars"),
    startup_timeout_ms = Scope.integer(args.startup_timeout_ms, nil, 0, 300000, "startup_timeout_ms"),
    diagnostic_timeout_ms = Scope.integer(args.diagnostic_timeout_ms, nil, 0, 120000, "diagnostic_timeout_ms"),
  }
  if args.load ~= nil and type(args.load) ~= "boolean" then error("load must be a boolean", 0) end
  if name == "diagnostics" and args.path == nil and args.buffer == nil and (args.diagnostic_timeout_ms or 0) ~= 0 then
    error("diagnostic_timeout_ms requires a specific path or buffer; workspace diagnostics are cache-only", 0)
  end
  if args.load and (name == "workspace_symbols" or (args.path == nil and args.buffer == nil)) then
    error("load=true requires a specific path or buffer; workspace queries never load files", 0)
  end
  if args.source ~= nil and type(args.source) ~= "string" then error("source must be a string", 0) end
  if args.severity ~= nil and not vim.tbl_contains(severity_names, args.severity) then
    error("severity must be error, warning, information, or hint", 0)
  end
  if name == "workspace_symbols" then
    if type(args.query) ~= "string" then error("query must be a string", 0) end
    if #args.query > 4096 then error("query is too long", 0) end
    if args.path ~= nil or args.buffer ~= nil then error("workspace_symbols takes root, not path or buffer", 0) end
  elseif name ~= "diagnostics" and args.root ~= nil then
    error("only aggregate queries accept root", 0)
  end
  if args.include_declaration ~= nil and type(args.include_declaration) ~= "boolean" then
    error("include_declaration must be a boolean", 0)
  end
  return out
end

local function accumulator(scope, opts)
  local a = { items = {}, keys = {}, scope = scope, opts = opts, truncated = false, scanned = 0,
    locations = { buffers = {}, files = {}, bytes = 0, lines = 0 } }
  function a.add(item, client)
    if not item then return end
    local key = vim.json.encode(item)
    local existing = a.keys[key]
    if existing then
      if client and not vim.tbl_contains(existing.client_ids, client.id) then
        existing.client_ids[#existing.client_ids + 1] = client.id
      end
      return
    end
    a.keys[key] = item
    item.client_ids = client and { client.id } or nil
    a.items[#a.items + 1] = item
  end
  function a.visit()
    a.scanned = a.scanned + 1
    if a.scanned > SCAN_LIMIT then a.truncated = true; return false end
    return true
  end
  return a
end

local function ordered(a, b)
  if a.text and b.text then
    local ac, bc = a.client_ids[1], b.client_ids[1]
    if ac ~= bc then return ac < bc end
  end
  local ar, br = a.range ~= vim.NIL and a.range or nil, b.range ~= vim.NIL and b.range or nil
  local av = { a.path or "", ar and ar.start.line or 0, ar and ar.start.column or 0,
    a.severity_number or 0, a.name or a.message or a.text or "", a.kind or 0 }
  local bv = { b.path or "", br and br.start.line or 0, br and br.start.column or 0,
    b.severity_number or 0, b.name or b.message or b.text or "", b.kind or 0 }
  for i = 1, #av do
    if av[i] ~= bv[i] then return av[i] < bv[i] end
  end
  return vim.json.encode(a) < vim.json.encode(b)
end

local function page(a, extra)
  table.sort(a.items, ordered)
  local total, items = #a.items, {}
  local text_left = a.opts.max_chars
  for i = a.opts.offset + 1, math.min(total, a.opts.offset + a.opts.limit) do
    local item = a.items[i]
    if item.client_ids then table.sort(item.client_ids) end
    if item.text then
      if text_left == 0 then a.truncated = true; break end
      local shortened
      item.text, shortened = clip(item.text, text_left)
      text_left = text_left - vim.fn.strchars(item.text)
      if shortened then item.truncated, a.truncated = true, true end
    end
    items[#items + 1] = item
  end
  local next_offset = a.opts.offset + #items
  local out = extra or {}
  out.items, out.total, out.offset, out.limit = items, total, a.opts.offset, a.opts.limit
  out.next_offset = next_offset < total and next_offset or vim.NIL
  out.truncated = a.truncated or next_offset < total
  out.filtered = a.scope.filtered
  out.position_encoding = "utf-8"
  out.coordinates = "1-based lines and byte columns; end exclusive"
  return vim.json.encode(out)
end

local function point(line, column)
  return { line = line + 1, column = column + 1 }
end

local function diagnostic_range(d)
  return { start = point(d.lnum, d.col),
    ["end"] = point(d.end_lnum or d.lnum, d.end_col or d.col) }
end

local function diagnostics(scope, args, opts, respond, entries, startup, diagnostic_wait)
  local target, a = scope.target, accumulator(scope, opts)
  local selected = target.buffer
  local diagnostics_list = selected and vim.diagnostic.get(selected)
    or target.path and {} or vim.diagnostic.get()
  for _, d in ipairs(diagnostics_list) do
    local path = Scope.buffer_path(d.bufnr)
    local resource = path or ("buffer:" .. d.bufnr)
    if (not target.root or (path and scope.in_root(path))) and scope.allows(resource)
      and (not args.severity or args.severity == severity_names[d.severity or 1])
      and (not args.source or args.source == d.source) then
      if not a.visit() then break end
      local message, truncated = clip(d.message, 4096)
      local source = d.source and clip(d.source, 256) or nil
      local code = d.code and clip(d.code, 256) or nil
      a.add({ path = path or vim.NIL, buffer = d.bufnr, range = diagnostic_range(d),
        severity = severity_names[d.severity or 1], severity_number = d.severity or 1,
        source = source, code = code, message = message, truncated = truncated })
      a.truncated = a.truncated or truncated
    end
  end
  local pending, unconfirmed = false, #entries == 0 or target.root ~= nil
  for _, entry in ipairs(entries) do
    pending = pending or entry.info.state == "initializing" or entry.info.diagnostics.state == "not_received"
    unconfirmed = unconfirmed or entry.info.state ~= "ready" or entry.info.diagnostics.state ~= "current_version"
  end
  local status = pending and "diagnostics_pending" or unconfirmed and "diagnostics_unconfirmed" or "ok"
  local next_action
  if pending or unconfirmed then
    next_action = target.root and {
      action = "query_file", tool = "weave_diagnostics",
      message = "Choose a specific path or buffer to wait for diagnostic reports; workspace queries are cache-only.",
    } or { action = "retry", argument = "diagnostic_timeout_ms", value = 120000 }
  end
  respond(page(a, { status = status, clients = Runtime.infos(entries), startup = startup,
    diagnostic_wait = diagnostic_wait, partial = pending or unconfirmed, analysis_complete = false,
    can_conclude_clean = false, coverage = "cached", fresh = false,
    diagnostic_scope = target.root and "workspace_cache" or "buffer",
    message = "Cached diagnostics, NOT proof of a clean file. Each client's report/version state is listed separately. Initialized does not mean fully indexed; undiscovered providers and non-LSP linters may not have reported.",
    next_action = next_action,
    target = not target.root and Scope.metadata(target) or nil, root = target.root }))
end

local function buffer_line(buf, line)
  return vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1]
end

local function request_position(buf, args)
  local line = Scope.integer(args.line, nil, 1, vim.api.nvim_buf_line_count(buf), "line")
  if not line then error("line is required", 0) end
  local text = buffer_line(buf, line - 1)
  local col = Scope.integer(args.column, nil, 1, #text + 1, "column")
  if not col then error("column is required", 0) end
  local byte = text:byte(col)
  if byte and byte >= 128 and byte < 192 then error("column must be at a UTF-8 character boundary", 0) end
  return { line = line - 1, byte = col - 1, text = text }
end

-- Normalize only after authorization. Read lines from loaded buffers first;
-- an unopened target may be read from disk, but never becomes an editor buffer.
local function location_range(path, range, encoding, source_buf, cache)
  if type(range) ~= "table" or type(range.start) ~= "table" or type(range["end"]) ~= "table" then return nil end
  local buf = source_buf
  if not buf and path then
    if cache.buffers[path] == nil then cache.buffers[path] = Scope.find_buffer(path, true) or false end
    buf = cache.buffers[path]
  end
  if not path and not buf then return nil end
  local function disk_lines()
    if cache.files[path] then return cache.files[path] end
    local size = vim.uv.fs_stat(path)
    local remaining = 100000 - cache.lines
    local lines = {}
    if size and size.type == "file" and size.size <= 8388608 - cache.bytes and remaining > 0 then
      local ok, read = pcall(vim.fn.readfile, path, "", remaining)
      if ok then
        lines = read
        cache.bytes, cache.lines = cache.bytes + size.size, cache.lines + #lines
      end
    end
    cache.files[path] = lines
    return lines
  end
  local function convert(pos)
    if type(pos.line) ~= "number" or pos.line < 0 or pos.line ~= math.floor(pos.line)
      or type(pos.character) ~= "number" or pos.character < 0 or pos.character ~= math.floor(pos.character) then return nil end
    local column = pos.character
    if encoding ~= "utf-8" then
      local text
      if buf then
        if pos.line >= vim.api.nvim_buf_line_count(buf) then return nil end
        text = buffer_line(buf, pos.line)
      else
        text = disk_lines()[pos.line + 1]
      end
      if not text then return nil end
      local ok, byte_index = pcall(vim.str_byteindex, text, encoding, column, true)
      if not ok then return nil end
      column = byte_index
    end
    return point(pos.line, column)
  end
  local start, finish = convert(range.start), convert(range["end"])
  if not start or not finish then return nil end
  if finish.line < start.line or (finish.line == start.line and finish.column < start.column) then return nil end
  return { start = start, ["end"] = finish }
end

local function uri_path(uri)
  if type(uri) ~= "string" or not uri:match("^file://") then return nil end
  -- Remote file authorities are not local editor paths.
  local authority = uri:match("^file://([^/]*)")
  if authority ~= "" and authority ~= "localhost" then return nil end
  local ok, path = pcall(vim.uri_to_fname, uri)
  return ok and Scope.absolute(path, "/") or nil
end

local function location(a, value, client, allow_unresolved)
  if type(value) ~= "table" then return nil end
  local path = uri_path(value.uri or value.targetUri)
  if not path or not a.scope.in_root(path) or not a.scope.allows(path) then
    a.scope.filtered = true
    return nil
  end
  local raw_range = value.range or value.targetSelectionRange or value.targetRange
  local range = raw_range and location_range(path, raw_range, client.offset_encoding or "utf-16", nil, a.locations)
  if raw_range and not range then a.truncated = true; return nil end
  if not range and not allow_unresolved then a.truncated = true; return nil end
  local out = { path = path, range = range or vim.NIL, range_available = range ~= nil }
  if value.targetRange then
    out.target_range = location_range(path, value.targetRange, client.offset_encoding or "utf-16", nil, a.locations) or vim.NIL
  end
  return out
end

local function symbol(a, value, client, path, parent, depth)
  if not a.visit() then return end
  if type(value) ~= "table" or type(value.name) ~= "string" then return end
  local item
  if not value.location and not path then
    local target = a.scope.target
    if not a.scope.allows(target.resource) then return end
    local range = location_range(nil, value.range, client.offset_encoding or "utf-16", target.buffer, a.locations)
    if not range then a.truncated = true; return end
    item = { path = vim.NIL, buffer = target.buffer, range = range, range_available = true }
  else
    local loc = value.location or { uri = vim.uri_from_fname(path), range = value.range }
    item = location(a, loc, client, true)
  end
  if not item then return end
  item.name = clip(value.name, 1024)
  item.kind = type(value.kind) == "number" and value.kind or nil
  item.detail = type(value.detail) == "string" and clip(value.detail, 2048) or nil
  item.container = (parent or type(value.containerName) == "string" and clip(value.containerName, 1024)) or nil
  if value.selectionRange then
    item.selection_range = location_range(item.path ~= vim.NIL and item.path or nil, value.selectionRange, client.offset_encoding or "utf-16", item.buffer, a.locations) or vim.NIL
  end
  a.add(item, client)
  if depth < 100 then
    for _, child in ipairs(value.children or {}) do
      if a.scanned >= SCAN_LIMIT then a.truncated = true; break end
      symbol(a, child, client, path, item.name, depth + 1)
    end
  elseif value.children and #value.children > 0 then
    a.truncated = true
  end
end

local function hover_content(contents)
  if type(contents) == "string" then return contents, "markdown" end
  if type(contents) ~= "table" then return "", "plaintext" end
  if type(contents.value) == "string" then
    if contents.language then return "```" .. contents.language .. "\n" .. contents.value .. "\n```", "markdown" end
    return contents.value, contents.kind == "markdown" and "markdown" or "plaintext"
  end
  local parts = {}
  for _, part in ipairs(contents) do
    local text = hover_content(part)
    if text ~= "" then parts[#parts + 1] = text end
  end
  return table.concat(parts, "\n\n"), "markdown"
end

local function normalize(name, a, result, client, target)
  if type(result) ~= "table" then return end
  if name == "document_symbols" or name == "workspace_symbols" then
    for _, value in ipairs(result) do
      if a.scanned >= SCAN_LIMIT then a.truncated = true; break end
      symbol(a, value, client, target.path, nil, 0)
    end
  elseif name == "hover" then
    if not a.scope.allows(target.resource) then return end
    local text, format = hover_content(result.contents)
    if text == "" then return end
    local shortened
    text, shortened = clip(text, a.opts.max_chars)
    a.truncated = a.truncated or shortened
    a.add({ text = text, format = format, truncated = shortened,
      range = result.range and location_range(target.path, result.range, client.offset_encoding or "utf-16", target.buffer, a.locations) or vim.NIL }, client)
  else
    local list = (result.uri or result.targetUri) and { result } or result
    for _, value in ipairs(list) do
      if not a.visit() then break end
      a.add(location(a, value, client), client)
    end
  end
end

local function query(name, scope, args, opts, respond, ctx, selected, observed, startup)
  local target = scope.target
  if not target.root and (not target.buffer or not vim.api.nvim_buf_is_loaded(target.buffer)) then
    return respond(Scope.error("Target buffer is not loaded; open it explicitly before requesting LSP data"))
  end
  local position = (name == "definition" or name == "references" or name == "hover")
    and request_position(target.buffer, args) or nil
  if #selected == 0 then
    return respond(Runtime.failure(startup.state,
      "No ready client supports this operation. See each client's initialization and capability state; no successful empty query is implied.",
      scope, observed, { startup = startup }))
  end
  local pending, launching, finished = #selected, true, false
  local timer = assert(vim.uv.new_timer())
  local snapshots, unsubscribe = {}, nil
  for _, entry in ipairs(selected) do
    local buf = entry.buffer
    snapshots[buf] = { tick = vim.api.nvim_buf_get_changedtick(buf), name = vim.api.nvim_buf_get_name(buf) }
    entry.status = "pending"
  end
  local function cancel(entry)
    if entry.request_id then pcall(entry.client.cancel_request, entry.client, entry.request_id) end
  end
  local function finish(reason)
    if finished then return end
    finished = true
    if unsubscribe then unsubscribe(); unsubscribe = nil end
    timer:stop()
    timer:close()
    for _, entry in ipairs(selected) do
      if entry.status == "pending" then entry.status = "timeout"; cancel(entry) end
    end
    if not Gate.valid(ctx) then return respond(Scope.error("stale session context")) end
    if reason then return respond(Runtime.failure("cancelled", reason, scope, observed, { startup = startup })) end
    for buf, snapshot in pairs(snapshots) do
      if not vim.api.nvim_buf_is_loaded(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= snapshot.tick
        or vim.api.nvim_buf_get_name(buf) ~= snapshot.name then
        return respond(Runtime.failure("buffer_changed", "Buffer changed during the LSP query; retry against the current contents.", scope, observed, { startup = startup }))
      end
    end
    local ok, out = pcall(function()
      local a, statuses, partial, requested = accumulator(scope, opts), {}, false, {}
      for _, entry in ipairs(selected) do requested[entry.client.id] = entry end
      observed = Runtime.observe(scope, methods[name], observed)
      for _, seen in ipairs(observed) do
        local entry, info = requested[seen.client.id], seen.info
        if entry then
          if info.state ~= "ready" then entry.status = "unavailable" end
          info.status, info.code = entry.status, entry.code
          partial = partial or entry.status ~= "ok"
          if entry.status == "ok" then normalize(name, a, entry.result, entry.client, target) end
        else
          partial = partial or info.state ~= "unsupported"
        end
        statuses[#statuses + 1] = info
      end
      return page(a, { status = partial and "partial" or "ok", clients = statuses, partial = partial,
        analysis_complete = false, startup = startup, root = target.root,
        message = "Per-client request results. Ready means protocol initialized and operation supported, NOT fully indexed. Empty results are not proof of complete analysis.",
        next_action = partial and { action = "retry", argument = "startup_timeout_ms", value = 120000 } or nil,
        target = not target.root and Scope.metadata(target) or nil })
    end)
    respond(ok and out or Runtime.failure("normalization_failed", "Could not normalize the language-server response; no successful empty query is implied.", scope, observed, { startup = startup }))
  end
  local function maybe_finish()
    if pending == 0 and not launching then vim.schedule(finish) end
  end
  if ctx and ctx.caller then
    unsubscribe = ctx.caller.session:subscribe_events(function(event)
      if event.kind == "reset" or event.kind == "stopped" or event.kind == "cancel_requested" then
        vim.schedule(function() finish("Session ended or cancelled the editor query") end)
      end
    end)
  end
  timer:start(opts.timeout_ms, 0, function() vim.schedule(finish) end)
  for _, entry in ipairs(selected) do
    local client, buf = entry.client, entry.buffer
    local encoding_ok = vim.tbl_contains({ "utf-8", "utf-16", "utf-32" }, client.offset_encoding or "utf-16")
    local params_ok, params = pcall(function()
      if not encoding_ok then error("unsupported position encoding") end
      if name == "workspace_symbols" then return { query = args.query } end
      local value = { textDocument = { uri = vim.uri_from_bufnr(buf) } }
      if position then
        value.position = { line = position.line,
          character = vim.str_utfindex(position.text, client.offset_encoding or "utf-16", position.byte, true) }
      end
      if name == "references" then value.context = { includeDeclaration = args.include_declaration ~= false } end
      return value
    end)
    local function complete(err, result)
      if finished or entry.status ~= "pending" then return end
      entry.status = err and "error" or "ok"
      entry.code = type(err) == "table" and type(err.code) == "number" and err.code or nil
      entry.result = result
      pending = pending - 1
      maybe_finish()
    end
    local ok, accepted, id
    if params_ok then ok, accepted, id = pcall(client.request, client, methods[name], params, complete, buf) end
    if not ok or not accepted then
      complete({ code = -32603 })
    else
      entry.request_id = id
    end
  end
  launching = false
  maybe_finish()
end

local descriptions = {
  diagnostics = "Get cached diagnostics from all namespaces, including non-LSP linters. Pass path OR buffer, or omit both for workspace cache aggregation (optional root). A specific file MUST already be loaded unless load=true explicitly permits background loading and normal configured LSP startup. Reports every observed client separately: initializing, no report, unversioned/stale report, or current-version report. diagnostic_timeout_ms waits per client; workspace aggregation is cache-only. Empty items NEVER prove clean: can_conclude_clean=false.",
  document_symbols = "Get document symbols from language servers already attached to a loaded buffer. Pass exactly one of path or buffer. Returns flattened symbols with parent/container and selection ranges. No file loading or configured server startup unless load=true explicitly opts in; it never navigates or saves.",
  workspace_symbols = "Search workspace symbols using already-attached language servers with readable buffers in root (default: calling session's project). Only authorized local-file results within root are returned. Unresolved symbols may have a null range. This aggregate query never loads files or starts servers. Use a file-targeted tool with load=true to prepare a file first.",
  definition = "Find definitions at a position in a loaded buffer using already-attached language servers. Pass exactly one of path or buffer, plus line and column. Returns normalized locations/LocationLinks; unreadable targets are filtered. load=true explicitly permits hidden-buffer loading and normal configured LSP startup; otherwise the target MUST already be loaded. Never navigates or saves.",
  references = "Find references at a position in a loaded buffer using already-attached language servers. Pass exactly one of path or buffer, plus line and column. include_declaration defaults true. Returned file locations are permission-filtered. load=true explicitly permits hidden-buffer loading and normal configured LSP startup; otherwise the target MUST already be loaded. Never navigates or saves.",
  hover = "Get hover text at a position in a loaded buffer from already-attached language servers. Pass exactly one of path or buffer, plus line and column. Preserves plaintext/markdown, with a bounded text budget. No file loading or configured server startup unless load=true explicitly opts in; it never navigates or saves.",
}

local function schema(name)
  local props = {
    limit = { type = "integer", description = "Maximum items returned, default 100, maximum 1000", minimum = 1, maximum = 1000 },
    offset = { type = "integer", description = "Zero-based result offset for pagination, default 0", minimum = 0 },
  }
  if name == "workspace_symbols" then
    props.query = { type = "string", description = "Symbol query, including an empty string for all symbols (up to 4096 bytes)" }
  else
    props.load = { type = "boolean", description = "Explicitly allow loading an existing file into a hidden, unlisted buffer and running normal filetype/LSP setup. Default false: an unloaded target is rejected. Loaded buffers remain open; no save or visible window is requested." }
    props.path = { type = "string", description = "File path, absolute or relative to the calling session's project; mutually exclusive with buffer" }
    props.buffer = { type = { "integer", "string" }, description = "Existing buffer id or exact name/unambiguous suffix, mutually exclusive with path" }
  end
  if name == "diagnostics" or name == "workspace_symbols" then
    props.root = { type = "string", description = "Aggregate query directory, default calling session's project; cannot be combined with path or buffer" }
  end
  if name == "diagnostics" then
    props.diagnostic_timeout_ms = { type = "integer", minimum = 0, maximum = 120000, description = "Wait for current-version reports from EACH observed client, including empty reports. A positive wait requires path or buffer; workspace queries are cache-only. Default 30000 after load=true, otherwise 0 (cache snapshot). Unknown push-diagnostic support is not treated as no diagnostics. Maximum 120000." }
    props.severity = { type = "string", enum = severity_names, description = "Exact severity filter: error, warning, information, or hint" }
    props.source = { type = "string", description = "Exact diagnostic source filter (all sources by default)" }
  else
    props.timeout_ms = { type = "integer", description = "Overall LSP deadline in milliseconds, default 3000, maximum 30000", minimum = 1, maximum = 30000 }
  end
  if name == "definition" or name == "references" or name == "hover" then
    props.line = { type = "integer", description = "1-based line in the live buffer", minimum = 1 }
    props.column = { type = "integer", description = "1-based UTF-8 byte column at a character boundary (not LSP UTF-16 units)", minimum = 1 }
  end
  if name == "references" then
    props.include_declaration = { type = "boolean", description = "Include the declaration, default true" }
  elseif name == "hover" then
    props.max_chars = { type = "integer", description = "Total hover-text budget in Unicode characters, default 16000, maximum 64000", minimum = 1, maximum = 64000 }
  end
  props.startup_timeout_ms = { type = "integer", minimum = 0, maximum = 300000, description = "Separate asynchronous attachment/initialization deadline. Waits for a client supporting the requested operation, even if an unsupported client attaches first. Default 120000 after load=true or when clients are initializing, otherwise 0. Set 0 for immediate status. Maximum 300000. Reports every client's state; a ready formatter cannot satisfy another client's diagnostic readiness." }
  local required = {}
  if name == "workspace_symbols" then required = { "query" }
  elseif name == "definition" or name == "references" or name == "hover" then required = { "line", "column" } end
  return { type = "object", properties = props, required = required, additionalProperties = false }
end

for _, name in ipairs(M.names) do
  M[name] = {
    description = descriptions[name] .. " Positions use 1-based lines and UTF-8 byte columns, with exclusive range ends. limit defaults 100 (max 1000); offset paginates. Startup/attachment waiting is separate from the 3000ms request timeout (max 30000). startup_timeout_ms defaults 120000 after load=true or while clients initialize, otherwise 0; set 0 for immediate status. Responses list all observed clients, including initializing and unsupported ones. Ready does NOT mean indexing finished; analysis_complete=false and empty results are not proof of complete analysis.",
    inputSchema = schema(name),
    annotations = { readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false },
    async = true,
    handler = function(args, respond, ctx)
      local opts = options(name, args)
      Scope.open(name, args, ctx, name == "diagnostics" or name == "workspace_symbols", respond, function(scope)
        if not scope.allows(scope.target.resource) then return respond(Scope.error("Read permission denied for editor query scope")) end
        if not Runtime.prepare(scope, args, respond, ctx) then return end
        if name == "definition" or name == "references" or name == "hover" then
          request_position(scope.target.buffer, args)
        end
        Runtime.await_start(scope, args, opts, ctx, respond, function(observed, ready, startup)
          if name == "diagnostics" then
            Runtime.await_diagnostics(scope, args, opts, ctx, respond, observed, function(entries, timing)
              diagnostics(scope, args, opts, respond, entries, startup, timing)
            end)
          else
            query(name, scope, args, opts, respond, ctx, ready, observed, startup)
          end
        end, methods[name])
      end)
    end,
  }
end

function M.resource(name, args, ctx)
  return Scope.target(args, ctx, name == "diagnostics" or name == "workspace_symbols").resource
end

return M
