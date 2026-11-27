-- Some transcript interactions target exact cells, including inert text.
return function()
  local mode = require("fibrous.inline.widget_mode")
  if mode.enabled then
    mode.toggle()
    return mode.toggle
  end
  return function() end
end
