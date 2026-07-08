-- The prompt: a text_input wired for chat, ported from agentic's
-- reactive/view/components/prompt.lua onto fibrous. <CR> submits and clears
-- (fibrous's clear_on_submit — the buffer is the post-seed source of truth,
-- so only the subwin layer can clear it); <C-x> steers (cancel + send now);
-- both skip empty text. The input border colour tracks the permission mode
-- (an ambient reminder of what's being auto-allowed), a status row above the
-- input shows turn activity, and on_create wires the input buffer's
-- slash-command completion + the steer keymap.

local ui = require("fibrous.inline.components")
local Theme = require("weave.view.theme")
local Water = require("weave.view.water")
local use_store = require("weave.view.use_store")

local M = {}

--- `completefunc` for the prompt buffer (slash commands). Neovim's
--- completefunc must be a `v:lua` string, so it can't close over a store — it
--- reads the per-buffer command list stashed in
--- `vim.b[bufnr].weave_slash_commands` by the on_create wiring below.
--- @param findstart integer 1 = find completion start, 0 = return matches
--- @return integer|table start column (findstart=1) or completion items (=0)
function M.slash_complete(findstart, _base)
  if findstart == 1 then
    return 1
  end
  return vim.b[vim.api.nvim_get_current_buf()].weave_slash_commands or {}
end

--- Wire slash-command completion on the input buffer: native completefunc fed
--- from a buffer-local mirror of the store's command list (a v:lua
--- completefunc can't reach the store), auto-triggered on a `/`-leading first
--- line. The store subscription keeps the mirror fresh; it lives as long as
--- the buffer (checked on each fire).
--- @param store weave.store.SessionStore
--- @param bufnr integer the input buffer
local function wire_completion(store, bufnr)
  vim.b[bufnr].weave_slash_commands = store:get_commands()
  local unsubscribe
  unsubscribe = store:subscribe(function(state)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      unsubscribe()
      return
    end
    vim.b[bufnr].weave_slash_commands = state.commands
  end)

  vim.bo[bufnr].completeopt = "menu,menuone,noinsert,popup,fuzzy"
  vim.bo[bufnr].iskeyword = vim.bo[bufnr].iskeyword .. ",-"
  vim.bo[bufnr].completefunc = "v:lua.require'weave.view.prompt'.slash_complete"

  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = bufnr,
    callback = function()
      local commands = vim.b[bufnr].weave_slash_commands or {}
      if #commands == 0 then
        return
      end
      local cursor = vim.api.nvim_win_get_cursor(0)
      if cursor[1] ~= 1 or cursor[2] < 1 then
        return
      end
      local line = vim.api.nvim_get_current_line()
      if not line:match("^/") or line:match("%s") then
        return
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true), "n", false)
    end,
  })
end

--- @param ctx table
--- @param props { store: weave.store.SessionStore, on_submit: fun(text: string), on_steer: fun(text: string), height?: integer, on_create?: fun(bufnr: integer) }
---   `height` fixes the prompt block's total rows (inline in the panel
---   column); `on_create` receives the input buffer after the prompt's own
---   wiring, so the shell can add panel keymaps to it.
function M.Prompt(ctx, props)
  local state = use_store(ctx, props.store)

  -- Empty text is a no-op for both actions (nothing to send). clear_on_submit
  -- still fires on the empty <CR>, harmlessly clearing an empty buffer.
  local function skip_empty(action)
    return function(text)
      if text ~= "" then
        action(text)
      end
    end
  end

  -- The status row is ALWAYS rendered: the water indicator stays mounted (only
  -- its `status` prop changes), so a turn ending and starting again keeps its
  -- sim/colour state, AND — because fibrous reconciles positionally — the
  -- text_input below never moves or gets its subwin recreated (which would
  -- discard mid-turn input). Its width is constant, so the input never shifts as
  -- the water ripples. The status word is spliced into the centre of the water;
  -- when idle there's no label and the water settles to a flat blue line (still
  -- clickable — <CR>/click drops a ripple).
  local children = {
    {
      comp = Water.Water,
      props = {
        status = state.status,
        label = state.status ~= "idle" and (state.status .. "…") or nil,
      },
    },
  }

  children[#children + 1] = {
    comp = ui.text_input,
    props = {
      value = "",
      grow = 1,
      clear_on_submit = true,
      on_submit = skip_empty(props.on_submit),
      style = {
        border = {
          "rounded",
          title = {
            text = "Prompt (" .. (Theme.PROMPT_TITLE_EXTRA[state.permission_mode] or "normal") .. ")",
            hl = Theme.PROMPT_BORDER_HL[state.permission_mode] or Theme.PROMPT_BORDER_HL.normal,
            align = "left"
          }
        },
        border_hl = Theme.PROMPT_BORDER_HL.normal,
      },
      on_create = function(bufnr)
        wire_completion(props.store, bufnr)
        -- Steer: interrupt the in-flight turn and send THIS. Reads + clears
        -- the buffer itself — unlike <CR>, no subwin plumbing handles it.
        for _, mode in ipairs({ "n", "i" }) do
          vim.keymap.set(mode, "<C-x>", function()
            local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
            if text == "" then
              return
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
            props.on_steer(text)
          end, { buffer = bufnr, desc = "weave: steer (interrupt + send)" })
        end
        if props.on_create then
          props.on_create(bufnr)
        end
      end,
    },
  }

  return { comp = ui.col, props = { justify = "end", height = props.height }, children = children }
end

return M
