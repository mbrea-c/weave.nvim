-- An old/new line pair rendered through fibrous's ui.diff (roadmap R6):
-- treesitter syntax highlighting UNDER the DiffAdd/DiffDelete line fills, a
-- sign column, folded context, and (opt-in) real line numbers. Store-agnostic
-- (props in, vnode out) — the transcript's native edit path, the fs-tool
-- renderers and anything a plugin registers all draw through here, so every
-- diff weave shows picks the upgrade up at once.
--
-- `path` rides along for LANGUAGE inference only (ui.diff resolves it via
-- vim.filetype.match): transcript entries already name the file in their own
-- header, so the component's reference header stays off.
--
-- Line numbers default OFF because a transcript diff is usually a FRAGMENT
-- pair (an edit tool's old_string/new_string, an ACP diff part of unknown
-- extent), and numbering a fragment from 1 would claim file lines it doesn't
-- have. A caller that really diffs whole files (the write renderer, which
-- diffs the pre-write snapshot against the written content) opts in.

local ui = require("fibrous.inline.components")

local M = {}

--- @param _ table ctx (unused; ui.diff keeps its memo on its own fiber)
--- @param props { old?: string[], new?: string[], path?: string, lang?: string, line_numbers?: boolean, start_line?: integer, max_lines?: integer, indent?: string, style?: table }
---   max_lines caps the rendered rows (a dimmed "… diff truncated" marker
---   follows); indent shifts the whole block right (default "").
function M.Diff(_, props)
  local style = props.style
  local indent = props.indent and #props.indent or 0
  if indent > 0 then
    style = vim.tbl_deep_extend("force", { padding = { left = indent } }, style or {})
  end
  return {
    comp = ui.diff,
    props = {
      before = table.concat(props.old or {}, "\n"),
      after = table.concat(props.new or {}, "\n"),
      lang = props.lang,
      ref = props.path and { path = props.path } or nil,
      header = false,
      line_numbers = props.line_numbers == true,
      start_line = props.start_line,
      max_lines = props.max_lines,
      style = style,
    },
  }
end

return M
