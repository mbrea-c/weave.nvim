-- weave.briefs: the `brief` setting reaching the agent. Announcements are
-- delivery-confirmed (announced moves only on on_sent) and re-established at
-- every conversation start — the construction that closes the old tutor gap
-- where /new silently forgot the mode.

local Briefs = require("weave.briefs")
local Config = require("weave.config")
local Settings = require("weave.settings")

local function fake_session()
  local session = { sent = {} }
  function session:is_ready()
    return true
  end
  function session:send_system(opts)
    self.sent[#self.sent + 1] = opts
    if opts.on_sent then
      opts.on_sent()
    end
    return true
  end
  return session
end

local function busy_session()
  local session = { sent = {} }
  function session:is_ready()
    return true
  end
  function session:send_system(opts)
    self.sent[#self.sent + 1] = opts
    return true
  end
  function session:deliver(i)
    local opts = self.sent[i or #self.sent]
    if opts and opts.on_sent then
      opts.on_sent()
    end
  end
  function session:wipe(i)
    local opts = self.sent[i or #self.sent]
    if opts and opts.on_dropped then
      opts.on_dropped()
    end
  end
  return session
end

describe("agent briefs", function()
  local saved_settings

  before_each(function()
    saved_settings = Config.settings
    Briefs._reset()
    Settings._reset()
  end)

  after_each(function()
    Config.settings = saved_settings
    Briefs._reset()
    Settings._reset()
  end)

  it("says nothing while the brief stays at the baseline", function()
    local session = fake_session()
    Briefs.watch(session)
    Briefs.on_conversation_ready(session)
    assert.equal(0, #session.sent)
  end)

  it("announces a switch to a non-default brief, interrupting", function()
    local session = fake_session()
    Briefs.watch(session)
    Settings.for_session(session):set("brief", "tutor")

    assert.equal(1, #session.sent)
    assert.is_true(session.sent[1].interrupt)
    assert.truthy(session.sent[1].text:lower():find("tutor"))
    assert.equal("brief: tutor", session.sent[1].label)
    assert.equal("tutor", Briefs._announced(session))
  end)

  it("announces the way back too — the default's prompt is the transition message", function()
    local session = fake_session()
    Briefs.watch(session)
    Settings.for_session(session):set("brief", "tutor")
    Settings.for_session(session):set("brief", "normal")

    assert.equal(2, #session.sent)
    assert.truthy(session.sent[2].text:lower():find("off"))
  end)

  it("does not repeat itself", function()
    local session = fake_session()
    Briefs.watch(session)
    Settings.for_session(session):set("brief", "tutor")
    Briefs.ensure(session)
    Briefs.ensure(session)
    assert.equal(1, #session.sent)
  end)

  it("re-announces a non-default brief to every fresh conversation", function()
    local session = fake_session()
    Briefs.watch(session)
    Settings.for_session(session):set("brief", "tutor")
    assert.equal(1, #session.sent)

    -- /new: the fresh conversation has heard nothing
    Briefs.on_conversation_ready(session)
    assert.equal(2, #session.sent)
    assert.truthy(session.sent[2].text:lower():find("tutor"))

    -- but a conversation born at the baseline stays silent
    Settings.for_session(session):set("brief", "normal")
    assert.equal(3, #session.sent) -- the transition message
    Briefs.on_conversation_ready(session)
    assert.equal(3, #session.sent) -- no fresh-conversation echo of the default
  end)

  it("holds the gap open until the announcement actually dispatches", function()
    local session = busy_session()
    Briefs.watch(session)
    Settings.for_session(session):set("brief", "tutor")

    assert.equal("normal", Briefs._announced(session)) -- parked, not heard
    session:deliver()
    assert.equal("tutor", Briefs._announced(session))
  end)

  it("retries an announcement whose parked send was wiped", function()
    local session = busy_session()
    Briefs.watch(session)
    Settings.for_session(session):set("brief", "tutor")
    session:wipe() -- cancel emptied the steer queue under it

    vim.wait(50, function()
      return #session.sent >= 2
    end)
    assert.equal(2, #session.sent) -- the drop rescheduled itself
    session:deliver()
    assert.equal("tutor", Briefs._announced(session))
  end)

  it("announces once a refusing session finally comes up", function()
    local session = fake_session()
    local ready = false
    local dispatch = session.send_system
    function session:send_system(opts)
      if not ready then
        return false
      end
      return dispatch(self, opts)
    end

    Briefs.watch(session)
    Settings.for_session(session):set("brief", "tutor")
    assert.equal("normal", Briefs._announced(session)) -- refused, still owed

    ready = true
    Briefs.on_conversation_ready(session) -- the session came up: ready sites fire this
    assert.equal(1, #session.sent)
    assert.equal("tutor", Briefs._announced(session))
  end)

  it("treats a brief with no prompt as heard for free", function()
    Config.settings = vim.tbl_deep_extend("force", {}, saved_settings, {
      briefs = { quiet = { prompt = "" } },
    })
    local session = fake_session()
    Briefs.watch(session)
    Settings.for_session(session):set("brief", "quiet")
    assert.equal(0, #session.sent)
    assert.equal("quiet", Briefs._announced(session))
  end)

  it("announces a user-configured brief from setup", function()
    Config.settings = vim.tbl_deep_extend("force", {}, saved_settings, {
      briefs = { architect = { prompt = "[weave] You are reviewing architecture only." } },
    })
    local session = fake_session()
    Briefs.watch(session)
    Settings.for_session(session):set("brief", "architect")
    assert.equal(1, #session.sent)
    assert.truthy(session.sent[1].text:find("architecture", 1, true))
    -- and a fresh conversation hears it again
    Briefs.on_conversation_ready(session)
    assert.equal(2, #session.sent)
  end)
end)
