local ui = require("fibrous.inline.components")
local ToolCall = require("weave.view.tool_call")
local Output = require("weave.tool_output")
local M = { output = Output }

function M.clean(value, limit, multiline)
  if type(value) ~= "string" and type(value) ~= "number" then return "" end
  local s = tostring(value):gsub("\27%[[0-?]*[ -/]*[@-~]", ""):gsub("[%z\1-\8\11\12\14-\31\127]", "?")
  if not multiline then s = s:gsub("[\r\n]+", " ") end
  if limit and vim.fn.strchars(s) > limit then return vim.fn.strcharpart(s, 0, limit) .. "..." end
  return s
end

function M.line(value, hl)
  return { comp = ui.text, props = { text = value, wrap = "char", style = { text_hl = hl or "@comment" } } }
end

function M.column(children)
  return { comp = ui.col, props = { style = { padding = { left = 4 } } }, children = children }
end

-- A wrapped code snippet with a gutter per logical source line. Fibrous's
-- ui.code intentionally does not wrap; using it directly here would clip long
-- commands and misalign line numbers if only its text child were wrapped.
function M.Code(ctx, props)
  local code = M.clean(props.code or "", nil, true)
  local ref, lang = ctx.use_ref(), props.lang
  if not lang and props.path then
    local ok, ft = pcall(vim.filetype.match, { filename = props.path })
    if ok then lang = ft end
  end
  local memo = ref.current
  if not memo or memo.code ~= code or memo.lang ~= lang then
    memo = { code = code, lang = lang, plain = vim.split(code, "\n", { plain = true }),
      highlighted = require("fibrous.doc.highlight").code_lines(code, lang) }
    ref.current = memo
  end
  local shown, start = math.min(#memo.plain, props.max_lines or math.huge), props.start_line or 1
  local rows, width = {}, #tostring(start + #memo.plain - 1)
  if props.title then rows[#rows + 1] = M.line(props.title, "Comment") end
  local offset = 0
  for i = 1, shown do
    local content = memo.highlighted and memo.highlighted[i] or memo.plain[i]
    if content == "" then content = " " end
    local source = props.source and vim.tbl_extend("force", {}, props.source, { offset = offset }) or nil
    local body = { comp = ui.text, props = { text = content, wrap = "char", grow = 1, source = source,
      style = { text_hl = "@markup.raw" } } }
    offset = offset + #memo.plain[i] + 1
    if props.line_numbers == false then rows[#rows + 1] = body
    else
      rows[#rows + 1] = { comp = ui.row, props = { gap = 1 }, children = {
        { comp = ui.label, props = { text = string.format("%" .. width .. "d", start + i - 1),
          style = { text_hl = "FibrousCodeGutter" } } }, body,
      } }
    end
  end
  if shown < #memo.plain then rows[#rows + 1] = M.line((#memo.plain - shown) .. " more lines; expand to view.") end
  return { comp = ui.col, props = { style = props.title and {
    border = { left = true, hl = "Comment" }, padding = { left = 1 },
  } or nil }, children = rows }
end

function M.nothing() return nil end

-- New detail views are header-only until explicitly expanded. Only existing
-- edit/write diff previews opt into an always-visible body.
function M.entry(props, body, details, extra, collapsed_preview)
  return { comp = ToolCall.Entry, props = vim.tbl_extend("force", {}, props, extra or {}, {
    render_body = (props.expanded or collapsed_preview) and body or M.nothing,
    render_metadata = details or M.nothing,
  }) }
end

-- Parse once per immutable recorded result; expansion must not rerun a query.
function M.cached(ctx, block, parse)
  local ref = ctx.use_ref()
  if not ref.current or ref.current.output ~= block.output or ref.current.body ~= block.body
    or ref.current.input ~= block.input then
    ref.current = { output = block.output, body = block.body, input = block.input, data = parse(block) }
  end
  return ref.current.data
end

function M.notice(block)
  local waiting = block.status == nil or block.status == "pending" or block.status == "in_progress"
  return M.line(waiting and "Waiting for tool result..."
    or Output.failed(block) and "Tool failed; K for raw details."
    or "Result unavailable or unsupported; K for raw details.", waiting and "@comment" or "DiagnosticWarn")
end

function M.location(item, label)
  local range = type(item.selection_range) == "table" and item.selection_range or item.range
  local at = type(range) == "table" and range.start
  local valid = type(at) == "table" and type(at.line) == "number" and at.line >= 1
    and at.line % 1 == 0 and type(at.column) == "number" and at.column >= 1 and at.column % 1 == 0
  if not valid or not (type(item.path) == "string" and item.path ~= "" or type(item.buffer) == "number") then
    return M.line(label)
  end
  local target = vim.tbl_extend("force", {}, item, { range = range })
  return { comp = ui.button, props = { label = label, theme = false, wrap = "char",
    style = { text_hl = "Directory", _hover = { hl = "FibrousHover" } },
    on_press = function()
      if not require("weave.view.renderers.diagnostics").open_location(target) then
        vim.notify("weave: recorded location is unavailable", vim.log.levels.WARN)
      end
    end,
  } }
end

function M.page(rows, data, shown, noun)
  noun = noun or "results"
  if data.filtered then rows[#rows + 1] = M.line("Some results were omitted by permissions.") end
  if data.truncated or (type(data.total) == "number" and data.total > shown) or (data.offset or 0) > 0 then
    rows[#rows + 1] = M.line(("Returned page: offset %s, %d shown%s%s"):format(
      tostring(data.offset or 0), shown, type(data.total) == "number" and (" of " .. data.total) or "",
      data.truncated and " (truncated)" or ""))
  end
  if type(data.next_offset) == "number" then rows[#rows + 1] = M.line("Next offset: " .. data.next_offset) end
  if shown == 0 then rows[#rows + 1] = M.line("No " .. noun .. " in the returned result.") end
end

function M.omitted(rows, total, shown, expanded)
  if shown < total then rows[#rows + 1] = M.line(("%d more returned entries; %s"):format(
    total - shown, expanded and "K for full result." or "expand to view.")) end
end

return M
