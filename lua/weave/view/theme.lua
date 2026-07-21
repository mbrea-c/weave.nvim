-- Highlight groups + glyph tables for the fibrous view. Pure data + one-time
-- highlight-group setup (no view state). Ported from agentic's
-- reactive/view/theme.lua. Defining the groups at module load is intentional:
-- it runs once when the view is first required, and every group uses
-- `default = true` so a user's explicit :highlight always wins.

local M = {}

--- Glyphs for tool-call status. `awaiting_permission` is not an ACP status —
--- it's derived in the view when a pending permission request targets the
--- tool call. ACP has no "cancelled" status; the protocol enum is pending /
--- in_progress / completed / failed.
M.STATUS_ICON = {
  pending = "○",
  in_progress = "◐",
  completed = "●",
  failed = "✗",
  awaiting_permission = "",
}

-- One glyph per ACP ToolKind so a tool-call header is self-describing even
-- when the agent sends no title. Unknown kinds fall back to "other".
M.KIND_ICON = {
  read = " ",
  edit = " ",
  delete = " ",
  move = " ",
  search = " ",
  execute = " ",
  think = " ",
  fetch = " ",
  other = " ",
}

-- Collapsed/expanded affordance drawn at the head of every tool-call row.
M.CHEVRON = { collapsed = "", expanded = "" }

