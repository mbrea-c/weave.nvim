-- A recorded diagnostics result, not a subscription to the editor's live cache.
-- Raw arguments/results stay behind K; expansion is a human-readable report.
local ui = require("fibrous.inline.components")
local ToolCall = require("weave.view.tool_call")

local M = {}
local PREVIEW_ITEMS, DETAIL_ITEMS, MAX_CLIENTS = 3, 100, 32
local MAX_JSON_BYTES, MAX_ITEMS = 8 * 1024 * 1024, 1000
local severities = {
  error = { rank = 1, letter = "E", name = "error", hl = "DiagnosticError" },
  warning = { rank = 2, letter = "W", name = "warning", hl = "DiagnosticWarn" },
  information = { rank = 3, letter = "I", name = "info", hl = "DiagnosticInfo" },
  hint = { rank = 4, letter = "H", name = "hint", hl = "DiagnosticHint" },
}
local unknown = { rank = 5, letter = "?", name = "other", hl = "@comment" }
local successful = { ok = true, diagnostics_pending = true, diagnostics_unconfirmed = true }
local report_labels = {
  not_received = "no report received", version_unknown = "unversioned report",
  stale = "stale report", current_version = "current-version report",
}

local function integer(value, fallback)
  return type(value) == "number" and value >= 0 and value < math.huge
    and value == math.floor(value) and value or fallback
end

local function text(value, limit, multiline)
  if type(value) ~= "string" and type(value) ~= "number" then return "" end
  local s = tostring(value):gsub("[%z\1-\8\11\12\14-\31\127]", "?")
  if not multiline then s = s:gsub("[\r\n]+", " ") end
  if vim.fn.strchars(s) > limit then return vim.fn.strcharpart(s, 0, limit) .. "..." end
  return s
end

local function is_report(value)
  return type(value) == "table" and type(value.status) == "string"
    and type(value.can_conclude_clean) == "boolean" and type(value.items) == "table"
    and vim.islist(value.items) and #value.items <= MAX_ITEMS
end

