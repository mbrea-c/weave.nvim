-- The prompt (roadmap R5): a text_input wired for chat — <CR> submits (and
-- clears), <C-x> steers (interrupts the turn and sends), empty text is a
-- no-op, the border colour tracks the permission mode, a status line shows
-- turn activity, and the input buffer carries slash-command completion fed
-- from the store's command list.

local mount = require("fibrous.inline.mount")

local SessionStore = require("clanker.session_store")
local prompt = require("clanker.view.prompt")
local Theme = require("clanker.view.theme")

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
    press("<Esc><CR>")
    assert.same({ "run tests" }, submitted)
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
    press("<Esc><C-x>")
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
    assert.falsy(text():find("⟳", 1, true))

    store:set_status("generating")
    assert.truthy(text():find("⟳ generating…", 1, true))

    store:set_status("idle")
    assert.falsy(text():find("⟳", 1, true))
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

  it("border colour tracks the permission mode", function()
    local store = SessionStore:new()
    local handle = mount_prompt(store)

    assert.is_true(#marks_with(handle.bufnr, Theme.PROMPT_BORDER_HL.normal) > 0)

    store:cycle_permission_mode() -- normal → auto
    assert.is_true(#marks_with(handle.bufnr, Theme.PROMPT_BORDER_HL.auto) > 0)
    assert.equal(0, #marks_with(handle.bufnr, Theme.PROMPT_BORDER_HL.normal))
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
    end, vim.b[bufnr].clanker_slash_commands)
    assert.same({ "new" }, words)
    assert.equal("v:lua.require'clanker.view.prompt'.slash_complete", vim.bo[bufnr].completefunc)

    -- … and kept in sync with command updates
    store:set_commands({ { name = "plan", description = "Make a plan" } })
    words = vim.tbl_map(function(item)
      return item.word
    end, vim.b[bufnr].clanker_slash_commands)
    assert.same({ "plan", "new" }, words)
    handle.unmount()
  end)
end)
