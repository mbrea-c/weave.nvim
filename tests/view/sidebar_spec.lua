-- The sidebar (roadmap R5): the panel's metadata column — session info, the
-- view-pref checkboxes, the rotating hint, the plan/tasks block, and the
-- permission block (mode + head request with numbered options). A pure
-- projection of SessionStore + Prefs, mounted fixed-mode in its own window.

local mount = require("fibrous.inline.mount")

local SessionStore = require("weave.session_store")
local Prefs = require("weave.view.prefs")
local sidebar = require("weave.view.sidebar")
local Theme = require("weave.view.theme")

local function trimmed(bufnr)
  local out = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    out[i] = (l:gsub("%s+$", ""))
  end
  return out
end

local function text_of(bufnr)
  return table.concat(trimmed(bufnr), "\n")
end

-- Find "needle" in the buffer; returns 1-based row and 0-based col.
local function locate(bufnr, needle)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local col = l:find(needle, 1, true)
    if col then
      return i, col - 1
    end
  end
  error("not found in buffer: " .. needle)
end

local function marks_with(bufnr, hl)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    if m[4].hl_group == hl then
      out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col }
    end
  end
  return out
end

local function press_on(handle, needle)
  local row, col = locate(handle.bufnr, needle)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
  vim.api.nvim_set_current_win(handle.winid)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
end

local SIDEBAR_WIDTH = 30

local function mount_sidebar(store, prefs)
  return mount.floating(
    sidebar.Sidebar,
    { store = store, prefs = prefs or Prefs:new(), sidebar_width = SIDEBAR_WIDTH },
    { width = 34, height = 30 }
  )
end

