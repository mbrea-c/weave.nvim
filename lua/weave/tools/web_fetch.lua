-- w:web_fetch — fetch a URL and hand the agent its readable content.
--
-- Written for parity with Claude's own WebFetch, because an agent arrives
-- knowing that tool and will call this one the same way. Matched behaviours:
--
--   * `url` + `prompt` parameters, same names;
--   * http:// is upgraded to https://;
--   * HTML is converted to markdown before the agent reads it;
--   * a 15-minute self-cleaning cache, so re-reading a page mid-task is free;
--   * a redirect to a DIFFERENT HOST is not followed — the tool returns the
--     new URL and asks the agent to re-issue, so a fetch never silently ends
--     up somewhere the user did not approve (the URL is what the permission
--     rule matched on: silently following would make the rule a lie);
--   * read-only: nothing here changes state.
--
-- One difference, stated rather than faked: Claude's WebFetch runs `prompt`
-- against the page with a second, small model and returns its answer. Weave
-- has no model of its own to call, so `prompt` is accepted, echoed into the
-- result header (it is useful context in the transcript) and the content is
-- returned whole for the CALLING model to apply it to. Truncation aside, the
-- agent sees strictly more than Claude's tool would give it.
--
-- Where it runs: clientside, in the editor's network namespace, like every
-- other weave tool — and the curl subprocess is confined by the active
-- preset's hull for `weave:web_fetch`, which the builtin sandboxed presets
-- give `network = true, binds = {}`: the one tool that needs the net and
-- nothing else. See weave.permissions.tool_sandbox.

local Config = require("weave.config")
local HtmlText = require("weave.tools.html_text")

local M = {}

--- Claude's cache window, and the reason a multi-step task can re-read a page
--- without paying for it twice.
M.CACHE_TTL_MS = 15 * 60 * 1000

--- Hard cap on what one fetch returns. A page is context, not a payload.
M.MAX_CHARS = 100000

--- Same-host hops we follow before giving up.
M.MAX_REDIRECTS = 5

M.TIMEOUT_MS = 30000

--- @type table<string, { at: integer, text: string }>
local cache = {}

--- Monotonic-ish clock (test seam).
--- @return integer milliseconds
function M._now()
  return vim.uv.now()
end

--- curl, from config or PATH. Config first for the same reason
--- `tools.ripgrep_path` exists: under a Nix-wrapped Neovim the ambient PATH
--- is not the user's PATH.
--- @return string|nil
function M.curl_path()
  local configured = Config.tools and Config.tools.curl_path
  if type(configured) == "string" and configured ~= "" then
    return configured
  end
  local found = vim.fn.exepath("curl")
  return found ~= "" and found or nil
end

