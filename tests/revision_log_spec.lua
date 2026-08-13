-- weave.revision_log: the collection side of tutor mode. Watches buffers, cuts
-- editing bursts into revisions, and hands out the window a session has not
-- seen yet. The log is append-only and UNBOUNDED by design — sessions read it
-- through a cursor, so nothing is ever consumed and two sessions at different
-- debounce phases each get their own window.
--
-- Attribution is the load-bearing part: weave's own writes must NOT show up as
-- the user's work, and neither must a reload from disk.

local Log = require("weave.revision_log")
local Permissions = require("weave.permissions")
local Revision = require("weave.revision")

describe("revision log", function()
  local root

  --- A real file under the project root, with a real buffer on it.
  local function open(name, lines)
    local path = root .. "/" .. name
    if lines then
      vim.fn.writefile(lines, path)
    end
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    Log.track(bufnr)
    return bufnr, path
  end

  --- Type into a buffer the way the user would: change it, then let the burst
  --- close.
  local function edit(bufnr, lines)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    Log.note_change(bufnr)
    Log.close_burst()
  end

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    Permissions._reset()
    Permissions.set_project_root(root)
    Log._reset()
  end)

  after_each(function()
    Log._reset()
    Permissions._reset()
    vim.fn.delete(root, "rf")
  end)

  it("records a modification as before/after content", function()
    local bufnr = open("a.lua", { "one", "two" })
    edit(bufnr, { "one", "TWO" })

    local revs = Log.since(0)
    assert.equal(1, #revs)
    local fc = revs[1].files[root .. "/a.lua"]
    assert.equal("one\ntwo\n", fc.before)
    assert.equal("one\nTWO\n", fc.after)
  end)

  it("gives every revision a rising id and hands back only what is newer", function()
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    edit(bufnr, { "three" })

    local all = Log.since(0)
    assert.equal(2, #all)
    assert.is_true(all[1].id < all[2].id)
    assert.same({ all[2] }, Log.since(all[1].id))
    assert.same({}, Log.since(all[2].id))
    assert.equal(all[2].id, Log.head_id())
  end)

  it("puts every buffer touched in one burst into ONE revision", function()
    local a = open("a.lua", { "a" })
    local b = open("b.lua", { "b" })
    vim.api.nvim_buf_set_lines(a, 0, -1, false, { "a2" })
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "b2" })
    Log.note_change(a)
    Log.note_change(b)
    Log.close_burst()

    local revs = Log.since(0)
    assert.equal(1, #revs)
    assert.same({ root .. "/a.lua", root .. "/b.lua" }, Revision.paths(revs[1]))
  end)

  it("records nothing at all when the burst netted no change", function()
    local bufnr = open("a.lua", { "one" })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "two" })
    Log.note_change(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one" })
    Log.note_change(bufnr)
    Log.close_burst()

    assert.same({}, Log.since(0))
    assert.equal(0, Log.head_id())
  end)

  it("squashes the window a cursor has not seen", function()
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    local mid = Log.head_id()
    edit(bufnr, { "three" })
    edit(bufnr, { "four" })

    local squashed = Log.squash_since(mid)
    local fc = squashed.files[root .. "/a.lua"]
    assert.equal("two\n", fc.before)
    assert.equal("four\n", fc.after)
    assert.is_nil(Log.squash_since(Log.head_id()))
  end)

  -- Two sessions in tutor mode debounce independently; neither may consume the
  -- other's window.
  it("serves two cursors independently", function()
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    local slow = 0
    local fast = Log.head_id()
    edit(bufnr, { "three" })

    assert.equal("one\n", Log.squash_since(slow).files[root .. "/a.lua"].before)
    assert.equal("two\n", Log.squash_since(fast).files[root .. "/a.lua"].before)
  end)
end)

