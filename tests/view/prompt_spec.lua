-- The prompt (roadmap R5): a text_input wired for chat — <CR> submits (and
-- clears), <C-x> steers (interrupts the turn and sends), empty text is a
-- no-op, the border colour tracks the permission mode, a status line shows
-- turn activity, and the input buffer carries slash-command completion fed
-- from the store's command list.

local mount = require("fibrous.inline.mount")

local SessionStore = require("weave.session_store")
local prompt = require("weave.view.prompt")
local Theme = require("weave.view.theme")

local function subwin_of(handle)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "win" and cfg.win == handle.winid then
      return win
    end
  end
  error("no input subwin found")
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

local function marks_with(bufnr, hl)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    if m[4].hl_group == hl then
      out[#out + 1] = m
    end
  end
  return out
end

local function mount_prompt(store, callbacks)
  callbacks = callbacks or {}
  return mount.floating(prompt.Prompt, {
    store = store,
    on_submit = callbacks.on_submit or function() end,
    on_steer = callbacks.on_steer or function() end,
  }, { width = 40, height = 5 })
end

describe("view.prompt", function()
  it("<CR> submits the typed text and clears the input", function()
    local store = SessionStore:new()
    local submitted = {}
    local handle = mount_prompt(store, {
      on_submit = function(text)
        submitted[#submitted + 1] = text
      end,
    })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    press("irun tests")
    press("<CR>") -- normal-mode <CR> submits (headless lands in normal after typing)
    assert.same({ "run tests" }, submitted)
    assert.same({ "" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sub), 0, -1, false))
    handle.unmount()
  end)

  it("insert <CR> is a newline; <C-s> submits (multi-line) from insert mode", function()
    local store = SessionStore:new()
    local submitted = {}
    local handle = mount_prompt(store, {
      on_submit = function(text)
        submitted[#submitted + 1] = text
      end,
    })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    -- one batch keeps us in insert: <CR> composes a second line (NOT a submit),
    -- then <C-s> submits the whole multi-line buffer without leaving insert
    press("iline one<CR>line two<C-s>")
    assert.same({ "line one\nline two" }, submitted)
    assert.same({ "" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sub), 0, -1, false))
    handle.unmount()
  end)

  it("empty submit is a no-op", function()
    local store = SessionStore:new()
    local submitted = {}
    local handle = mount_prompt(store, {
      on_submit = function(text)
        submitted[#submitted + 1] = text
      end,
    })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    press("<CR>")
    assert.same({}, submitted)
    handle.unmount()
  end)

  it("<C-x> steers with the typed text and clears the input", function()
    local store = SessionStore:new()
    local steered = {}
    local handle = mount_prompt(store, {
      on_steer = function(text)
        steered[#steered + 1] = text
      end,
    })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    press("ido this instead")
    press("<C-x>") -- <C-x> steers from insert too (mapped for {n,i})
    assert.same({ "do this instead" }, steered)
    assert.same({ "" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sub), 0, -1, false))

    -- empty steer is a no-op
    press("<C-x>")
    assert.same({ "do this instead" }, steered)
    handle.unmount()
  end)

  it("shows turn activity in the status line", function()
    local store = SessionStore:new()
    local handle = mount_prompt(store)

    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
    end
    -- the status line is the first row (above the input border)
    local function status_line()
      return vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1] or ""
    end
    assert.falsy(text():find("generating", 1, true))

    store:set_status("generating")
    -- the status word is spliced into the CENTRE of the water indicator (which
    -- replaced the old bouncing wave as the activity indicator)
    assert.truthy(text():find("generating…", 1, true))
    assert.is_true(vim.fn.strwidth(vim.trim(status_line())) >= 12)

    store:set_status("idle")
    -- the label goes when idle, but the water line stays (a flat, still-clickable
    -- rest line — it no longer collapses to blank)
    assert.falsy(text():find("generating", 1, true))
    assert.is_true(vim.trim(status_line()) ~= "")
    handle.unmount()
  end)

  it("shows a distinct 'awaiting' status while a permission is pending", function()
    local store = SessionStore:new()
    local handle = mount_prompt(store)
    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
    end

    -- mid-turn the agent hits a tool needing approval: the water must say the
    -- agent is blocked on YOU — distinct from "generating" AND from idle (your
    -- mic), so a pending approval never reads as a finished turn.
    store:set_status("generating")
    store:enqueue_permission({
      request = { toolCall = { toolCallId = "t1" }, options = {} },
      respond = function() end,
    })
    assert.truthy(text():find("awaiting…", 1, true), "no 'awaiting' cue while a permission is pending")
    assert.falsy(text():find("generating…", 1, true), "should not read as plain generating while blocked on you")

    -- answering it falls back to the underlying activity (the agent proceeds),
    -- NOT to idle — idle is reserved for a genuinely ended turn
    store:pop_permission()
    assert.falsy(text():find("awaiting", 1, true))
    assert.truthy(text():find("generating…", 1, true))
    handle.unmount()
  end)

  it("typed text survives status flips (the input is never repositioned)", function()
    local store = SessionStore:new()
    local handle = mount_prompt(store)
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    press("idraft in progress<Esc>")
    -- a turn ends while the user is typing: the status row comes and goes,
    -- but the input subwin (and its buffer) must stay put
    store:set_status("generating")
    store:set_status("idle")
    assert.same(
      { "draft in progress" },
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(subwin_of(handle)), 0, -1, false)
    )
    handle.unmount()
  end)

  it("the prompt title colour + label track the permission mode", function()
    local store = SessionStore:new()
    local handle = mount_prompt(store)
    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
    end

    -- The permission mode tints the TITLE and names the mode in it; the border
    -- edge itself stays a constant 'normal' hl. So in normal mode the title
    -- reads "(normal)" and there's no auto tint anywhere.
    assert.truthy(text():find("(normal)", 1, true))
    assert.equal(0, #marks_with(handle.bufnr, Theme.PROMPT_BORDER_HL.auto))

    store:cycle_permission_mode() -- normal → auto
    -- the title gains the mode's colour + label; the border_hl is unchanged, so
    -- an auto mark can ONLY come from the title
    assert.truthy(text():find("(auto", 1, true))
    assert.is_true(#marks_with(handle.bufnr, Theme.PROMPT_BORDER_HL.auto) > 0)
    handle.unmount()
  end)

  it("wires slash-command completion on the input buffer", function()
    local store = SessionStore:new()
    local handle = mount_prompt(store)
    local sub = subwin_of(handle)
    local bufnr = vim.api.nvim_win_get_buf(sub)

    -- seeded at mount with the store's list (always includes /new) …
    local words = vim.tbl_map(function(item)
      return item.word
    end, vim.b[bufnr].weave_slash_commands)
    assert.same({ "new" }, words)
    assert.equal("v:lua.require'weave.view.prompt'.slash_complete", vim.bo[bufnr].completefunc)

    -- … and kept in sync with command updates
    store:set_commands({ { name = "plan", description = "Make a plan" } })
    words = vim.tbl_map(function(item)
      return item.word
    end, vim.b[bufnr].weave_slash_commands)
    assert.same({ "plan", "new" }, words)
    handle.unmount()
  end)
end)
