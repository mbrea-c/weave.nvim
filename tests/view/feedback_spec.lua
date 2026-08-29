-- Sidebar section + comment editor. Both are plain components, so the layout
-- and the button wiring are exercised here without mounting a window.

local ui = require("fibrous.inline.components")
local View = require("weave.view.feedback")
local Store = require("weave.feedback_store")

--- The fibrous ReactiveCtx surface these components actually use. use_state
--- returns a { get, set } handle (see fibrous use_store), use_ref a stable
--- { current } container.
local function fake_ctx()
  local refs, states = {}, {}
  local n = 0
  return {
    use_state = function(initial)
      n = n + 1
      local slot = n
      if states[slot] == nil then
        states[slot] = initial
      end
      return {
        get = function()
          return states[slot]
        end,
        set = function(v)
          states[slot] = v
        end,
      }
    end,
    use_ref = function()
      n = n + 1
      refs[n] = refs[n] or {}
      return refs[n]
    end,
    use_effect = function() end,
  }
end

-- Buffer names must be unique within the nvim instance, and before_each runs
-- this per test, so the caller's name gets a serial suffix.
local seq = 0
local function scratch(lines, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if name then
    seq = seq + 1
    -- parenthesised: gsub's second return would otherwise land in format
    vim.api.nvim_buf_set_name(buf, ("%s.%d.lua"):format((name:gsub("%.lua$", "")), seq))
  end
  return buf
end

--- Every node in a tree, depth first.
local function flatten(node, out)
  out = out or {}
  out[#out + 1] = node
  for _, child in ipairs(node.children or {}) do
    flatten(child, out)
  end
  return out
end

local function find_button(tree, label)
  for _, node in ipairs(flatten(tree)) do
    if node.comp == ui.button and (node.props or {}).label == label then
      return node
    end
  end
  return nil
end

local function labels(tree)
  local out = {}
  for _, node in ipairs(flatten(tree)) do
    local p = node.props or {}
    out[#out + 1] = p.label or p.text
  end
  return table.concat(out, "\n")
end

describe("pending flush sidebar section", function()
  local Log = require("weave.revision_log")
  local Permissions = require("weave.permissions")
  local Settings = require("weave.settings")
  local Sync = require("weave.edit_sync")

  local root, session

  --- One recorded user edit under the project root — what puts a "files
  --- edited" row on the section.
  local function edit_a_file(name, before, after)
    local path = root .. "/" .. name
    vim.fn.writefile(before, path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    Log.track(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, after)
    Log.note_change(bufnr)
    Log.close_burst()
  end

  before_each(function()
    Store._reset()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    Permissions._reset()
    Permissions.set_project_root(root)
    Sync._reset()
    Settings._reset()
    Log._reset()
    session = { name = "pending-flush-double" }
    Settings.global():set("track_edits", true)
    Sync.watch(session)
  end)

  after_each(function()
    Sync._reset()
    Settings._reset()
    Log._reset()
    Permissions._reset()
    vim.fn.delete(root, "rf")
  end)

  local function section(props)
    return View.Section(fake_ctx(), vim.tbl_extend("force", { width = 40, session = session }, props or {}))
  end

  it("shows the header and a nothing-pending note", function()
    local tree = section()
    assert.truthy(labels(tree):find("Pending flush", 1, true))
    assert.truthy(labels(tree):find("(nothing pending)", 1, true))
  end)

  it("offers no flush or discard with nothing pending", function()
    assert.is_nil(find_button(section(), "flush"))
    assert.is_nil(find_button(section(), "discard"))
  end)

  -- The sidebar is narrow and a draft can hold a dozen comments from several
  -- sources; a count plus a way in beats a list that pushes Permissions off
  -- the bottom of the screen.
  it("summarises comments as a count rather than listing them", function()
    local buf = scratch({ "alpha", "beta" }, "/tmp/weave-fb-section.lua")
    Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "rename this" })
    Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "and this" })
    local text = labels(section())
    assert.truthy(text:find("2 comment(s)", 1, true))
    assert.is_nil(text:find("rename this", 1, true))
  end)

  it("makes the comments row the way into the full list", function()
    local buf = scratch({ "alpha" }, "/tmp/weave-fb-header.lua")
    Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "x" })
    local row = find_button(section(), "1 comment(s)")
    assert.is_not_nil(row)

    local opened = false
    local real = View.open_list
    View.open_list = function()
      opened = true
    end
    row.props.on_press()
    View.open_list = real
    assert.is_true(opened)
  end)

  -- The count alone would hide this, and "which line was that again" is worth
  -- knowing BEFORE sending, not after.
  it("warns when a comment's code is gone", function()
    local buf = scratch({ "alpha", "beta" }, "/tmp/weave-fb-orphan.lua")
    Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "x" })
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    local text = labels(section())
    assert.truthy(text:find("⚠", 1, true))
    assert.truthy(text:find("1 stale", 1, true))
  end)

  it("shows the unsent-edits window as a file count", function()
    edit_a_file("a.lua", { "one" }, { "two" })
    edit_a_file("b.lua", { "x" }, { "y" })
    local text = labels(section())
    assert.truthy(text:find("2 files edited", 1, true))
  end)

  it("phrases the window's shape: new and deleted files called out", function()
    assert.equal("1 file edited", View.edits_label({ files = 1, created = 0, deleted = 0 }))
    assert.equal("3 files edited (1 new)", View.edits_label({ files = 3, created = 1, deleted = 0 }))
    assert.equal("2 files edited (1 new, 1 deleted)", View.edits_label({ files = 2, created = 1, deleted = 1 }))
  end)

  it("skips the edits row when nothing is tracked for this session", function()
    Settings.global():set("track_edits", false)
    local text = labels(section())
    assert.is_nil(text:find("edited", 1, true))
  end)

  it("makes the edits row a peek at the pending diff", function()
    edit_a_file("a.lua", { "one" }, { "two" })
    local row = find_button(section(), "1 file edited")
    assert.is_not_nil(row)

    local peeked
    local real = View.peek_edits
    View.peek_edits = function(s)
      peeked = s
    end
    row.props.on_press()
    View.peek_edits = real
    assert.rawequal(session, peeked)
  end)

  it("offers flush once anything is pending, wired to the whole flush", function()
    edit_a_file("a.lua", { "one" }, { "two" })
    local flushed
    local tree = section({
      on_flush = function(s)
        flushed = s
      end,
    })
    find_button(tree, "flush").props.on_press()
    assert.rawequal(session, flushed)
  end)

  it("discard drops BOTH halves: comments cleared, edits marked seen", function()
    local buf = scratch({ "alpha" }, "/tmp/weave-fb-discard.lua")
    Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "x" })
    edit_a_file("a.lua", { "one" }, { "two" })

    find_button(section(), "discard").props.on_press()
    assert.is_nil(Store.draft())
    assert.is_nil(Sync.pending_summary(session))
  end)
