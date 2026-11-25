local ui = require("fibrous.inline.components")
local Width = require("fibrous.inline.width")
local Theme = require("weave.view.theme")

local TITLE = "Last prompt: "

-- Cut by display cells, not bytes, using the same clusters as the painter.
local function fits(text, columns)
  local bytes, cells = 0, 0
  for cluster in Width.clusters(text) do
    cells = cells + Width.char(cluster)
    if cells > columns then break end
    bytes = bytes + #cluster
  end
  return bytes
end

local function preview(text, columns)
  if columns == 0 then return "" end
  local title = columns >= #TITLE + 4 and TITLE or (columns >= 6 and "❯ " or "")
  local cut = fits(text, columns - Width.str(title))
  local first = text:sub(1, cut)
  if cut < #text and text:sub(cut + 1, cut + 1) ~= " " then
    -- Prefer breaking at a word boundary; hard-cut an unbroken path or word.
    local space = first:match(".*() ")
    if space then cut, first = space - 1, first:sub(1, space - 1) end
  end
  local rest = text:sub(cut + 1):gsub("^ +", "")
  local tail = fits(rest, columns)
  if tail < #rest then
    local ellipsis = Width.str("…") <= columns and "…" or "."
    rest = rest:sub(1, fits(rest, columns - Width.str(ellipsis))):gsub(" +$", "") .. ellipsis
  end
  return { { title, hl = Theme.USER_MARKER_HL }, first:gsub(" +$", "") .. "\n" .. rest }
end

-- Only the sent prompt invalidates this strip, not streamed transcript updates.
-- It is painted into the panel canvas, outside the scrolling transcript.
return function(ctx, props)
  local store = props.store
  local prompt = ctx.use_state(store.state.last_prompt)
  ctx.use_effect(function()
    local function sync(state)
      prompt.set(state.last_prompt)
    end
    sync(store.state)
    return store:subscribe(sync)
  end, { store })
  local text = prompt.get()
  if not text then return nil end
  text = vim.trim((text:gsub("[%c%s]+", " ")))
  return {
    comp = ui.label,
    props = {
      height = 2,
      fill = function(columns) return preview(text, columns) end,
      style = { hl = Theme.USER_BUBBLE_HL, text_hl = Theme.USER_MSG_HL, padding = { x = 1 } },
    },
  }
end
