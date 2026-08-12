-- HTML → markdown-ish text, for w:web_fetch.
--
-- A model reading a page wants the prose, the headings, the link targets and
-- the code — not the chrome. Claude's WebFetch converts HTML to markdown
-- before the content is read; this is that step, kept deliberately small: a
-- tag-level rewriter, not a parser. Malformed markup degrades to "some tags
-- were stripped", which is the right failure for a reading tool.
--
-- What survives, and why: headings (structure), links WITH their href (a
-- model's next fetch), list items (enumerations are usually the answer),
-- code and pre (the reason we are on a docs page at all), emphasis (cheap).
-- What goes: script/style/svg/head noise, every remaining tag, and the
-- whitespace HTML authors never meant to be significant.

local M = {}

--- Named entities worth knowing plus the numeric forms. A full table is a
--- kilobyte of noise; these are what actually shows up in prose.
local ENTITIES = {
  amp = "&",
  lt = "<",
  gt = ">",
  quot = '"',
  apos = "'",
  nbsp = " ",
  ndash = "–",
  mdash = "—",
  hellip = "…",
  laquo = "«",
  raquo = "»",
  lsquo = "‘",
  rsquo = "’",
  ldquo = "“",
  rdquo = "”",
  copy = "©",
  reg = "®",
  trade = "™",
  middot = "·",
  bull = "•",
}

--- @param text string
--- @return string
function M.decode_entities(text)
  text = text:gsub("&#[xX](%x+);", function(hex)
    local n = tonumber(hex, 16)
    return n and vim.fn.nr2char(n) or ""
  end)
  text = text:gsub("&#(%d+);", function(dec)
    local n = tonumber(dec)
    return n and vim.fn.nr2char(n) or ""
  end)
  text = text:gsub("&(%a+);", function(name)
    return ENTITIES[name:lower()] or ("&" .. name .. ";")
  end)
  return text
end

--- The contents of the first <title>, decoded, or nil.
--- @param html string
--- @return string|nil
function M.title(html)
  local title = html:match("<[Tt][Ii][Tt][Ll][Ee][^>]*>(.-)</[Tt][Ii][Tt][Ll][Ee]>")
  if not title then
    return nil
  end
  title = M.decode_entities(title):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return title ~= "" and title or nil
end

--- Drop a container element and everything inside it (case-insensitively).
--- @param html string
--- @param tag string
--- @return string
local function drop_element(html, tag)
  return (html:gsub("<" .. tag .. "[^>]*>.-</" .. tag .. "%s*>", " "))
end

--- Case-insensitive tag pattern piece: "div" -> "[dD][iI][vV]".
--- @param tag string
--- @return string
local function ci(tag)
  return (tag:gsub("%a", function(c)
    return "[" .. c:lower() .. c:upper() .. "]"
  end))
end

--- Convert `html` to markdown-ish plain text.
--- @param html string
--- @return string
function M.to_markdown(html)
  local out = html

  -- Newlines are the hard part: in HTML a line break in the source is just
  -- whitespace, but the breaks WE introduce (a list item, a <br>, a paragraph
  -- boundary) are structure. They are indistinguishable once emitted, so the
  -- structural ones are emitted as control sentinels, incidental whitespace is
  -- collapsed wholesale at the end, and the sentinels then become real
  -- newlines. Verbatim blocks (<pre>) are parked out of the text entirely and
  -- put back last, so their own indentation and line breaks survive intact.
  local NL, PARA = "\1", "\2"
  local blocks = {}

  -- 1. Whole elements whose CONTENT is not content.
  out = out:gsub("<!%-%-.-%-%->", " ")
  for _, tag in ipairs({ "script", "style", "noscript", "svg", "head", "template", "iframe" }) do
    out = drop_element(out, ci(tag))
  end
  -- <head> is dropped above, so recover the title first: callers that want it
  -- ask M.title on the ORIGINAL html.

  -- 2. Code, before the generic tag strip eats the markers. <pre> becomes a
  -- fence, parked verbatim; inline <code> gets backticks.
  out = out:gsub("<" .. ci("pre") .. "[^>]*>(.-)</" .. ci("pre") .. "%s*>", function(inner)
    inner = M.decode_entities(inner:gsub("<[^>]+>", "")):gsub("^\n+", ""):gsub("%s+$", "")
    blocks[#blocks + 1] = "```\n" .. inner .. "\n```"
    return PARA .. "\3" .. #blocks .. "\3" .. PARA
  end)
  out = out:gsub("<" .. ci("code") .. "[^>]*>(.-)</" .. ci("code") .. "%s*>", function(inner)
    return "`" .. inner:gsub("<[^>]+>", "") .. "`"
  end)

  -- 3. Links keep their target: a href is the model's next fetch.
  out = out:gsub(
    "<" .. ci("a") .. "%s[^>]-" .. ci("href") .. '%s*=%s*"([^"]*)"[^>]*>(.-)</' .. ci("a") .. "%s*>",
    function(href, inner)
      inner = inner:gsub("<[^>]+>", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      if inner == "" then
        return ""
      end
      if href == "" or href:sub(1, 1) == "#" then
        return inner
      end
      return "[" .. inner .. "](" .. href .. ")"
    end
  )

  -- 4. Structure → markdown.
  for level = 1, 6 do
    local h = ci("h" .. level)
    out = out:gsub("<" .. h .. "[^>]*>(.-)</" .. h .. "%s*>", function(inner)
      inner = inner:gsub("<[^>]+>", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      return PARA .. string.rep("#", level) .. " " .. inner .. PARA
    end)
  end
  out = out:gsub("<" .. ci("li") .. "[^>]*>", NL .. "- ")
  out = out:gsub("<" .. ci("br") .. "%s*/?>", NL)
  out = out:gsub("<" .. ci("hr") .. "%s*/?>", PARA .. "---" .. PARA)
  for _, tag in ipairs({ "strong", "b" }) do
    out = out:gsub("<" .. ci(tag) .. "[^>]*>(.-)</" .. ci(tag) .. "%s*>", "**%1**")
  end
  for _, tag in ipairs({ "em", "i" }) do
    out = out:gsub("<" .. ci(tag) .. "[^>]*>(.-)</" .. ci(tag) .. "%s*>", "*%1*")
  end
  -- Block boundaries become blank lines so paragraphs stay paragraphs.
  local BLOCKS = {
    "p",
    "div",
    "section",
    "article",
    "tr",
    "ul",
    "ol",
    "table",
    "blockquote",
    "header",
    "footer",
    "nav",
    "main",
    "aside",
    "figure",
    "dl",
    "dt",
    "dd",
    "form",
  }
  for _, tag in ipairs(BLOCKS) do
    out = out:gsub("</?" .. ci(tag) .. "[^>]*>", PARA)
  end
  out = out:gsub("</?" .. ci("td") .. "[^>]*>", " | ")
  out = out:gsub("</?" .. ci("th") .. "[^>]*>", " | ")

  -- 5. Everything still wearing angle brackets is chrome.
  out = out:gsub("<[^>]+>", "")
  out = M.decode_entities(out)

  -- 6. Everything left is whitespace HTML never meant — including the source's
  -- own line breaks, which are not paragraph breaks. Collapse it all, then let
  -- the sentinels become the structure they stood for.
  out = out:gsub("%s+", " ")
  out = out:gsub(" *" .. PARA .. " *", PARA)
  out = out:gsub(" *" .. NL .. " *", NL)
  out = out:gsub(PARA .. "+", "\n\n")
  out = out:gsub(NL .. "+", "\n")
  out = out:gsub("\n\n\n+", "\n\n")
  out = out:gsub("^%s+", ""):gsub("%s+$", "")

  -- 7. Verbatim blocks back, whitespace and all.
  out = out:gsub("\3(%d+)\3", function(i)
    return blocks[tonumber(i)] or ""
  end)
  return out
end

return M
