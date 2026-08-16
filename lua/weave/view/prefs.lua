-- Per-panel view preferences became the VIEW scope of weave.settings — one
-- registry, one store contract, three scopes (see lua/weave/settings.lua).
-- This forwarder keeps the old constructor for existing callers; new code
-- should ask weave.settings directly.

local Settings = require("weave.settings")

return {
  new = function()
    return Settings.new_view()
  end,
}
