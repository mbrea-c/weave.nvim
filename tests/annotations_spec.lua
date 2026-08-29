-- weave.annotations: the AGENT's notes on the user's code — the mirror of
-- weave.feedback, which carries the user's notes to the agent. One extmark per
-- annotation does all three jobs at once: it highlights the span, it anchors
-- the note as the user keeps typing around it, and its virt_lines are how the
-- message is rendered.
--
-- The hard part is drift. In tutor mode the user is editing CONSTANTLY, so by
-- the time a tool call lands, the line number the agent quoted may point
-- somewhere else entirely.

local Annotations = require("weave.annotations")

local function scratch(lines, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if name then
    vim.api.nvim_buf_set_name(buf, name)
  end
  return buf
end

--- The extmark details behind an annotation.
local function mark(ann)
  return vim.api.nvim_buf_get_extmark_by_id(ann.bufnr, Annotations.NS, ann.anchor, { details = true })
end

describe("annotations", function()
  before_each(function()
    Annotations._reset()
  end)

  after_each(function()
    Annotations._reset()
  end)

  it("anchors a span and renders the message as virtual lines below it", function()
    local buf = scratch({ "local x = 1", "return x" })
    local ann = assert(Annotations.add({ bufnr = buf, lnum = 1, message = "shadowed name" }))

    assert.equal("shadowed name", ann.message)
    local details = mark(ann)[3]
    assert.equal(Annotations.HL, details.hl_group)
    assert.truthy(details.virt_lines)
    assert.is_false(details.virt_lines_above)
    assert.truthy(table
      .concat(vim.tbl_map(function(chunk)
        return chunk[1][1]
      end, details.virt_lines))
      :find("shadowed name", 1, true))
  end)

  it("puts them above when the agent asks for above", function()
    local buf = scratch({ "local x = 1" })
    local ann = assert(Annotations.add({ bufnr = buf, lnum = 1, message = "note", position = "above" }))
    assert.is_true(mark(ann)[3].virt_lines_above)
  end)

  it("wraps a long message rather than running off the window", function()
    local buf = scratch({ "code" })
    local ann = assert(Annotations.add({
      bufnr = buf,
      lnum = 1,
      message = string.rep("word ", 60),
      width = 30,
    }))
    local lines = mark(ann)[3].virt_lines
    assert.is_true(#lines > 1)
    for _, chunk in ipairs(lines) do
      assert.is_true(#chunk[1][1] <= 30)
    end
  end)

  it("caps how many lines it will take over the buffer, and says it did", function()
    local buf = scratch({ "code" })
    local ann = assert(Annotations.add({
      bufnr = buf,
      lnum = 1,
      message = string.rep("word ", 400),
      width = 20,
      max_lines = 4,
    }))
    local lines = mark(ann)[3].virt_lines
    assert.equal(4, #lines)
    assert.truthy(lines[4][1][1]:find("more"))
  end)

  it("follows the code as the user types above it", function()
    local buf = scratch({ "one", "two", "three" })
    local ann = assert(Annotations.add({ bufnr = buf, lnum = 3, message = "here" }))
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "zero" })
    assert.equal(4, Annotations.resolve(ann).lnum)
  end)

  it("reports an annotation whose code was deleted as orphaned", function()
    local buf = scratch({ "one", "two", "three" })
    local ann = assert(Annotations.add({ bufnr = buf, lnum = 2, message = "here" }))
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    assert.is_true(Annotations.resolve(ann).orphaned)
  end)
end)

-- The agent names a span from the file as it last READ it. In tutor mode the
-- user has very likely typed since, so the line number alone is a guess; the
-- text the agent expected to find there is what makes it checkable.
-- The marker is derived from the feedback draft — "a reply is pending" MEANS
-- "a draft comment with reply_to = this id exists" — so it can never disagree
-- with what a flush would actually send.
describe("annotation reply markers", function()
  local Store = require("weave.feedback_store")

  before_each(function()
    Store._reset()
    Annotations._reset()
  end)

  after_each(function()
    Store._reset()
    Annotations._reset()
  end)

  local function virt_text(ann)
    return table.concat(
      vim.tbl_map(function(chunk)
        return chunk[1][1]
      end, mark(ann)[3].virt_lines),
      "\n"
    )
  end

  it("marks a note while a draft reply to it exists, and unmarks when it goes", function()
    local buf = scratch({ "local x = 1" })
    local ann = assert(Annotations.add({ bufnr = buf, lnum = 1, message = "note" }))
    assert.falsy(virt_text(ann):find("reply pending", 1, true))

    local c = assert(Store.add({ bufnr = buf, range = { lnum = 1 }, reply_to = { id = ann.id, message = "note" } }))
    assert.truthy(virt_text(ann):find("reply pending", 1, true))

    Store.remove(c.id)
    assert.falsy(virt_text(ann):find("reply pending", 1, true))
  end)

  it("does not mark a note someone else's reply names", function()
    local buf = scratch({ "local x = 1", "local y = 2" })
    local a = assert(Annotations.add({ bufnr = buf, lnum = 1, message = "one" }))
    local b = assert(Annotations.add({ bufnr = buf, lnum = 2, message = "two" }))
    assert(Store.add({ bufnr = buf, range = { lnum = 1 }, reply_to = { id = a.id, message = "one" } }))
    assert.truthy(virt_text(a):find("reply pending", 1, true))
    assert.falsy(virt_text(b):find("reply pending", 1, true))
  end)

  it("clears every marker when the draft is discarded", function()
    local buf = scratch({ "local x = 1" })
    local ann = assert(Annotations.add({ bufnr = buf, lnum = 1, message = "note" }))
    assert(Store.add({ bufnr = buf, range = { lnum = 1 }, reply_to = { id = ann.id, message = "note" } }))
    Store.clear()
    assert.falsy(virt_text(ann):find("reply pending", 1, true))
  end)
end)

describe("annotation placement", function()
  before_each(function()
    Annotations._reset()
  end)

  after_each(function()
    Annotations._reset()
  end)

  it("places at the given line when the expected text is there", function()
    local buf = scratch({ "one", "two", "three" })
    local ann = assert(Annotations.add({ bufnr = buf, lnum = 2, expect = { "two" }, message = "m" }))
    assert.equal(2, Annotations.resolve(ann).lnum)
    assert.is_false(ann.drifted)
  end)

  it("re-finds the expected text when the line number went stale", function()
    local buf = scratch({ "inserted", "inserted", "one", "two", "three" })
    -- the agent read the file before those two lines existed and said line 2
    local ann = assert(Annotations.add({ bufnr = buf, lnum = 2, expect = { "two" }, message = "m" }))
    assert.equal(4, Annotations.resolve(ann).lnum)
    assert.is_true(ann.drifted)
  end)

  it("refuses rather than annotating whatever moved into that spot", function()
    local buf = scratch({ "one", "two" })
    local ann, err = Annotations.add({ bufnr = buf, lnum = 1, expect = { "gone forever" }, message = "m" })
    assert.is_nil(ann)
    assert.truthy(tostring(err):find("no longer"))
  end)

  it("takes the line on faith when the agent offers no expectation", function()
    local buf = scratch({ "one", "two" })
    local ann = assert(Annotations.add({ bufnr = buf, lnum = 2, message = "m" }))
    assert.equal(2, Annotations.resolve(ann).lnum)
  end)
end)

describe("annotation lifecycle", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    Annotations._reset()
  end)

  after_each(function()
    Annotations._reset()
    vim.fn.delete(root, "rf")
  end)

  it("lists what is outstanding, with where each one sits now", function()
    local buf = scratch({ "one", "two" }, root .. "/a.lua")
    Annotations.add({ bufnr = buf, lnum = 1, message = "first" })
    Annotations.add({ bufnr = buf, lnum = 2, message = "second" })

    local list = Annotations.list()
    assert.equal(2, #list)
    assert.equal("first", list[1].message)
    assert.equal(1, list[1].lnum)
    assert.equal(2, list[2].lnum)
  end)

  it("edits a message in place, keeping the anchor", function()
    local buf = scratch({ "one" })
    local ann = assert(Annotations.add({ bufnr = buf, lnum = 1, message = "before" }))
    local anchor = ann.anchor
    assert.is_true(Annotations.update(ann.id, { message = "after" }))
    assert.equal("after", Annotations.get(ann.id).message)
    -- the mark is replaced (virt_lines change), but it still resolves
    assert.equal(1, Annotations.resolve(Annotations.get(ann.id)).lnum)
    assert.is_not_nil(anchor)
  end)

  it("dismisses one, taking its highlight with it", function()
    local buf = scratch({ "one" })
    local ann = assert(Annotations.add({ bufnr = buf, lnum = 1, message = "m" }))
    assert.is_true(Annotations.dismiss(ann.id))
    assert.is_nil(Annotations.get(ann.id))
    assert.same({}, vim.api.nvim_buf_get_extmarks(buf, Annotations.NS, 0, -1, {}))
  end)

  it("dismisses the one under the cursor, and only that one", function()
    local buf = scratch({ "one", "two" })
    local a = assert(Annotations.add({ bufnr = buf, lnum = 1, message = "a" }))
    local b = assert(Annotations.add({ bufnr = buf, lnum = 2, message = "b" }))
    assert.equal(a.id, Annotations.at_cursor(buf, 1).id)
    assert.is_true(Annotations.dismiss_at(buf, 1))
    assert.is_nil(Annotations.get(a.id))
    assert.is_not_nil(Annotations.get(b.id))
  end)

  it("clears everything at once", function()
    local buf = scratch({ "one", "two" })
    Annotations.add({ bufnr = buf, lnum = 1, message = "a" })
    Annotations.add({ bufnr = buf, lnum = 2, message = "b" })
    Annotations.clear()
    assert.same({}, Annotations.list())
    assert.same({}, vim.api.nvim_buf_get_extmarks(buf, Annotations.NS, 0, -1, {}))
  end)

  -- Feedback on a file nobody has open is not useless — it is early. It waits
  -- for the buffer rather than being dropped on the floor.
  it("holds an annotation for an unopened file and places it when it opens", function()
    local path = root .. "/later.lua"
    vim.fn.writefile({ "alpha", "beta" }, path)

    local ann = assert(Annotations.add({ path = path, lnum = 2, expect = { "beta" }, message = "m" }))
    assert.is_nil(ann.bufnr)
    assert.is_true(ann.pending)

    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    Annotations.reattach(bufnr)

    local placed = Annotations.get(ann.id)
    assert.equal(bufnr, placed.bufnr)
    assert.is_false(placed.pending)
    assert.equal(2, Annotations.resolve(placed).lnum)
  end)

  it("refuses an annotation for a file that does not exist at all", function()
    local ann, err = Annotations.add({ path = root .. "/nope.lua", lnum = 1, message = "m" })
    assert.is_nil(ann)
    assert.truthy(tostring(err):find("no such file"))
  end)

  it("notifies subscribers so a UI can follow along", function()
    local buf = scratch({ "one" })
    local seen = 0
    local off = Annotations.subscribe(function()
      seen = seen + 1
    end)
    local ann = assert(Annotations.add({ bufnr = buf, lnum = 1, message = "m" }))
    Annotations.dismiss(ann.id)
    off()
    Annotations.add({ bufnr = buf, lnum = 1, message = "m2" })
    assert.equal(2, seen)
  end)
end)
