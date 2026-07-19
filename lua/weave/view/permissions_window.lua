-- The permission-preset configuration window (design-agent-sandbox.md,
-- phase 1): the UI over the editor-global engine (weave.permissions).
-- A floating fibrous modal lists every preset — source-tagged, the active
-- one marked, a row activates — and the active preset's rules beneath.
-- Editing is vim-native rather than form widgets: [edit]/[new] open the
-- preset as a Lua table in an acwrite scratch float; `:w` parses, validates
-- and applies it as a RUNTIME preset (shadowing a builtin/setup preset of
-- the same name — always reversible via [delete]); `:q` discards. Runtime
-- presets are in-memory for now (persistence is an open question in the
-- design doc).

local ui = require("fibrous.inline.components")
local Logger = require("weave.utils.logger")
local Permissions = require("weave.permissions")
local use_permissions = require("weave.view.use_permissions")

local M = {}

local function header(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "Title" } } }
end

local function dim(text)
  return { comp = ui.label, props = { text = text, style = { text_hl = "@comment" } } }
end

local function blank()
  return { comp = ui.label, props = { text = "" } }
end

local function bare_button(label, on_press)
  return {
    comp = ui.button,
    props = {
      label = label,
      theme = false,
      style = { _hover = { hl = "FibrousHover" } },
      on_press = on_press,
    },
  }
end

--- The preset serialized for the editor buffer: a usage comment, then the
--- caller-owned fields as a Lua table literal (never `source` — the engine
--- assigns that).
--- @param preset weave.permissions.Preset
--- @return string[] lines
function M.serialize(preset)
  local lines = {
    "-- weave permission preset: `:w` applies it as a runtime preset, `:q` discards.",
    "-- A rule is { tool = <glob>, resource = <glob, optional>, decision = allow|deny|ask };",
    "-- first match wins. Tools: acp:<kind>, weave:<tool>, <plugin>:<tool>.",
  }
  local body = vim.inspect({ name = preset.name, label = preset.label, rules = preset.rules })
  vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
  return lines
end

--- Parse an editor buffer back into a preset table. Errors are messages for
--- the user, not traces.
--- @param text string
--- @return table|nil preset, string|nil err
function M.parse(text)
  local chunk, err = loadstring("return \n" .. text)
  if not chunk then
    return nil, "parse error: " .. tostring(err)
  end
  setfenv(chunk, {}) -- a preset is data; nothing to call, nothing to reach
  local ok, tbl = pcall(chunk)
  if not ok then
    return nil, "evaluation error: " .. tostring(tbl)
  end
  if type(tbl) ~= "table" then
    return nil, "the buffer must contain a single Lua table"
  end
  return tbl, nil
end

--- Open `preset` in the acwrite editor float. `:w` saves it through
--- Permissions.save_preset (errors notify and keep the float open, so the
--- edit is never lost); close_float refuses to discard unsaved edits (`:q!`
--- remains the explicit discard).
--- @param preset weave.permissions.Preset
local function open_editor(preset)
  local lines = M.serialize(preset)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "lua"
  pcall(vim.api.nvim_buf_set_name, buf, "weave://permission-preset/" .. preset.name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  local width = 72
  local height = math.min(#lines + 4, math.max(vim.o.lines - 6, 8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2), 1),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    border = "rounded",
    title = " permission preset ",
    title_pos = "center",
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      local tbl, perr = M.parse(text)
      if not tbl then
        Logger.notify("weave: preset not saved — " .. perr, vim.log.levels.WARN)
        return
      end
      local ok, serr = pcall(Permissions.save_preset, tbl)
      if not ok then
        Logger.notify("weave: preset not saved — " .. tostring(serr), vim.log.levels.WARN)
        return
      end
      vim.bo[buf].modified = false
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      Logger.notify(("weave: permission preset %q saved (runtime)"):format(tbl.name), vim.log.levels.INFO)
    end,
  })

  require("weave.keys").map(buf, "close_float", function()
    if vim.bo[buf].modified then
      Logger.notify("weave: unsaved preset edits — :w applies, :q! discards", vim.log.levels.WARN)
      return
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { nowait = true, desc = "weave: close preset editor" })
end

