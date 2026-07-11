-- An old/new line pair as a properly INTERLEAVED unified diff (roadmap R6).
-- Store-agnostic (props in, vnodes out) — extracted from
-- the transcript's inline diff preview so any view can render one. vim.diff
-- gives minimal line-level hunks with context and +/-/space gutters; each
-- line maps to a Diff* highlight (hunk headers dim to @comment).
--
-- Syntax highlighting layered UNDER the Diff* colors is out of scope for
-- now: fibrous spans carry ONE hl per run, so fg-syntax + bg-diff stacking
-- would need combined highlight groups.

local ui = require("fibrous.inline.components")

local M = {}

--- @param ctx table
--- @param props { old?: string[], new?: string[], max_lines?: integer, indent?: string, style?: table }
---   max_lines caps the rendered rows (a dimmed "… diff truncated" marker
---   follows); indent prefixes every row (default "").
function M.Diff(ctx, props)
  local indent = props.indent or ""
  local old_str = table.concat(props.old or {}, "\n")
  local new_str = table.concat(props.new or {}, "\n")

  -- vim.diff is pure on its inputs — cache per (old, new) like markdown's
  -- parse, so settled tool calls never re-diff on unrelated flushes.
  local cache = ctx.use_ref()
  if cache.old ~= old_str or cache.new ~= new_str then
    cache.old, cache.new = old_str, new_str
    cache.unified = vim.diff(old_str, new_str, { result_type = "unified", ctxlen = 3 }) or ""
  end

  local children = {}
  if cache.unified ~= "" then
    local rendered = 0
    for _, raw in ipairs(vim.split(cache.unified, "\n")) do
      -- Skip the blank tail and the "\ No newline at end of file" marker.
      if raw ~= "" and raw:sub(1, 1) ~= "\\" then
        if props.max_lines and rendered >= props.max_lines then
          children[#children + 1] = {
            comp = ui.label,
            props = { text = indent .. "… diff truncated", style = { text_hl = "@comment" } },
          }
          break
        end
        local c = raw:sub(1, 1)
        local hl
        if c == "@" then
          hl = "@comment" -- @@ hunk header, dimmed
        elseif c == "+" then
          hl = "DiffAdd"
        elseif c == "-" then
          hl = "DiffDelete"
        end
        children[#children + 1] = {
          comp = ui.label,
          props = { text = { indent, hl and { raw, hl = hl } or raw } },
        }
        rendered = rendered + 1
      end
    end
  end

  return { comp = ui.col, props = { style = props.style }, children = children }
end

return M
