-- Public entrypoint: setup() + the panel/session lifecycle. One session at a
-- time (multi-session lands later, mirroring agentic's registry); the session
-- OUTLIVES the panel — closing the dock keeps the conversation running, and
-- reopening binds the same store. stop() is the full shutdown.

local Config = require("clanker.config")
local Panel = require("clanker.view.panel")
local Prefs = require("clanker.view.prefs")
local Session = require("clanker.session")

local M = {}

--- @type clanker.Session|nil
local session = nil
--- @type clanker.view.PanelHandle|nil
local panel = nil
--- Per-session view prefs: survive close/reopen so toggles don't reset.
--- @type clanker.view.Prefs|nil
local prefs = nil

--- Merge user config. Config is a LIVE table other modules hold references
--- to, so merge in place — never reassign it.
--- @param opts table|nil clanker.UserConfig overrides
function M.setup(opts)
  for k, v in pairs(vim.tbl_deep_extend("force", Config, opts or {})) do
    Config[k] = v
  end
  vim.api.nvim_create_user_command("Clanker", function()
    M.toggle()
  end, { desc = "Toggle the clanker panel" })
end

--- The current session (nil before the first open / after stop()).
--- @return clanker.Session|nil
function M.get_session()
  return session
end

--- @return boolean
function M.is_open()
  return panel ~= nil and panel.is_open()
end

--- Open the panel (starting a session on first use); focuses the prompt if
--- already open.
--- @param opts { provider?: string, get_instance?: function, width?: integer, sidebar_width?: integer, prompt_height?: integer }|nil
---   provider/get_instance apply only when a session is (re)created.
function M.open(opts)
  opts = opts or {}
  if M.is_open() then
    panel.focus_prompt()
    return
  end

  if not session then
    session = Session:new({ provider = opts.provider, get_instance = opts.get_instance })
    prefs = Prefs:new()
    session:start()
  end

  local panel_opts = session:view_handlers()
  panel_opts.store = session:get_store()
  panel_opts.prefs = prefs
  panel_opts.width = opts.width
  panel_opts.sidebar_width = opts.sidebar_width
  panel_opts.prompt_height = opts.prompt_height
  panel = Panel.open(panel_opts)
end

--- Close the panel; the session keeps running.
function M.close()
  if panel then
    panel.close()
    panel = nil
  end
end

--- @param opts table|nil see open()
function M.toggle(opts)
  if M.is_open() then
    M.close()
  else
    M.open(opts)
  end
end

--- Full shutdown: close the panel AND stop/drop the session.
function M.stop()
  M.close()
  if session then
    session:cancel()
    session:stop()
    session = nil
    prefs = nil
  end
end

return M