end)

describe("feedback comment list", function()
  before_each(function()
    Store._reset()
  end)

  it("lists every comment location with its body", function()
    local buf = scratch({ "alpha", "beta" }, "/tmp/weave-fb-list.lua")
    Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "rename this" })
    Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "and this" })
    local text = labels(View.List(fake_ctx(), {}))
    assert.truthy(text:find("weave%-fb%-list%.%d+%.lua:1"))
    assert.truthy(text:find("rename this", 1, true))
    assert.truthy(text:find("and this", 1, true))
  end)

  -- Two comments on the same line are indistinguishable by location alone, so
  -- activation has to carry the comment id, not its position.
  it("activates the comment it was rendered from", function()
    local buf = scratch({ "alpha", "beta" }, "/tmp/weave-fb-activate.lua")
    Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "first" })
    local second = Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "second" })

    local activated
    local tree = View.List(fake_ctx(), {
      on_activate = function(id)
        activated = id
      end,
    })
    local buttons = {}
    for _, node in ipairs(flatten(tree)) do
      if node.comp == ui.button then
        buttons[#buttons + 1] = node
      end
    end
    assert.equal(2, #buttons)
    buttons[2].props.on_press()
    assert.equal(second.id, activated)
  end)

  it("marks an orphaned comment", function()
    local buf = scratch({ "alpha", "beta" }, "/tmp/weave-fb-list-orphan.lua")
    Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "x" })
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    assert.truthy(labels(View.List(fake_ctx(), {})):find("⚠", 1, true))
  end)

  it("says so when there is nothing to list", function()
    assert.truthy(labels(View.List(fake_ctx(), {})):find("(no comments)", 1, true))
  end)
end)

