-- The `annotate` tool suite: how the agent leaves feedback ON the user's code
-- instead of only in chat. The store is weave.annotations; this is the surface
-- the model sees.
--
-- Four narrow tools rather than one with an `action` parameter, because that
-- is what models actually pick correctly. `annotate` doubles as the plain
-- notification channel: called with a message and no span it just says the
-- thing, which is the shape for "you are about to hit the same bug again"
-- where there is no one line to point at.

local Annotations = require("weave.annotations")

local M = {}

--- @param text string
--- @return table MCP error result
local function fail(text)
  return { content = { { type = "text", text = text } }, isError = true }
end

--- Where an annotation is, spelled for the agent.
--- @param ann weave.annotations.Annotation
--- @return string
local function locus(ann)
  local at = Annotations.resolve(ann)
  local name = ann.path ~= "" and vim.fn.fnamemodify(ann.path, ":.") or ("buffer " .. tostring(ann.bufnr))
  local span = at.lnum == at.end_lnum and tostring(at.lnum) or (at.lnum .. "-" .. at.end_lnum)
  return ("%s:%s"):format(name, span)
end

M.annotate = {
  description = "Leave feedback ON a span of the user's code: a highlighted range with your message rendered "
    .. "beside it in their editor. This is how the user actually reads your review — chat scrolls away, an "
    .. "annotation sits on the line it is about. Call it once per point you want to make.\n\n"
    .. "Pass `expect` with the exact line(s) you are annotating: the user may have edited since you read the "
    .. "file, and it is what lets weave re-find your span instead of highlighting whatever moved into it. "
    .. "With NO path/lnum this is just a notification to the user — use that when there is no one line to "
    .. "point at. Annotating does not modify the file.\n\n"
    .. "The user can reply to an annotation; the reply arrives in their next feedback message as "
    .. "'reply to your annotation #N' with your note quoted. Act on it through the annotation it names: "
    .. "annotate_update to continue the thread on the code, annotate_dismiss once it is settled.",
  inputSchema = {
    type = "object",
    properties = {
      message = { type = "string", description = "What you want to say about this code" },
      path = { type = "string", description = "File to annotate; omit for a notification with no span" },
      lnum = { type = "integer", description = "1-based first line of the span" },
      end_lnum = { type = "integer", description = "1-based last line (inclusive); defaults to lnum" },
      expect = {
        type = "array",
        items = { type = "string" },
        description = "The line(s) you expect to find at lnum, verbatim. Strongly recommended: without it a "
          .. "stale line number silently annotates the wrong code.",
      },
      position = {
        type = "string",
        enum = { "above", "below" },
        description = "Render the message above or below the span (default below)",
      },
      notify = {
        type = "boolean",
        description = "Also raise it as an editor notification. Default false — reserve it for something the "
          .. "user needs to see before they next look at that file.",
      },
    },
    required = { "message" },
  },
  handler = function(args)
    args = args or {}
    if type(args.message) ~= "string" or args.message == "" then
      return fail("annotate needs a `message`")
    end

    -- No span: this is the notification form.
    if not args.path and not args.buffer then
      vim.notify("weave (agent): " .. args.message, vim.log.levels.INFO)
      return "notified the user"
    end

    if type(args.lnum) ~= "number" then
      return fail("annotate needs `lnum` (the 1-based line) when you give a `path`")
    end

    local ann, err = Annotations.add({
      path = args.path,
      bufnr = args.buffer,
      lnum = args.lnum,
      end_lnum = args.end_lnum,
      message = args.message,
      position = args.position,
      expect = args.expect,
    })
    if not ann then
      return fail(tostring(err))
    end

    if args.notify then
      vim.notify(("weave (agent) %s: %s"):format(locus(ann), args.message), vim.log.levels.INFO)
    end

    local note = ann.pending and " (held until the file is open)" or ""
    if ann.drifted then
      -- Say it rather than let the agent believe its line number was right:
      -- it may want to re-read the file before the next call.
      note = note .. " — the code had moved, so it was re-found by `expect`"
    end
    return ("annotated %s as #%d%s"):format(locus(ann), ann.id, note)
  end,
}

M.annotate_list = {
  description = "List the annotations you have left that the user has not dismissed, with where each one sits "
    .. "NOW (the user keeps editing, so lines move). Use it before annotating to avoid repeating yourself.",
  inputSchema = {
    type = "object",
    properties = {
      path = { type = "string", description = "Only annotations on this file" },
    },
  },
  handler = function(args)
    args = args or {}
    local list = Annotations.list({ path = args.path })
    if #list == 0 then
      return "no annotations outstanding"
    end
    local lines = {}
    for _, ann in ipairs(list) do
      local at = Annotations.resolve(ann)
      local flags = {}
      if at.orphaned then
        flags[#flags + 1] = "orphaned: the code it pointed at is gone"
      end
      if ann.pending then
        flags[#flags + 1] = "pending: the file is not open"
      end
      local suffix = #flags > 0 and (" [" .. table.concat(flags, "; ") .. "]") or ""
      lines[#lines + 1] = ("#%d %s%s\n    %s"):format(ann.id, locus(ann), suffix, ann.message)
    end
    return table.concat(lines, "\n")
  end,
}

M.annotate_update = {
  description = "Rewrite an annotation you already left, keeping it anchored to the same code.",
  inputSchema = {
    type = "object",
    properties = {
      id = { type = "integer", description = "The annotation id (from annotate or annotate_list)" },
      message = { type = "string", description = "The new message" },
      position = {
        type = "string",
        enum = { "above", "below" },
        description = "Render the message above or below the span (unchanged when omitted)",
      },
    },
    required = { "id" },
  },
  handler = function(args)
    args = args or {}
    if type(args.id) ~= "number" then
      return fail("annotate_update needs an `id`")
    end
    if not Annotations.get(args.id) then
      return fail(("no annotation #%d — it may have been dismissed; call annotate_list"):format(args.id))
    end
    Annotations.update(args.id, { message = args.message, position = args.position })
    return ("updated #%d"):format(args.id)
  end,
}

M.annotate_dismiss = {
  description = "Remove an annotation once it no longer applies — the user fixed it, or you were wrong. Leaving "
    .. "stale annotations on the code is worse than never having left them.",
  inputSchema = {
    type = "object",
    properties = {
      id = { type = "integer", description = "The annotation id to remove" },
      all = { type = "boolean", description = "Remove every annotation instead" },
      path = { type = "string", description = "With `all`, only the ones on this file" },
    },
  },
  handler = function(args)
    args = args or {}
    if args.all then
      local n = #Annotations.list({ path = args.path })
      Annotations.clear({ path = args.path })
      return ("dismissed %d annotation(s)"):format(n)
    end
    if type(args.id) ~= "number" then
      return fail("annotate_dismiss needs an `id`, or `all = true`")
    end
    if not Annotations.dismiss(args.id) then
      return fail(("no annotation #%d — it may already be gone; call annotate_list"):format(args.id))
    end
    return ("dismissed #%d"):format(args.id)
  end,
}

return M
