-- weave.tutor: the mode that turns the agent into a tutor watching over your
-- shoulder. Per SESSION (it is a property of one conversation), while
-- collection is editor-global and runs whenever ANY session has it on.
--
-- The session is a double here: tutor only ever calls send_system/is_ready on
-- it, and the real send lane has its own specs in session_spec.

local Config = require("weave.config")
local Log = require("weave.revision_log")
local Permissions = require("weave.permissions")
local Tutor = require("weave.tutor")

--- @return table session double recording what tutor sent it
local function fake_session()
  local session = { sent = {} }
  function session:is_ready()
    return true
  end
  function session:send_system(opts)
    self.sent[#self.sent + 1] = opts
  end
  return session
end

describe("tutor mode", function()
  local root, saved_tutor

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

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    saved_tutor = vim.deepcopy(Config.tutor)
    Permissions._reset()
    Permissions.set_project_root(root)
    Tutor._reset()
    Log._reset()
  end)

  after_each(function()
    Tutor._reset()
    Log._reset()
    Config.tutor = saved_tutor
    Permissions._reset()
    vim.fn.delete(root, "rf")
  end)

  it("announces itself to the agent on the way in, interrupting", function()
    local session = fake_session()
    Tutor.enable(session)

    assert.is_true(Tutor.is_on(session))
    assert.equal(1, #session.sent)
    assert.is_true(session.sent[1].interrupt)
    assert.truthy(session.sent[1].text:lower():find("tutor"))
    assert.is_true(Log.collecting())
  end)

  it("announces the way out too, and stops collecting", function()
    local session = fake_session()
    Tutor.enable(session)
    Tutor.disable(session)

    assert.is_false(Tutor.is_on(session))
    assert.equal(2, #session.sent)
    assert.is_true(session.sent[2].interrupt)
    assert.is_false(Log.collecting())
  end)

  it("is idempotent in both directions, so a stray toggle says nothing twice", function()
    local session = fake_session()
    Tutor.enable(session)
    Tutor.enable(session)
    assert.equal(1, #session.sent)
    Tutor.disable(session)
    Tutor.disable(session)
    assert.equal(2, #session.sent)
  end)

  it("keeps collecting while ANY session still has it on", function()
    local a, b = fake_session(), fake_session()
    Tutor.enable(a)
    Tutor.enable(b)
    Tutor.disable(a)
    assert.is_true(Log.collecting())
    Tutor.disable(b)
    assert.is_false(Log.collecting())
  end)

  it("sends the squashed diff of everything since its last send", function()
    local session = fake_session()
    Tutor.enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    edit(bufnr, { "three" })
    Tutor.flush_now(session)

    local sent = session.sent[2]
    assert.truthy(sent.text:find("--- a/a.lua", 1, true))
    -- squashed: the intermediate "two" never appears, only one -> three
    assert.truthy(sent.text:find("\n-one", 1, true))
    assert.truthy(sent.text:find("\n+three", 1, true))
    assert.is_nil(sent.text:find("\n+two", 1, true))
    assert.truthy(sent.label:find("1 file"))
  end)

  it("sends nothing when nothing changed", function()
    local session = fake_session()
    Tutor.enable(session)
    Tutor.flush_now(session)
    assert.equal(1, #session.sent)
  end)

  it("advances its cursor, so the next flush repeats nothing", function()
    local session = fake_session()
    Tutor.enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    Tutor.flush_now(session)
    assert.equal(2, #session.sent)
    Tutor.flush_now(session)
    assert.equal(2, #session.sent)
  end)

  -- A window the user edited and then reverted has nothing to say, but it must
  -- still be stepped over: leaving the cursor behind it means re-squashing the
  -- same dead revisions on every flush forever.
  it("steps past a window that netted no change", function()
    local session = fake_session()
    Tutor.enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    edit(bufnr, { "one" })
    Tutor.flush_now(session)

    assert.equal(1, #session.sent)
    assert.equal(Log.head_id(), Tutor._cursor(session))
  end)

  it("gives each session its own cursor", function()
    local a, b = fake_session(), fake_session()
    Tutor.enable(a)
    Tutor.enable(b)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    Tutor.flush_now(a)
    edit(bufnr, { "three" })
    Tutor.flush_now(a)
    Tutor.flush_now(b)

    -- a saw two windows: one->two, then two->three
    assert.truthy(a.sent[2].text:find("\n+two", 1, true))
    assert.truthy(a.sent[3].text:find("\n+three", 1, true))
    -- b saw one window covering both
    assert.truthy(b.sent[2].text:find("\n-one", 1, true))
    assert.truthy(b.sent[2].text:find("\n+three", 1, true))
    assert.is_nil(b.sent[2].text:find("\n+two", 1, true))
  end)

  it("honours on_flush = queue for the debounced send", function()
    Config.tutor = vim.tbl_extend("force", Config.tutor, { on_flush = "queue" })
    local session = fake_session()
    Tutor.enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    Tutor.flush(session)
    assert.is_false(session.sent[2].interrupt)
  end)

  -- flush_now is the impatient path: the user asked for it THIS second, so it
  -- interrupts whatever the config says about the timer-driven send.
  it("interrupts on flush_now even when the debounced send would queue", function()
    Config.tutor = vim.tbl_extend("force", Config.tutor, { on_flush = "queue" })
    local session = fake_session()
    Tutor.enable(session)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    Tutor.flush_now(session)
    assert.is_true(session.sent[2].interrupt)
  end)

  it("does not collect at all until some session turns it on", function()
    assert.is_false(Log.collecting())
  end)
end)

-- The debounce is "quiet for a while OR waited long enough", which a
-- continuously-typing user needs: an idle-only timer would never fire for them.
describe("tutor debounce", function()
  local cfg = { debounce_ms = 15000, max_wait_ms = 60000 }

  it("waits out the idle window when there is time to spare", function()
    assert.equal(15000, Tutor._delay({ first_pending_at = 1000 }, 1000, cfg))
  end)

  it("shortens to the deadline as the max wait approaches", function()
    -- 55s into the window: 5s left, which is sooner than another idle 15s
    assert.equal(5000, Tutor._delay({ first_pending_at = 0 }, 55000, cfg))
  end)

  it("never asks for a negative delay once the deadline has passed", function()
    assert.equal(0, Tutor._delay({ first_pending_at = 0 }, 90000, cfg))
  end)

  it("treats a first change as starting the window now", function()
    assert.equal(15000, Tutor._delay({}, 42000, cfg))
  end)
end)