describe("revision log attribution", function()
  local root

  local function open(name, lines)
    local path = root .. "/" .. name
    if lines then
      vim.fn.writefile(lines, path)
    end
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    Log.track(bufnr)
    return bufnr, path
  end

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    Permissions._reset()
    Permissions.set_project_root(root)
    Log._reset()
  end)

  after_each(function()
    Log._reset()
    Permissions._reset()
    vim.fn.delete(root, "rf")
  end)

  -- The whole point of the feature: the tutor is looking at what the USER did.
  it("does not record a change weave's own write tools made", function()
    local bufnr = open("a.lua", { "one" })
    Log.suppress(function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "written by the agent" })
      Log.note_change(bufnr)
    end)
    Log.close_burst()
    assert.same({}, Log.since(0))
  end)

  -- ...and the agent's write becomes the new baseline, or the user's NEXT edit
  -- would be reported as having also made the agent's change.
  it("adopts an agent write as the baseline for the user's next edit", function()
    local bufnr = open("a.lua", { "one" })
    Log.suppress(function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "agent" })
      Log.note_change(bufnr)
    end)
    Log.close_burst()

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "agent", "user" })
    Log.note_change(bufnr)
    Log.close_burst()

    local fc = Log.since(0)[1].files[root .. "/a.lua"]
    assert.equal("agent\n", fc.before)
    assert.equal("agent\nuser\n", fc.after)
  end)

  it("re-baselines silently when a buffer is reloaded from disk", function()
    local bufnr = open("a.lua", { "one" })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "reloaded" })
    Log.rebaseline(bufnr)
    Log.close_burst()
    assert.same({}, Log.since(0))

    -- ...and the reloaded content is what the user's next edit is measured from
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "reloaded", "then typed" })
    Log.note_change(bufnr)
    Log.close_burst()
    assert.equal("reloaded\n", Log.since(0)[1].files[root .. "/a.lua"].before)
  end)

  it("ignores buffers outside the project root", function()
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    vim.fn.writefile({ "x" }, outside .. "/o.lua")
    local bufnr = vim.fn.bufadd(outside .. "/o.lua")
    vim.fn.bufload(bufnr)

    assert.is_false(Log.track(bufnr))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "y" })
    Log.note_change(bufnr)
    Log.close_burst()
    assert.same({}, Log.since(0))
    vim.fn.delete(outside, "rf")
  end)

  it("ignores buffers with no file behind them", function()
    local scratch = vim.api.nvim_create_buf(false, true)
    assert.is_false(Log.track(scratch))
    vim.api.nvim_buf_delete(scratch, { force = true })
  end)

  -- The wiring, not just the mechanism: w:write and w:edit both land through
  -- weave.tools.fs, and that is where suppression has to be, or every agent
  -- edit is reported back to the agent as the user's.
  it("keeps a w:write out of the log entirely", function()
    local bufnr, path = open("a.lua", { "one" })
    require("weave.tools.fs").write.handler({ path = path, content = "agent wrote this\n" })
    Log.close_burst()
    assert.same({}, Log.since(0))

    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "and then the user typed" })
    Log.note_change(bufnr)
    Log.close_burst()
    local fc = Log.since(0)[1].files[path]
    assert.equal("agent wrote this\n", fc.before)
    assert.truthy(fc.after:find("user typed", 1, true))
  end)

  -- ...and the user's unsent work is not swallowed by the agent's write. The
  -- burst has to close BEFORE the splice: on_lines fires after the mutation,
  -- so by then the buffer already holds the agent's text and there is no way
  -- to tell the two apart.
  it("records the user's pending edits before adopting an agent write", function()
    local bufnr, path = open("a.lua", { "one" })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "user was here" })
    Log.note_change(bufnr)

    require("weave.tools.fs").write.handler({ path = path, content = "agent clobbered it\n" })
    Log.close_burst()

    local revs = Log.since(0)
    assert.equal(1, #revs)
    local fc = revs[1].files[path]
    assert.equal("one\n", fc.before)
    assert.equal("user was here\n", fc.after)
  end)
end)

describe("revision log file lifecycle", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    Permissions._reset()
    Permissions.set_project_root(root)
    Log._reset()
  end)

  after_each(function()
    Log._reset()
    Permissions._reset()
    vim.fn.delete(root, "rf")
  end)

  it("reports a file that did not exist as a creation", function()
    local path = root .. "/new.lua"
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    Log.track(bufnr)

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "fresh" })
    Log.note_change(bufnr)
    Log.close_burst()

    local fc = Log.since(0)[1].files[path]
    assert.is_nil(fc.before)
    assert.equal("fresh\n", fc.after)
    assert.equal("created", Revision.kind(fc))
  end)

  it("reports a tracked file that has gone from disk as a deletion", function()
    local path = root .. "/doomed.lua"
    vim.fn.writefile({ "here" }, path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    Log.track(bufnr)

    vim.fn.delete(path)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    Log.forget(bufnr)
    Log.close_burst()

    local fc = Log.since(0)[1].files[path]
    assert.equal("here\n", fc.before)
    assert.is_nil(fc.after)
    assert.equal("deleted", Revision.kind(fc))
  end)

  it("says nothing when a buffer is closed and its file is still there", function()
    local path = root .. "/kept.lua"
    vim.fn.writefile({ "here" }, path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    Log.track(bufnr)

    vim.api.nvim_buf_delete(bufnr, { force = true })
    Log.forget(bufnr)
    Log.close_burst()
    assert.same({}, Log.since(0))
  end)
end)
