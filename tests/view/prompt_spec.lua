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
    if vim.w[win].fibrous_anchor == handle.winid then
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

  it("gives the input buffer the markdown filetype", function()
    local store = SessionStore:new()
    local handle = mount_prompt(store)
    local sub = subwin_of(handle)
    local bufnr = vim.api.nvim_win_get_buf(sub)

    assert.equal("markdown", vim.bo[bufnr].filetype)
    -- the ftplugin must not clobber the prompt's own wiring (it runs first)
    assert.equal("v:lua.require'weave.view.prompt'.slash_complete", vim.bo[bufnr].completefunc)
    assert.truthy(vim.bo[bufnr].iskeyword:find(",%-$"))
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

describe("view.prompt queue + history", function()
  local function pump()
    vim.wait(100, function()
      return false
    end, 5)
  end
  local function lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  local function mount_tall(store, callbacks)
    callbacks = callbacks or {}
    return mount.floating(prompt.Prompt, {
      store = store,
      on_submit = callbacks.on_submit or function() end,
      on_steer = callbacks.on_steer or function() end,
    }, { width = 44, height = 16 })
  end
  -- row/col (1-based row, 0-based col) of the first cell containing `needle`
  local function locate(bufnr, needle)
    for i, l in ipairs(lines(bufnr)) do
      local col = l:find(needle, 1, true)
      if col then
        return i, col - 1
      end
    end
    error("not found in buffer: " .. needle)
  end

  it("stacks queued prompts as rows above the box, each with a ✕", function()
    local store = SessionStore:new()
    store:enqueue_prompt("first queued")
    store:enqueue_prompt("second queued")
    local handle = mount_tall(store)
    pump()

    local text = table.concat(lines(handle.bufnr), "\n")
    assert.truthy(text:find("⏳", 1, true), "the queued marker")
    assert.truthy(text:find("✕", 1, true), "the remove button")
    local first_row = locate(handle.bufnr, "first queued")
    local second_row = locate(handle.bufnr, "second queued")
    -- both above the box (the input's border row is below them)
    assert.is_true(first_row < second_row, "queued prompts render in order")
    handle.unmount()
  end)

  it("renders queued prompts single-line, ellipsized to the row (requests.md)", function()
    local store = SessionStore:new()
    store:enqueue_prompt("first line of a long pasted block\nsecond line\nthird line")
    local handle = mount_tall(store)
    pump()

    local ls = lines(handle.bufnr)
    -- exactly ONE row carries the prompt (a pasted block must never stack
    -- rows into the layout) …
    local rows = {}
    for _, l in ipairs(ls) do
      if l:find("first line", 1, true) then
        rows[#rows + 1] = l
      end
    end
    assert.equal(1, #rows)
    -- … cut with a trailing ellipsis, the ✕ still on the row after it
    assert.truthy(rows[1]:find("…", 1, true))
    assert.truthy(rows[1]:find("✕", 1, true))
    for _, l in ipairs(ls) do
      assert.is_nil(l:find("third line", 1, true))
    end
    handle.unmount()
  end)

  it("the ✕ on a queued row removes just that prompt", function()
    local store = SessionStore:new()
    store:enqueue_prompt("keep me")
    store:enqueue_prompt("remove me")
    local handle = mount_tall(store)
    pump()

    -- activate the FIRST ✕ (the "keep me" row) via the root interaction layer
    local row, col = locate(handle.bufnr, "✕")
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { row, col })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    press("<CR>")
    pump()
    assert.same({ "remove me" }, store:queued_texts())
    handle.unmount()
  end)

  it("<C-Up> moves the box onto the last queued prompt; <C-s> saves the edit in place", function()
    local store = SessionStore:new()
    store:enqueue_prompt("alpha")
    store:enqueue_prompt("bravo")
    local handle = mount_tall(store)
    local sub = subwin_of(handle)
    vim.api.nvim_set_current_win(sub)
    pump()

    -- navigate up onto the LAST queued prompt: the box now shows its text
    press("<C-Up>")
    pump()
    local boxbuf = vim.api.nvim_win_get_buf(sub)
    assert.same({ "bravo" }, lines(boxbuf))

    -- edit it and save in place: the queue keeps its order, entry updated
    vim.api.nvim_buf_set_lines(boxbuf, 0, -1, false, { "bravo EDITED" })
    press("<C-s>")
    pump()
    assert.same({ "alpha", "bravo EDITED" }, store:queued_texts())
    handle.unmount()
  end)

  it("keeps the box on the SAME queued prompt (by identity) when an earlier one drains", function()
    local store = SessionStore:new()
    store:enqueue_prompt("alpha")
    store:enqueue_prompt("bravo")
    store:enqueue_prompt("charlie")
    local handle = mount_tall(store)
    local sub = subwin_of(handle)
    vim.api.nvim_set_current_win(sub)
    pump()

    -- navigate up twice to edit the MIDDLE queued prompt ("bravo")
    press("<C-Up>") -- charlie (last)
    press("<C-Up>") -- bravo
    pump()
    local boxbuf = vim.api.nvim_win_get_buf(sub)
    assert.same({ "bravo" }, lines(boxbuf))

    -- a turn ends → the FRONT prompt ("alpha") drains. "bravo" shifts index but
    -- the box tracks it by id, so it stays put (no jump onto "charlie").
    store:dequeue_prompt()
    pump()
    assert.same({ "bravo" }, lines(vim.api.nvim_win_get_buf(sub)))
    handle.unmount()
  end)

  it("marks the queued prompt under the box as being edited, and unmarks on leave", function()
    local store = SessionStore:new()
    store:enqueue_prompt("alpha")
    store:enqueue_prompt("bravo")
    local handle = mount_tall(store)
    local sub = subwin_of(handle)
    vim.api.nvim_set_current_win(sub)
    pump()
    assert.is_nil(store.state.editing_queued)

    -- onto "bravo" (last queued): the store knows it is under the user's cursor
    press("<C-Up>")
    pump()
    assert.equal(store.state.queued[2].id, store.state.editing_queued)

    -- onto "alpha"
    press("<C-Up>")
    pump()
    assert.equal(store.state.queued[1].id, store.state.editing_queued)

    -- back down to compose: released
    press("<C-Down>")
    press("<C-Down>")
    pump()
    assert.is_nil(store.state.editing_queued)
    handle.unmount()
  end)

  it("<C-Up>/<C-Down> walk the WHOLE column: queue (nearest first) then sent history", function()
    local store = SessionStore:new()
    store:push_history("hist A") -- older
    store:push_history("hist B") -- newer
    store:enqueue_prompt("q1")
    store:enqueue_prompt("q2")
    local handle = mount_tall(store)
    local sub = subwin_of(handle)
    vim.api.nvim_set_current_win(sub)
    pump()
    local function box()
      return table.concat(lines(vim.api.nvim_win_get_buf(sub)), "\n")
    end

    -- up through the queue nearest-first, then into sent history newest-first
    local up = { "q2", "q1", "hist B", "hist A" }
    for i, want in ipairs(up) do
      press("<C-Up>")
      pump()
      assert.equal(want, box(), "C-Up step " .. i)
    end
    -- at the top, another <C-Up> stays put
    press("<C-Up>")
    pump()
    assert.equal("hist A", box())

    -- and back down to an empty compose box
    local down = { "hist B", "q1", "q2", "" }
    for i, want in ipairs(down) do
      press("<C-Down>")
      pump()
      assert.equal(want, box(), "C-Down step " .. i)
    end
    handle.unmount()
  end)

  it("navigating past the queue recalls a sent prompt as a copy in the box", function()
    local store = SessionStore:new()
    store:push_history("an old prompt")
    local handle = mount_tall(store)
    local sub = subwin_of(handle)
    vim.api.nvim_set_current_win(sub)
    pump()

    -- no queue, so the first <C-Up> lands on the newest sent prompt
    press("<C-Up>")
    pump()
    local boxbuf = vim.api.nvim_win_get_buf(sub)
    assert.same({ "an old prompt" }, lines(boxbuf))
    -- the history entry is untouched (recall is a copy)
    assert.same({ "an old prompt" }, store.state.history)
    handle.unmount()
  end)

  it("<C-x> while editing a queued prompt sends it directly, leaving the queue", function()
    local store = SessionStore:new()
    store:enqueue_prompt("alpha")
    store:enqueue_prompt("bravo")
    local steered = {}
    local handle = mount_tall(store, {
      on_steer = function(t)
        steered[#steered + 1] = t
      end,
    })
    local sub = subwin_of(handle)
    vim.api.nvim_set_current_win(sub)
    pump()

    press("<C-Up>") -- edit "bravo"
    pump()
    press("<C-x>") -- interrupt + send it directly
    pump()
    assert.same({ "bravo" }, steered)
    assert.same({ "alpha" }, store:queued_texts()) -- bravo left the queue
    handle.unmount()
  end)
end)
