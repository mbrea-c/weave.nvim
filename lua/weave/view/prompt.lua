-- The prompt: a text_input wired for chat, ported from agentic's
-- reactive/view/components/prompt.lua onto fibrous. NORMAL-mode <CR> submits and
-- insert-mode <CR> is a newline (compose multi-line); <C-s> submits and <C-x>
-- steers (cancel + send now) from BOTH modes. The input border colour tracks the
-- permission mode; a water status row above it shows turn activity.
--
-- Prompt queue + history (requests.md): queued prompts stack ABOVE the box,
-- between the waterline and the box. The box is a movable "edit cursor" over a
-- virtual column — from the bottom up: [box] · queued[last..first] · sent
-- history[newest..oldest]. <C-Up>/<C-Down> move it:
--   * onto a QUEUED slot: the box physically moves there (earlier queued above,
--     later below) and shows that prompt for in-place editing; <C-s>/<CR> saves
--     the edit and drops the box back to the bottom.
--   * onto a SENT prompt: only queued rows render, so the box sits at the bottom
--     showing a COPY of the sent text; submitting makes a NEW prompt.
-- Your in-progress draft is preserved as you navigate away and back. A `✕` on a
-- queued row removes it; <C-x> while editing a queued prompt sends it directly
-- (leaving the queue), skipping the rest.
--
-- The box tracks the queued prompt it edits by the entry's stable IDENTITY (id),
-- resolved to a position every render — so earlier prompts draining as turns end
-- never bump you onto a different prompt mid-edit. Its buffer / typed text /
-- focus survive moving index because it carries a stable `key` (keyed
-- reconciliation reuses its fiber, and the subwindow float keyed on that fiber).

local ui = require("fibrous.inline.components")
local Theme = require("weave.view.theme")
local Water = require("weave.view.water")
local use_store = require("weave.view.use_store")

local M = {}

local BOX_KEY = "weave-prompt-box"

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

--- One queued-prompt row: a ⏳ marker, the (dimmed) prompt text, and a `✕`
--- button that removes it from the queue (by its stable id).
--- @param _ table
--- @param props { store: weave.store.SessionStore, id: integer, text: string }
function M.QueuedRow(_, props)
  return {
    comp = ui.row,
    props = { gap = 1 },
    children = {
      { comp = ui.label, props = { text = "⏳", style = { text_hl = "@comment" } } },
      { comp = ui.paragraph, props = { grow = 1, text = props.text, style = { text_hl = "@comment" } } },
      {
        comp = ui.button,
        props = {
          theme = false,
          label = { { "✕", hl = "@comment" } },
          on_press = function()
            props.store:remove_queued(props.id)
          end,
        },
      },
    },
  }
end

--- Text of the box buffer as one string (newlines joined).
local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

--- Current index of the queued entry carrying `id`, or nil.
local function qindex_of(queued, id)
  for i, e in ipairs(queued) do
    if e.id == id then
      return i
    end
  end
  return nil
end

