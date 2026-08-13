-- The anchor layer is what keeps inline comments pointing at the right code.
-- Line numbers go stale the moment anything edits above them, and the agent is
-- the main thing doing that editing, so a comment is anchored to an extmark and
-- resolved to a line number only when it is rendered or sent.

local Anchors = require("weave.feedback_anchors")

local function scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- The layer is parameterized because the SAME mechanism serves both
-- directions: the user's comments awaiting send, and the agent's annotations
-- (weave.annotations). They must not share a namespace — `at()` is a reverse
-- lookup, and one that mixed the two would hand "dismiss the annotation under
-- my cursor" a user comment instead.
describe("feedback anchor layers", function()
  it("keeps two layers' marks apart", function()
    local mine = Anchors.layer({ name = "weave_test_layer_a", hl = "WeaveTestA" })
    local theirs = Anchors.layer({ name = "weave_test_layer_b", hl = "WeaveTestB" })
    local buf = scratch({ "one", "two" })

    local a = mine.set(buf, { lnum = 1, end_lnum = 1 })
    theirs.set(buf, { lnum = 1, end_lnum = 1 })

    assert.same({ a }, mine.at(buf, 1))
    assert.equal(1, #theirs.at(buf, 1))
    assert.truthy(mine.range(buf, a))
    -- clearing one leaves the other standing
    mine.clear(buf, a)
    assert.same({}, mine.at(buf, 1))
    assert.equal(1, #theirs.at(buf, 1))
  end)

  it("carries its own highlight group", function()
    local layer = Anchors.layer({ name = "weave_test_layer_c", hl = "WeaveTestC" })
    local buf = scratch({ "one" })
    local id = layer.set(buf, { lnum = 1, end_lnum = 1 })
    local mark = vim.api.nvim_buf_get_extmark_by_id(buf, layer.NS, id, { details = true })
    assert.equal("WeaveTestC", mark[3].hl_group)
  end)

  it("passes extra extmark options through, which is how a message gets rendered", function()
    local layer = Anchors.layer({ name = "weave_test_layer_d", hl = "WeaveTestD" })
    local buf = scratch({ "one" })
    local id = layer.set(buf, { lnum = 1, end_lnum = 1 }, {
      virt_lines = { { { "a note", "WeaveTestD" } } },
      virt_lines_above = true,
    })
    local mark = vim.api.nvim_buf_get_extmark_by_id(buf, layer.NS, id, { details = true })
    assert.same({ { { "a note", "WeaveTestD" } } }, mark[3].virt_lines)
    assert.is_true(mark[3].virt_lines_above)
  end)
end)

describe("feedback anchors", function()
  it("round-trips a whole-line range", function()
    local buf = scratch({ "one", "two", "three" })
    local id = Anchors.set(buf, { lnum = 2, end_lnum = 2 })
    -- col/end_col are 1-based and INCLUSIVE, so a whole "two" line is 1..3.
    assert.same({ lnum = 2, end_lnum = 2, col = 1, end_col = 3 }, Anchors.range(buf, id))
  end)

  it("round-trips a partial column range", function()
    local buf = scratch({ "local x = compute()" })
    local id = Anchors.set(buf, { lnum = 1, end_lnum = 1, col = 11, end_col = 19 })
    local r = Anchors.range(buf, id)
    assert.equal(11, r.col)
    assert.equal(19, r.end_col)
  end)

  it("carries the feedback highlight group", function()
    local buf = scratch({ "one" })
    local id = Anchors.set(buf, { lnum = 1, end_lnum = 1 })
    local mark = vim.api.nvim_buf_get_extmark_by_id(buf, Anchors.NS, id, { details = true })
    assert.equal(Anchors.HL, mark[3].hl_group)
  end)

  it("follows text inserted above it", function()
    local buf = scratch({ "one", "two", "three" })
    local id = Anchors.set(buf, { lnum = 3, end_lnum = 3 })
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "zero", "half" })
    assert.equal(5, Anchors.range(buf, id).lnum)
  end)

  it("reports no range once the anchored lines are deleted", function()
    local buf = scratch({ "one", "two", "three" })
    local id = Anchors.set(buf, { lnum = 2, end_lnum = 2 })
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    assert.is_nil(Anchors.range(buf, id))
  end)

  it("clears a mark", function()
    local buf = scratch({ "one" })
    local id = Anchors.set(buf, { lnum = 1, end_lnum = 1 })
    Anchors.clear(buf, id)
    assert.is_nil(Anchors.range(buf, id))
  end)

  it("finds the marks covering a line, and only those", function()
    local buf = scratch({ "one", "two", "three", "four" })
    local a = Anchors.set(buf, { lnum = 1, end_lnum = 2 })
    local b = Anchors.set(buf, { lnum = 4, end_lnum = 4 })
    assert.same({ a }, Anchors.at(buf, 2))
    assert.same({ b }, Anchors.at(buf, 4))
    assert.same({}, Anchors.at(buf, 3))
  end)

  it("quotes the anchored lines whole, even for a partial selection", function()
    local buf = scratch({ "local x = compute()", "return x" })
    assert.same({ "local x = compute()" }, Anchors.quote(buf, { lnum = 1, end_lnum = 1, col = 11, end_col = 19 }))
    assert.same({ "local x = compute()", "return x" }, Anchors.quote(buf, { lnum = 1, end_lnum = 2 }))
  end)

  -- Re-anchoring is the buffer-unload story: extmarks die with the buffer, so a
  -- comment that outlives its buffer is re-placed by searching for the text it
  -- was originally attached to.
  it("re-finds a quote that has moved", function()
    local buf = scratch({ "header", "alpha", "beta", "tail" })
    assert.equal(2, Anchors.find(buf, { "alpha", "beta" }))
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "x", "y", "z" })
    assert.equal(5, Anchors.find(buf, { "alpha", "beta" }))
  end)

  it("returns nil when the quoted text is gone", function()
    local buf = scratch({ "header", "tail" })
    assert.is_nil(Anchors.find(buf, { "alpha", "beta" }))
  end)
end)
