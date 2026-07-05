-- The live configuration table. Modules require this once at the top and read
-- fields at call time, so user overrides (a future setup()) must mutate this
-- table IN PLACE — never reassign it. Mirrors the shape agentic used, minus
-- everything view-related.

local defaults = require("weave.config_default")

--- @type weave.UserConfig
local Config = vim.tbl_deep_extend("force", defaults, {})

return Config