-- Default foreground per tool-call status. These seed the standalone
-- WeaveToolHeader*/WeaveToolKindTag* groups below; they are NOT derived
-- from Diagnostic* (a theme's DiagnosticInfo is often ~Normal fg). Users are
-- expected to set these groups explicitly — the defaults are just sensible
-- initial colours.
local STATUS_DEFAULT_FG = {
  pending = "#7aa2f7", -- blue
  in_progress = "#e0af68", -- amber
  completed = "#9ece6a", -- green
  failed = "#f7768e", -- red
  awaiting_permission = "#bb9af7", -- purple
}

--- status -> header highlight group name (plain, status colour).
--- @type table<string, string>
M.HEADER_HL = {}
--- status -> kind-tag highlight group name (bold, same status colour).
--- @type table<string, string>
M.KIND_TAG_HL = {}

local function status_suffix(status)
  return status
    :gsub("_(%l)", function(c)
      return c:upper()
    end)
    :gsub("^%l", string.upper)
end

-- Define the user-facing groups ONCE with { default = true }, so an explicit
-- user :highlight/nvim_set_hl always wins and is never clobbered.
for status, fg in pairs(STATUS_DEFAULT_FG) do
  local suffix = status_suffix(status)
  M.HEADER_HL[status] = "WeaveToolHeader" .. suffix
  M.KIND_TAG_HL[status] = "WeaveToolKindTag" .. suffix
  vim.api.nvim_set_hl(0, M.HEADER_HL[status], { fg = fg, default = true })
  vim.api.nvim_set_hl(0, M.KIND_TAG_HL[status], { fg = fg, bold = true, default = true })
end

-- Context-usage bar (sidebar Usage section): a horizontal fill drawn with block
-- octants (a 2x4 sub-canvas per cell). Full cells are █; the boundary cell fills
-- an octant column-major — left column bottom-up to a half-lit ▌, then the right
-- to full — so a W-cell bar resolves 8W steps, one glyph doing a whole cell's
-- worth of precision. The lit glyphs are FOREGROUND-coloured by fullness (green
-- with headroom, amber past two thirds, red near the cap — the tool-status
-- palette); every cell, lit or not, carries the SAME background tint so a
-- partially-lit octant's unlit sub-cells read as the track, not a hole. The bg
-- is therefore baked into the fill groups too, not just the track group (a text
-- span replaces the cell highlight, so a node background wouldn't show under it).
-- default = true keeps a user override authoritative.
local USAGE_TRACK_BG = "#3b4261" -- subtle slate under the whole bar row
M.USAGE_BAR_HL = {
  low = "WeaveUsageBarLow",
  mid = "WeaveUsageBarMid",
  high = "WeaveUsageBarHigh",
}
M.USAGE_TRACK_HL = "WeaveUsageBarTrack"
vim.api.nvim_set_hl(0, M.USAGE_BAR_HL.low, { fg = STATUS_DEFAULT_FG.completed, bg = USAGE_TRACK_BG, default = true })
vim.api.nvim_set_hl(0, M.USAGE_BAR_HL.mid, { fg = STATUS_DEFAULT_FG.in_progress, bg = USAGE_TRACK_BG, default = true })
vim.api.nvim_set_hl(0, M.USAGE_BAR_HL.high, { fg = STATUS_DEFAULT_FG.failed, bg = USAGE_TRACK_BG, default = true })
vim.api.nvim_set_hl(0, M.USAGE_TRACK_HL, { bg = USAGE_TRACK_BG, default = true })

-- Thinking tag: link to @comment as a default so it tracks the theme's
-- comment colour out of the box, while a user override still wins.
M.THINKING_TAG_HL = "WeaveThinkingTag"
vim.api.nvim_set_hl(0, M.THINKING_TAG_HL, { link = "@comment", default = true })

-- User-message highlight: blue italic so the user's own prompts stand out
-- from the agent's replies. Standalone user-owned group.
M.USER_MSG_HL = "WeaveUserMessage"
vim.api.nvim_set_hl(0, M.USER_MSG_HL, { fg = "#7aa2f7", italic = true, default = true })

--- Plan-task glyphs, one per status. The sidebar's task list uses these (NOT
--- STATUS_ICON, which is the tool-call vocabulary): pending stays a plain
--- outline, in-progress fills it, done/failed are check/cross. ACP's plan
--- enum has no "failed", but the tool-call enum does — mapped defensively in
--- case an agent sends it.
M.TASK_ICON = {
  pending = "□",
  in_progress = "■",
  completed = "✔",
  failed = "✖",
}

--- status -> icon highlight group (the TEXT dims separately via TASK_DONE_HL;
--- the icon keeps its colour and is never struck through). No pending entry:
--- a not-started task renders entirely plain.
--- @type table<string, string>
M.TASK_ICON_HL = {
  in_progress = "WeaveTaskIconInProgress",
  completed = "WeaveTaskIconDone",
  failed = "WeaveTaskIconFailed",
}
vim.api.nvim_set_hl(0, M.TASK_ICON_HL.in_progress, { fg = STATUS_DEFAULT_FG.in_progress, default = true })
vim.api.nvim_set_hl(0, M.TASK_ICON_HL.completed, { fg = STATUS_DEFAULT_FG.completed, default = true })
vim.api.nvim_set_hl(0, M.TASK_ICON_HL.failed, { fg = STATUS_DEFAULT_FG.failed, default = true })

-- Done/failed plan-task TEXT: strikethrough + comment-dim. `link` can't ADD
-- strikethrough to a linked group's attrs, so derive the dim colour from
-- @comment's fg and set it explicitly; re-derived on ColorScheme so it tracks
-- the active theme. default = true keeps a user override authoritative.
M.TASK_DONE_HL = "WeaveTaskDone"
local function define_task_done_hl()
  local comment = vim.api.nvim_get_hl(0, { name = "@comment", link = false })
  local fg = comment.fg or vim.api.nvim_get_hl(0, { name = "Comment", link = false }).fg
  vim.api.nvim_set_hl(0, M.TASK_DONE_HL, { fg = fg, strikethrough = true, default = true })
end
define_task_done_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("WeaveTaskDoneHl", { clear = true }),
  callback = define_task_done_hl,
})

-- Permission options that PERSIST: answering one writes a rule into weave's
-- client-side permission store, so it changes how every future call resolves
-- rather than just this one. Amber, the same "this is not the default path"
-- signal the auto prompt border uses.
M.PERMISSION_PERSIST_HL = "WeavePermissionPersist"
vim.api.nvim_set_hl(0, M.PERMISSION_PERSIST_HL, { fg = "#e0af68", bold = true, default = true })

