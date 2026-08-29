-- weave.prompts: the text weave sends to AGENTS, kept as markdown files
-- instead of Lua string literals.
--
-- Everything under prompts/ is prose meant to be REWRITTEN — the tutor brief
-- especially is the whole agent-facing contract of that mode, and the shipped
-- wording is a starting point, not a fixture. Editing prose inside a
-- `table.concat` of quoted lines is miserable (no wrapping, no spell check, a
-- diff per line, quotes to escape), so it lives where prose belongs: one
-- markdown file per prompt.
--
-- Three roads to the text, in order:
--
--   1. an inline string in config, where one already existed (a brief's
--      `prompt`, `edits.edits_prompt`) — still supported, still wins
--   2. a file the USER points at: `Config.prompts[name]`, or a brief's
--      `prompt_file`
--   3. the shipped `prompts/<name>.md`
--
-- Read at SEND time, never cached: edit a prompt and the next send uses it,
-- with no restart and no reload. These are a few hundred bytes read a handful
-- of times per conversation — the cache would buy nothing and cost exactly
-- the iteration loop the files exist to make pleasant.
--
-- Relative paths resolve inside weave's own prompts/ dir, never the cwd: a
-- prompt whose meaning changed with `:cd` would be a bad surprise. Point at
-- your own files with an absolute or ~-relative path.

local Config = require("weave.config")

local M = {}

--- weave's own prompts/ directory, derived from THIS file's path rather than
--- from the runtimepath: the specs load the checkout directly (no rtp entry
--- for it), and a plugin that ends up installed twice must never read the
--- other copy's prompts.
--- @return string
function M.dir()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h") .. "/prompts"
end

--- @param path string
--- @return string
local function resolve_path(path)
  local first = path:sub(1, 1)
  if first == "~" then
    return vim.fn.expand(path)
  end
  if first == "/" then
    return path
  end
  return M.dir() .. "/" .. path
end

--- Read a prompt file.
---
--- Missing or unreadable is a WARNING that returns nil, never an error: these
--- are read on the way into a send, and a typo'd path must not take the send
--- (or the conversation) down with it. Every caller treats nil as "this has
--- nothing to say", which is the same thing an empty prompt has always meant.
--- @param path string absolute, ~-relative, or relative to weave's prompts/
--- @return string|nil text trailing whitespace trimmed; nil when empty/missing
function M.read(path)
  local resolved = resolve_path(path)
  local fd = io.open(resolved, "r")
  if not fd then
    vim.notify(("weave: cannot read prompt file %s"):format(resolved), vim.log.levels.WARN)
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  text = (text or ""):gsub("%s+$", "")
  if text == "" then
    return nil
  end
  return text
end

--- A named prompt: the user's override (`Config.prompts[name]`, a file path)
--- when there is one, else the shipped `prompts/<name>.md`.
--- @param name string
--- @return string|nil
function M.get(name)
  local override = (Config.prompts or {})[name]
  if type(override) == "string" and override ~= "" then
    return M.read(override)
  end
  return M.read(name .. ".md")
end

--- The text behind a `{ prompt = "...", prompt_file = "..." }` pair — the
--- shape briefs use. An inline `prompt` wins: it is the more specific answer,
--- and it is what config written before `prompt_file` existed already says.
--- @param spec { prompt?: string, prompt_file?: string }|nil
--- @return string|nil
function M.resolve(spec)
  spec = spec or {}
  if type(spec.prompt) == "string" and spec.prompt ~= "" then
    return spec.prompt
  end
  if type(spec.prompt_file) == "string" and spec.prompt_file ~= "" then
    return M.read(spec.prompt_file)
  end
  return nil
end

return M
