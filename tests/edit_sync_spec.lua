-- weave.edit_sync: user edits reaching a conversation, driven by settings
-- rather than a mode — auto_send_edits/debounce_ms/edit_gate per session,
-- track_edits globally. The session is a double here: edit_sync only ever
-- calls send_system on it, and the real send lane has its own specs in
-- session_spec.

local Config = require("weave.config")
local Log = require("weave.revision_log")
local Permissions = require("weave.permissions")
local Settings = require("weave.settings")
local Sync = require("weave.edit_sync")

--- @return table session double recording what edit_sync sent it
--- An IDLE real session dispatches immediately (see session_spec's delivery
--- contract): accepted, on_sent fired before send_system returns.
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

--- A session mid-turn: accepts sends but PARKS them (the steer queue). The
--- spec decides each message's fate afterwards — deliver() fires its on_sent
--- (the turn ended and the queue drained), wipe() its on_dropped (cancel /
--- /new / restore emptied the queue under it).
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

describe("edit sync", function()
  local root, saved_edits, saved_notify, notifications

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

  --- Watch the session and flip one of its sync settings on.
  local function enable(session, key)
    Sync.watch(session)
    Settings.for_session(session):set(key or "auto_send_edits", true)
  end

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    saved_edits = vim.deepcopy(Config.edits)
    notifications = {}
    saved_notify = vim.notify
    vim.notify = function(msg)
      notifications[#notifications + 1] = msg
    end
    Permissions._reset()
    Permissions.set_project_root(root)
    Sync._reset()
    Settings._reset()
    Log._reset()
  end)

  after_each(function()
    Sync._reset()
    Settings._reset()
    Log._reset()
    Config.edits = saved_edits
    vim.notify = saved_notify
    Permissions._reset()
    vim.fn.delete(root, "rf")
  end)

  it("does not collect at all until something asks for it", function()
    assert.is_false(Log.collecting())
  end)

  it("collection follows the global track_edits switch", function()
    Sync.init()
    Settings.global():set("track_edits", true)
    assert.is_true(Log.collecting())
    Settings.global():set("track_edits", false)
    assert.is_false(Log.collecting())
  end)

  it("turns tracking on (out loud) when a session starts syncing without it", function()
    local session = fake_session()
    enable(session)

    assert.is_true(Settings.global():get("track_edits"))
    assert.is_true(Log.collecting())
    assert.equal(1, #notifications)
    -- and only says it once: the second session finds tracking already on
    local other = fake_session()
    enable(other)
    assert.equal(1, #notifications)
  end)

  it("keeps tracking when a session stops syncing — the global switch is explicit", function()
    local session = fake_session()
    enable(session)
    Settings.for_session(session):set("auto_send_edits", false)
    assert.is_true(Log.collecting())
    -- and the cursor stays with it: auto-send is one road out of three, and
    -- an explicit flush still needs somewhere to measure "unseen" from. This
    -- is the shape tutor mode runs in now (tracking on, auto-send off).
    assert.is_not_nil(Sync._cursor(session))
  end)

  it("flushes on demand with auto-send and the gate both off", function()
    local session = fake_session()
    Sync.watch(session)
    Settings.global():set("track_edits", true)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })

    assert.is_true(Sync.flush_now(session))
    assert.truthy(session.sent[1].text:find("\n+two", 1, true))
  end)

  it("drops the cursor when collection stops, and starts a fresh one when it resumes", function()
    local session = fake_session()
    Sync.watch(session)
    Settings.global():set("track_edits", true)
    assert.is_not_nil(Sync._cursor(session))

    Settings.global():set("track_edits", false)
    assert.is_nil(Sync._cursor(session))
    -- and turning it back off does not turn it back on behind the user's back
    assert.is_false(Settings.global():get("track_edits"))

    Settings.global():set("track_edits", true)
    assert.is_not_nil(Sync._cursor(session))
  end)

  -- The global switch is the user's to hold: a session with auto-send on must
  -- not silently re-enable collection they just turned off.
  it("does not re-arm collection when the user switches it off under a syncing session", function()
    local session = fake_session()
    enable(session)
    Settings.global():set("track_edits", false)

    assert.is_false(Settings.global():get("track_edits"))
    assert.is_false(Log.collecting())
    assert.is_nil(Sync._cursor(session))
  end)

  it("sends the squashed diff of everything since its last send", function()
    local session = fake_session()
    enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    edit(bufnr, { "three" })
    Sync.flush_now(session)

    local sent = session.sent[1]
    assert.truthy(sent.text:find("--- a/a.lua", 1, true))
    -- squashed: the intermediate "two" never appears, only one -> three
    assert.truthy(sent.text:find("\n-one", 1, true))
    assert.truthy(sent.text:find("\n+three", 1, true))
    assert.is_nil(sent.text:find("\n+two", 1, true))
    assert.truthy(sent.label:find("1 file"))
  end)

  it("sends nothing when nothing changed", function()
    local session = fake_session()
    enable(session)
    Sync.flush_now(session)
    assert.equal(0, #session.sent)
  end)

  it("sends nothing for a session that never opted in", function()
    local session = fake_session()
    Sync.watch(session)
    assert.is_false(Sync.flush_now(session))
    assert.is_nil(Sync._cursor(session))
  end)

  it("advances its cursor, so the next flush repeats nothing", function()
    local session = fake_session()
    enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    Sync.flush_now(session)
    assert.equal(1, #session.sent)
    Sync.flush_now(session)
    assert.equal(1, #session.sent)
  end)

  -- A window the user edited and then reverted has nothing to say, but it must
  -- still be stepped over: leaving the cursor behind it means re-squashing the
  -- same dead revisions on every flush forever.
  it("steps past a window that netted no change", function()
    local session = fake_session()
    enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    edit(bufnr, { "one" })
    Sync.flush_now(session)

    assert.equal(0, #session.sent)
    assert.equal(Log.head_id(), Sync._cursor(session))
  end)

  it("gives each session its own cursor", function()
    local a, b = fake_session(), fake_session()
    enable(a)
    enable(b)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    Sync.flush_now(a)
    edit(bufnr, { "three" })
    Sync.flush_now(a)
    Sync.flush_now(b)

    -- a saw two windows: one->two, then two->three
    assert.truthy(a.sent[1].text:find("\n+two", 1, true))
    assert.truthy(a.sent[2].text:find("\n+three", 1, true))
    -- b saw one window covering both
    assert.truthy(b.sent[1].text:find("\n-one", 1, true))
    assert.truthy(b.sent[1].text:find("\n+three", 1, true))
    assert.is_nil(b.sent[1].text:find("\n+two", 1, true))
  end)

  it("honours on_flush = queue for the debounced send", function()
    Config.edits = vim.tbl_extend("force", Config.edits, { on_flush = "queue" })
    local session = fake_session()
    enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    Sync.flush(session)
    assert.is_false(session.sent[1].interrupt)
  end)

  -- flush_now is the impatient path: the user asked for it THIS second, so it
  -- interrupts whatever the config says about the timer-driven send.
  it("interrupts on flush_now even when the debounced send would queue", function()
    Config.edits = vim.tbl_extend("force", Config.edits, { on_flush = "queue" })
    local session = fake_session()
    enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    Sync.flush_now(session)
    assert.is_true(session.sent[1].interrupt)
  end)

  -- The lost-edits bug: flush used to advance the cursor when it HANDED the
  -- diff to the session, but a send parked behind an active turn dies with
  -- cancel//new/restore, and one refused by a not-ready session never went
  -- anywhere — precisely the moments the user is editing over the agent's
  -- shoulder. The cursor moves only on actual dispatch (on_sent).
  it("holds its cursor until the send actually dispatches", function()
    local session = busy_session()
    enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    Sync.flush_now(session)

    assert.equal(0, Sync._cursor(session)) -- parked, not delivered
    session:deliver()
    assert.equal(Log.head_id(), Sync._cursor(session))
  end)

  it("resends the whole window when a queued send is wiped with its dying turn", function()
    local session = busy_session()
    enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    Sync.flush_now(session)
    session:wipe() -- cancel / /new emptied the steer queue under the diff

    edit(bufnr, { "three" })
    Sync.flush_now(session)
    local resent = session.sent[#session.sent]
    -- the wiped edits ride again, squashed with what came after
    assert.truthy(resent.text:find("\n-one", 1, true))
    assert.truthy(resent.text:find("\n+three", 1, true))

    session:deliver()
    Sync.flush_now(session)
    assert.equal(2, #session.sent) -- two flushes, nothing more
  end)

  it("retries instead of skipping when the session refuses the send", function()
    local session = fake_session()
    enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })

    local ready = false
    local dispatch = session.send_system
    function session:send_system(opts)
      if not ready then
        return false -- what a not-ready real session reports
      end
      return dispatch(self, opts)
    end

    assert.is_false(Sync.flush_now(session))
    assert.equal(0, Sync._cursor(session)) -- window still pending
    ready = true
    assert.is_true(Sync.flush_now(session))
    assert.truthy(session.sent[#session.sent].text:find("\n+two", 1, true))
    assert.equal(Log.head_id(), Sync._cursor(session))
  end)

  describe("the gate's questions (edit_gate without auto-send)", function()
    it("tracks a cursor for a gate-only session and reports unseen edits", function()
      local session = fake_session()
      enable(session, "edit_gate")
      assert.is_false(Sync.pending(session))

      local bufnr = open("a.lua", { "one" })
      edit(bufnr, { "two" })
      assert.is_true(Sync.pending(session))
      assert.equal(0, #session.sent) -- the gate is pulled, never pushed
    end)

    it("counts what the user is typing RIGHT NOW by closing the burst", function()
      local session = fake_session()
      enable(session, "edit_gate")
      local bufnr = open("a.lua", { "one" })
      -- mid-burst: changed but not yet closed into a revision
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "two" })
      Log.note_change(bufnr)
      assert.is_true(Sync.pending(session))
    end)

    it("consume hands the squashed window over and advances the cursor", function()
      local session = fake_session()
      enable(session, "edit_gate")
      local bufnr = open("a.lua", { "one" })
      edit(bufnr, { "two" })
      edit(bufnr, { "three" })

      local diff = Sync.consume(session)
      assert.truthy(diff:find("\n-one", 1, true))
      assert.truthy(diff:find("\n+three", 1, true))
      assert.is_nil(diff:find("\n+two", 1, true))

      assert.is_false(Sync.pending(session))
      assert.is_nil(Sync.consume(session))
    end)

    it("consume steps over a window that netted no change", function()
      local session = fake_session()
      enable(session, "edit_gate")
      local bufnr = open("a.lua", { "one" })
      edit(bufnr, { "two" })
      edit(bufnr, { "one" })
      assert.is_nil(Sync.consume(session))
      assert.equal(Log.head_id(), Sync._cursor(session))
    end)

    it("auto-send and the gate share one cursor — either road marks it seen", function()
      local session = fake_session()
      enable(session)
      Settings.for_session(session):set("edit_gate", true)
      local bufnr = open("a.lua", { "one" })
      edit(bufnr, { "two" })

      Sync.flush_now(session) -- delivered: the fake session dispatches at once
      assert.is_false(Sync.pending(session))

      edit(bufnr, { "three" })
      assert.is_true(Sync.pending(session))
      assert.truthy(Sync.consume(session):find("\n+three", 1, true))
      Sync.flush_now(session)
      assert.equal(1, #session.sent) -- consumed window is not re-sent
    end)
  end)
end)

-- The debounce is "quiet for a while OR waited long enough", which a
-- continuously-typing user needs: an idle-only timer would never fire for them.
describe("edit sync debounce", function()
  local cfg = { debounce_ms = 15000, max_wait_ms = 60000 }

  it("waits out the idle window when there is time to spare", function()
    assert.equal(15000, Sync._delay({ first_pending_at = 1000 }, 1000, cfg))
  end)

  it("shortens to the deadline as the max wait approaches", function()
    -- 55s into the window: 5s left, which is sooner than another idle 15s
    assert.equal(5000, Sync._delay({ first_pending_at = 0 }, 55000, cfg))
  end)

  it("never asks for a negative delay once the deadline has passed", function()
    assert.equal(0, Sync._delay({ first_pending_at = 0 }, 90000, cfg))
  end)

  it("treats a first change as starting the window now", function()
    assert.equal(15000, Sync._delay({}, 42000, cfg))
  end)
end)