describe("feedback comment editor", function()
  local buf, comment

  before_each(function()
    Store._reset()
    buf = scratch({ "local x = compute()", "return x" }, "/tmp/weave-fb-editor.lua")
    comment = Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "" })
  end)

  it("heads with the location and quotes the code as a real snippet", function()
    local tree = View.Editor(fake_ctx(), { id = comment.id })
    assert.truthy(labels(tree):find("weave%-fb%-editor%.%d+%.lua:1"))
    -- the quote is a ui.code snippet: highlighted, numbered from the
    -- comment's LIVE line, capped at the preview length
    local snippet
    for _, node in ipairs(flatten(tree)) do
      if node.comp == ui.code then
        snippet = node
      end
    end
    assert.is_not_nil(snippet)
    assert.equal("local x = compute()", snippet.props.code)
    assert.equal(1, snippet.props.start_line)
    assert.equal(View.QUOTE_PREVIEW_LINES, snippet.props.max_lines)
    assert.is_false(snippet.props.header)
    assert.truthy(snippet.props.ref.path:find("weave%-fb%-editor"))
  end)

  it("skips the snippet for a comment with no quoted lines", function()
    local c2 = Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "x" })
    local stored = Store.get(c2.id)
    stored.quote = {}
    for _, node in ipairs(flatten(View.Editor(fake_ctx(), { id = c2.id }))) do
      assert.is_true(node.comp ~= ui.code)
    end
  end)

  it("seeds the input with the existing body", function()
    Store.update(comment.id, "already written")
    for _, node in ipairs(flatten(View.Editor(fake_ctx(), { id = comment.id }))) do
      if node.comp == ui.text_input then
        assert.equal("already written", node.props.value)
        return
      end
    end
    error("no text_input in the editor")
  end)

  it("gives the input buffer the markdown filetype", function()
    for _, node in ipairs(flatten(View.Editor(fake_ctx(), { id = comment.id }))) do
      if node.comp == ui.text_input then
        local buf = vim.api.nvim_create_buf(false, true)
        node.props.on_create(buf)
        assert.equal("markdown", vim.bo[buf].filetype)
        return
      end
    end
    error("no text_input in the editor")
  end)

  -- The box follows the body between 3 and 8 content rows (border excluded);
  -- the height prop is border-box, so the assertions carry the +2.
  it("sizes the input to the body, clamped to 3..8 content rows", function()
    local function input_height(body)
      Store.update(comment.id, body)
      for _, node in ipairs(flatten(View.Editor(fake_ctx(), { id = comment.id }))) do
        if node.comp == ui.text_input then
          return node.props.height
        end
      end
      error("no text_input in the editor")
    end
    assert.equal(5, input_height("one line"))
    assert.equal(7, input_height("1\n2\n3\n4\n5"))
    assert.equal(10, input_height(("x\n"):rep(20)))
  end)

  it("saves the typed body and closes", function()
    local ctx = fake_ctx()
    local closed = false
    local tree = View.Editor(ctx, {
      id = comment.id,
      on_close = function()
        closed = true
      end,
    })
    for _, node in ipairs(flatten(tree)) do
      if node.comp == ui.text_input then
        node.props.on_change("this needs a guard")
      end
    end
    find_button(tree, "save").props.on_press()
    assert.equal("this needs a guard", Store.get(comment.id).body)
    assert.is_true(closed)
  end)

  it("saving an empty body removes the comment rather than bundling a blank", function()
    local tree = View.Editor(fake_ctx(), { id = comment.id })
    find_button(tree, "save").props.on_press()
    assert.is_nil(Store.get(comment.id))
  end)

  it("delete drops the comment", function()
    Store.update(comment.id, "written")
    local tree = View.Editor(fake_ctx(), { id = comment.id })
    find_button(tree, "delete").props.on_press()
    assert.is_nil(Store.get(comment.id))
  end)

  it("cancel restores the body the editor opened with", function()
    Store.update(comment.id, "original")
    local ctx = fake_ctx()
    local tree = View.Editor(ctx, { id = comment.id })
    for _, node in ipairs(flatten(tree)) do
      if node.comp == ui.text_input then
        node.props.on_change("scribbled over")
      end
    end
    find_button(tree, "cancel").props.on_press()
    assert.equal("original", Store.get(comment.id).body)
  end)

  -- Backing out of a fresh ;;cc must not strand a highlighted span with no
  -- comment attached to it.
  it("cancel on a never-written comment removes it", function()
    local tree = View.Editor(fake_ctx(), { id = comment.id })
    find_button(tree, "cancel").props.on_press()
    assert.is_nil(Store.get(comment.id))
  end)

  it("survives the comment being deleted under it", function()
    Store.remove(comment.id)
    assert.truthy(labels(View.Editor(fake_ctx(), { id = comment.id })):find("gone", 1, true))
  end)

  it("reports every keystroke to the float that owns it", function()
    local seen
    local tree = View.Editor(fake_ctx(), {
      id = comment.id,
      on_change = function(txt)
        seen = txt
      end,
    })
    for _, node in ipairs(flatten(tree)) do
      if node.comp == ui.text_input then
        node.props.on_change("half a thought")
      end
    end
    assert.equal("half a thought", seen)
  end)
end)

-- Closing the editor SAVES, unlike every other popup, because this one holds
-- text you typed: `q` — or clicking into the code to check what you are
-- commenting on (weave.view.float dismisses on blur) — must not throw the
-- comment away. Cancel stays the explicit discard.
describe("feedback comment editor, closed", function()
  local comment

  before_each(function()
    Store._reset()
    comment = Store.add({ bufnr = scratch({ "local x = 1" }), range = { lnum = 1, end_lnum = 1 } })
  end)

  after_each(function()
    Store._reset()
  end)

  it("keeps what was typed", function()
    View.save_body(comment.id, "worth keeping")
    assert.equal("worth keeping", Store.get(comment.id).body)
  end)

  it("removes a comment nothing was ever written into, leaving no orphan", function()
    View.save_body(comment.id, comment.body)
    assert.is_nil(Store.get(comment.id))
  end)

  it("treats whitespace as empty", function()
    Store.update(comment.id, "typed then cleared")
    View.save_body(comment.id, "   \n  ")
    assert.is_nil(Store.get(comment.id))
  end)
end)
