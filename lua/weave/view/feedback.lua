-- The inline code feedback UI: the sidebar's Pending-flush section (below
-- terminal tasks — the comment draft plus this session's unsent-edits window,
-- everything weave.flush would send) and a floating editor for writing or
-- revising one comment.
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
local Autosize = require("weave.view.autosize")
local Store = require("weave.feedback_store")
local TerminalTasks = require("weave.view.terminal_tasks")
local Theme = require("weave.view.theme")

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

--- "2 files edited (1 new, 1 deleted)" — the unsent-edits window, phrased
--- from its Revision.summary. Pure, so the wording is spec'd directly.
--- @param summary { files: integer, created: integer, deleted: integer }
--- @return string
function M.edits_label(summary)
  local noun = summary.files == 1 and "1 file" or (summary.files .. " files")
  local parts = {}
  if summary.created > 0 then
    parts[#parts + 1] = summary.created .. " new"
  end
  if summary.deleted > 0 then
    parts[#parts + 1] = summary.deleted .. " deleted"
  end
  local extra = #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""
  return noun .. " edited" .. extra
end

--- Peek the unsent edits as the very diff a flush would send. A look, not a
--- hand-off: the window stays pending.
--- @param session table|nil
function M.peek_edits(session)
  local diff = require("weave.edit_sync").pending_preview(session)
  if diff then
    require("weave.view.peek").open(diff, "unsent edits", "diff")
  end
end

--- The Pending-flush sidebar section: everything a flush would send — the
--- comment draft and this session's unsent-edits window — with one flush and
--- one discard for the whole bundle. The two halves travel together
--- (weave.flush sends them as ONE turn), so they read together too.
---
--- Each half is a COUNT with its own way in: the comments row opens the full
--- list, the edits row peeks the pending diff. Counts, not listings — the
--- sidebar is narrow and either half can hold more rows than it can spare
--- without pushing Permissions off-screen. The header is always present so
--- the feature is discoverable before anything is pending.
--- @param ctx table
--- @param props { session?: table, width?: integer, on_flush?: fun(session: table|nil), on_discard?: fun(session: table|nil) }
---   on_flush/on_discard override the buttons' targets (spec injection);
---   the defaults are weave.flush and feedback.discard + edits mark_seen.
function M.Section(ctx, props)
  local Sync = require("weave.edit_sync")
  local draft = use_feedback(ctx)
  -- Re-render when the edits half changes: a revision lands (the log) or a
  -- cursor moves — flush delivered, gate consumed, window discarded (sync).
  local ver = ctx.use_state(0)
  ctx.use_effect(function()
    local function bump()
      ver.set(ver.get() + 1)
    end
    local unsub_log = require("weave.revision_log").subscribe(bump)
    local unsub_sync = Sync.subscribe(bump)
    return function()
      unsub_log()
      unsub_sync()
    end
  end, {})
  ver.get()

  local session = props.session
  local comments = draft and draft.comments or {}
  local summary = Sync.pending_summary(session)

  local rows = {
    { comp = ui.label, props = { text = "Pending flush", style = { text_hl = "Title" } } },
  }

  if #comments > 0 then
    local replies = 0
    for _, comment in ipairs(comments) do
      if comment.reply_to then
        replies = replies + 1
      end
    end
    local label = ("%d comment(s)"):format(#comments)
    if replies > 0 then
      -- Called out separately: a reply answers a note the agent is waiting
      -- on, which reads differently from fresh remarks about the code.
      label = label .. (" (%d repl%s)"):format(replies, replies == 1 and "y" or "ies")
    end
    rows[#rows + 1] = {
      comp = ui.button,
      props = {
        label = label,
        theme = false,
        style = { _hover = { hl = "FibrousHover" } },
        on_press = function()
          M.open_list()
        end,
      },
    }
    local stale = 0
    for _, comment in ipairs(comments) do
      if Store.resolve(comment).orphaned then
        stale = stale + 1
      end
    end
    if stale > 0 then
      -- An orphaned comment still gets sent, labelled stale; the glyph warns
      -- BEFORE sending that its line numbers can no longer be trusted.
      rows[#rows + 1] = {
        comp = ui.label,
        props = { text = ("⚠ %d stale"):format(stale), style = { text_hl = "WeaveTaskIconFailed" } },
      }
    end
  end

  if summary then
    rows[#rows + 1] = {
      comp = ui.button,
      props = {
        label = M.edits_label(summary),
        theme = false,
        style = { _hover = { hl = "FibrousHover" } },
        on_press = function()
          M.peek_edits(session)
        end,
      },
    }
  end

  if #comments == 0 and not summary then
    rows[#rows + 1] = dim("(nothing pending)")
    return { comp = ui.col, props = {}, children = rows }
  end

  rows[#rows + 1] = {
    comp = ui.row,
    props = { gap = 1 },
    children = {
      {
        comp = ui.button,
        props = {
          label = "flush",
          on_press = function()
            if props.on_flush then
              props.on_flush(session)
            else
              require("weave").flush({ session = session })
            end
          end,
        },
      },
      {
        comp = ui.button,
        props = {
          label = "discard",
          on_press = function()
            if props.on_discard then
              props.on_discard(session)
            else
              require("weave.feedback").discard()
              Sync.mark_seen(session)
            end
          end,
        },
      },
    },
  }
  return { comp = ui.col, props = {}, children = rows }
end

--- Every comment in the draft, one activatable row each. Rendered into its own
--- float by open_list, and kept a plain component so the row wiring is testable
--- without a window.
--- @param ctx table
--- @param props { on_activate?: fun(id: integer), width?: integer }
function M.List(ctx, props)
  local draft = use_feedback(ctx)
  local comments = draft and draft.comments or {}
  local activate = props.on_activate or function(id)
    M.activate(id)
  end
  local rows = {
    {
      comp = ui.label,
      props = { text = ("Code feedback (%d)"):format(#comments), style = { text_hl = "Title" } },
    },
  }
  if #comments == 0 then
    rows[#rows + 1] = dim("(no comments)")
  end

  local text_w = props.width or 66
  for _, comment in ipairs(comments) do
    local label, orphaned = M.comment_label(comment)
    -- Captured per row: two comments can share a line, so the id is the only
    -- thing that distinguishes which one this button opens.
    local id = comment.id
    rows[#rows + 1] = {
      comp = ui.row,
      props = { gap = 1 },
      children = {
        {
          comp = ui.label,
          -- ⚠ beats ↩: knowing the line numbers went stale matters more than
          -- knowing the comment is a reply.
          props = orphaned and { text = "⚠", style = { text_hl = "WeaveTaskIconFailed" } }
            or { text = comment.reply_to and "↩" or "•" },
        },
        {
          comp = ui.button,
          props = {
            label = TerminalTasks.truncate(label, text_w),
            theme = false,
            style = { _hover = { hl = "FibrousHover" } },
            on_press = function()
              activate(id)
            end,
          },
        },
      },
    }
  end
  return { comp = ui.col, props = {}, children = rows }
end

--- Jump to a comment's code and open its editor there. Navigation happens
--- FIRST so the editor float lands over the code it is about.
--- @param id integer
function M.activate(id)
  require("weave.feedback").goto_comment(id)
  M.open_editor(id)
end

--- The full comment list in its own floating mount, live off the store;
--- q/<Esc> closes. Activating a row closes the list, jumps to that comment's
--- code and opens its editor.
function M.open_list()
  local mount = require("fibrous.inline.mount")
  local app
  local function Body(ctx)
    return M.List(ctx, {
      on_activate = function(id)
        if app then
          app.unmount()
        end
        M.activate(id)
      end,
    })
  end
  app = mount.floating(Body, {}, {
    width = 70,
    height = math.min(math.max(#Store.comments() + 2, 4), math.max(vim.o.lines - 6, 8)),
    mode = "scroll",
    border = "rounded",
    backdrop = true,
    title = " code feedback ",
  })
  return require("weave.view.float").chrome(app, {
    close = function()
      app.unmount()
    end,
    desc = "weave: close the code feedback list",
  })
end

--- Commit `body` to comment `id`. The save rule, in one place because three
--- roads reach it: the save button, `<CR>`, and closing the editor at all
--- (`q` or focusing something else — see open_editor).
---
--- An empty comment is noise in the bundle, so saving one DELETES it. That is
--- what makes "clear the box and save" a way to drop a comment, and what
--- keeps a fresh `;;cc` you walked away from without typing anything from
--- leaving an orphan highlight behind.
--- @param id integer
--- @param body string|nil
function M.save_body(id, body)
  body = vim.trim(body or "")
  if body == "" then
    Store.remove(id)
  else
    Store.update(id, body)
  end
end

--- The comment editor for one comment id.
---
--- Cancel restores the body the comment had when the editor opened, and removes
--- the comment outright if that body was empty — which is exactly the case
--- where the editor was opened by a fresh ;;cc, so backing out of writing a new
--- comment leaves no orphan highlight behind.
--- @param ctx table
--- @param props { id: integer, on_close?: fun(), on_change?: fun(text: string) }
---   on_change reports every keystroke to the OWNER of the float, which is how
---   closing it can save text that only the component knows about.
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

  -- A reply shows what it answers while the user types it: the snapshot of
  -- the annotation, in the same teal the note wears on the code.
  if comment.reply_to then
    rows[#rows + 1] = dim(("replying to the agent's annotation #%d:"):format(comment.reply_to.id))
    rows[#rows + 1] = {
      comp = ui.text,
      props = {
        text = comment.reply_to.message,
        wrap = "char",
        style = { text_hl = Theme.ANNOTATION_TEXT_HL, padding = { left = 2 } },
      },
    }
  end

  -- The quoted code as a real snippet (fibrous ui.code): syntax-highlighted,
  -- with a gutter whose numbers are the comment's LIVE position — resolve()
  -- follows the anchor, so they match the file as it is now, exactly what the
  -- head above claims. The head already names the file, so the snippet's own
  -- reference header stays off; the ref still rides along for language
  -- inference (a scratch comment has no path and degrades to plain).
  local quote = comment.quote or {}
  if #quote > 0 then
    rows[#rows + 1] = {
      comp = ui.code,
      props = {
        code = table.concat(quote, "\n"),
        ref = comment.path ~= "" and { path = comment.path } or nil,
        header = false,
        start_line = at.lnum,
        max_lines = M.QUOTE_PREVIEW_LINES,
        style = { padding = { left = 2 } },
      },
    }
  end

  local function save()
    M.save_body(props.id, text.get())
    close()
  end

  rows[#rows + 1] = {
    comp = ui.text_input,
    props = {
      value = comment.body,
      -- Sized to the text (each on_change re-renders through `text`, so the
      -- box follows every added/removed line while typing).
      height = Autosize.height(text.get()),
      clear_on_submit = false,
      on_create = function(bufnr)
        -- comments are markdown, like the prompt box
        vim.bo[bufnr].filetype = "markdown"
      end,
      on_change = function(txt)
        text.set(txt)
        if props.on_change then
          props.on_change(txt)
        end
      end,
      on_submit = save,
      -- Bordered, like the prompt box: an empty unbordered input is literally
      -- invisible — blank mirror rows on a blank canvas, with nothing to say
      -- where to start typing.
      style = {
        border = {
          "rounded",
          title = { text = comment.reply_to and "Reply" or "Comment", align = "left" },
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
---
--- Closing this float SAVES, unlike every other popup, where closing is just
--- closing. The difference is that this one holds text you typed and nothing
--- else does: dismissing it — with `q`, or by clicking into the code to check
--- the thing you are commenting on — would otherwise throw the comment away.
--- Saving loses nothing either way (an empty body deletes the comment, so
--- walking away from an untouched `;;cc` still strands no highlight), and
--- **cancel** remains the explicit discard.
--- @param id integer
function M.open_editor(id)
  local mount = require("fibrous.inline.mount")
  local app
  -- The component owns the live text; this is the last value it reported, so
  -- a close initiated from OUT here still knows what to save.
  local typed = nil
  local function close()
    if app then
      app.unmount()
    end
  end
  local function save_and_close()
    local comment = Store.get(id)
    if comment then
      M.save_body(id, typed or comment.body)
    end
    close()
  end
  app = mount.floating(function(ctx)
    return M.Editor(ctx, {
      id = id,
      on_close = close,
      on_change = function(txt)
        typed = txt
      end,
    })
  end, {}, {
    width = 76,
    height = math.min(20, math.max(vim.o.lines - 6, 8)),
    mode = "scroll",
    border = "rounded",
    backdrop = true,
    title = " code feedback ",
  })
  return require("weave.view.float").chrome(app, {
    close = save_and_close,
    desc = "weave: save and close the code feedback editor",
  })
end

return M