-- Providers report either structured data, MCP text content, or ACP body lines.
-- Bound decoding and traversal, including malformed/cyclic provider payloads.
local function decode(value, depth)
  if depth > 5 then return nil end
  if type(value) == "string" then
    if #value > MAX_JSON_BYTES then return nil end
    local ok, parsed = pcall(vim.json.decode, value)
    if ok and type(parsed) == "table" then return decode(parsed, depth + 1) end
  elseif type(value) == "table" then
    if is_report(value) then return value, value.isError == true end
    for _, key in ipairs({ "structuredContent", "result", "output", "text" }) do
      local parsed, failed = decode(value[key], depth + 1)
      if parsed then return parsed, failed or value.isError == true end
    end
    if type(value.content) == "table" then
      for i = 1, math.min(#value.content, 32) do
        local part = value.content[i]
        if type(part) == "table" and part.type == "text" then
          local parsed, failed = decode(part.text, depth + 1)
          if parsed then return parsed, failed or value.isError == true end
        end
      end
    end
  end
  return nil
end

local function position(item)
  local range = type(item.range) == "table" and item.range or {}
  local at = type(range.start) == "table" and range.start or {}
  local line, column = integer(at.line), integer(at.column)
  if line and line > 0 and column and column > 0 then return line, column end
end

local function file_key(item)
  return type(item.path) == "string" and item.path ~= "" and item.path
    or ("buffer:" .. tostring(integer(item.buffer, "?")))
end

local function short_path(path)
  if path:sub(1, 7) == "buffer:" then return path end
  return text(vim.fn.fnamemodify(path, ":~:."), 512)
end

local function ordered(a, b)
  local sa, sb = severities[a.severity] or unknown, severities[b.severity] or unknown
  if sa.rank ~= sb.rank then return sa.rank < sb.rank end
  local ka, kb = file_key(a), file_key(b)
  if ka ~= kb then return ka < kb end
  local la, ca = position(a)
  local lb, cb = position(b)
  if la ~= lb then return (la or 0) < (lb or 0) end
  if ca ~= cb then return (ca or 0) < (cb or 0) end
  return a._index < b._index
end

local function model(block)
  local report, failed = decode(block.output, 0)
  if not report and type(block.body) == "table" then
    local parts, bytes = {}, 0
    for _, line in ipairs(block.body) do
      if type(line) ~= "string" then break end
      bytes = bytes + #line + 1
      if bytes > MAX_JSON_BYTES then break end
      parts[#parts + 1] = line
    end
    if bytes <= MAX_JSON_BYTES then report, failed = decode(table.concat(parts, "\n"), 0) end
  end
  if not report then return nil end
  local items, counts = {}, {}
  for i, item in ipairs(report.items) do
    if type(item) ~= "table" or type(item.message) ~= "string" then return nil end
    local copy = vim.tbl_extend("force", {}, item, { _index = i })
    items[#items + 1] = copy
    local severity = severities[item.severity] and item.severity or "other"
    counts[severity] = (counts[severity] or 0) + 1
  end
  table.sort(items, ordered)
  local grouped = vim.list_slice(items)
  table.sort(grouped, function(a, b)
    local ka, kb = file_key(a), file_key(b)
    return ka ~= kb and ka < kb or ka == kb and ordered(a, b)
  end)
  return { report = report, failed = failed or not successful[report.status],
    items = items, grouped = grouped, counts = counts }
end

local function line(value, hl)
  return { comp = ui.text, props = { text = value, wrap = "word", style = { text_hl = hl or "@comment" } } }
end

local function column(children)
  return { comp = ui.col, props = { style = { padding = { left = 4 } } }, children = children }
end

--- Only explicit location activation loads a file or changes the user's window.
--- Coordinates in the stored result are 1-based UTF-8 byte columns.
--- @param item table
--- @return boolean
function M.open_location(item)
  local lnum, col = position(item)
  if not lnum then return false end
  local path = type(item.path) == "string" and item.path ~= "" and item.path or nil
  if path and (path:find("%z") or path:match("^%a[%w+.-]*://")) then return false end
  local buf = path and vim.fn.bufnr(path) or integer(item.buffer)
  if not buf or buf < 1 or not vim.api.nvim_buf_is_valid(buf) then buf = nil end
  -- bufnr() also accepts patterns; recorded file names must match literally.
  if buf and path and vim.api.nvim_buf_get_name(buf) ~= vim.fn.fnamemodify(path, ":p") then buf = nil end
  if path then
    if not buf or not vim.api.nvim_buf_is_loaded(buf) then
      local stat = vim.uv.fs_stat(path)
      if not stat or stat.type ~= "file" then return false end
    end
  elseif not buf or not vim.api.nvim_buf_is_loaded(buf) then
    return false
  end
  local target
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local shown = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative == "" and vim.bo[shown].buftype == "" then
      target = target or win
      if shown == buf then target = win; break end
    end
  end
  if not target then return false end
  local ok = pcall(function()
    vim.api.nvim_set_current_win(target)
    if buf then vim.api.nvim_win_set_buf(target, buf)
    else vim.api.nvim_cmd({ cmd = "edit", args = { path } }, {}) end
    local current = vim.api.nvim_win_get_buf(target)
    lnum = math.min(lnum, vim.api.nvim_buf_line_count(current))
    local source = vim.api.nvim_buf_get_lines(current, lnum - 1, lnum, false)[1] or ""
    vim.api.nvim_win_set_cursor(target, { lnum, math.min(col - 1, #source) })
  end)
  return ok
end

local function diagnostic_row(item, expanded)
  local severity = severities[item.severity] or unknown
  local lnum, col = position(item)
  local label = severity.letter .. " " .. (lnum and (lnum .. ":" .. col) or "?:?")
  local location = { comp = ui.label, props = { text = label, style = { text_hl = severity.hl } } }
  if lnum and (type(item.path) == "string" or integer(item.buffer)) then
    location = { comp = ui.button, props = {
      label = label, theme = false, style = { text_hl = severity.hl, _hover = { hl = "FibrousHover" } },
      on_press = function()
        if not M.open_location(item) then
          vim.notify("weave: diagnostic target is unavailable", vim.log.levels.WARN)
        end
      end,
    } }
  end
  local description = text(item.message, expanded and 2048 or 160, expanded)
  local origin = text(item.source, 100)
  local code = text(item.code, 100)
  if code ~= "" then origin = origin ~= "" and (origin .. "/" .. code) or code end
  local spans = { { description, hl = severity.hl } }
  if origin ~= "" then spans[#spans + 1] = { " [" .. origin .. "]", hl = "@comment" } end
  if item.truncated then spans[#spans + 1] = { " [truncated by tool]", hl = "@comment" } end
  return { comp = ui.row, props = { gap = 1 }, children = {
    location, { comp = ui.text, props = { text = spans, grow = 1, wrap = "char" } },
  } }
end

local function append_items(rows, items, limit, expanded, grouped)
  local shown, previous = math.min(#items, limit), nil
  for i = 1, shown do
    local item, key = items[i], file_key(items[i])
    if grouped and key ~= previous then
      rows[#rows + 1] = line(short_path(key), "Title")
      previous = key
    end
    rows[#rows + 1] = diagnostic_row(item, expanded)
  end
  if shown < #items then
    rows[#rows + 1] = line(("%d more returned diagnostics; %s"):format(#items - shown,
      expanded and "K for full result." or "expand to view."))
  end
end

--- @param props table
function M.Body(_, props)
  local data, block = props.diagnostics, props.block
  if not data then
    local waiting = block.status == nil or block.status == "pending" or block.status == "in_progress"
    return column({ line(waiting and "Waiting for diagnostics result..."
      or "Diagnostics result unavailable; K for raw details.", waiting and "@comment" or "DiagnosticWarn") })
  end
  local report, rows = data.report, {}
  if data.failed then
    local status = props.block.status == "failed" and "request failed" or text(report.status, 80)
    rows[#rows + 1] = line("Not checked (" .. status .. ")", "DiagnosticWarn")
    rows[#rows + 1] = line(text(report.message, 1024, true))
    return column(rows)
  end
  local summary = {}
  for _, key in ipairs({ "error", "warning", "information", "hint", "other" }) do
    local count, severity = data.counts[key], severities[key] or unknown
    if count then
      if #summary > 0 then summary[#summary + 1] = { " | ", hl = "@comment" } end
      summary[#summary + 1] = { count .. " " .. severity.name .. (count == 1 and "" or "s"), hl = severity.hl }
    end
  end
  rows[#rows + 1] = line(#summary > 0 and summary or "0 diagnostics")
  rows[#rows + 1] = line("Cached snapshot; coverage incomplete")
  if report.diagnostic_scope == "workspace_cache" then
    rows[#rows + 1] = line("Workspace cache; files may not have reported.")
  end
  local offset, total = integer(report.offset, 0), integer(report.total, #data.items)
  if offset > 0 or total > #data.items or report.truncated then
    local range = #data.items > 0 and (offset + 1) .. "-" .. (offset + #data.items) or "0"
    rows[#rows + 1] = line(range .. " of " .. total .. " | counts are for the returned page")
  end
  if report.filtered then rows[#rows + 1] = line("Some results were omitted by permissions.") end
  if #data.items == 0 then
    rows[#rows + 1] = line("No diagnostics in this snapshot; completeness is not established.")
  elseif not props.expanded then
    append_items(rows, data.items, PREVIEW_ITEMS, false, report.diagnostic_scope == "workspace_cache")
  end
  return column(rows)
end

local function timing(rows, title, value)
  if type(value) ~= "table" then return end
  rows[#rows + 1] = line(("%s: %d / %d ms%s"):format(title,
    integer(value.waited_ms, 0), integer(value.timeout_ms, 0), value.timed_out and " (timed out)" or ""))
end

--- Expanded details deliberately replace raw input/output and duplicate JSON.
--- @param props table
function M.Details(_, props)
  local data = props.diagnostics
  if not data then return nil end
  local report, rows = data.report, {}
  local input = type(props.block.input) == "table" and props.block.input or {}
  local filters = {}
  for _, key in ipairs({ "severity", "source" }) do
    if type(input[key]) == "string" then filters[#filters + 1] = key .. "=" .. text(input[key], 160) end
  end
  if #filters > 0 then rows[#rows + 1] = line("Filters: " .. table.concat(filters, " | ")) end
  if not data.failed then
    append_items(rows, data.grouped, DETAIL_ITEMS, true, true)
    local next_offset = integer(report.next_offset)
    if next_offset then rows[#rows + 1] = line("More results available; next offset: " .. next_offset) end
  end
  local clients = type(report.clients) == "table" and report.clients or {}
  rows[#rows + 1] = line("Language servers", "Title")
  if #clients == 0 then rows[#rows + 1] = line("No language server observed for this scope.") end
  for i = 1, math.min(#clients, MAX_CLIENTS) do
    local client = type(clients[i]) == "table" and clients[i] or {}
    local diagnostic = type(client.diagnostics) == "table" and client.diagnostics or {}
    local state = text(client.state, 80)
    local status = report_labels[diagnostic.state] or "report state unknown"
    local count = integer(diagnostic.report_count)
    rows[#rows + 1] = line(text(client.name, 160) .. ": " .. state .. " | " .. status
      .. (count and (" (" .. count .. " diagnostics)") or ""))
  end
  if #clients > MAX_CLIENTS then rows[#rows + 1] = line((#clients - MAX_CLIENTS) .. " more servers; K for full result.") end
  rows[#rows + 1] = line("Initialized does not mean indexing or analysis is complete.")
  timing(rows, "Startup", report.startup)
  timing(rows, "Diagnostic wait", report.diagnostic_wait)
  local action = type(report.next_action) == "table" and report.next_action or {}
  if type(action.message) == "string" then rows[#rows + 1] = line(text(action.message, 512)) end
  return column(rows)
end

--- Decode once per changed result, not once per redraw/expansion.
--- @param ctx table
--- @param props weave.view.ToolCallProps
function M.Render(ctx, props)
  local ref, block = ctx.use_ref(), props.block
  local cached = ref.current
  if not cached or cached.output ~= block.output or cached.body ~= block.body then
    cached = { output = block.output, body = block.body, data = model(block) }
    ref.current = cached
  end
  local data = cached.data
  if data and (block.status == "failed" or type(block.output) == "table" and block.output.isError == true) then
    data = vim.tbl_extend("force", {}, data, { failed = true })
  end
  return { comp = ToolCall.Entry, props = vim.tbl_extend("force", {}, props, {
    diagnostics = data, render_body = M.Body, render_metadata = M.Details,
  }) }
end

function M.install()
  ToolCall.register({
    name = "weave.lsp.diagnostics",
    match = function(block) return ToolCall.weave_tool(block) == "diagnostics" end,
    render = M.Render,
  })
end

return M
