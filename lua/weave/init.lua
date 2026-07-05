-- Public entrypoint: setup() + the panel/session lifecycle. Active sessions
-- live in the registry — editor-global, several at once, possibly on
-- DIFFERENT providers. Each TABPAGE has its own selected session and its own
-- panel; toggle shows the tab's selection (starting a session on first use).
-- Sessions outlive panels: closing the dock keeps the conversation running,
-- reopening binds the same store. stop() is the full shutdown.

local AgentInstance = require("weave.acp.agent_instance")
local Config = require("weave.config")
local Logger = require("weave.utils.logger")
local Panel = require("weave.view.panel")
local Registry = require("weave.registry")
local SessionModal = require("weave.view.session_modal")

local M = {}

--- Open panels by tabpage handle. `opts` keeps the geometry the panel was
--- opened with, so a session swap in the same tab reopens at the same size.
--- @type table<integer, { handle: weave.view.PanelHandle, key: integer, opts: table }>
local panels = {}

--- The get_instance injection last handed to open(), reused by the modal's
--- new-session/load-saved flows — specs and the demo script the agent ONCE
--- and every later session stays scripted. nil = the real AgentInstance.
--- @type function|nil
local injected_get_instance = nil

--- The current tab's open panel, pruning a stale record (dock closed via :q).
--- @return { handle: weave.view.PanelHandle, key: integer, opts: table }|nil
local function tab_panel()
  local tab = vim.api.nvim_get_current_tabpage()
  local p = panels[tab]
  if p and p.handle.is_open() then
    return p
  end
  panels[tab] = nil
  return nil
end

--- Bind `entry` to a panel in the current tab.
--- @param entry weave.registry.Entry
--- @param opts { width?: integer, sidebar_width?: integer, prompt_height?: integer }
local function open_panel(entry, opts)
  local panel_opts = entry.session:view_handlers()
  panel_opts.store = entry.session:get_store()
  panel_opts.prefs = entry.prefs
  panel_opts.width = opts.width
  panel_opts.sidebar_width = opts.sidebar_width
  panel_opts.prompt_height = opts.prompt_height
  panel_opts.on_sessions = function()
    M.sessions()
  end
  panels[vim.api.nvim_get_current_tabpage()] = {
    handle = Panel.open(panel_opts),
    key = entry.key,
    opts = opts,
  }
end

--- Make `entry` the current tab's session: select it and (re)bind the tab's
--- panel to it, keeping the geometry the panel was opened with.
--- @param entry weave.registry.Entry
local function select_session(entry)
  local tab = vim.api.nvim_get_current_tabpage()
  local p = tab_panel()
  local opts = p and p.opts or {}
  Registry.select(entry.key)
  if p then
    if p.key == entry.key then
      return
    end
    p.handle.close()
    panels[tab] = nil
  end
  open_panel(entry, opts)
end

--- vim.ui.select over the configured providers (● marks the default).
--- @param on_picked fun(provider: string)
local function pick_provider(on_picked)
  local names = vim.tbl_keys(Config.acp_providers)
  table.sort(names)
  vim.ui.select(names, {
    prompt = "Provider:",
    format_item = function(name)
      local cfg = Config.acp_providers[name]
      local marker = name == Config.provider and "● " or "  "
      return marker .. (cfg and cfg.name or name) .. " (" .. name .. ")"
    end,
  }, function(choice)
    if choice then
      on_picked(choice)
    end
  end)
end

