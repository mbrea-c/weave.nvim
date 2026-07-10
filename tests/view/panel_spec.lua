-- The panel shell (roadmap R5, reworked onto ui.container): ONE docked pane,
-- ONE fibrous mount. The transcript is a container (its own buffer in a
-- scrolling float), the prompt and sidebar render inline in the root canvas.
-- The shell owns the panel keymaps, follow-mode autoscroll, and teardown;
-- fibrous owns everything window-shaped (the container's interaction layer
-- drives tool-call toggles inside the transcript).

local SessionStore = require("weave.session_store")
local Prefs = require("weave.view.prefs")
local panel = require("weave.view.panel")

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

  it("resolves panel geometry from Config.view, per-open opts still winning", function()
    local Config = require("weave.config")
    -- the geometry defaults live in config now (view-configurable)
    assert.equal(30, Config.view.sidebar_width)

    -- no per-open sidebar_width: the panel takes it from Config.view (width wide
    -- enough that the half-panel clamp doesn't bite)
    local h1 = panel.open({ store = SessionStore:new(), prefs = Prefs:new(), width = 120 })
    assert.equal(30, h1.sidebar_width)
    h1.close()

    -- a config override is picked up by a fresh open with no per-open opt
    local saved = Config.view.sidebar_width
    Config.view.sidebar_width = 42
    local h2 = panel.open({ store = SessionStore:new(), prefs = Prefs:new(), width = 120 })
    assert.equal(42, h2.sidebar_width)
    h2.close()
    Config.view.sidebar_width = saved

    -- an explicit per-open opt still overrides the configured default
    local h3 = panel.open({ store = SessionStore:new(), prefs = Prefs:new(), width = 120, sidebar_width = 18 })
    assert.equal(18, h3.sidebar_width)
    h3.close()
  end)

  it("close from OUTSIDE the panel leaves focus where it is", function()
    local handle = open_panel()
    -- a window that has nothing to do with the panel takes focus (like the
    -- session modal's float when its ✕ closes a session); enew — a vsplit
    -- of the focused prompt would still SHOW a panel buffer
    vim.cmd("topleft vsplit | enew")
    local outside = vim.api.nvim_get_current_win()

    handle.close()
    assert.equal(outside, vim.api.nvim_get_current_win())
    vim.api.nvim_win_close(outside, true)
  end)

  it("opened during startup, the prompt is genuinely focused after VimEnter", function()
    -- The bug: nvim's startup re-enters the first window AFTER `-u init`
    -- sourcing with autocmds suppressed — a panel opened from init had
    -- focused the prompt (WinEnter → _focus style ON), then focus was
    -- yanked back with no WinLeave: blue border, cursor elsewhere. The
    -- panel must defer its focus grab past startup. Only a real child
    -- nvim exercises that startup window shuffle.
    local weave_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
    -- fibrous is on package.path (not the rtp) in the test runner — locate its
    -- root through the loaded module. :p absolutizes: the child nvim's cwd is
    -- not guaranteed to match ours.
    local mount_src = debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2)
    local fibrous_root = vim.fn.fnamemodify(mount_src, ":p:h:h:h:h")
    local result_file = vim.fn.tempname()
    local init_file = vim.fn.tempname() .. ".lua"
    local init = ([==[
      vim.opt.rtp:prepend(%q)
      vim.opt.rtp:prepend(%q)
      local handle = require("weave.view.panel").open({
        store = require("weave.session_store"):new(),
        prefs = require("weave.view.prefs"):new(),
        width = 45,
      })
      vim.api.nvim_create_autocmd("VimEnter", {
        callback = function()
          vim.schedule(function()
            local cur_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            local marks = 0
            for _, m in ipairs(vim.api.nvim_buf_get_extmarks(handle.bufnr, -1, 0, -1, { details = true })) do
              if m[4].hl_group == "FibrousBorderFocus" then marks = marks + 1 end
            end
            local fd = assert(io.open(%q, "w"))
            fd:write(vim.json.encode({
              cur_is_prompt = vim.bo[cur_buf].completefunc
                == "v:lua.require'weave.view.prompt'.slash_complete",
              focus_marks = marks,
            }))
            fd:close()
            vim.cmd("qa!")
          end)
        end,
      })
      vim.defer_fn(function() vim.cmd("qa!") end, 5000) -- never hang the suite
    ]==]):format(fibrous_root, weave_root, result_file)
    local fd = assert(io.open(init_file, "w"))
    fd:write(init)
    fd:close()

    local out = vim.system({ vim.v.progpath, "--headless", "--clean", "-u", init_file }, {}):wait(10000)

    local rf = assert(
      io.open(result_file, "r"),
      ("child nvim wrote no result (code=%s stderr=%s)"):format(tostring(out.code), tostring(out.stderr))
    )
    local result = vim.json.decode(rf:read("*a"))
    rf:close()
    os.remove(result_file)
    os.remove(init_file)

    -- the prompt holds the cursor, and the focus accent it shows is honest
    assert.is_true(result.cur_is_prompt)
    assert.is_true(result.focus_marks > 0)
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
    press("<CR>") -- normal-mode <CR> submits (headless lands in normal after typing)
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

  it(";;s reaches the session-modal callback", function()
    local opened = 0
    local handle = open_panel({
      on_sessions = function()
        opened = opened + 1
      end,
    })
    vim.api.nvim_set_current_win(handle.transcript.winid)
    press(";;s")
    assert.equal(1, opened)
    handle.close()
  end)

  it(";;r reaches the restore-picker callback", function()
    local restores = 0
    local handle = open_panel({
      on_restore_picker = function()
        restores = restores + 1
      end,
    })
    vim.api.nvim_set_current_win(handle.transcript.winid)
    press(";;r")
    assert.equal(1, restores)
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

describe("view.panel tail window", function()
  local K = SessionStore.WINDOW

  it("following slides the window so only the last WINDOW entries render", function()
    local handle, store, prefs = open_panel()
    assert.is_true(prefs.state.follow) -- default
    for i = 1, K + 20 do
      store:append_entry({ kind = "agent", text = "line " .. i })
    end
    -- the panel advances window_start synchronously as content grows while following
    assert.equal(K + 20 - K + 1, store.state.window_start)
    local text = buf_text(handle.transcript.bufnr)
    assert.truthy(text:find("▸ 20 older messages", 1, true), "collapse not reflected")
    assert.falsy(text:find("line 1\n", 1, true), "oldest entry still rendered")
    assert.truthy(text:find("line " .. (K + 20), 1, true), "newest entry missing")
    handle.close()
  end)

  it("scrolled up (not following) the window is frozen — no entries collapse", function()
    local handle, store, prefs = open_panel()
    prefs:set("follow", false)
    for i = 1, K + 20 do
      store:append_entry({ kind = "agent", text = "line " .. i })
    end
    assert.equal(1, store.state.window_start, "window must not slide while the reader is scrolled up")
    assert.truthy(buf_text(handle.transcript.bufnr):find("line 1", 1, true), "history was collapsed under the reader")
    handle.close()
  end)
end)
