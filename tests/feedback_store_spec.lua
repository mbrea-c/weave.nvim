-- The draft store holds ONE in-progress code-feedback item at a time. An item
-- is a BUNDLE of comments, possibly from several sources (weave's own inline
-- commenting, perijove, anything else that calls add), sent to the agent as one
-- message.

local Store = require("weave.feedback_store")

local function scratch(lines, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if name then
    vim.api.nvim_buf_set_name(buf, name)
  end
  return buf
end

describe("feedback store", function()
  before_each(function()
    Store._reset()
  end)

  it("creates a draft on the first comment and captures the quoted code", function()
    local buf = scratch({ "local x = 1", "return x" })
    local c = Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "why?" })
    assert.equal("why?", c.body)
    assert.same({ "return x" }, c.quote)
    assert.equal(1, #Store.draft().comments)
  end)

  it("adds later comments to the SAME open draft", function()
    local buf = scratch({ "a", "b", "c" })
    Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "one" })
    local item_id = Store.draft().id
    Store.add({ bufnr = buf, range = { lnum = 3, end_lnum = 3 }, body = "two" })
    assert.equal(item_id, Store.draft().id)
    assert.equal(2, #Store.draft().comments)
  end)

  it("bundles comments from different sources into one item", function()
    local buf = scratch({ "a", "b" })
    Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "mine" })
    Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "theirs", source = "perijove" })
    local comments = Store.draft().comments
    assert.equal("weave", comments[1].source)
    assert.equal("perijove", comments[2].source)
  end)

  it("resolves a comment to where its code sits now", function()
    local buf = scratch({ "a", "b", "c" })
    local c = Store.add({ bufnr = buf, range = { lnum = 3, end_lnum = 3 }, body = "x" })
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "header" })
    local at = Store.resolve(c)
    assert.equal(4, at.lnum)
    assert.is_false(at.orphaned)
  end)

  it("reports a comment as orphaned once its code is deleted", function()
    local buf = scratch({ "a", "b", "c" })
    local c = Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "x" })
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    local at = Store.resolve(c)
    assert.is_true(at.orphaned)
    -- still reports the LAST known line rather than dropping the comment
    assert.equal(2, at.lnum)
  end)

  it("keeps the last known position across resolves", function()
    local buf = scratch({ "a", "b", "c" })
    local c = Store.add({ bufnr = buf, range = { lnum = 3, end_lnum = 3 }, body = "x" })
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "header" })
    Store.resolve(c) -- caches lnum 4
    vim.api.nvim_buf_set_lines(buf, 3, 4, false, {}) -- delete the anchored line
    assert.equal(4, Store.resolve(c).lnum)
  end)

  it("updates a comment body", function()
    local buf = scratch({ "a" })
    local c = Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "old" })
    Store.update(c.id, "new")
    assert.equal("new", Store.get(c.id).body)
  end)

  it("removes a comment and clears its highlight", function()
    local buf = scratch({ "a", "b" })
    local c1 = Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "one" })
    Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "two" })
    Store.remove(c1.id)
    assert.equal(1, #Store.draft().comments)
    assert.equal(0, #vim.api.nvim_buf_get_extmarks(buf, require("weave.feedback_anchors").NS, 0, 0, {}))
  end)

  it("drops the draft entirely when its last comment is removed", function()
    local buf = scratch({ "a" })
    local c = Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "one" })
    Store.remove(c.id)
    assert.is_nil(Store.draft())
  end)

  it("clear drops the draft and every highlight with it", function()
    local buf = scratch({ "a", "b" })
    Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "one" })
    Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "two" })
    Store.clear()
    assert.is_nil(Store.draft())
    assert.equal(0, #vim.api.nvim_buf_get_extmarks(buf, require("weave.feedback_anchors").NS, 0, -1, {}))
  end)

  it("notifies subscribers on add, update and remove", function()
    local buf = scratch({ "a" })
    local hits = 0
    local unsub = Store.subscribe(function()
      hits = hits + 1
    end)
    local c = Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "one" })
    Store.update(c.id, "two")
    Store.remove(c.id)
    assert.equal(3, hits)
    unsub()
    Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "three" })
    assert.equal(3, hits)
  end)

  it("finds the comment under a cursor line", function()
    local buf = scratch({ "a", "b", "c" })
    local c = Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "one" })
    assert.equal(c.id, Store.at_cursor(buf, 2).id)
    assert.is_nil(Store.at_cursor(buf, 3))
  end)

  -- Extmarks die with their buffer, so a comment that outlives an unload is
  -- re-placed by searching for the code it quoted.
  it("reattaches a comment whose anchor died with the buffer", function()
    local buf = scratch({ "alpha", "beta" }, "/tmp/weave-feedback-reattach.lua")
    local c = Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "one" })
    require("weave.feedback_anchors").clear(buf, c.anchor)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new header" })

    Store.reattach(buf)
    local at = Store.resolve(Store.get(c.id))
    assert.is_false(at.orphaned)
    assert.equal(3, at.lnum)
  end)

  it("leaves a comment orphaned when its quote is nowhere in the buffer", function()
    local buf = scratch({ "alpha" }, "/tmp/weave-feedback-orphan.lua")
    local c = Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "one" })
    require("weave.feedback_anchors").clear(buf, c.anchor)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "totally different" })

    Store.reattach(buf)
    assert.is_true(Store.resolve(Store.get(c.id)).orphaned)
  end)
end)
