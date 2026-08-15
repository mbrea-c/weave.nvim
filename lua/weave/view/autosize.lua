-- Sizing for the auto-resizing text inputs (the prompt box and the code
-- feedback comment editor): the box follows its content, one row per line,
-- between MIN_ROWS and MAX_ROWS content rows. Both bounds EXCLUDE the border;
-- text_input's `height` prop is border-box, so height() hands back content
-- rows plus the two border rows, ready to pass straight through.

local M = {}

M.MIN_ROWS = 3
M.MAX_ROWS = 8

--- Border-box height for an input showing `text`.
--- @param text string|nil the input's current text
--- @param min_rows integer|nil taller floor (config may want a bigger resting
---   box); a floor above MAX_ROWS wins over the cap, below MIN_ROWS it is
---   ignored — the box never sinks under the minimum that keeps it readable
--- @return integer
function M.height(text, min_rows)
  local _, breaks = (text or ""):gsub("\n", "")
  local floor = math.max(min_rows or M.MIN_ROWS, M.MIN_ROWS)
  local rows = math.min(math.max(breaks + 1, floor), math.max(M.MAX_ROWS, floor))
  return rows + 2
end

return M
