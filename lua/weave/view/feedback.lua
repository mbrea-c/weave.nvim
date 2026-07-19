-- The inline code feedback UI: a sidebar section listing the open draft (below
-- terminal tasks) and a floating editor for writing or revising one comment.
--
-- Both surfaces are projections of weave.feedback_store, re-rendered off one
-- bridge hook over its subscribe — the same shape as view/terminal_tasks.lua,
-- for the same reason: the store mutates in place and carries no snapshot, so a
-- bumped version counter drives the re-render and the component re-reads.
--
-- Section and Editor are plain components returning trees; only open_editor
-- mounts anything. That keeps the layout and the button wiring testable without
-- putting a window on the screen.

local ui = require("fibrous.inline.components")
local Store = require("weave.feedback_store")
local TerminalTasks = require("weave.view.terminal_tasks")

local M = {}

-- How many quoted lines the editor shows above the input before eliding.
M.QUOTE_PREVIEW_LINES = 6

--- @param ctx table fibrous ReactiveCtx
local function use_feedback(ctx)
  local ver = ctx.use_state(0)
  ctx.use_effect(function()
    return Store.subscribe(function()
      ver.set(ver.get() + 1)
    end)
  end, { Store })
  ver.get() -- read it: the version bump is what re-renders us
  return Store.draft()
end

local function dim(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "@comment" } } }
end

--- "session.lua:461" / "session.lua:461-463" — the basename only, because the
--- sidebar is narrow and the full path is the least distinguishing part of it.
--- @param comment weave.feedback.Comment
--- @return string label, boolean orphaned
function M.comment_label(comment)
  local at = Store.resolve(comment)
  local name = comment.path ~= "" and vim.fn.fnamemodify(comment.path, ":t") or "[scratch]"
  local where = at.end_lnum > at.lnum and ("%s:%d-%d"):format(name, at.lnum, at.end_lnum)
    or ("%s:%d"):format(name, at.lnum)
  local body = (comment.body or ""):gsub("%s+", " ")
  if body ~= "" then
    where = where .. "  " .. body
  end
  return where, at.orphaned
end

