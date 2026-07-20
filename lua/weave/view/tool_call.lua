-- How a tool call draws in the transcript, and the registry that lets someone
-- else decide instead.
--
-- `Entry` is the default rendering, split into three subrenderers it takes as
-- optional props:
--
--   render_header    the chevron/status/tag/title row that toggles expansion
--                    (the tag is the ACP kind, or `w:<tool>` for a call that
--                    went through weave's own clankbox suite — see M.tool_tag)
--   render_body      directly under the header, ALWAYS visible (the edit diff
--                    lives here) — the call's primary display
--   render_metadata  the <CR>-toggleable detail: kind, file, status, raw
--                    input/output, content body
--
-- Overriding one part is composition, not configuration: delegate to `Entry`
-- with the one subrenderer swapped and you keep the rest.
--
--   ToolCall.register({
--     name = "my.plugin:tasks",
--     match = function(block) return block.input and block.input.command ~= nil end,
--     render = function(_, props)
--       return { comp = ToolCall.Entry, props = vim.tbl_extend("force", props, { render_body = MyBody }) }
--     end,
--   })
--
-- Don't delegate to `Entry` at all and you own the whole entry — there is no
-- flag for that, it falls out of `render` being an ordinary component.
--
-- ── The identity problem: match is a predicate, because there is no name ────
--
-- ACP tool calls DO NOT CARRY A TOOL NAME. The wire shape is toolCallId /
-- title / kind / status / content / locations / rawInput / rawOutput (see
-- weave.acp.ToolCallBase): `kind` is a coarse ToolKind enum shared by every
-- tool of that shape, and `title` is agent-authored prose that providers word
-- differently and localize. Neither is a stable key, so there is deliberately
-- no `match = "task_start"` form — it would be a lie about what we can
-- observe. A matcher gets the whole normalized block and duck-types, usually
-- on rawInput shape. `_meta` (ACP's extension slot) is carried through onto
-- the block as `meta`; it is the one place a provider could ever put a real
-- tool name, so a name-based match becomes possible the day one does.
--
-- ── Precedence ─────────────────────────────────────────────────────────────
--
-- Matchers run in priority order, HIGHEST FIRST; ties break on most-recently
-- registered. Priority defaults to 0 and exists because registration order is
-- decided by plugin load order, which nobody controls — without it, two
-- plugins that both match `kind = "execute"` would silently fight, and which
-- one won could change between restarts. Set it explicitly when you mean to
-- outrank someone: weave's own renderers register at 0, so a plugin at 10
-- reliably wins and one at -10 reliably yields.
--
-- No match, or a matcher that throws, falls through to the builtin rendering
-- silently. This is a user extension point; a bad predicate is a config bug,
-- not a reason to stop drawing the conversation.

local ui = require("fibrous.inline.components")
local Diff = require("weave.view.diff")
local Logger = require("weave.utils.logger")
local Theme = require("weave.view.theme")
local ToolIdent = require("weave.tool_ident")

local M = {}

--- @class weave.view.ToolRenderer
--- @field name string Unique id; re-registering the same name replaces it
--- @field match fun(block: table): boolean Predicate over the normalized tool-call block
--- @field render fun(ctx: table, props: weave.view.ToolCallProps): table A fibrous component
--- @field priority? integer Higher wins; ties break newest-first (default 0)

--- What every renderer and subrenderer is handed. `block` is the tool call out
--- of the store (reference-stable, so `memo = true` still bails correctly).
--- @class weave.view.ToolCallProps
--- @field block table tool_call_id, kind, status, input, output, diff, body, file_path, argument, meta
--- @field store weave.store.SessionStore The owning session store
--- @field expanded boolean Whether the user has expanded this call
--- @field awaiting boolean Whether a permission request targets this call
--- @field show_diff boolean The show_diffs view pref
--- @field render_header? fun(ctx: table, props: weave.view.ToolCallProps): table
--- @field render_body? fun(ctx: table, props: weave.view.ToolCallProps): table|nil
--- @field render_metadata? fun(ctx: table, props: weave.view.ToolCallProps): table|nil

-- ── Registry ────────────────────────────────────────────────────────────────

--- @type weave.view.ToolRenderer[]
local registered = {}

--- Register a renderer, replacing any existing one with the same name (so a
--- plugin reloading itself doesn't stack duplicates).
--- @param spec weave.view.ToolRenderer
function M.register(spec)
  assert(type(spec) == "table", "tool renderer: spec must be a table")
  assert(type(spec.name) == "string" and spec.name ~= "", "tool renderer: `name` is required")
  assert(type(spec.match) == "function", "tool renderer: `match` must be a predicate over the tool-call block")
  assert(type(spec.render) == "function", "tool renderer: `render` must be a function")
  assert(spec.priority == nil or type(spec.priority) == "number", "tool renderer: `priority` must be a number")
  M.unregister(spec.name)
  registered[#registered + 1] = spec
end

--- @param name string
function M.unregister(name)
  for i, spec in ipairs(registered) do
    if spec.name == name then
      table.remove(registered, i)
      return
    end
  end
end

--- @return weave.view.ToolRenderer[] registration order (NOT match order)
function M.list()
  return registered
end

--- Drop every registration (setup re-runs, specs).
function M.reset()
  registered = {}
end

--- The renderer for `block`, or nil for the builtin rendering. See the
--- precedence note above: highest priority first, newest-registered breaks
--- ties, throwing matchers are logged and skipped.
--- @param block table
--- @return weave.view.ToolRenderer|nil
function M.resolve(block)
  local best, best_rank
  for i = #registered, 1, -1 do
    local spec = registered[i]
    local priority = spec.priority or 0
    -- `i` descending means the first spec seen at a given priority is the
    -- most recently registered one, so a strict > keeps it on a tie.
    if best_rank == nil or priority > best_rank then
      local ok, matched = pcall(spec.match, block)
      if not ok then
        Logger.debug(("tool_call: matcher '%s' errored: %s"):format(spec.name, tostring(matched)))
      elseif matched then
        best, best_rank = spec, priority
      end
    end
  end
  return best
end

-- ── Shared helpers ──────────────────────────────────────────────────────────

--- Collapse any newlines in agent-supplied single-line text (titles, kinds).
--- Multi-line CONTENT goes through paragraphs, which handle "\n"; headers are
--- one row by design, so a stray newline must not break them in two.
--- @param text string|nil
--- @return string
local function one_line(text)
  return (tostring(text or ""):gsub("[\r\n]+", " "))
end
M.one_line = one_line

--- Human-readable title for a tool call, with a fallback chain so the header
--- is never empty: the agent-supplied title (carried as `argument`) wins;
--- else the file path; else a last-resort id label. Verified against
--- providers that omit the title (e.g. OpenCode edits arrive with only
--- kind + rawInput).
--- @param tc table ToolCallBlock
--- @return string title
function M.tool_title(tc)
  if tc.argument and tc.argument ~= "" then
    return tc.argument
  end
  if tc.file_path and tc.file_path ~= "" then
    return vim.fn.fnamemodify(tc.file_path, ":~:.")
  end
  return "tool call " .. tc.tool_call_id
end

--- The bracketed tag in a header. A call that went through weave's OWN
--- clankbox tool suite is tagged `w:<tool>` (identified by its arguments via
--- weave.tool_ident — the block itself carries no tool name), so it reads
--- apart from the agent's builtin `<kind>` tools at a glance. Everything else
--- keeps the ACP kind.
--- @param tc table ToolCallBlock
--- @return string
function M.tool_tag(tc)
  local weave_tool = ToolIdent.lookup(tc.input)
  if weave_tool then
    return "w:" .. weave_tool
  end
  return one_line(tc.kind or "tool")
end

--- Max lines rendered for a single raw input/output block when expanded. MCP
--- results can be huge; cap them so one tool call can't flood the transcript.
--- The full value is always in the store.
M.RAW_BLOCK_MAX_LINES = 40

--- Max lines for an inline diff preview. The full edit is on disk once
--- applied; this is a preview, not the source of truth.
M.DIFF_PREVIEW_MAX_LINES = 60

--- One indented, dimmed metadata line ("    kind: execute").
local function meta_line(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "@comment" } } }
end

--- Append labels for a labeled, indented, truncated vim.inspect dump of an
--- arbitrary tool input/output table. No-op when the value is absent.
--- @param children table[] accumulator of component specs
--- @param label string e.g. "input" / "output"
--- @param value table|nil
local function append_raw_block(children, label, value)
  if value == nil then
    return
  end
  children[#children + 1] = meta_line("    " .. label .. ":")
  local lines = vim.split(vim.inspect(value), "\n")
  local shown = math.min(#lines, M.RAW_BLOCK_MAX_LINES)
  for i = 1, shown do
    children[#children + 1] = { comp = ui.label, props = { text = "    │ " .. lines[i] } }
  end
  if #lines > shown then
    children[#children + 1] = meta_line(string.format("    │ … %d more lines", #lines - shown))
  end
end

-- ── Default subrenderers ────────────────────────────────────────────────────

--- The header row: chevron, status glyph, kind glyph + tag, title. The tag is
--- the ACP kind, or `w:<tool>` when the call is one of weave's own clankbox
--- tools (M.tool_tag). Pressing it (<CR>/click) toggles expansion.
--- @param props weave.view.ToolCallProps
function M.Header(_, props)
  local tc = props.block
  local effective_status = props.awaiting and "awaiting_permission" or (tc.status or "pending")
  local status_icon = Theme.STATUS_ICON[effective_status] or "○"
  local kind_icon = Theme.KIND_ICON[tc.kind or "other"] or Theme.KIND_ICON.other
  local chevron = props.expanded and Theme.CHEVRON.expanded or Theme.CHEVRON.collapsed
  -- Header + [kind] tag share the status colour; the tag is bold so the tool
  -- type stays emphasized while the whole header signals state at a glance.
  local header_hl = Theme.HEADER_HL[effective_status] or "Function"
  local tag_hl = Theme.KIND_TAG_HL[effective_status] or "Function"

  return {
    comp = ui.button,
    props = {
      theme = false, -- bare header, no button chrome
      label = {
        { chevron .. " ", hl = "@comment" },
        { status_icon .. " ", hl = header_hl },
        { kind_icon, hl = header_hl },
        { "[" .. M.tool_tag(tc) .. "] ", hl = tag_hl },
        { one_line(M.tool_title(tc)), hl = header_hl },
      },
      on_press = function()
        props.store:toggle_tool_call(tc.tool_call_id)
      end,
    },
  }
end

--- The always-visible body: for an edit, the inline diff, so what changed is
--- readable at a glance without expanding. Everything else has no body by
--- default — nil means "render nothing here".
--- @param props weave.view.ToolCallProps
--- @return table|nil
function M.Body(_, props)
  local tc = props.block
  if not tc.diff or props.show_diff == false then
    return nil
  end
  return {
    comp = Diff.Diff,
    props = {
      old = tc.diff.old,
      new = tc.diff.new,
      max_lines = M.DIFF_PREVIEW_MAX_LINES,
      indent = "    ",
    },
  }
end

--- The expand-toggled detail: kind, file, status, then raw input/output (the
--- only detail MCP/other tools provide — they send no content/body) and the
--- content body lines.
--- @param props weave.view.ToolCallProps
function M.Metadata(_, props)
  local tc = props.block
  local children = {}

  if tc.kind then
    children[#children + 1] = meta_line("    kind: " .. tc.kind)
  end
  if tc.file_path then
    children[#children + 1] = meta_line("    file: " .. tc.file_path)
  end
  children[#children + 1] = meta_line("    status: " .. (tc.status or "pending"))

  append_raw_block(children, "input", tc.input)
  append_raw_block(children, "output", tc.output)

  for _, body_line in ipairs(tc.body or {}) do
    -- A body element may itself contain newlines (it's content, not a
    -- label); paragraphs handle those, keeping the "│" gutter per row.
    for _, physical in ipairs(vim.split(body_line, "\n")) do
      children[#children + 1] = { comp = ui.label, props = { text = "    │ " .. physical } }
    end
  end

  return { comp = ui.col, props = {}, children = children }
end

-- ── The entry ───────────────────────────────────────────────────────────────

--- One tool call: header, body, and (when expanded) metadata, each drawn by
--- its default subrenderer unless the props override it.
---
--- Subrenderers mount as COMPONENTS rather than being called inline, so each
--- gets its own fibrous ctx and can hold state or subscribe to a store — a
--- body that streams live output is the case this exists for.
--- @param props weave.view.ToolCallProps
function M.Entry(_, props)
  local children = {
    { comp = props.render_header or M.Header, props = props },
    { comp = props.render_body or M.Body, props = props },
  }
  if props.expanded then
    children[#children + 1] = { comp = props.render_metadata or M.Metadata, props = props }
  end
  return { comp = ui.col, props = {}, children = children }
end

--- Mounts a registered renderer as a component, so its `render` gets a live
--- fibrous ctx. The pcall contains a throwing renderer to THIS entry: the
--- rest of the conversation keeps drawing, and the entry degrades to a
--- visible error instead of a blank hole.
--- @param props { spec: weave.view.ToolRenderer, inner: weave.view.ToolCallProps }
function M.RendererHost(ctx, props)
  local ok, tree = pcall(props.spec.render, ctx, props.inner)
  if not ok then
    return {
      comp = ui.label,
      props = {
        text = ("    [renderer '%s' failed: %s]"):format(props.spec.name, one_line(tree)),
        style = { text_hl = "ErrorMsg" },
      },
    }
  end
  return tree
end

--- The dispatcher the transcript mounts: a registered renderer if one matches
--- this block, else the builtin `Entry`.
---
--- Dispatch lives HERE and not inside `Entry` on purpose — an override that
--- delegates back to `Entry` (the whole point of the subrenderer props) would
--- otherwise re-resolve itself and recurse forever.
--- @param props weave.view.ToolCallProps
function M.Dispatch(_, props)
  local spec = M.resolve(props.block)
  if spec then
    return { comp = M.RendererHost, props = { spec = spec, inner = props } }
  end
  return { comp = M.Entry, props = props }
end

return M