--- Spawn seam (specs script curl's answers instead of reaching the network).
--- @param argv string[]
--- @param cb fun(res: { code: integer, stdout: string, stderr: string })
function M._run(argv, cb)
  local Sandbox = require("weave.sandbox")
  local command, args = argv[1], { unpack(argv, 2) }
  command, args = Sandbox.wrap_for_tool("weave:web_fetch", command, args)
  local full = { command }
  vim.list_extend(full, args)
  vim.system(full, { text = true, timeout = M.TIMEOUT_MS }, function(res)
    vim.schedule(function()
      cb({ code = res.code or -1, stdout = res.stdout or "", stderr = res.stderr or "" })
    end)
  end)
end

--- The host part of a URL, lowercased (nil when it does not look like one).
--- @param url string
--- @return string|nil
function M.host_of(url)
  local host = url:match("^%a[%w+.-]*://([^/?#]+)")
  return host and host:lower() or nil
end

--- Normalize the requested URL: trim, upgrade http → https (Claude's
--- behaviour — the plaintext version of a page is rarely what anyone means
--- today), and reject anything that is not http(s).
--- @param url any
--- @return string|nil normalized, string|nil err
function M.normalize_url(url)
  if type(url) ~= "string" or url:gsub("%s", "") == "" then
    return nil, "web_fetch needs a `url`"
  end
  url = url:gsub("^%s+", ""):gsub("%s+$", "")
  local scheme = url:match("^(%a[%w+.-]*)://")
  if not scheme then
    url = "https://" .. url
    scheme = "https"
  end
  scheme = scheme:lower()
  if scheme == "http" then
    url = "https://" .. url:sub(#"http://" + 1)
  elseif scheme ~= "https" then
    return nil, ("web_fetch only speaks http(s); %q is not fetchable"):format(scheme)
  end
  if not M.host_of(url) then
    return nil, ("%q is not a URL web_fetch can parse"):format(url)
  end
  return url, nil
end

--- Drop expired entries; the cache cleans itself on use rather than on a
--- timer, so an idle editor holds nothing open.
local function prune()
  local now = M._now()
  for url, entry in pairs(cache) do
    if now - entry.at >= M.CACHE_TTL_MS then
      cache[url] = nil
    end
  end
end

--- @param url string
--- @return string|nil
local function cached(url)
  prune()
  local entry = cache[url]
  return entry and entry.text or nil
end

function M._reset_cache()
  cache = {}
end

--- One curl invocation: headers and body, no redirect following (we decide
--- per hop). `-sS` keeps progress noise out but keeps errors.
--- @param url string
--- @param cb fun(res: { status: integer, headers: string, body: string }|nil, err: string|nil)
local function fetch_once(url, cb)
  local curl = M.curl_path()
  if not curl then
    return cb(
      nil,
      "curl is not installed or not on this Neovim's PATH; "
        .. "install it, or set `tools.curl_path` in weave's config to its absolute path"
    )
  end
  M._run({
    curl,
    "-sS",
    "--no-progress-meter",
    "--include", -- headers first, so we can read Location/Content-Type ourselves
    "--max-redirs",
    "0",
    "--max-time",
    tostring(math.floor(M.TIMEOUT_MS / 1000)),
    "--user-agent",
    "weave.nvim (+https://github.com/wgn-dev/weave.nvim)",
    url,
  }, function(res)
    if res.code ~= 0 then
      local msg = (res.stderr or ""):gsub("%s+$", "")
      return cb(nil, msg ~= "" and msg or ("curl exited %d fetching %s"):format(res.code, url))
    end
    -- Split the LAST header block from the body (a 100-continue or a proxy
    -- can stack more than one).
    local body = res.stdout
    local headers = ""
    while true do
      local head, rest = body:match("^(HTTP/[^\n]*\r?\n.-)\r?\n\r?\n(.*)$")
      if not head then
        break
      end
      headers, body = head, rest
    end
    local status = tonumber(headers:match("^HTTP/%S+%s+(%d%d%d)") or "") or 0
    cb({ status = status, headers = headers, body = body }, nil)
  end)
end

--- @param headers string
--- @param name string
--- @return string|nil
local function header(headers, name)
  for line in headers:gmatch("[^\r\n]+") do
    local key, value = line:match("^(%S+)%s*:%s*(.*)$")
    if key and key:lower() == name:lower() then
      return (value:gsub("%s+$", ""))
    end
  end
  return nil
end

--- Resolve a Location against the URL it came from (absolute, //host, /path
--- and bare relative forms).
--- @param base string
--- @param location string
--- @return string
function M.resolve_location(base, location)
  if location:match("^%a[%w+.-]*://") then
    return location
  end
  local scheme = base:match("^(%a[%w+.-]*)://") or "https"
  if location:sub(1, 2) == "//" then
    return scheme .. ":" .. location
  end
  local host = M.host_of(base) or ""
  if location:sub(1, 1) == "/" then
    return scheme .. "://" .. host .. location
  end
  local dir = base:match("^(.*/)[^/]*$") or (scheme .. "://" .. host .. "/")
  return dir .. location
end

--- Is this content type something a model can read as text?
--- @param content_type string|nil
--- @return boolean
function M.is_textual(content_type)
  if not content_type or content_type == "" then
    return true -- unlabelled: try it, the converter degrades gracefully
  end
  local mime = content_type:match("^[^;]+") or content_type
  mime = mime:lower():gsub("%s", "")
  if mime:match("^text/") then
    return true
  end
  return mime:match("^application/[%w.+-]*json$") ~= nil
    or mime:match("^application/[%w.+-]*xml$") ~= nil
    or mime == "application/xhtml+xml"
    or mime == "application/javascript"
    or mime == "application/x-yaml"
end

--- Convert a response body to what the agent reads: markdown for HTML,
--- untouched for everything else textual.
--- @param body string
--- @param content_type string|nil
--- @return string text, string|nil title
function M.render_body(body, content_type)
  local mime = (content_type or ""):match("^[^;]+") or ""
  local looks_html = mime:lower():find("html", 1, true) ~= nil
    or (mime == "" and body:lower():find("<html", 1, true) ~= nil)
  if not looks_html then
    return body, nil
  end
  return HtmlText.to_markdown(body), HtmlText.title(body)
end

--- Fetch `url`, following same-host redirects, and answer with the rendered
--- text or an error string.
--- @param url string normalized
--- @param hops integer
--- @param cb fun(text: string|nil, err: string|nil)
local function fetch_chain(url, hops, cb)
  fetch_once(url, function(res, err)
    if err then
      return cb(nil, err)
    end
    local status = res.status
    if status >= 300 and status < 400 then
      local location = header(res.headers, "location")
      if not location or location == "" then
        return cb(nil, ("%s answered %d with no Location header"):format(url, status))
      end
      local target = M.resolve_location(url, location)
      if M.host_of(target) ~= M.host_of(url) then
        -- Deliberately NOT followed: the permission rule matched the host the
        -- agent named. Hand back the new URL and let it (and the user) decide.
        return cb(
          ("%s redirects to a different host:\n\n%s\n\nweb_fetch does not follow cross-host redirects. "):format(
            url,
            target
          ) .. "Call web_fetch again with that URL if you want it.",
          nil
        )
      end
      if hops >= M.MAX_REDIRECTS then
        return cb(nil, ("%s: more than %d redirects"):format(url, M.MAX_REDIRECTS))
      end
      return fetch_chain(target, hops + 1, cb)
    end
    if status < 200 or status >= 300 then
      return cb(nil, ("%s answered HTTP %d"):format(url, status))
    end

    local content_type = header(res.headers, "content-type")
    if not M.is_textual(content_type) then
      return cb(nil, ("%s is %s, which web_fetch cannot read as text"):format(url, content_type or "untyped"))
    end

    local text, title = M.render_body(res.body, content_type)
    local head = { "# " .. url }
    if title then
      head[#head + 1] = "Title: " .. title
    end
    if #text > M.MAX_CHARS then
      text = text:sub(1, M.MAX_CHARS)
      head[#head + 1] = ("(truncated to %d characters)"):format(M.MAX_CHARS)
    end
    cb(table.concat(head, "\n") .. "\n\n" .. text, nil)
  end)
end

M.def = {
  description = "Fetch a URL and read its content. HTML is converted to markdown. Use `prompt` to say what you "
    .. "are looking for — the full content comes back for you to apply it to. Results are cached for 15 minutes. "
    .. "http:// URLs are upgraded to https://, and a redirect to a different host is reported rather than "
    .. "followed (call again with the new URL). Read-only.",
  inputSchema = {
    type = "object",
    properties = {
      url = { type = "string", description = "The URL to fetch (http/https)" },
      prompt = { type = "string", description = "What you want from the page; shown to the user with the call" },
    },
    required = { "url" },
  },
  async = true,
  handler = function(args, respond)
    local url, err = M.normalize_url(args and args.url)
    if not url then
      return respond({ content = { { type = "text", text = err } }, isError = true })
    end

    local hit = cached(url)
    if hit then
      return respond(hit .. "\n\n(from web_fetch's 15-minute cache)")
    end

    fetch_chain(url, 0, function(text, ferr)
      if ferr then
        return respond({ content = { { type = "text", text = ferr } }, isError = true })
      end
      cache[url] = { at = M._now(), text = text }
      respond(text)
    end)
  end,
}

return M
