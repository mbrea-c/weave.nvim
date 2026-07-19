-- The public API users bind. The editor opener is injected so these exercise
-- the capture and send paths without mounting a float.

local Feedback = require("weave.feedback")
local Sinks = require("weave.feedback_sinks")
local Store = require("weave.feedback_store")

local function open_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

--- Records the comment id the editor would have been opened on.
local function capture_open()
  local opened = {}
  return opened, function(id)
    opened[#opened + 1] = id
  end
end

describe("feedback API", function()
  before_each(function()
    Store._reset()
    Sinks._reset()
  end)

  describe("visual range", function()
    it("orders a backwards selection", function()
      local r = Feedback._visual_range("v", { lnum = 5, col = 3 }, { lnum = 2, col = 7 })
      assert.equal(2, r.lnum)
      assert.equal(5, r.end_lnum)
      assert.equal(7, r.col)
      assert.equal(3, r.end_col)
    end)

    it("keeps columns for a charwise selection", function()
      local r = Feedback._visual_range("v", { lnum = 1, col = 11 }, { lnum = 1, col = 19 })
      assert.equal(11, r.col)
      assert.equal(19, r.end_col)
    end)

    it("drops columns for a linewise selection", function()
      local r = Feedback._visual_range("V", { lnum = 1, col = 4 }, { lnum = 3, col = 2 })
      assert.same({ lnum = 1, end_lnum = 3 }, r)
    end)

    -- A block's columns describe several disjoint spans, not one range.
    it("drops columns for a blockwise selection", function()
      local r = Feedback._visual_range("\22", { lnum = 1, col = 4 }, { lnum = 3, col = 2 })
      assert.same({ lnum = 1, end_lnum = 3 }, r)
    end)
  end)

  describe("comment_line", function()
    it("comments the cursor line and opens the editor on it", function()
      local buf = open_buffer({ "alpha", "beta", "gamma" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      local opened, open = capture_open()
      local c = Feedback.comment_line({ open = open })
      assert.same({ "beta" }, c.quote)
      assert.equal(buf, c.bufnr)
      assert.same({ c.id }, opened)
    end)

    it("joins the open draft rather than starting a new one", function()
      open_buffer({ "alpha", "beta" })
      local _, open = capture_open()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      Feedback.comment_line({ open = open })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      Feedback.comment_line({ open = open })
      assert.equal(2, #Feedback.draft().comments)
    end)

    it("carries a caller's source through", function()
      open_buffer({ "alpha" })
      local _, open = capture_open()
      assert.equal("perijove", Feedback.comment_line({ open = open, source = "perijove" }).source)
    end)
  end)

  describe("edit_comment", function()
    it("opens the comment under the cursor", function()
      open_buffer({ "alpha", "beta" })
      local opened, open = capture_open()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      local c = Feedback.comment_line({ open = open })
      assert.equal(c.id, Feedback.edit_comment({ open = open }).id)
    end)

    it("opens nothing when the cursor is not on a comment", function()
      open_buffer({ "alpha", "beta" })
      local opened, open = capture_open()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      Feedback.comment_line({ open = open })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      assert.is_nil(Feedback.edit_comment({ open = open }))
    end)
  end)

  describe("send", function()
    local function seed()
      open_buffer({ "local x = compute()" })
      local _, open = capture_open()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local c = Feedback.comment_line({ open = open })
      Store.update(c.id, "why compute here?")
      return c
    end

    it("formats the draft and hands it to the default sink", function()
      seed()
      local got
      Sinks.register({
        name = "weave",
        send = function(text)
          got = text
          return true
        end,
      })
      assert.is_true(Feedback.send())
      assert.truthy(got:find("why compute here?", 1, true))
      assert.truthy(got:find("local x = compute()", 1, true))
    end)

    it("clears the draft after a successful send", function()
      seed()
      Sinks.register({
        name = "weave",
        send = function()
          return true
        end,
      })
      Feedback.send()
      assert.is_nil(Feedback.draft())
    end)

    -- Losing a batch of hand-written comments to a transient failure would be
    -- the worst bug this feature could have.
    it("KEEPS the draft when the sink fails", function()
      seed()
      Sinks.register({
        name = "weave",
        send = function()
          return nil, "no session"
        end,
      })
      local ok, err = Feedback.send()
      assert.falsy(ok)
      assert.equal("no session", err)
      assert.equal(1, #Feedback.draft().comments)
    end)

    it("routes to a named sink", function()
      seed()
      local hit = false
      Sinks.register({
        name = "perijove",
        send = function()
          hit = true
          return true
        end,
      })
      assert.is_true(Feedback.send({ sink = "perijove" }))
      assert.is_true(hit)
    end)

    it("reports having nothing to send", function()
      local ok, err = Feedback.send()
      assert.falsy(ok)
      assert.truthy(err:find("no code feedback", 1, true))
    end)
  end)

  it("discard drops the draft", function()
    open_buffer({ "alpha" })
    local _, open = capture_open()
    Feedback.comment_line({ open = open })
    Feedback.discard()
    assert.is_nil(Feedback.draft())
  end)
end)