--- The load-saved flow: pick a provider, list ITS saved sessions for this
--- cwd, and activate the pick into a FRESH registry entry (unlike ;;r, which
--- restores in place over the current conversation).
--- @param get_instance function|nil spec injection; defaults to AgentInstance
local function load_saved_flow(get_instance)
  pick_provider(function(provider)
    local get = get_instance or AgentInstance.get_instance
    get(provider, function(client)
      vim.schedule(function()
        client:list_sessions(vim.fn.getcwd(), function(result, err)
          vim.schedule(function()
            if err or not result then
              Logger.notify(
                "Failed to list sessions: " .. (err and err.message or "unknown error"),
                vim.log.levels.WARN
              )
              return
            end
            local sessions = result.sessions or {}
            if #sessions == 0 then
              Logger.notify("No saved sessions found.", vim.log.levels.INFO)
              return
            end
            local items = {}
            for _, s in ipairs(sessions) do
              local date = s.updatedAt and s.updatedAt:sub(1, 16):gsub("T", " ") or "unknown date"
              items[#items + 1] = {
                session_id = s.sessionId,
                display = string.format("%s - %s", date, s.title or "(no title)"),
              }
            end
            vim.ui.select(items, {
              prompt = "Activate saved session:",
              format_item = function(item)
                return item.display
              end,
            }, function(choice)
              if not choice then
                return
              end
              select_session(Registry.add({
                provider = provider,
                restore = choice.session_id,
                get_instance = get_instance,
              }))
            end)
          end)
        end)
      end)
    end)
  end)
end

-- A session closed anywhere (the modal's ✕, stop()) tears down every panel
-- showing it, in whatever tab.
Registry.on_close(function(entry)
  for tab, p in pairs(panels) do
    if p.key == entry.key then
      p.handle.close()
      panels[tab] = nil
    end
  end
end)

--- Merge user config. Config is a LIVE table other modules hold references
--- to, so merge in place — never reassign it.
--- @param opts table|nil weave.UserConfig overrides
function M.setup(opts)
  for k, v in pairs(vim.tbl_deep_extend("force", Config, opts or {})) do
    Config[k] = v
  end
  vim.api.nvim_create_user_command("Weave", function(cmd)
    if cmd.args == "sessions" then
      M.sessions()
    else
      M.toggle()
    end
  end, {
    desc = "Toggle the weave panel (:Weave sessions for the session modal)",
    nargs = "?",
    complete = function()
      return { "sessions" }
    end,
  })
end

--- The session selected in the current tab (nil when none is).
--- @return weave.Session|nil
function M.get_session()
  local entry = Registry.selected()
  return entry and entry.session or nil
end

--- Whether the current tab has an open panel.
--- @return boolean
function M.is_open()
  return tab_panel() ~= nil
end

--- Open the panel for the current tab's selected session (starting and
--- selecting a new one when the tab has none); focuses the prompt if already
--- open.
--- @param opts { provider?: string, get_instance?: function, width?: integer, sidebar_width?: integer, prompt_height?: integer }|nil
---   provider/get_instance apply only when a session is (re)created.
function M.open(opts)
  opts = opts or {}
  local p = tab_panel()
  if p then
    p.handle.focus_prompt()
    return
  end

  injected_get_instance = opts.get_instance or injected_get_instance

  local entry = Registry.selected()
  if not entry then
    entry = Registry.add({ provider = opts.provider, get_instance = opts.get_instance })
    Registry.select(entry.key)
  end
  open_panel(entry, opts)
end

--- Close the current tab's panel; the session keeps running.
function M.close()
  local p = tab_panel()
  if p then
    p.handle.close()
    panels[vim.api.nvim_get_current_tabpage()] = nil
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

--- Open the session modal for the current tab: every active session, this
--- tab's selection, per-row close, and the new/load-saved flows.
--- @param opts { get_instance?: function }|nil get_instance is spec injection
---   for the new-session and load-saved flows.
--- @return weave.view.SessionModalHandle handle
function M.sessions(opts)
  opts = opts or {}
  local get_instance = opts.get_instance or injected_get_instance
  return SessionModal.open({
    on_select = select_session,
    on_new = function()
      pick_provider(function(provider)
        select_session(Registry.add({ provider = provider, get_instance = get_instance }))
      end)
    end,
    on_load_saved = function()
      load_saved_flow(get_instance)
    end,
  })
end

--- Full shutdown: close every session — the on_close hook takes each
--- session's panels (in every tab) down with it.
function M.stop()
  for _, entry in ipairs(Registry.list()) do
    Registry.close(entry.key)
  end
end

return M
