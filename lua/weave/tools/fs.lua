-- weave's MCP fs tools: read/write/edit with builtin-agent-tool parity,
-- routed through the editor (design-agent-sandbox.md, phase 0). Open buffers
-- win over disk: reads serve live buffer state, writes land in the buffer
-- (then save), so the user and weave see every change as it happens. Buffers
-- with no backing file are first-class targets via `buffer` — something no
-- plain path-based tool can reach.
--
-- Handlers follow the clankbox contract: take the decoded arguments table,
-- return a string, raise an error() for an isError result the agent reads.

local M = {}

-- Read parity with builtin agent tools: cap unpaged reads, tell the agent how
-- to continue instead of silently flooding its context.
local DEFAULT_LIMIT = 2000

---------------------------------------------------------------------------
-- Target resolution
---------------------------------------------------------------------------

--- Loaded buffer backing `abs`, if any (names of file buffers are absolute).
--- @param abs string
--- @return integer|nil
local function loaded_file_buf(abs)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) == abs then
      return bufnr
    end
  end
  return nil
end

--- Resolve `buffer` (id, exact name, or name suffix) to a loaded buffer.
--- Errors are messages for the agent, listing what IS loaded.
--- @param ref integer|string
--- @return integer bufnr
local function resolve_buffer(ref)
  if type(ref) == "number" then
    if not vim.api.nvim_buf_is_valid(ref) then
      error(("no buffer with id %d"):format(ref), 0)
    end
    return ref
  end
  local matches = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and (name == ref or name:sub(-#ref) == ref) then
        matches[#matches + 1] = { bufnr = bufnr, name = name }
      end
    end
  end
  if #matches == 0 then
    error(("no loaded buffer matches %q"):format(ref), 0)
  end
  if #matches > 1 then
    local names = {}
    for _, m in ipairs(matches) do
      names[#names + 1] = ("%d: %s"):format(m.bufnr, m.name)
    end
    error(("buffer %q is ambiguous:\n%s"):format(ref, table.concat(names, "\n")), 0)
  end
  return matches[1].bufnr
end

--- Resolve the tool target: a live buffer (open path, or explicit `buffer`)
--- or a plain disk path. Exactly one of `path`/`buffer` must be given.
--- @param args table
--- @return { bufnr: integer }|{ path: string }
local function resolve(args)
  if args.buffer ~= nil then
    return { bufnr = resolve_buffer(args.buffer) }
  end
  -- The schema says `path`, but agents arrive with priors: `file_path` from
  -- Claude's builtin tools, `filePath` from OpenCode over ACP (acp_client.lua
  -- absorbs the same split on the way in). Accepting them costs nothing and
  -- saves a guaranteed failed call; `path` still wins when several are given.
  local path = args.path or args.file_path or args.filePath
  if type(path) == "string" and path ~= "" then
    local abs = vim.fn.fnamemodify(path, ":p")
    local bufnr = loaded_file_buf(abs)
    if bufnr then
      return { bufnr = bufnr }
    end
    return { path = abs }
  end
  error("pass `path` (a file) or `buffer` (a buffer id or name)", 0)
end

---------------------------------------------------------------------------
-- Content plumbing
---------------------------------------------------------------------------

--- @param path string
--- @return string text raw bytes
local function read_disk_raw(path)
  local f = io.open(path, "rb")
  if not f then
    error("file not found: " .. path, 0)
  end
  local text = f:read("*a")
  f:close()
  return text
end

--- @param path string
--- @return string[] lines
local function read_disk_lines(path)
  local lines = vim.split(read_disk_raw(path), "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines) -- trailing newline is line termination, not a line
  end
  return lines
end

--- @param path string
--- @param content string written verbatim (parent dirs created)
local function write_disk(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f, err = io.open(path, "wb")
  if not f then
    error(("cannot write %s: %s"):format(path, err), 0)
  end
  f:write(content)
  f:close()
end

--- Whether the buffer writes through to a file (`:write` is meaningful).
--- acwrite counts: BufWriteCmd owners (perijove notebooks) get their own save.
--- @param bufnr integer
--- @return boolean
local function file_backed(bufnr)
  local buftype = vim.bo[bufnr].buftype
  return vim.api.nvim_buf_get_name(bufnr) ~= "" and (buftype == "" or buftype == "acwrite")
end

--- Replace buffer content with `new_lines` touching only the changed span,
--- so extmarks/folds/cursors outside it survive.
--- @param bufnr integer
--- @param new_lines string[]
local function splice_buffer(bufnr, new_lines)
  if not vim.bo[bufnr].modifiable then
    error(("buffer %d is not modifiable"):format(bufnr), 0)
  end
  local old = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local first = 1
  while first <= #old and first <= #new_lines and old[first] == new_lines[first] do
    first = first + 1
  end
  local last_old, last_new = #old, #new_lines
  while last_old >= first and last_new >= first and old[last_old] == new_lines[last_new] do
    last_old = last_old - 1
    last_new = last_new - 1
  end
  if first > last_old and first > last_new then
    return -- identical
  end
  local mid = {}
  for i = first, last_new do
    mid[#mid + 1] = new_lines[i]
  end
  vim.api.nvim_buf_set_lines(bufnr, first - 1, last_old, false, mid)
end

--- @param bufnr integer
local function save_buffer(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent keepalt write!")
  end)
end

--- Land `lines` in the target: through the buffer (saving when file-backed)
--- or straight to disk. Returns a one-line summary for the agent.
--- @param target { bufnr: integer }|{ path: string }
--- @param lines string[]
--- @param disk_content string exact bytes for the direct-to-disk path
--- @return string where
local function land(target, lines, disk_content)
  if target.bufnr then
    splice_buffer(target.bufnr, lines)
    if file_backed(target.bufnr) then
      save_buffer(target.bufnr)
      return ("%s (through the open buffer)"):format(vim.api.nvim_buf_get_name(target.bufnr))
    end
    return ("buffer %d (no backing file; live buffer only)"):format(target.bufnr)
  end
  write_disk(target.path, disk_content)
  return target.path
end

--- Current text of the target as one string (live buffer state wins). Disk
--- targets are raw bytes, so the file's trailing-newline convention survives
--- a replace-and-rewrite round trip.
--- @param target { bufnr: integer }|{ path: string }
--- @return string
local function target_text(target)
  if target.bufnr then
    return table.concat(vim.api.nvim_buf_get_lines(target.bufnr, 0, -1, false), "\n")
  end
  return read_disk_raw(target.path)
end

--- Content string -> buffer lines (a single trailing newline terminates).
--- @param content string
--- @return string[]
local function content_lines(content)
  local lines = vim.split(content, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

-- Both tools address a target the same way; keep the schema in one place.
local TARGET_PROPS = {
  path = { type = "string", description = "File path (absolute or relative to cwd)" },
  buffer = {
    type = { "integer", "string" },
    description = "Neovim buffer id (number) or buffer name/suffix (string); reaches buffers with no backing file",
  },
}

--- Every fs tool takes exactly one target. `required` cannot say "one of
--- these two", so the pair goes in `anyOf`: without it the announced schema
--- lets a caller omit both and only find out from resolve() at run time.
--- Lenient clients ignore anyOf and still see the properties.
local TARGET_ANY_OF = { { required = { "path" } }, { required = { "buffer" } } }

local function schema(extra_props, required)
  local props = vim.tbl_extend("force", {}, TARGET_PROPS, extra_props or {})
  return { type = "object", properties = props, required = required, anyOf = TARGET_ANY_OF }
end

---------------------------------------------------------------------------
-- read
---------------------------------------------------------------------------

M.read = {
  description = table.concat({
    "Read a file or Neovim buffer, with line numbers.",
    "Prefer this over shell reads: when the file is open in the editor it serves the LIVE",
    "buffer state (unsaved edits included), and `buffer` reaches buffers with no backing file.",
    "Large files: page with `offset` (1-based first line) and `limit`.",
  }, " "),
  inputSchema = schema({
    offset = { type = "integer", description = "1-based first line to read (default 1)" },
    limit = { type = "integer", description = "Max lines to return (default " .. DEFAULT_LIMIT .. ")" },
  }),
  handler = function(args)
    local target = resolve(args)
    local lines, note
    if target.bufnr then
      lines = vim.api.nvim_buf_get_lines(target.bufnr, 0, -1, false)
      if vim.api.nvim_buf_get_name(target.bufnr) == "" then
        note = ("(buffer %d has no backing file)"):format(target.bufnr)
      elseif vim.bo[target.bufnr].modified then
        note = "(live buffer state; unsaved changes not yet on disk)"
      end
    else
      lines = read_disk_lines(target.path)
    end

    local total = #lines
    if total == 0 or (total == 1 and lines[1] == "") then
      return "(empty)" .. (note and "\n" .. note or "")
    end

    local offset = args.offset or 1
    if offset < 1 then
      error("`offset` must be >= 1", 0)
    end
    if offset > total then
      error(("offset %d is past the end (%d lines)"):format(offset, total), 0)
    end
    local limit = args.limit or DEFAULT_LIMIT
    local last = math.min(total, offset + limit - 1)

    local out = {}
    for i = offset, last do
      out[#out + 1] = ("%d\t%s"):format(i, lines[i])
    end
    if last < total then
      out[#out + 1] = ("(truncated: lines %d-%d of %d; continue with offset=%d)"):format(offset, last, total, last + 1)
    end
    if note then
      out[#out + 1] = note
    end
    return table.concat(out, "\n")
  end,
}

---------------------------------------------------------------------------
-- write
---------------------------------------------------------------------------

M.write = {
  description = table.concat({
    "Write full content to a file or Neovim buffer.",
    "When the file is open in the editor the write routes THROUGH the buffer (then saves),",
    "so the editor stays in sync; `buffer` writes buffers with no backing file.",
    "Creates missing files and parent directories. For partial changes prefer `edit`.",
  }, " "),
  inputSchema = schema({
    content = { type = "string", description = "The complete new content" },
  }, { "content" }),
  handler = function(args)
    if type(args.content) ~= "string" then
      error("`content` must be a string", 0)
    end
    local target = resolve(args)
    local lines = content_lines(args.content)
    local where = land(target, lines, args.content)
    return ("wrote %d lines to %s"):format(#lines, where)
  end,
}

---------------------------------------------------------------------------
-- edit
---------------------------------------------------------------------------

--- Occurrences of `needle` in `text`, plain (no patterns).
--- @return integer
local function count_plain(text, needle)
  local n, from = 0, 1
  while true do
    local s, e = text:find(needle, from, true)
    if not s then
      return n
    end
    n = n + 1
    from = e + 1
  end
end

--- @return string
local function replace_plain(text, needle, replacement)
  local parts, from = {}, 1
  while true do
    local s, e = text:find(needle, from, true)
    if not s then
      parts[#parts + 1] = text:sub(from)
      return table.concat(parts)
    end
    parts[#parts + 1] = text:sub(from, s - 1)
    parts[#parts + 1] = replacement
    from = e + 1
  end
end

M.edit = {
  description = table.concat({
    "Replace an exact string in a file or Neovim buffer (like a surgical partial write).",
    "Operates on the LIVE buffer state when the file is open, then saves.",
    "`old_string` must match exactly and be unique unless `replace_all` is set.",
  }, " "),
  inputSchema = schema({
    old_string = { type = "string", description = "Exact text to replace (must be unique unless replace_all)" },
    new_string = { type = "string", description = "Replacement text" },
    replace_all = { type = "boolean", description = "Replace every occurrence (default false)" },
  }, { "old_string", "new_string" }),
  handler = function(args)
    local old, new = args.old_string, args.new_string
    if type(old) ~= "string" or old == "" then
      error("`old_string` must be a non-empty string", 0)
    end
    if type(new) ~= "string" then
      error("`new_string` must be a string", 0)
    end
    if old == new then
      error("`old_string` and `new_string` are identical", 0)
    end

    local target = resolve(args)
    local text = target_text(target)
    local n = count_plain(text, old)
    if n == 0 then
      error("old_string not found in the target", 0)
    end
    if n > 1 and not args.replace_all then
      error(("old_string occurs %d times; make it unique or pass replace_all=true"):format(n), 0)
    end

    local new_text = replace_plain(text, old, new)
    local where = land(target, vim.split(new_text, "\n", { plain = true }), new_text)
    return ("replaced %d occurrence(s) in %s"):format(n, where)
  end,
}

return M