describe("view.sidebar", function()
  it("renders every section for a fresh session", function()
    local store = SessionStore:new()
    local handle = mount_sidebar(store)
    local text = text_of(handle.bufnr)

    assert.truthy(text:find("Session", 1, true))
    assert.truthy(text:find("(connecting…)", 1, true))
    assert.truthy(text:find("[x] Show thinking", 1, true))
    assert.truthy(text:find("[x] Show edit diffs", 1, true))
    assert.truthy(text:find("[x] Prettify markdown", 1, true))
    assert.truthy(text:find("[x] Follow streaming", 1, true))
    assert.truthy(text:find("Usage", 1, true))
    assert.truthy(text:find("(no usage yet)", 1, true))
    assert.truthy(text:find("Hint", 1, true))
    assert.truthy(text:find("Tasks", 1, true))
    assert.truthy(text:find("(no tasks)", 1, true))
    assert.truthy(text:find("Permissions", 1, true))
    assert.truthy(text:find("Mode: Normal (ask)  (;;p)", 1, true))
    handle.unmount()
  end)

  it("context_bar draws a block-octant fill with eighth-cell precision", function()
    local octant = require("weave.view.octant")
    -- concat a span list's texts into the rendered glyph row
    local function row(frac, w)
      local s = ""
      for _, sp in ipairs(sidebar.context_bar(frac, w, "Hl")) do
        s = s .. (type(sp) == "table" and sp[1] or sp)
      end
      return s
    end
    -- 8 sub-levels per cell (an octant's 2x4 canvas) → 0.25 of a 10-cell bar =
    -- 20 sub → 2 full + a half-lit ▌ (left column full, level 4)
    assert.equal("██▌" .. (" "):rep(7), row(0.25, 10))
    -- exactly full: no track, no partial
    assert.equal(("█"):rep(10), row(1.0, 10))
    -- empty: all track (bare spaces — the bg tint is the track)
    assert.equal((" "):rep(10), row(0.0, 10))
    -- a live-but-tiny context never reads as empty: at least one sub-cell lit
    assert.equal(octant.glyph(octant.col_fill(1)) .. (" "):rep(9), row(0.001, 10))
    -- the boundary cell is column-major: below half-full it is the LEFT column
    -- filled bottom-up (levels 1-4), past half the RIGHT column joins (levels
    -- 5-8) until the cell is a full █. 0.1375 of a 10-cell bar = 11 sub →
    -- 1 full + level-3 (left column, bottom 3 rows).
    assert.equal("█" .. octant.glyph(octant.col_fill(3)) .. (" "):rep(8), row(0.1375, 10))
    -- 0.1875 = 15 sub → 1 full + level-7 (left full ▌ + right bottom 3 rows)
    assert.equal("█" .. octant.glyph(octant.col_fill(4) + octant.col_fill(3) * 16) .. (" "):rep(8), row(0.1875, 10))
  end)

  it("projects usage live: a context bar + centered used/total (percent), and cost when charged", function()
    local store = SessionStore:new()
    local handle = mount_sidebar(store)

    store:set_usage({ used = 7837, size = 200000, cost = { amount = 0.42, currency = "USD" } })
    local text = text_of(handle.bufnr)
    -- the exact figure stays: thousands-separated, with the rounded percent
    assert.truthy(text:find("7,837 / 200,000 (4%)", 1, true)) -- 7837/200000 ≈ 3.9% → 4%
    assert.truthy(text:find("$0.42", 1, true))
    assert.falsy(text:find("(no usage yet)", 1, true))
    -- a two-line block: a fine-grained fill bar (█ lit, a bg-tinted track) over
    -- the figure, the figure CENTERED under it (not flush left like other rows)
    local bar_row = locate(handle.bufnr, "█") -- the lit portion of the bar
    local fig_row, fig_col = locate(handle.bufnr, "7,837 / 200,000")
    assert.is_true(fig_row == bar_row + 1, "the figure sits directly under the bar")
    assert.is_true(fig_col > 2, "the figure is centered (indented), not flush left")

    -- the fill tracks the fraction: near-full paints more blocks than near-empty
    local function block_count(t)
      local n = 0
      for _ in t:gmatch("█") do
        n = n + 1
      end
      return n
    end
    store:set_usage({ used = 190000, size = 200000 })
    local full_blocks = block_count(text_of(handle.bufnr))
    store:set_usage({ used = 2000, size = 200000 })
    local empty_blocks = block_count(text_of(handle.bufnr))
    assert.is_true(full_blocks > empty_blocks, "a fuller context paints more blocks")

    -- the fill is coloured by fullness: green with headroom, red near the cap
    store:set_usage({ used = 50000, size = 200000 })
    assert.is_true(#marks_with(handle.bufnr, Theme.USAGE_BAR_HL.low) >= 1, "green fill with headroom")
    store:set_usage({ used = 195000, size = 200000 })
    assert.is_true(#marks_with(handle.bufnr, Theme.USAGE_BAR_HL.high) >= 1, "red fill near the cap")

    -- every cell shares one background: a partially-lit octant's unlit sub-cells
    -- must read as the track, not a hole — so the fill groups carry the SAME bg
    -- as the track group (a span replaces the cell hl, so a node bg won't show)
    local function bg(hl)
      return vim.api.nvim_get_hl(0, { name = hl, link = false }).bg
    end
    assert.is_true(bg(Theme.USAGE_TRACK_HL) ~= nil, "the track has a visible background")
    assert.equal(bg(Theme.USAGE_TRACK_HL), bg(Theme.USAGE_BAR_HL.low))
    assert.equal(bg(Theme.USAGE_TRACK_HL), bg(Theme.USAGE_BAR_HL.high))

    -- only a window size gives a bar; a raw token count stays a plain line
    store:set_usage({ used = 1234 })
    local t = text_of(handle.bufnr)
    assert.truthy(t:find("Tokens: 1,234", 1, true))
    assert.falsy(t:find("█", 1, true))

    -- a zero cost (free/subscription model) shows no cost line, just context
    store:set_usage({ used = 100, size = 200000, cost = { amount = 0, currency = "USD" } })
    assert.falsy(text_of(handle.bufnr):find("Cost:", 1, true))
    handle.unmount()
  end)

  it("projects session meta and permission mode live", function()
    local store = SessionStore:new()
    local handle = mount_sidebar(store)

    store:set_meta({ provider = "Kiro ACP", agent = "kiro 1.0", model = "sonnet", mode = "dev" })
    local text = text_of(handle.bufnr)
    assert.truthy(text:find("Provider: Kiro ACP", 1, true))
    assert.truthy(text:find("Agent: kiro 1.0", 1, true))
    assert.truthy(text:find("Model: sonnet", 1, true))
    assert.truthy(text:find("Mode: dev", 1, true))
    assert.falsy(text:find("(connecting…)", 1, true))

    store:cycle_permission_mode()
    assert.truthy(text_of(handle.bufnr):find("Mode: Auto (allow all)  (;;p)", 1, true))
    handle.unmount()
  end)

  it("activating the Session section opens the details handler (requests.md)", function()
    local store = SessionStore:new()
    local opened = 0
    local handle = mount.floating(sidebar.Sidebar, {
      store = store,
      prefs = Prefs:new(),
      sidebar_width = SIDEBAR_WIDTH,
      on_details = function()
        opened = opened + 1
      end,
    }, { width = 34, height = 30 })

    store:set_meta({ provider = "Kiro ACP", agent = "kiro 1.0", model = "sonnet", mode = "dev" })
    -- <CR> anywhere on the meta block activates: first row…
    press_on(handle, "Provider: Kiro ACP")
    assert.equal(1, opened)
    -- …and the last row alike (one interactable block, not one lucky line)
    press_on(handle, "Mode: dev")
    assert.equal(2, opened)
    handle.unmount()
  end)

  it("plan tasks: status glyphs with coloured icons; done/failed text struck through", function()
    local store = SessionStore:new()
    store:set_plan({
      { content = "write specs", status = "completed" },
      { content = "implement", status = "in_progress" },
      { content = "ship it", status = "pending" },
      { content = "old idea", status = "failed" },
    }, "acp")
    local handle = mount_sidebar(store)

    -- glyphs: pending □ / in-progress ■ / done ✔ / failed ✖
    local done_row, done_col = locate(handle.bufnr, "✔ write specs")
    locate(handle.bufnr, "■ implement")
    locate(handle.bufnr, "□ ship it")
    local failed_row = locate(handle.bufnr, "✖ old idea")

    -- the icons carry their own status colour (pending stays plain)...
    local amber = marks_with(handle.bufnr, Theme.TASK_ICON_HL.in_progress)
    assert.equal(1, #amber)
    local green = marks_with(handle.bufnr, Theme.TASK_ICON_HL.completed)
    assert.equal(1, #green)
    assert.equal(done_row - 1, green[1].row)
    local red = marks_with(handle.bufnr, Theme.TASK_ICON_HL.failed)
    assert.equal(1, #red)

    -- ...and only the TEXT of done/failed tasks is dimmed + struck through:
    -- the strikethrough starts after the icon, which is never struck
    local struck = marks_with(handle.bufnr, Theme.TASK_DONE_HL)
    assert.equal(2, #struck)
    assert.same({ done_row - 1, failed_row - 1 }, { struck[1].row, struck[2].row })
    assert.is_true(struck[1].col > done_col)
    handle.unmount()
  end)

  -- The refined task-list spec (requests.md): at most 8 items on the sidebar,
  -- each clamped to 3 lines with an ellipsis; overflow hides oldest COMPLETED
  -- items first, then oldest of any state; anything hidden or truncated adds a
  -- "…see full list" button that opens the whole plan in a floating mount.

  it("visible_tasks hides oldest completed first, then oldest of any state", function()
    local plan = {}
    for i = 1, 12 do
      plan[i] = { content = "task " .. i, status = (i >= 3 and i <= 5) and "completed" or "pending" }
    end
    -- 12 items, cap 8 → hide 4: completed 3,4,5 first, then oldest other (1)
    local shown, hidden = sidebar.visible_tasks(plan, 8)
    assert.equal(4, hidden)
    local contents = vim.tbl_map(function(e)
      return e.content
    end, shown)
    assert.same({ "task 2", "task 6", "task 7", "task 8", "task 9", "task 10", "task 11", "task 12" }, contents)

    -- short plans pass through whole
    local all, none = sidebar.visible_tasks({ { content = "a" }, { content = "b" } }, 8)
    assert.equal(0, none)
    assert.equal(2, #all)
  end)

  it("clamp_lines wraps to width and clamps at max lines with an ellipsis", function()
    local lines, truncated = sidebar.clamp_lines("alpha bravo charlie delta echo foxtrot golf", 13, 3)
    assert.is_true(truncated)
    assert.equal(3, #lines)
    assert.same({ "alpha bravo", "charlie delta" }, { lines[1], lines[2] })
    assert.truthy(lines[3]:find("…$"))
    for _, l in ipairs(lines) do
      assert.is_true(vim.api.nvim_strwidth(l) <= 13, "line overflows: " .. l)
    end

    local short, t2 = sidebar.clamp_lines("just two words", 20, 3)
    assert.is_false(t2)
    assert.same({ "just two words" }, short)
  end)

  it("shows at most 8 tasks and a see-full-list button; the tail is hidden", function()
    local store = SessionStore:new()
    local plan = {}
    for i = 1, 12 do
      plan[i] = { content = "task " .. i .. " padding", status = i <= 3 and "completed" or "pending" }
    end
    store:set_plan(plan, "acp")
    local handle = mount_sidebar(store)

    -- hide 4 = completed 1..3 first, then the oldest pending (task 4)
    local text = text_of(handle.bufnr)
    for i = 1, 4 do
      assert.is_nil(text:find("task " .. i .. " ", 1, true), "task " .. i .. " should be hidden")
    end
    locate(handle.bufnr, "task 5")
    locate(handle.bufnr, "task 12")
    locate(handle.bufnr, "see full list")
    -- the sections below survive: permission block still on the sidebar
    locate(handle.bufnr, "Permissions")
    handle.unmount()
  end)

  it("clamps a rambling task to 3 lines and opens the FULL list from the button", function()
    local store = SessionStore:new()
    local long = "investigate the flaky bench harness on the ci runner and "
      .. "quantify the noise floor then decide whether the bound is safe OMEGA"
    store:set_plan({
      { content = long, status = "in_progress" },
      { content = "short one", status = "pending" },
    }, "acp")
    local handle = mount_sidebar(store)

    -- the sidebar row is clamped: the tail word never renders inline…
    local text = text_of(handle.bufnr)
    assert.is_nil(text:find("OMEGA", 1, true))
    assert.truthy(text:find("…", 1, true))
    -- …which alone (2 tasks < 8) warrants the see-full-list button
    locate(handle.bufnr, "see full list")

    -- activating it opens a floating mount carrying the UNTRUNCATED plan
    press_on(handle, "see full list")
    local modal
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative == "editor" and win ~= handle.winid then
        local content = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
        if content:find("OMEGA", 1, true) then
          modal = win
        end
      end
    end
    assert.is_not_nil(modal, "full task list floating mount with the untruncated text")
    local content = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(modal), 0, -1, false), "\n")
    assert.truthy(content:find("short one", 1, true))

    -- q closes it
    vim.api.nvim_set_current_win(modal)
    vim.api.nvim_feedkeys("q", "xt", false)
    assert.is_false(vim.api.nvim_win_is_valid(modal))
    handle.unmount()
  end)

  it("sections are self-contained: TasksSection mounts standalone and updates live", function()
    local store = SessionStore:new()
    local handle = mount.floating(sidebar.TasksSection, { store = store }, { width = 30, height = 6 })
    assert.truthy(text_of(handle.bufnr):find("Tasks", 1, true))
    assert.truthy(text_of(handle.bufnr):find("(no tasks)", 1, true))

    -- its own use_store subscription re-renders it without the Sidebar shell
    store:set_plan({ { content = "solo", status = "in_progress" } }, "acp")
    assert.truthy(text_of(handle.bufnr):find("■ solo", 1, true))
    assert.falsy(text_of(handle.bufnr):find("(no tasks)", 1, true))
    handle.unmount()
  end)

  it("shows the head permission request with numbered options", function()
    local store = SessionStore:new()
    store:enqueue_permission({
      request = {
        toolCall = { toolCallId = "t1", title = "run ls", kind = "execute" },
        options = {
          { optionId = "allow", name = "Allow", kind = "allow_once" },
          { optionId = "reject", name = "Reject", kind = "reject_once" },
        },
      },
      respond = function() end,
    })
    store:enqueue_permission({
      request = { toolCall = { toolCallId = "t2" }, options = {} },
      respond = function() end,
    })
    local handle = mount_sidebar(store)

    local text = text_of(handle.bufnr)
    assert.truthy(text:find("(1 of 2 pending)", 1, true))
    assert.truthy(text:find("run ls", 1, true))
    assert.truthy(text:find("[1] Allow", 1, true))
    assert.truthy(text:find("[2] Reject", 1, true))

    store:drain_permissions()
    assert.falsy(text_of(handle.bufnr):find("[1] Allow", 1, true))
    handle.unmount()
  end)

  it("checkbox <CR> flips the pref and the mark", function()
    local store = SessionStore:new()
    local prefs = Prefs:new()
    local handle = mount_sidebar(store, prefs)

    press_on(handle, "Show thinking")
    assert.is_false(prefs.state.show_thoughts)
    assert.truthy(text_of(handle.bufnr):find("[ ] Show thinking", 1, true))

    press_on(handle, "Show thinking")
    assert.is_true(prefs.state.show_thoughts)
    handle.unmount()
  end)

  it("rotates the hint live", function()
    local store = SessionStore:new()
    local handle = mount_sidebar(store)
    store:rotate_hint()
    -- the shown hint is whatever the store now holds; hints are random and a
    -- long one WRAPS at the sidebar width, so compare whitespace-collapsed
    -- (the wrap turns a space into a newline, never more)
    local prefix = store.state.hint:sub(1, 20)
    local flat = text_of(handle.bufnr):gsub("%s+", " ")
    assert.truthy(flat:find((prefix:gsub("%s+", " ")), 1, true))
    handle.unmount()
  end)
end)
