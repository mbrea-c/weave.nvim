-- weave.flush: one keypress that hands the conversation everything the user
-- has pending — the edits it has not seen AND the inline comments they wrote
-- about them — as ONE turn.
--
-- Two halves with different owners (weave.edit_sync holds the revision
-- cursor, weave.feedback_store the comment draft), so the interesting part is
-- that each keeps its own delivery hook: a batch that dies in a wiped steer
-- queue must re-arm the edits and leave the comments in the draft, not
-- half-clear both.

local Config = require("weave.config")
local Feedback = require("weave.feedback")
local FeedbackStore = require("weave.feedback_store")
local Log = require("weave.revision_log")
local Permissions = require("weave.permissions")
local Settings = require("weave.settings")
local Sinks = require("weave.feedback_sinks")
local Sync = require("weave.edit_sync")
local Weave = require("weave")

--- A session double recording the batches handed to it. Idle by default: the
--- batch dispatches immediately, like a real session with no turn in flight.
local function fake_session()
  local session = { batches = {}, prompts = {} }
  function session:is_ready()
    return true
  end
  function session:send_batch(msgs)
    self.batches[#self.batches + 1] = msgs
    for _, msg in ipairs(msgs) do
      if msg.on_sent then
        msg.on_sent()
      end
    end
    return true
  end
  function session:submit(text)
    self.prompts[#self.prompts + 1] = text
  end
  --- The batch was accepted but died with a cancelled turn.
  function session:wipe(i)
    for _, msg in ipairs(self.batches[i or #self.batches]) do
      if msg.on_dropped then
        msg.on_dropped()
      end
    end
  end
  return session
end

--- A session mid-turn: it ACCEPTS the batch but parks it (the steer queue),
--- so nothing is delivered until the spec says so — deliver() or wipe().
local function busy_session()
  local session = fake_session()
  function session:send_batch(msgs)
    self.batches[#self.batches + 1] = msgs
    return true
  end
  function session:deliver(i)
    for _, msg in ipairs(self.batches[i or #self.batches]) do
      if msg.on_sent then
        msg.on_sent()
      end
    end
  end
  return session
end

--- A session that cannot take anything yet.
local function unready_session()
  local session = fake_session()
  function session:is_ready()
    return false
  end
  function session:send_batch()
    return false
  end
  return session
end

describe("weave.flush", function()
  local root, saved_notify, notifications

  local function open(name, lines)
    local path = root .. "/" .. name
    vim.fn.writefile(lines, path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    Log.track(bufnr)
    return bufnr, path
  end

  local function edit(bufnr, lines)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    Log.note_change(bufnr)
    Log.close_burst()
  end

  --- A tracked session (the shape the tutor preset leaves you in: collecting,
  --- auto-send OFF) with an edited file behind it.
  local function tracked()
    local session = fake_session()
    Sync.watch(session)
    Settings.global():set("track_edits", true)
    return session
  end

  local function comment_on(bufnr, body)
    return FeedbackStore.add({ bufnr = bufnr, range = { lnum = 1, end_lnum = 1 }, body = body })
  end

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    notifications = {}
    saved_notify = require("weave.utils.logger").notify
    require("weave.utils.logger").notify = function(msg)
      notifications[#notifications + 1] = msg
    end
    Permissions._reset()
    Permissions.set_project_root(root)
    Sync._reset()
    Settings._reset()
    Log._reset()
    FeedbackStore._reset()
    Sinks._reset()
  end)

  after_each(function()
    require("weave.utils.logger").notify = saved_notify
    Sync._reset()
    Settings._reset()
    Log._reset()
    FeedbackStore._reset()
    Sinks._reset()
    Permissions._reset()
    vim.fn.delete(root, "rf")
  end)

  it("sends the edits and the comments as ONE turn", function()
    local session = tracked()
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    comment_on(bufnr, "is this right?")

    assert.is_true(Weave.flush({ session = session }))
    assert.equal(1, #session.batches)

    local batch = session.batches[1]
    assert.equal(2, #batch)
    -- the edits ride as a system message (its own transcript entry), the
    -- comments as the user's own words
    assert.equal("tutor", batch[1].kind)
    assert.truthy(batch[1].text:find("\n+two", 1, true))
    assert.equal("user", batch[2].kind)
    assert.truthy(batch[2].text:find("is this right?", 1, true))
  end)

  it("takes either half alone", function()
    local session = tracked()
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })

    assert.is_true(Weave.flush({ session = session }))
    assert.equal(1, #session.batches[1])
    assert.equal("tutor", session.batches[1][1].kind)

    comment_on(bufnr, "just a comment")
    assert.is_true(Weave.flush({ session = session }))
    assert.equal(1, #session.batches[2])
    assert.equal("user", session.batches[2][1].kind)
  end)

  it("says so instead of sending an empty turn", function()
    local session = tracked()
    assert.is_false(Weave.flush({ session = session }))
    assert.equal(0, #session.batches)
    assert.equal(1, #notifications)
    assert.truthy(notifications[1]:find("nothing to flush", 1, true))
  end)

  it("clears the comment draft and advances the edit cursor on delivery", function()
    local session = tracked()
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    comment_on(bufnr, "look")

    Weave.flush({ session = session })
    assert.is_nil(Feedback.draft())
    assert.equal(Log.head_id(), Sync._cursor(session))
    -- and a second flush has nothing left to say
    assert.is_false(Weave.flush({ session = session }))
  end)

  -- The delivery contract both halves ride on: a batch parked behind a dying
  -- turn is wiped, and neither half may count itself delivered.
  it("keeps both halves when the batch dies with a cancelled turn", function()
    local session = busy_session()
    Sync.watch(session)
    Settings.global():set("track_edits", true)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    comment_on(bufnr, "still mine")

    Weave.flush({ session = session })
    -- parked, not delivered: neither half has counted itself sent
    assert.equal(1, #Feedback.draft().comments)
    assert.equal(0, Sync._cursor(session))

    session:wipe()
    assert.equal(1, #Feedback.draft().comments)
    assert.equal(0, Sync._cursor(session))

    -- and the whole window rides again on the next flush, comments included
    edit(bufnr, { "three" })
    assert.is_true(Weave.flush({ session = session }))
    local batch = session.batches[2]
    assert.equal(2, #batch)
    assert.truthy(batch[1].text:find("\n+three", 1, true))
    assert.truthy(batch[2].text:find("still mine", 1, true))

    session:deliver()
    assert.is_nil(Feedback.draft())
    assert.equal(Log.head_id(), Sync._cursor(session))
  end)

  it("hands both halves back when the session is not ready", function()
    local session = unready_session()
    Sync.watch(session)
    Settings.global():set("track_edits", true)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    comment_on(bufnr, "mine")

    assert.is_false(Weave.flush({ session = session }))
    assert.equal(1, #Feedback.draft().comments)
    assert.equal(0, Sync._cursor(session))
  end)

  it("says which way to go when there is no session at all", function()
    assert.is_false(Weave.flush({}))
    assert.truthy(notifications[1]:find("No weave session", 1, true))
  end)

  -- A user who REPLACED the default sink meant it: their comments go THERE,
  -- and only the edits ride this session's turn. Replacing it by name is the
  -- documented way, so the check cannot be a name comparison.
  it("leaves the comments to a replaced default sink", function()
    local taken = {}
    Sinks.register({
      name = "weave",
      label = "somewhere else",
      send = function(text)
        taken[#taken + 1] = text
        return true
      end,
    })

    local session = tracked()
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    comment_on(bufnr, "mine")

    assert.is_true(Weave.flush({ session = session }))
    assert.equal(1, #taken)
    assert.truthy(taken[1]:find("mine", 1, true))
    -- only the edits went into the turn
    assert.equal(1, #session.batches[1])
    assert.equal("tutor", session.batches[1][1].kind)
  end)

  it("reports a send through a replaced sink even with no edits to carry", function()
    local Sinks_local = Sinks
    Sinks_local.register({
      name = "weave",
      send = function()
        return true
      end,
    })
    local session = tracked()
    local bufnr = open("a.lua", { "one" })
    comment_on(bufnr, "only a comment")

    assert.is_true(Weave.flush({ session = session }))
    assert.equal(0, #session.batches)
    assert.equal(0, #notifications)
  end)

  it("still honours a config prompt override for the edits preamble", function()
    local saved = Config.edits
    Config.edits = vim.tbl_extend("force", Config.edits, { edits_prompt = "[mine] here:" })
    local session = tracked()
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })

    Weave.flush({ session = session })
    assert.truthy(session.batches[1][1].text:find("[mine] here:", 1, true))
    Config.edits = saved
  end)
end)