--- @param ctx table
--- @param props { store: weave.store.SessionStore, on_submit: fun(text: string), on_steer: fun(text: string), height?: integer, on_create?: fun(bufnr: integer) }
---   `height` sizes the input box (the block itself grows with queued rows so
---   the transcript above shrinks); `on_create` receives the input buffer after
---   the prompt's own wiring, so the shell can add panel keymaps to it.
function M.Prompt(ctx, props)
  local state = use_store(ctx, props.store)
  local store = props.store
  local queued = state.queued
  local history = state.history

  -- nav is an IDENTITY, not a position: { kind = "compose" } | { kind =
  -- "queued", id } | { kind = "sent", index }. Resolved to a concrete slot each
  -- render, so a drain that shifts the edited entry's index never moves the box
  -- off it (and a drained/removed entry falls gracefully back to compose).
  local nav = ctx.use_state({ kind = "compose" })
  local seed = ctx.use_state(0) -- bump to force a box re-seed without a position change
  local st = ctx.use_ref() -- live values the once-wired keymap handlers read at fire time

  local n = nav.get()
  local target
  if n.kind == "queued" then
    local qi = qindex_of(queued, n.id)
    target = qi and { kind = "queued", id = n.id, qindex = qi } or { kind = "compose" }
  elseif n.kind == "sent" then
    target = (n.index >= 1 and n.index <= #history) and { kind = "sent", index = n.index } or { kind = "compose" }
  else
    target = { kind = "compose" }
  end

  -- Refresh the mirror the keymap handlers close over (wired once in on_create,
  -- but they must act on the CURRENT store/queue/position at fire time).
  st.store = store
  st.props = props
  st.queued = queued
  st.history = history
  st.nav = nav
  st.seed = seed
  st.target = target
  st.draft = st.draft or ""

  -- What the box shows at `t`: the saved draft at compose, the queued text (by
  -- id) when editing one, a copy of the sent text when recalling history.
  local function text_for(t)
    if t.kind == "compose" then
      return st.draft
    elseif t.kind == "queued" then
      local qi = qindex_of(st.queued, t.id)
      return qi and st.queued[qi].text or ""
    end
    return st.history[t.index] or ""
  end

  -- Seed keyed on the target IDENTITY (id for queued) + a re-seed nonce, so a
  -- drain that only shifts the edited entry's index never re-seeds (your edit
  -- stays), while a real position change does. Plain typing changes neither.
  local sig = target.kind .. ":" .. tostring(target.id or target.index or "") .. ":" .. seed.get()
  ctx.use_effect(function()
    if st.bufnr and vim.api.nvim_buf_is_valid(st.bufnr) then
      vim.api.nvim_buf_set_lines(st.bufnr, 0, -1, false, vim.split(text_for(st.target), "\n", { plain = true }))
    end
  end, { sig })

  -- The recall column as IDENTITIES, nearest-first: last queued .. first queued,
  -- then newest sent .. oldest.
  local function recall_list()
    local r = {}
    for k = #st.queued, 1, -1 do
      r[#r + 1] = { kind = "queued", id = st.queued[k].id }
    end
    for j = #st.history, 1, -1 do
      r[#r + 1] = { kind = "sent", index = j }
    end
    return r
  end

  -- Position (1-based) of the current nav identity within `r`; 0 = compose.
  local function recall_pos(r)
    local t = st.target
    if t.kind == "compose" then
      return 0
    end
    for i, item in ipairs(r) do
      if item.kind == t.kind then
        if t.kind == "queued" and item.id == t.id then
          return i
        elseif t.kind == "sent" and item.index == t.index then
          return i
        end
      end
    end
    return 0
  end

  -- Save the box back to its slot before leaving it: the draft at compose, the
  -- queued entry (by id) in place when editing one; sent recalls are copies.
  local function commit_current()
    if not (st.bufnr and vim.api.nvim_buf_is_valid(st.bufnr)) then
      return
    end
    local txt = buf_text(st.bufnr)
    if st.target.kind == "compose" then
      st.draft = txt
    elseif st.target.kind == "queued" then
      st.store:update_queued(st.target.id, txt)
    end
  end

  if not st.wired then
    st.wired = true
    st.nav_move = function(dir)
      commit_current()
      local r = recall_list()
      local pos = math.max(0, math.min(recall_pos(r) + dir, #r))
      st.nav.set(pos == 0 and { kind = "compose" } or r[pos])
    end
    st.do_submit = function()
      if not st.bufnr then
        return
      end
      local txt = buf_text(st.bufnr)
      if st.target.kind == "queued" then
        st.store:update_queued(st.target.id, txt) -- save the edit in place…
        st.nav.set({ kind = "compose" }) -- …and drop the box back to the bottom
      else
        if txt ~= "" then
          st.props.on_submit(txt)
        end
        st.draft = ""
        st.nav.set({ kind = "compose" })
        st.seed.set(st.seed.get() + 1) -- clear the box even though we stay at compose
      end
    end
    st.do_steer = function()
      if not st.bufnr then
        return
      end
      local txt = buf_text(st.bufnr)
      if txt == "" then
        return
      end
      if st.target.kind == "queued" then
        st.store:remove_queued(st.target.id) -- sent directly, so it leaves the queue
      end
      st.props.on_steer(txt) -- interrupt the turn + send now, skipping the queue
      st.draft = ""
      st.nav.set({ kind = "compose" })
      st.seed.set(st.seed.get() + 1)
    end
    -- Live-sync the box into its slot so a drain (turn end) sends your CURRENT
    -- text and the draft persists — without a re-seed, since `sig` keys on
    -- identity, not text.
    st.on_change = function(txt)
      if st.target.kind == "queued" then
        st.store:update_queued(st.target.id, txt)
      elseif st.target.kind == "compose" then
        st.draft = txt
      end
    end
  end

  -- ── Assemble the block: waterline, then the queued stack with the box at its
  -- navigation position ──────────────────────────────────────────────────────
  local water_status = state.permission and "awaiting" or state.status
  local children = {
    {
      comp = Water.Water,
      props = {
        status = water_status,
        label = water_status ~= "idle" and (water_status .. "…") or nil,
      },
    },
  }

  local function queued_row(entry)
    return { comp = M.QueuedRow, memo = true, props = { store = store, id = entry.id, text = entry.text } }
  end

  local box = {
    comp = ui.text_input,
    key = BOX_KEY,
    props = {
      value = "",
      height = math.max((props.height or 5) - 1, 3),
      clear_on_submit = false, -- do_submit owns clearing / re-seeding
      on_change = function(txt)
        st.on_change(txt)
      end,
      on_submit = function()
        st.do_submit()
      end,
      style = {
        border = {
          "rounded",
          title = {
            text = "Prompt (" .. (Theme.PROMPT_TITLE_EXTRA[state.permission_mode] or "normal") .. ")",
            hl = Theme.PROMPT_BORDER_HL[state.permission_mode] or Theme.PROMPT_BORDER_HL.normal,
            align = "left",
          },
        },
        border_hl = Theme.PROMPT_BORDER_HL.normal,
      },
      on_create = function(bufnr)
        st.bufnr = bufnr
        wire_completion(props.store, bufnr)
        for _, mode in ipairs({ "n", "i" }) do
          vim.keymap.set(mode, "<C-s>", function()
            st.do_submit()
          end, { buffer = bufnr, desc = "weave: submit" })
          vim.keymap.set(mode, "<C-x>", function()
            st.do_steer()
          end, { buffer = bufnr, desc = "weave: steer (interrupt + send)" })
          vim.keymap.set(mode, "<C-Up>", function()
            st.nav_move(1)
          end, { buffer = bufnr, desc = "weave: recall previous prompt / edit queued" })
          vim.keymap.set(mode, "<C-Down>", function()
            st.nav_move(-1)
          end, { buffer = bufnr, desc = "weave: recall next prompt" })
        end
        if props.on_create then
          props.on_create(bufnr)
        end
      end,
    },
  }

  if target.kind == "queued" then
    -- editing a queued prompt: earlier queued above the box, later below
    for k = 1, target.qindex - 1 do
      children[#children + 1] = queued_row(queued[k])
    end
    children[#children + 1] = box
    for k = target.qindex + 1, #queued do
      children[#children + 1] = queued_row(queued[k])
    end
  else
    -- compose or recalling sent history: all queued rows above the box
    for k = 1, #queued do
      children[#children + 1] = queued_row(queued[k])
    end
    children[#children + 1] = box
  end

  return { comp = ui.col, props = {}, children = children }
end

return M
