-- The panel shell (roadmap R5, reworked onto ui.container): ONE docked pane,
-- ONE fibrous mount. The transcript is a container (its own buffer in a
-- scrolling float), the prompt and sidebar render inline in the root canvas.
-- The shell owns the panel keymaps, follow-mode autoscroll, and teardown;
-- fibrous owns everything window-shaped (the container's interaction layer
-- drives tool-call toggles inside the transcript).

local SessionStore = require("clanker.session_store")
local Prefs = require("clanker.view.prefs")
local panel = require("clanker.view.panel")

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function pane_count()
  local n = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      n = n + 1
    end
  end
  return n
end

local function open_panel(opts)
  opts = opts or {}
  opts.store = opts.store or SessionStore:new()
  opts.prefs = opts.prefs or Prefs:new()
  opts.width = opts.width or 45
  return panel.open(opts), opts.store, opts.prefs
end

describe("view.panel shell", function()
  it("opens ONE docked pane; the transcript is a container, the sidebar inline", function()
    local before_panes = pane_count()
    local before_wins = #vim.api.nvim_list_wins()
    local handle, store = open_panel()

    store:append_entry({ kind = "user", text = "hello panel" })
    -- the transcript has its own buffer (the container's flush target)…
    assert.is_true(handle.transcript.bufnr ~= handle.bufnr)
    assert.truthy(buf_text(handle.transcript.bufnr):find("hello panel", 1, true))
    -- …shown in a float of its own (scrollable independently of the root)
    assert.is_true(vim.api.nvim_win_is_valid(handle.transcript.winid))
    assert.equal(handle.transcript.bufnr, vim.api.nvim_win_get_buf(handle.transcript.winid))
    -- the sidebar renders inline in the root canvas
    assert.truthy(buf_text(handle.bufnr):find("Session", 1, true))

    -- exactly ONE new native pane — everything else is floats over it
    assert.equal(before_panes + 1, pane_count())

    handle.close()
    assert.equal(before_wins, #vim.api.nvim_list_wins())
  end)

  it("closing the dock pane tears the whole panel down", function()
    local before = #vim.api.nvim_list_wins()
    local handle = open_panel()

    vim.api.nvim_win_close(handle.host_winid, true)
    vim.wait(500, function()
      return #vim.api.nvim_list_wins() == before
    end)
    assert.equal(before, #vim.api.nvim_list_wins())
    assert.is_false(handle.is_open())
  end)

  it("focus_prompt lands in the input; submit reaches the callback", function()
    local submitted = {}
    local handle = open_panel({
      on_submit = function(text)
        submitted[#submitted + 1] = text
      end,
    })

    handle.focus_prompt()
    press("ido the thing")
    press("<Esc><CR>")
    assert.same({ "do the thing" }, submitted)
    handle.close()
  end)

  it("<CR> on a tool-call header toggles it, through the container's interaction layer", function()
    local handle, store = open_panel()
    store:upsert_tool_call({ tool_call_id = "t1", kind = "execute", argument = "ls -la", status = "pending" })

    -- find the header row inside the transcript buffer
    local row
    for i, line in ipairs(vim.api.nvim_buf_get_lines(handle.transcript.bufnr, 0, -1, false)) do
      if line:find("ls -la", 1, true) then
        row = i
        break
      end
    end
    assert.is_not_nil(row)

    vim.api.nvim_set_current_win(handle.transcript.winid)
    vim.api.nvim_win_set_cursor(handle.transcript.winid, { row, 2 })
    press("<CR>")
    assert.is_true(store.state.expanded.t1)
    -- za is the fold-flavoured alias for the same activation
    press("za")
    assert.falsy(store.state.expanded.t1)
    handle.close()
  end)

  it("toggling a tool call keeps the cursor on its header (follow ignores visibility flips)", function()
    local handle, store = open_panel()
    store:append_entry({ kind = "agent", text = "some earlier prose" })
    store:upsert_tool_call({
      tool_call_id = "t1",
      kind = "execute",
      argument = "ls -la",
      status = "completed",
      output = "a.txt\nb.txt\nc.txt",
    })

    local row
    for i, line in ipairs(vim.api.nvim_buf_get_lines(handle.transcript.bufnr, 0, -1, false)) do
      if line:find("ls -la", 1, true) then
        row = i
        break
      end
    end
    assert.is_not_nil(row)
    vim.wait(100) -- drain the follow-scroll the appends above scheduled

    -- expanding appends the metadata BELOW the header; follow is on (the
    -- default) but a visibility flip is not new content — the cursor must
    -- stay on the header just toggled, not jump to the transcript's bottom
    vim.api.nvim_set_current_win(handle.transcript.winid)
    vim.api.nvim_win_set_cursor(handle.transcript.winid, { row, 2 })
    press("<CR>")
    vim.wait(100) -- drain any (wrongly) scheduled follow-scroll
    assert.is_true(store.state.expanded.t1)
    assert.equal(row, vim.api.nvim_win_get_cursor(handle.transcript.winid)[1])
    handle.close()
  end)

  it("panel keymaps: pref chords, zR/zM, <C-c>, ;;<n> permissions", function()
    local cancelled, perm_index = false, nil
    local handle, store, prefs = open_panel({
      on_cancel = function()
        cancelled = true
      end,
      on_permission = function(i)
        perm_index = i
      end,
    })
    store:upsert_tool_call({ tool_call_id = "t1", kind = "execute", argument = "ls", status = "pending" })

    vim.api.nvim_set_current_win(handle.transcript.winid)
    press(";;t")
    assert.is_false(prefs.state.show_thoughts)
    press(";;d")
    assert.is_false(prefs.state.show_diffs)
    press(";;c")
    assert.is_false(prefs.state.conceal_markdown)
    press(";;f")
    assert.is_false(prefs.state.follow)

    press("zR")
    assert.is_true(store.state.expanded.t1)
    press("zM")
    assert.falsy(store.state.expanded.t1)

    press("<C-c>")
    assert.is_true(cancelled)
    press(";;2")
    assert.equal(2, perm_index)

    -- ;;p cycles the permission mode (default wiring, straight to the store)
    press(";;p")
    assert.equal("auto", store.state.permission_mode)
    handle.close()
  end)

  it(";;m and ;;M reach the model/mode picker callbacks", function()
    local picked = {}
    local handle = open_panel({
      on_pick_model = function()
        picked[#picked + 1] = "model"
      end,
      on_pick_mode = function()
        picked[#picked + 1] = "mode"
      end,
    })
    vim.api.nvim_set_current_win(handle.transcript.winid)
    press(";;m")
    press(";;M")
    assert.same({ "model", "mode" }, picked)
    handle.close()
  end)

  it("follow keeps the transcript scrolled to the bottom while streaming", function()
    local handle, store, prefs = open_panel()
    for i = 1, 60 do
      store:append_entry({ kind = "agent", text = "line " .. i })
    end
    vim.wait(200, function()
      local last = vim.api.nvim_buf_line_count(handle.transcript.bufnr)
      return vim.api.nvim_win_get_cursor(handle.transcript.winid)[1] == last
    end)
    local last = vim.api.nvim_buf_line_count(handle.transcript.bufnr)
    assert.equal(last, vim.api.nvim_win_get_cursor(handle.transcript.winid)[1])

    -- follow off: the view stays put while content grows
    prefs:set("follow", false)
    vim.api.nvim_win_set_cursor(handle.transcript.winid, { 1, 0 })
    store:append_entry({ kind = "agent", text = "more" })
    vim.wait(100)
    assert.equal(1, vim.api.nvim_win_get_cursor(handle.transcript.winid)[1])
    handle.close()
  end)

  it("default permission answer pops the head and responds by index", function()
    local answered
    local handle, store = open_panel()
    store:enqueue_permission({
      request = {
        toolCall = { toolCallId = "t1" },
        options = {
          { optionId = "allow", name = "Allow" },
          { optionId = "reject", name = "Reject" },
        },
      },
      respond = function(option_id)
        answered = option_id
      end,
    })

    vim.api.nvim_set_current_win(handle.transcript.winid)
    press(";;2")
    assert.equal("reject", answered)
    assert.equal(0, store.state.permission_count)

    -- out-of-range index is a no-op on an empty queue
    press(";;3")
    handle.close()
  end)
end)
