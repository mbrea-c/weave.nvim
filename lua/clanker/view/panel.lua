-- The panel shell (roadmap R5, reworked onto fibrous ui.container): ONE
-- docked pane, ONE fibrous mount, one component tree —
--
--   row
--   ├── col (grow)
--   │   ├── container (grow, scroll)  ← the transcript, in its OWN buffer
--   │   └── Prompt (status row + text_input subwin)
--   └── col (sidebar_width) — Sidebar, inline in the root canvas
--
-- The transcript container is fibrous's multi-buffer boundary: its entries
-- flush into a dedicated buffer shown in a natively-scrolling float, with its
-- own interaction layer (tool-call toggles, hover) wired by the subwin
-- manager — the shell never touches any of that. What the shell DOES own:
-- panel keymaps, follow-mode autoscroll, and teardown/origin restore.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local Transcript = require("clanker.view.transcript").Transcript
local Prompt = require("clanker.view.prompt").Prompt
local Sidebar = require("clanker.view.sidebar").Sidebar

local M = {}

local DEFAULT_WIDTH = 100
local DEFAULT_SIDEBAR_WIDTH = 30
local DEFAULT_PROMPT_HEIGHT = 5

--- The default ;;<n> answer: pop the HEAD permission and respond with its
--- n-th option (as numbered in the sidebar). Pop-then-respond — respond only
--- talks to the agent; queue management is ours (see the store's queue note).
--- @param store clanker.store.SessionStore
--- @return fun(index: integer)
local function default_permission_answer(store)
  return function(index)
    local head = store:get_permission()
    if not head then
      return
    end
    local opt = head.request.options and head.request.options[index]
    if not opt then
      return
    end
    store:pop_permission()
    head.respond(opt.optionId)
  end
end

--- The panel component: a pure function of its props (everything stateful
--- lives in the store/prefs; the on_create hooks are fibrous's creation-time
--- escape hatches handing the shell the transcript float and input buffer).
local function Panel(_, props)
  return {
    comp = ui.row,
    props = {},
    children = {
      {
        comp = ui.col,
        props = { grow = 1 },
        children = {
          {
            comp = ui.container,
            props = { grow = 1, on_create = props.on_transcript_create },
            children = {
              { comp = Transcript, props = { store = props.store, prefs = props.prefs } },
            },
          },
          {
            comp = Prompt,
            props = {
              store = props.store,
              height = props.prompt_height,
              on_submit = props.on_submit,
              on_steer = props.on_steer,
              on_create = props.on_prompt_create,
            },
          },
        },
      },
      {
        comp = ui.col,
        props = { width = props.sidebar_width },
        children = {
          { comp = Sidebar, props = { store = props.store, prefs = props.prefs } },
        },
      },
    },
  }
end

--- @class clanker.view.PanelHandle
--- @field bufnr integer       the root canvas buffer (sidebar/prompt keymaps live here)
--- @field winid integer       the mount's root float
--- @field host_winid integer  the docked native pane
--- @field transcript { bufnr: integer, winid: integer }  the transcript container's buffer and float
--- @field focus_prompt fun()
--- @field close fun()
--- @field is_open fun(): boolean

--- Open the panel.
--- @param opts { store: clanker.store.SessionStore, prefs: clanker.view.Prefs, on_submit?: fun(text: string), on_steer?: fun(text: string), on_cancel?: fun(), on_permission?: fun(index: integer), on_cycle_permission_mode?: fun(), on_pick_model?: fun(), on_pick_mode?: fun(), width?: integer, sidebar_width?: integer, prompt_height?: integer }
--- @return clanker.view.PanelHandle handle
function M.open(opts)
  local store = opts.store
  local prefs = opts.prefs
  local on_submit = opts.on_submit or function(_) end
  local on_steer = opts.on_steer or function(_) end
  local on_cancel = opts.on_cancel or function() end
  local on_permission = opts.on_permission or default_permission_answer(store)
  local on_cycle = opts.on_cycle_permission_mode
    or function()
      store:cycle_permission_mode()
    end
  local on_pick_model = opts.on_pick_model or function() end
  local on_pick_mode = opts.on_pick_mode or function() end

  local width = opts.width or DEFAULT_WIDTH
  -- The sidebar never eats more than half the panel.
  local sidebar_width = math.min(opts.sidebar_width or DEFAULT_SIDEBAR_WIDTH, math.floor(width / 2))
  local prompt_height = opts.prompt_height or DEFAULT_PROMPT_HEIGHT

  local origin_win = vim.api.nvim_get_current_win()

  -- Filled by the on_create hooks during the mount's first (synchronous)
  -- flush; the buffers persist for the panel's lifetime.
  local transcript = {}
  local input_bufnr

  local app = mount.split(Panel, {
    store = store,
    prefs = prefs,
    sidebar_width = sidebar_width,
    prompt_height = prompt_height,
    on_submit = on_submit,
    on_steer = on_steer,
    on_transcript_create = function(bufnr, winid)
      transcript.bufnr, transcript.winid = bufnr, winid
    end,
    on_prompt_create = function(bufnr)
      input_bufnr = bufnr
    end,
  }, {
    split = { direction = "vertical", position = "right", size = width },
    mode = "fixed",
  })

  local group = vim.api.nvim_create_augroup("ClankerPanel_" .. app.host_winid, { clear = true })
  local closing = false
  local open = true
  local unsubscribe_store, unsubscribe_prefs

  local function close()
    if closing then
      return
    end
    closing = true
    open = false
    unsubscribe_store()
    unsubscribe_prefs()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    -- One unmount tears the whole tree down, innermost first (fibrous walks
    -- any stranded focus out level by level).
    app.unmount()
    if vim.api.nvim_win_is_valid(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
  end

  -- ── Follow-mode autoscroll ──────────────────────────────────────────────
  -- The transcript container's buffer grows; its float stays where it was.
  -- Follow pins the float to the bottom while content streams in: one
  -- deferred scroll per burst (the store notifies synchronously per
  -- mutation, AFTER the re-render its use_store subscribers trigger).
  local scroll_pending = false
  local function follow_to_bottom()
    if scroll_pending then
      return
    end
    scroll_pending = true
    vim.schedule(function()
      scroll_pending = false
      if open and prefs.state.follow and transcript.winid and vim.api.nvim_win_is_valid(transcript.winid) then
        local last = vim.api.nvim_buf_line_count(transcript.bufnr)
        pcall(vim.api.nvim_win_set_cursor, transcript.winid, { last, 0 })
      end
    end)
  end
  -- Only CONTENT growth follows. Snapshots are immutable (mutations reassign
  -- fields with fresh tables), so reference checks tell content mutations
  -- (entries, tool-call updates) apart from visibility ones (expanded,
  -- permission queue) — toggling a fold must not yank the cursor off the
  -- header the user just pressed.
  local followed = store.state
  unsubscribe_store = store:subscribe(function(state)
    local content = state.entries ~= followed.entries or state.tool_calls ~= followed.tool_calls
    followed = state
    if content and prefs.state.follow then
      follow_to_bottom()
    end
  end)
  -- Flipping follow ON jumps to the bottom immediately.
  local was_following = prefs.state.follow
  unsubscribe_prefs = prefs:subscribe(function(state)
    if state.follow and not was_following then
      follow_to_bottom()
    end
    was_following = state.follow
  end)

  -- ── Panel keymaps ───────────────────────────────────────────────────────
  -- Applied to every panel buffer — the root canvas, the transcript
  -- container, the prompt input — so the chords work wherever the user is.
  local function apply_maps(bufnr)
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = bufnr, desc = "clanker: " .. desc })
    end
    map(";;t", function()
      prefs:toggle("show_thoughts")
    end, "toggle thinking")
    map(";;d", function()
      prefs:toggle("show_diffs")
    end, "toggle edit diffs")
    map(";;c", function()
      prefs:toggle("conceal_markdown")
    end, "toggle markdown conceal")
    map(";;f", function()
      prefs:toggle("follow")
    end, "toggle follow streaming")
    map(";;p", on_cycle, "cycle permission mode")
    map(";;m", on_pick_model, "pick model")
    map(";;M", on_pick_mode, "pick mode")
    map("zR", function()
      store:set_all_expanded(true)
    end, "expand all tool calls")
    map("zM", function()
      store:set_all_expanded(false)
    end, "collapse all tool calls")
    map("<C-c>", on_cancel, "cancel the running turn")
    for i = 1, 9 do
      map(";;" .. i, function()
        on_permission(i)
      end, "answer permission option " .. i)
    end
  end
  apply_maps(app.bufnr)
  if transcript.bufnr then
    apply_maps(transcript.bufnr)
    -- za on a tool-call header = the familiar fold key, re-bound to the same
    -- activation <CR> performs (tool-call folds are store state, not folds).
    vim.keymap.set(
      "n",
      "za",
      "<CR>",
      { buffer = transcript.bufnr, remap = true, desc = "clanker: toggle tool call" }
    )
  end
  if input_bufnr then
    apply_maps(input_bufnr)
  end

  -- Closing the dock pane (:q, <C-w>q) closes the panel. The mount already
  -- tears ITSELF down on the pane's close; this restores origin focus and
  -- flips is_open. Deferred: windows can't close mid-WinClosed.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(app.host_winid),
    callback = function()
      vim.schedule(close)
    end,
  })

  local function focus_prompt()
    if input_bufnr then
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == input_bufnr then
          vim.api.nvim_set_current_win(win)
          return
        end
      end
    end
    if vim.api.nvim_win_is_valid(app.winid) then
      vim.api.nvim_set_current_win(app.winid)
    end
  end

  focus_prompt()

  return {
    bufnr = app.bufnr,
    winid = app.winid,
    host_winid = app.host_winid,
    transcript = transcript,
    focus_prompt = focus_prompt,
    close = close,
    is_open = function()
      return open
    end,
  }
end

return M