--- One preset row: the active marker + label as an activate button, the
--- source tag dimmed beside it.
---
--- A preset the current sandbox profile does not satisfy is shown GREYED with
--- its reason, and stays selectable. Silence belongs in the ;;p cycle, not in
--- this list: a preset appearing in neither is indistinguishable from one
--- that does not exist, and the user never learns that turning on a profile
--- would unlock it. Activating one routes through profile_transition, which
--- confirms the restart before anything is applied.
--- @param p weave.permissions.Preset
--- @param active_name string
local function preset_row(p, active_name)
  local marker = p.name == active_name and "●" or "○"
  local ok, reason = Permissions.preset_compatible(p)
  local label = ("%s %s"):format(marker, p.label or p.name)
  local children = {
    ok and bare_button(label, function()
      Permissions.set_active(p.name)
    end) or {
      comp = ui.button,
      props = {
        label = label,
        theme = false,
        style = { text_hl = "@comment", _hover = { hl = "FibrousHover" } },
        on_press = function()
          require("weave.profile_transition").select_preset(p.name)
        end,
      },
    },
    dim(p.source or "?"),
  }
  if reason then
    children[#children + 1] = dim("(" .. reason .. ")")
  end
  return { comp = ui.row, props = { gap = 2 }, children = children }
end

--- @param rule weave.permissions.Rule
--- @param on_revoke fun()
local function grant_row(rule, on_revoke)
  local text = ("  %-5s  %s"):format(rule.decision, rule.tool)
  if rule.resource then
    text = text .. "  " .. rule.resource
  end
  return {
    comp = ui.row,
    props = { gap = 2 },
    children = { { comp = ui.label, props = { text = text } }, bare_button("[revoke]", on_revoke) },
  }
end

--- @param rule weave.permissions.Rule
local function rule_row(rule)
  local text = ("  %-5s  %s"):format(rule.decision, rule.tool)
  if rule.resource then
    text = text .. "  " .. rule.resource
  end
  return { comp = ui.label, props = { text = text } }
end

local function Window(ctx)
  local active = use_permissions(ctx)
  local rows = { header("Permission presets") }
  for _, p in ipairs(Permissions.presets()) do
    rows[#rows + 1] = preset_row(p, active.name)
  end

  rows[#rows + 1] = blank()
  rows[#rows + 1] = header("Rules: " .. (active.label or active.name))
  if #(active.rules or {}) == 0 then
    rows[#rows + 1] = dim("  (no rules: everything asks)")
  end
  for _, rule in ipairs(active.rules or {}) do
    rows[#rows + 1] = rule_row(rule)
  end

  -- Session grants: a grant the user cannot see is a grant they cannot
  -- revoke. Deliberately a separate list from the preset's rules — answering
  -- "allow for project" on a prompt must never silently redefine `normal`.
  local grants = Permissions.grants()
  if #grants > 0 then
    rows[#rows + 1] = blank()
    rows[#rows + 1] = header(("Session grants (%d)"):format(#grants))
    for i, rule in ipairs(grants) do
      rows[#rows + 1] = grant_row(rule, function()
        Permissions.revoke_grant(i)
      end)
    end
    rows[#rows + 1] = {
      comp = ui.row,
      props = { gap = 2 },
      children = {
        bare_button("[revoke all]", function()
          Permissions.clear_overlay()
        end),
      },
    }
  end

  -- The running agent's confinement, shown as session STATE rather than as a
  -- toggle: the bwrap argv was built at spawn, so anything that reads as "I
  -- turned on blackbox" while a process spawned under `off` still holds an
  -- open session is a confinement claim that is not true.
  rows[#rows + 1] = blank()
  rows[#rows + 1] = header("Sandbox profile")
  local profile = Permissions.current_profile()
  rows[#rows + 1] = {
    comp = ui.row,
    props = { gap = 2 },
    children = {
      { comp = ui.label, props = { text = "  " .. profile } },
      bare_button("[restart with profile…]", function()
        local Transition = require("weave.profile_transition")
        vim.ui.select({ "off", "workspace", "readonly", "blackbox" }, { prompt = "Sandbox profile" }, function(choice)
          if not choice or choice == profile then
            return
          end
          Transition.request_profile(choice)
        end)
      end),
    },
  }

  rows[#rows + 1] = blank()
  local buttons = {
    bare_button("[edit]", function()
      open_editor(active)
    end),
    bare_button("[new]", function()
      open_editor({
        name = "my-preset",
        label = "My preset",
        rules = {
          { tool = "acp:*", decision = "ask" },
          { tool = "*", decision = "allow" },
        },
      })
    end),
  }
  if active.source == "runtime" then
    buttons[#buttons + 1] = bare_button("[delete]", function()
      Permissions.delete_preset(active.name)
    end)
  end
  rows[#rows + 1] = { comp = ui.row, props = { gap = 2 }, children = buttons }
  rows[#rows + 1] = dim("row activates · [edit] opens the active preset as Lua · q closes")

  return { comp = ui.col, props = {}, children = rows }
end

--- Open the configuration window (also reached from the sidebar's
--- Permissions header). Returns the fibrous app handle.
function M.open()
  local mount = require("fibrous.inline.mount")
  local size = #Permissions.presets() + #(Permissions.active().rules or {}) + 15
  local app = mount.floating(Window, {}, {
    width = 64,
    height = math.min(math.max(size, 10), math.max(vim.o.lines - 6, 8)),
    mode = "scroll",
    border = "rounded",
    backdrop = true,
  })
  require("weave.keys").map(app.bufnr, "close_float", function()
    app.unmount()
  end, { nowait = true, desc = "weave: close permission presets" })
  app.focus()
  return app
end

return M
