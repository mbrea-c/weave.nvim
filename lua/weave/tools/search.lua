-- weave's MCP discovery tools: `glob` and `grep` (design-search-tools.md).
--
-- The rest of the suite reaches individual files the agent already knows
-- about. These are how it finds them, and under the `blackbox` sandbox
-- profile they are the ONLY way: the project directory is absent from the
-- agent's filesystem view, so its own built-in search returns empty rather
-- than erroring, and it concludes the tree is empty.
--
-- Two deliberate constraints:
--
--   Parity. Parameter names are Claude's, flag-shaped ones (`-i`, `-A`)
--   included, because an agent arrives with priors and honouring them costs
--   one schema entry versus a guaranteed failed call. Readable aliases
--   (case_insensitive, after, ...) are accepted alongside; the flag form wins.
--
--   One regex engine. Everything goes through ripgrep, including the LIVE
--   BUFFER overlay, which pipes a modified buffer's lines to a second rg on
--   stdin rather than matching in-process. Matching buffers in Lua would mean
--   a file's results changing flavour (case folding, multiline, context
--   lines) the moment the user opens it, and a result set that disagrees with
--   itself depending on what is open is worse than no tool at all.
--
-- Host-side, like every other tool here: these run in Neovim, outside bwrap.
-- Under `blackbox` that is the point — a mediated, visible read channel — not
-- a hole. The permission gate resources them at the search ROOT (not the
-- matched files), which is the one thing a rule author must know.

local Config = require("weave.config")

local M = {}

local uv = vim.uv or vim.loop

local TIMEOUT_MS = 10000
local MAX_GLOB = 1000
local MAX_CONTENT_LINES = 200
local MAX_COLUMNS = 500

---------------------------------------------------------------------------
-- Binary resolution
---------------------------------------------------------------------------

--- ripgrep, from config or PATH. Config first for the same reason
--- `clankbox_path` exists: under a Nix-wrapped Neovim the ambient PATH is not
--- the user's PATH.
--- @return string|nil
function M.rg_path()
  local configured = Config.tools and Config.tools.ripgrep_path
  if type(configured) == "string" and configured ~= "" then
    return configured
  end
  local found = vim.fn.exepath("rg")
  return found ~= "" and found or nil
end

--- @return string
local function require_rg()
  local rg = M.rg_path()
  if not rg then
    error(
      "ripgrep (rg) is not installed or not on this Neovim's PATH; "
        .. "install it, or set `tools.ripgrep_path` in weave's config to its absolute path",
      0
    )
  end
  return rg
end

---------------------------------------------------------------------------
-- Arguments
---------------------------------------------------------------------------

--- The flag-shaped name, else the readable alias. Flag form wins on conflict:
--- an agent that spells both meant the one it learned from its own tools.
--- @param args table
--- @param dash string
--- @param alias string
local function opt(args, dash, alias)
  local v = args[dash]
  if v == nil then
    v = args[alias]
  end
  return v
end

--- Absolute search root: the `path` argument, or cwd. Also the permission
--- gate's resource for both tools.
--- @param args table
--- @return string
function M.root(args)
  local path = args and (args.path or args.file_path or args.filePath)
  if type(path) == "string" and path ~= "" then
    return vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
  end
  return vim.fn.getcwd()
end