-- Prompt border per permission PRESET (keyed by preset name; custom presets
-- fall back to normal): an ambient reminder of how permission requests are
-- being answered while typing. normal is the neutral fibrous border
-- (FibrousBorder) so the buffer-mounted sidebar reads as one surface — the
-- prompt is a PAINTED border, not a real float, and FloatBorder made it stand
-- out against the Normal background; auto is amber (everything allowed),
-- allow_edits purple — the mode palette from STATUS_DEFAULT_FG.
M.PROMPT_BORDER_HL = {
  normal = "WeavePromptBorderNormal",
  auto = "WeavePromptBorderAuto",
  allow_edits = "WeavePromptBorderAllowEdits",
}

M.PROMPT_TITLE_EXTRA = {
  normal = "normal",
  auto = "auto ⏵⏵",
  allow_edits = "allow edits ⏵",
}

vim.api.nvim_set_hl(0, M.PROMPT_BORDER_HL.normal, { link = "FibrousBorder", default = true })
vim.api.nvim_set_hl(0, M.PROMPT_BORDER_HL.auto, { fg = "#e0af68", default = true })
vim.api.nvim_set_hl(0, M.PROMPT_BORDER_HL.allow_edits, { fg = "#bb9af7", default = true })

-- Inline code feedback: the span a user has attached a comment to, highlighted
-- in the CODE buffer itself (not in weave's own windows), so it has to be
-- legible over an arbitrary colourscheme's syntax highlighting. Both fg and bg
-- are therefore set explicitly rather than tinting the bg alone and hoping the
-- theme's foregrounds stay readable on yellow. default = true, so a user who
-- finds a solid amber block too loud over their code can link this anywhere.
M.CODE_FEEDBACK_HL = "WeaveCodeFeedback"
vim.api.nvim_set_hl(0, M.CODE_FEEDBACK_HL, { fg = "#1a1b26", bg = "#e0af68", default = true })

-- Busy-water indicator. The height ramp is four groups (WeaveWater1..4, dim →
-- bright by fill height) plus a label group; UNLIKE the other groups these are
-- ANIMATED — view/water.lua rewrites their fg every frame while the sim runs,
-- fading between the per-state base colours below. So they're seeded here (no
-- `default`, since the component owns them) and the palette is exposed for
-- restyling. Consumed as `Theme.WATER_HL[height]` / `Theme.WATER_LABEL_HL`.
--- @type table<integer, string>
M.WATER_HL = { "WeaveWater1", "WeaveWater2", "WeaveWater3", "WeaveWater4" }
M.WATER_LABEL_HL = "WeaveWaterLabel"

-- The colour the water fades TOWARD in each activity state (blue idle → yellow
-- thinking → red generating; busy is the pre-stream warm-up; awaiting is the
-- agent blocked on YOUR approval — a distinct purple so a pending permission
-- reads as neither "your turn" nor plain streaming). `{r,g,b}` 0-255.
--- @type table<string, integer[]>
M.WATER_STATE_FG = {
  idle = { 0x5a, 0x7f, 0xd0 }, -- #5a7fd0 blue
  thinking = { 0xe0, 0xaf, 0x68 }, -- #e0af68 yellow
  generating = { 0xf7, 0x76, 0x8e }, -- #f7768e red
  busy = { 0xff, 0x9e, 0x64 }, -- #ff9e64 orange
  awaiting = { 0xbb, 0x9a, 0xf7 }, -- #bb9af7 purple — agent blocked on YOUR approval
}
for _, group in ipairs(M.WATER_HL) do
  vim.api.nvim_set_hl(0, group, { fg = "#5a7fd0" })
end
vim.api.nvim_set_hl(0, M.WATER_LABEL_HL, { fg = "#5a7fd0", bold = true })

return M