--- The sidebar section. The header is always present so the feature is
--- discoverable before any comment exists; the send/discard buttons appear only
--- once there is something to send.
--- @param ctx table
--- @param props { width?: integer }
function M.Section(ctx, props)
  local draft = use_feedback(ctx)
  local rows = {
    { comp = ui.label, props = { text = "Code feedback", style = { text_hl = "Title" } } },
  }
  local text_w = math.max((props.width or 30) - 5, 4)

  if not draft then
    rows[#rows + 1] = dim("(no comments)")
    return { comp = ui.col, props = {}, children = rows }
  end

  for _, comment in ipairs(draft.comments) do
    local label, orphaned = M.comment_label(comment)
    local id = comment.id
    rows[#rows + 1] = {
      comp = ui.row,
      props = { gap = 1 },
      children = {
        -- An orphaned comment still gets sent, labelled stale; the glyph warns
        -- BEFORE sending that its line number can no longer be trusted.
        {
          comp = ui.label,
          props = orphaned and { text = "⚠", style = { text_hl = "WeaveTaskIconFailed" } } or { text = "•" },
        },
        {
          comp = ui.button,
          props = {
            label = TerminalTasks.truncate(label, text_w),
            theme = false,
            style = { _hover = { hl = "FibrousHover" } },
            on_press = function()
              M.open_editor(id)
            end,
          },
        },
      },
    }
  end

  rows[#rows + 1] = {
    comp = ui.col,
    props = {},
    children = {
      {
        comp = ui.button,
        props = {
          label = "send feedback",
          on_press = function()
            require("weave.feedback").send()
          end,
        },
      },
      {
        comp = ui.button,
        props = {
          label = "discard",
          on_press = function()
            require("weave.feedback").discard()
          end,
        },
      },
    },
  }
  return { comp = ui.col, props = {}, children = rows }
end

--- The comment editor for one comment id.
---
--- Cancel restores the body the comment had when the editor opened, and removes
--- the comment outright if that body was empty — which is exactly the case
--- where the editor was opened by a fresh ;;cc, so backing out of writing a new
--- comment leaves no orphan highlight behind.
--- @param ctx table
--- @param props { id: integer, on_close?: fun() }
function M.Editor(ctx, props)
  use_feedback(ctx)
  local comment = Store.get(props.id)
  local close = props.on_close or function() end
  if not comment then
    return { comp = ui.col, props = {}, children = { dim("(this comment is gone)") } }
  end

  -- use_ref() seeds nothing, so capture the body on the FIRST render only:
  -- re-seeding it every render would make cancel restore the latest edit.
  local original = ctx.use_ref()
  if original.current == nil then
    original.current = comment.body
  end
  local text = ctx.use_state(comment.body)

  local at = Store.resolve(comment)
  local head = ("%s:%d"):format(comment.path ~= "" and vim.fn.fnamemodify(comment.path, ":.") or "[scratch]", at.lnum)
  if at.end_lnum > at.lnum then
    head = head .. "-" .. at.end_lnum
  end

  local rows = {
    { comp = ui.label, props = { text = head, style = { text_hl = "Title" } } },
  }
  if at.orphaned then
    rows[#rows + 1] = dim("the code this points at has changed; it will be sent marked stale")
  end

  local quote = comment.quote or {}
  for i = 1, math.min(#quote, M.QUOTE_PREVIEW_LINES) do
    rows[#rows + 1] = dim("  " .. quote[i])
  end
  if #quote > M.QUOTE_PREVIEW_LINES then
    rows[#rows + 1] = dim(("  (… %d more lines)"):format(#quote - M.QUOTE_PREVIEW_LINES))
  end

  local function save()
    local body = vim.trim(text.get())
    -- An empty comment is noise in the bundle: saving one deletes it, which
    -- also makes "clear the box and save" a working way to drop a comment.
    if body == "" then
      Store.remove(props.id)
    else
      Store.update(props.id, body)
    end
    close()
  end

  rows[#rows + 1] = {
    comp = ui.text_input,
    props = {
      value = comment.body,
      height = 5,
      clear_on_submit = false,
      on_change = function(txt)
        text.set(txt)
      end,
      on_submit = save,
      -- Bordered, like the prompt box: an empty unbordered input is literally
      -- invisible — blank mirror rows on a blank canvas, with nothing to say
      -- where to start typing.
      style = {
        border = {
          "rounded",
          title = { text = "Comment", align = "left" },
        },
      },
    },
  }
  rows[#rows + 1] = {
    comp = ui.row,
    props = { gap = 1 },
    children = {
      { comp = ui.button, props = { label = "save", on_press = save } },
      {
        comp = ui.button,
        props = {
          label = "delete",
          on_press = function()
            Store.remove(props.id)
            close()
          end,
        },
      },
      {
        comp = ui.button,
        props = {
          label = "cancel",
          on_press = function()
            if vim.trim(original.current or "") == "" then
              Store.remove(props.id)
            else
              Store.update(props.id, original.current)
            end
            close()
          end,
        },
      },
    },
  }
  rows[#rows + 1] = dim("<CR> in normal mode saves")
  return { comp = ui.col, props = {}, children = rows }
end

--- Mount the editor for a comment in its own float.
--- @param id integer
function M.open_editor(id)
  local mount = require("fibrous.inline.mount")
  local app
  local function close()
    if app then
      app.unmount()
    end
  end
  app = mount.floating(function(ctx)
    return M.Editor(ctx, { id = id, on_close = close })
  end, {}, {
    width = 76,
    height = math.min(20, math.max(vim.o.lines - 6, 8)),
    mode = "scroll",
    border = "rounded",
    backdrop = true,
    title = " code feedback ",
  })
  require("weave.keys").map(app.bufnr, "close_float", function()
    close()
  end, { nowait = true, desc = "weave: close the code feedback editor" })
  app.focus()
  return app
end

return M