--- Filters that decide which FILES are in scope, shared by the search itself
--- and by the `--files` pass that tests buffer eligibility.
--- @param args table
--- @param argv string[]
local function file_filters(args, argv)
  if type(args.glob) == "string" and args.glob ~= "" then
    argv[#argv + 1] = "--glob"
    argv[#argv + 1] = args.glob
  end
  if type(args.type) == "string" and args.type ~= "" then
    argv[#argv + 1] = "--type"
    argv[#argv + 1] = args.type
  end
  if args.hidden then
    argv[#argv + 1] = "--hidden"
  end
  if args.no_ignore then
    argv[#argv + 1] = "--no-ignore"
  end
end

--- @param args table
--- @param opts { rg: string, root?: string, stdin?: boolean }
--- @return string[]
function M.grep_argv(args, opts)
  local mode = args.output_mode or "files_with_matches"
  local argv = { opts.rg }

  -- stdin is always --json: the buffer overlay derives paths, counts and
  -- content lines from one shape, and the OUTPUT format is not part of the
  -- matching semantics the two paths have to agree on.
  if opts.stdin or mode == "content" then
    argv[#argv + 1] = "--json"
  elseif mode == "count" then
    argv[#argv + 1] = "--count-matches"
  else
    argv[#argv + 1] = "--files-with-matches"
  end

  if opts.stdin or mode == "content" then
    argv[#argv + 1] = "--max-columns=" .. MAX_COLUMNS
    argv[#argv + 1] = "--max-columns-preview"
    local after, before, context = opt(args, "-A", "after"), opt(args, "-B", "before"), opt(args, "-C", "context")
    if tonumber(after) then
      argv[#argv + 1] = "--after-context"
      argv[#argv + 1] = tostring(math.floor(tonumber(after)))
    end
    if tonumber(before) then
      argv[#argv + 1] = "--before-context"
      argv[#argv + 1] = tostring(math.floor(tonumber(before)))
    end
    if tonumber(context) then
      argv[#argv + 1] = "--context"
      argv[#argv + 1] = tostring(math.floor(tonumber(context)))
    end
  end

  if opt(args, "-i", "case_insensitive") then
    argv[#argv + 1] = "--ignore-case"
  end
  if args.multiline then
    argv[#argv + 1] = "--multiline"
    argv[#argv + 1] = "--multiline-dotall"
  end
  file_filters(args, argv)

  -- -e, so a pattern that begins with a dash is a pattern and not a flag.
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = tostring(args.pattern)
  argv[#argv + 1] = opts.stdin and "-" or opts.root
  return argv
end

--- @param args table
--- @param opts { rg: string, root: string }
--- @return string[]
function M.glob_argv(args, opts)
  local argv = { opts.rg, "--files" }
  if type(args.pattern) == "string" and args.pattern ~= "" then
    argv[#argv + 1] = "--glob"
    argv[#argv + 1] = args.pattern
  end
  if args.hidden then
    argv[#argv + 1] = "--hidden"
  end
  if args.no_ignore then
    argv[#argv + 1] = "--no-ignore"
  end
  argv[#argv + 1] = opts.root
  return argv
end

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

--- @class weave.tools.search.Line
--- @field n integer 1-based line number
--- @field text string
--- @field kind "match"|"context"

--- @class weave.tools.search.Record
--- @field path string
--- @field count integer matches (not matched lines — `count` mode is rg's --count-matches)
--- @field lines weave.tools.search.Line[]

--- Parse `rg --json` into per-path records, in rg's own output order.
---
--- The reason content mode uses --json at all: plain `path:line:content`
--- output has to be split on a separator that also occurs in the content, and
--- that bug only ever shows up on the line you cared about.
--- @param stdout string
--- @param override_path? string name to use instead of rg's (stdin searches)
--- @return weave.tools.search.Record[]
function M.parse_json(stdout, override_path)
  local records, by_path = {}, {}
  for _, line in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line)
      local kind = ok and type(event) == "table" and event.type or nil
      if kind == "match" or kind == "context" then
        local data = event.data or {}
        local path = override_path or (data.path and data.path.text)
        if path then
          local rec = by_path[path]
          if not rec then
            rec = { path = path, count = 0, lines = {} }
            by_path[path] = rec
            records[#records + 1] = rec
          end
          -- rg terminates every line; the newline is termination, not content
          local text = (data.lines and data.lines.text or ""):gsub("\r?\n$", "")
          rec.lines[#rec.lines + 1] = { n = data.line_number or 0, text = text, kind = kind }
          if kind == "match" then
            -- MATCHES, not matched lines: this feeds `count` mode, which is
            -- rg's --count-matches, and "needle needle" is two.
            local subs = data.submatches
            rec.count = rec.count + ((type(subs) == "table" and #subs > 0) and #subs or 1)
          end
        end
      end
    end
  end
  return records
end

--- Parse the bare path list of `--files-with-matches` / `--files`.
--- @param stdout string
--- @return weave.tools.search.Record[]
local function parse_paths(stdout)
  local records = {}
  for _, line in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
    if line ~= "" then
      records[#records + 1] = { path = line, count = 0, lines = {} }
    end
  end
  return records
end

--- Parse `--count-matches` (`path:count`). Split from the RIGHT: a path may
--- contain a colon, the count never does.
--- @param stdout string
--- @return weave.tools.search.Record[]
local function parse_counts(stdout)
  local records = {}
  for _, line in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
    if line ~= "" then
      local path, count = line:match("^(.*):(%d+)$")
      if path then
        records[#records + 1] = { path = path, count = tonumber(count), lines = {} }
      end
    end
  end
  return records
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

--- Records -> the text the agent reads, shaped like the built-in grep tool so
--- there is nothing to relearn: `path:line:content` for matches, the grep
--- convention `path-line-content` for context lines, bare paths for
--- files_with_matches, `path:count` for counts.
---
--- Every cap says it capped. Silent truncation is the failure this whole
--- design exists to avoid.
--- @param records weave.tools.search.Record[]
--- @param args table
--- @return string
function M.render(records, args)
  local mode = args.output_mode or "files_with_matches"
  local head = tonumber(args.head_limit)
  local out, total = {}, 0

  if mode == "content" then
    local limit = head or MAX_CONTENT_LINES
    local numbered = opt(args, "-n", "line_numbers")
    for _, rec in ipairs(records) do
      for _, line in ipairs(rec.lines) do
        total = total + 1
        if #out < limit then
          local sep = line.kind == "match" and ":" or "-"
          if numbered then
            out[#out + 1] = ("%s%s%d%s%s"):format(rec.path, sep, line.n, sep, line.text)
          else
            out[#out + 1] = ("%s%s%s"):format(rec.path, sep, line.text)
          end
        end
      end
    end
    if total > #out then
      out[#out + 1] = ("(truncated: %d of %d lines; narrow the pattern, filter with `glob`/`type`, or raise `head_limit`)"):format(
        #out,
        total
      )
    end
  else
    local limit = head or math.huge
    for _, rec in ipairs(records) do
      total = total + 1
      if #out < limit then
        out[#out + 1] = mode == "count" and ("%s:%d"):format(rec.path, rec.count) or rec.path
      end
    end
    if total > #out then
      out[#out + 1] = ("(truncated: %d of %d files; narrow the pattern or raise `head_limit`)"):format(#out, total)
    end
  end

  if #out == 0 then
    return "(no matches)"
  end
  return table.concat(out, "\n")
end

---------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------

--- One rg invocation. rg exits 1 for "no matches", which is not an error;
--- anything above that is, and its stderr is the useful part.
--- @param argv string[]
--- @param stdin string|nil
--- @param cb fun(stdout: string|nil, err: string|nil)
local function run(argv, stdin, cb)
  local opts = { text = true, timeout = TIMEOUT_MS }
  if stdin then
    opts.stdin = stdin
  end
  vim.system(argv, opts, function(res)
    vim.schedule(function()
      if res.code and res.code > 1 then
        local msg = (res.stderr or ""):gsub("%s+$", "")
        return cb(nil, msg ~= "" and msg or ("ripgrep exited %d"):format(res.code))
      end
      cb(res.stdout or "", nil)
    end)
  end)
end

---------------------------------------------------------------------------
-- The live buffer overlay
---------------------------------------------------------------------------

--- @param path string
--- @param root string
--- @return boolean
local function under(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

--- Modified, file-backed, loaded buffers inside the search root. These are
--- the only files whose on-disk bytes are known to be stale.
--- @param root string
--- @return { bufnr: integer, path: string }[]
local function modified_buffers(root)
  local out = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and under(name, root) then
        out[#out + 1] = { bufnr = bufnr, path = name }
      end
    end
  end
  return out
end

--- @param bufnr integer
--- @return string
local function buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") .. "\n"
end

--- Which candidates pass the same file filters the search itself applies.
--- One `rg --files` over the candidate paths, so the answer comes from rg's
--- glob/type/ignore implementation and not from a second, subtly different
--- one here. Candidates with no file on disk yet simply do not come back.
--- @param rg string
--- @param args table
--- @param candidates { bufnr: integer, path: string }[]
--- @param cb fun(eligible: { bufnr: integer, path: string }[])
local function filter_candidates(rg, args, candidates, cb)
  if #candidates == 0 then
    return cb({})
  end
  local argv = { rg, "--files" }
  file_filters(args, argv)
  argv[#argv + 1] = "--"
  for _, c in ipairs(candidates) do
    argv[#argv + 1] = c.path
  end
  run(argv, nil, function(stdout)
    local ok = {}
    for _, line in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
      ok[line] = true
    end
    local eligible = {}
    for _, c in ipairs(candidates) do
      if ok[c.path] then
        eligible[#eligible + 1] = c
      end
    end
    cb(eligible)
  end)
end

--- Replace `path`'s record with `fresh` (nil = the buffer has no matches, so
--- the disk record goes away), appending when the disk missed it entirely.
--- @param records weave.tools.search.Record[]
--- @param path string
--- @param fresh weave.tools.search.Record|nil
local function substitute(records, path, fresh)
  for i, rec in ipairs(records) do
    if rec.path == path then
      if fresh then
        records[i] = fresh
      else
        table.remove(records, i)
      end
      return
    end
  end
  if fresh then
    records[#records + 1] = fresh
  end
end

---------------------------------------------------------------------------
-- glob
---------------------------------------------------------------------------

--- rg-less fallback. Glob is cheap enough to keep working without the
--- dependency; grep is not (see the module header on regex parity).
--- @param root string
--- @param pattern string
--- @return string[]
local function glob_walk(root, pattern)
  local hits = vim.fn.glob(root .. "/" .. pattern, true, true)
  local files = {}
  for _, p in ipairs(hits) do
    if vim.fn.isdirectory(p) == 0 then
      files[#files + 1] = p
    end
  end
  return files
end

--- Modification time, or 0. A modified buffer counts as touched NOW: that is
--- when its content last changed, which is what the sort is reporting.
--- @param path string
--- @return integer
local function mtime(path)
  local st = uv.fs_stat(path)
  return st and st.mtime and st.mtime.sec or 0
end

M.glob = {
  description = table.concat({
    "Find files by glob pattern (e.g. `**/*.lua`, `src/**/*.{ts,tsx}`), newest first.",
    "Prefer this over shell `find`/`ls`: it respects .gitignore, and it sees the project",
    "even when the agent process is sandboxed away from it.",
    "Returns absolute paths.",
  }, " "),
  inputSchema = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "Glob pattern, e.g. **/*.lua or src/**/*.{ts,tsx}" },
      path = { type = "string", description = "Directory to search under (default: the editor's cwd)" },
      hidden = { type = "boolean", description = "Include hidden files (default false)" },
      no_ignore = { type = "boolean", description = "Ignore .gitignore and friends (default false)" },
      buffers = { type = "string", description = '"auto" (default) counts unsaved buffers, "off" is disk only' },
    },
    required = { "pattern" },
  },
  async = true,
  handler = function(args, respond)
    if type(args.pattern) ~= "string" or args.pattern == "" then
      error("`pattern` must be a non-empty glob string", 0)
    end
    local root = M.root(args)
    local rg = M.rg_path()

    local function finish(paths)
      local seen = {}
      local entries = {}
      for _, p in ipairs(paths) do
        if not seen[p] then
          seen[p] = true
          entries[#entries + 1] = { path = p, mtime = mtime(p) }
        end
      end

      -- A modified buffer sorts as though touched NOW: that is when its
      -- content last changed, and "recently touched first" is the whole
      -- reason this output is useful without reading all of it.
      if args.buffers ~= "off" then
        local now = os.time()
        local dirty = {}
        for _, cand in ipairs(modified_buffers(root)) do
          dirty[cand.path] = true
        end
        for _, entry in ipairs(entries) do
          if dirty[entry.path] then
            entry.mtime = now
          end
        end
      end

      table.sort(entries, function(a, b)
        if a.mtime == b.mtime then
          return a.path < b.path
        end
        return a.mtime > b.mtime
      end)

      local out = {}
      for i = 1, math.min(#entries, MAX_GLOB) do
        out[i] = entries[i].path
      end
      if #entries == 0 then
        return respond("(no files match " .. args.pattern .. " under " .. root .. ")")
      end
      if #entries > MAX_GLOB then
        out[#out + 1] = ("(truncated: %d of %d matches; narrow the pattern)"):format(MAX_GLOB, #entries)
      end
      respond(table.concat(out, "\n"))
    end

    if not rg then
      return finish(glob_walk(root, args.pattern))
    end
    run(M.glob_argv(args, { rg = rg, root = root }), nil, function(stdout, err)
      if err then
        return respond({ content = { { type = "text", text = "ripgrep failed: " .. err } }, isError = true })
      end
      local paths = {}
      for _, line in ipairs(vim.split(stdout, "\n", { plain = true })) do
        if line ~= "" then
          paths[#paths + 1] = line
        end
      end
      finish(paths)
    end)
  end,
}

---------------------------------------------------------------------------
-- grep
---------------------------------------------------------------------------

M.grep = {
  description = table.concat({
    "Search file contents with a regular expression (Rust regex syntax), powered by ripgrep.",
    "Prefer this over shell `grep`/`rg`: it searches the LIVE buffer state for files with",
    "unsaved edits, and it sees the project even when the agent process is sandboxed away from it.",
    "Filter with `glob`/`type`; pick the shape of the answer with `output_mode`.",
  }, " "),
  inputSchema = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "Regular expression (Rust regex syntax)" },
      path = { type = "string", description = "File or directory to search (default: the editor's cwd)" },
      glob = { type = "string", description = 'Filter files, e.g. "*.lua" or "*.{ts,tsx}"' },
      type = { type = "string", description = "ripgrep file type, e.g. lua, py, rust" },
      output_mode = {
        type = "string",
        enum = { "content", "files_with_matches", "count" },
        description = 'Shape of the result (default "files_with_matches")',
      },
      ["-i"] = { type = "boolean", description = "Case insensitive" },
      ["-n"] = { type = "boolean", description = "Show line numbers (content mode)" },
      ["-A"] = { type = "integer", description = "Lines of context after each match (content mode)" },
      ["-B"] = { type = "integer", description = "Lines of context before each match (content mode)" },
      ["-C"] = { type = "integer", description = "Lines of context before and after (content mode)" },
      multiline = { type = "boolean", description = "Let the pattern span lines" },
      hidden = { type = "boolean", description = "Include hidden files (default false)" },
      no_ignore = { type = "boolean", description = "Ignore .gitignore and friends (default false)" },
      head_limit = { type = "integer", description = "Cap the output at the first N lines/entries" },
      buffers = { type = "string", description = '"auto" (default) searches unsaved buffers, "off" is disk only' },
    },
    required = { "pattern" },
  },
  async = true,
  handler = function(args, respond)
    if type(args.pattern) ~= "string" or args.pattern == "" then
      error("`pattern` must be a non-empty regular expression", 0)
    end
    local rg = require_rg()
    local root = M.root(args)
    local mode = args.output_mode or "files_with_matches"

    local function fail(err)
      respond({ content = { { type = "text", text = "ripgrep failed: " .. err } }, isError = true })
    end

    run(M.grep_argv(args, { rg = rg, root = root }), nil, function(stdout, err)
      if err then
        return fail(err)
      end
      local records
      if mode == "content" then
        records = M.parse_json(stdout)
      elseif mode == "count" then
        records = parse_counts(stdout)
      else
        records = parse_paths(stdout)
      end

      if args.buffers == "off" then
        return respond(M.render(records, args))
      end

      filter_candidates(rg, args, modified_buffers(root), function(eligible)
        if #eligible == 0 then
          return respond(M.render(records, args))
        end
        -- One rg per modified buffer, on stdin: same flags, same engine, so
        -- an open file's results cannot disagree in kind with a closed one's.
        local pending = #eligible
        local function done()
          pending = pending - 1
          if pending == 0 then
            respond(M.render(records, args))
          end
        end
        for _, cand in ipairs(eligible) do
          local argv = M.grep_argv(args, { rg = rg, stdin = true })
          run(argv, buffer_text(cand.bufnr), function(buf_out, buf_err)
            if not buf_err then
              local fresh = M.parse_json(buf_out, cand.path)[1]
              substitute(records, cand.path, fresh)
            end
            done()
          end)
        end
      end)
    end)
  end,
}

return M
