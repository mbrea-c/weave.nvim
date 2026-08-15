-- weave.tutor: the agent watches you work instead of waiting to be asked.
--
-- Per SESSION, because it is a property of one conversation — you can have a
-- tutor in one panel and an ordinary assistant in another. Collection is
-- editor-global though, and runs whenever ANY session has the mode on: there
-- is one revision log (weave.revision_log) and each tutor session holds a
-- CURSOR into it, so two sessions debouncing at different phases each get
-- exactly their own unseen window and neither consumes the other's.
--
-- Three things reach the agent, all through Session:send_system so none of
-- them read as words the user typed:
--
--   * going in and coming out. The mode is invisible to the agent otherwise,
--     and an agent that does not know it is tutoring will answer the diffs as
--     if they were requests.
--   * each batch of edits, squashed. Not twelve revisions — one revision
--     spanning twelve, so a line typed and retyped five times arrives as
--     whatever it finally says.
--
-- The debounce is "quiet for a while OR waited long enough". Idle alone would
-- never fire for someone who types continuously, which is precisely the user
-- this mode is for.

local Config = require("weave.config")
local Log = require("weave.revision_log")
local Revision = require("weave.revision")

local M = {}

--- @class weave.tutor.State
--- @field cursor integer last revision id sent to this session
--- @field first_pending_at integer|nil ms when the oldest unsent change landed
--- @field timer uv.uv_timer_t|nil

--- Per-session state, weak-keyed: a session that goes away takes its tutor
--- state with it without anything having to remember to unregister.
--- @type table<table, weave.tutor.State>
local states = setmetatable({}, { __mode = "k" })
local unsubscribe = nil

--- @return weave.TutorConfig
local function cfg()
  return Config.tutor or {}
end

--- @return integer ms
function M._now()
  return math.floor(vim.uv and vim.uv.now() or vim.loop.now())
end

--- The session a bare call acts on: the one selected in this tabpage.
--- @param session table|nil
--- @return table|nil
local function resolve(session)
  if session then
    return session
  end
  local ok, Registry = pcall(require, "weave.registry")
  local entry = ok and Registry.selected() or nil
  return entry and entry.session or nil
end

--- How long until this session should flush: the idle window, or whatever is
--- left of the hard ceiling, whichever comes first. Pure, so the policy is
--- specced without waiting out real timers.
--- @param state { first_pending_at?: integer }
--- @param now integer
--- @param conf { debounce_ms: integer, max_wait_ms: integer }
--- @return integer ms
function M._delay(state, now, conf)
  local waited = now - (state.first_pending_at or now)
  return math.max(0, math.min(conf.debounce_ms, conf.max_wait_ms - waited))
end

--- @param state weave.tutor.State
local function disarm(state)
  if state.timer then
    pcall(function()
      state.timer:stop()
    end)
    state.timer = nil
  end
end

--- @param session table
--- @param state weave.tutor.State
local function arm(session, state)
  disarm(state)
  local conf = cfg()
  local delay = M._delay(state, M._now(), {
    debounce_ms = conf.debounce_ms or 7000,
    max_wait_ms = conf.max_wait_ms or 60000,
  })
  state.timer = vim.defer_fn(function()
    state.timer = nil
    M.flush(session)
  end, delay)
end

--- Every tutoring session hears about every revision; each decides for itself
--- when its own window is worth sending.
local function on_revision()
  local now = M._now()
  for session, state in pairs(states) do
    state.first_pending_at = state.first_pending_at or now
    arm(session, state)
  end
end

--- Mirror the mode into the session's store, which is what the sidebar
--- checkbox reads. Guarded rather than assumed: tutor is driven by a plain
--- session object here and by a double in the specs.
--- @param session table
--- @param on boolean
local function mirror(session, on)
  if type(session.get_store) ~= "function" then
    return
  end
  local ok, store = pcall(session.get_store, session)
  if ok and store and type(store.set_tutor) == "function" then
    store:set_tutor(on)
  end
end

--- @param session table
--- @param text string
--- @param label string
--- @param interrupt boolean
--- @param hooks { on_sent?: fun(), on_dropped?: fun() }|nil
--- @return boolean accepted
local function send(session, text, label, interrupt, hooks)
  if type(session.send_system) ~= "function" then
    return false
  end
  hooks = hooks or {}
  local accepted = session:send_system({
    text = text,
    label = label,
    interrupt = interrupt,
    on_sent = hooks.on_sent,
    on_dropped = hooks.on_dropped,
  })
  -- Older doubles (and anything else driving a Session-shaped object) return
  -- nothing; treat only an explicit false as a refusal.
  return accepted ~= false
end

--- @param session table|nil
--- @return boolean
function M.is_on(session)
  session = resolve(session)
  return session ~= nil and states[session] ~= nil
end

--- Sessions currently tutoring.
--- @return integer
function M.count()
  local n = 0
  for _ in pairs(states) do
    n = n + 1
  end
  return n
end

--- Turn tutor mode on for a session. The cursor starts at the log's head: what
--- the user did BEFORE the agent was asked to watch is not the agent's
--- business, and dumping the backlog as the first thing it sees would bury the
--- instructions that just told it what to do with diffs.
--- @param session table|nil defaults to the tabpage's selected session
--- @return boolean on
function M.enable(session)
  session = resolve(session)
  if not session then
    vim.notify("weave: no session to put in tutor mode", vim.log.levels.WARN)
    return false
  end
  if states[session] then
    return true
  end

  Log.start()
  if not unsubscribe then
    unsubscribe = Log.subscribe(on_revision)
  end
  states[session] = { cursor = Log.head_id() }
  mirror(session, true)
  send(session, cfg().enabled_prompt or "", "tutor mode on", true)
  return true
end

--- Turn it off. Collection keeps running while any OTHER session still wants
--- it; the log itself is never discarded, so toggling back on does not
--- retroactively claim the user did nothing meanwhile.
--- @param session table|nil
--- @return boolean on
function M.disable(session)
  session = resolve(session)
  if not session or not states[session] then
    return false
  end
  disarm(states[session])
  states[session] = nil
  mirror(session, false)
  send(session, cfg().disabled_prompt or "", "tutor mode off", true)

  if M.count() == 0 then
    if unsubscribe then
      unsubscribe()
      unsubscribe = nil
    end
    Log.stop()
  end
  return false
end

--- @param session table|nil
--- @return boolean on
function M.toggle(session)
  session = resolve(session)
  if not session then
    return M.enable(nil)
  end
  if states[session] then
    return M.disable(session)
  end
  return M.enable(session)
end

--- Send this session's unsent window now, whatever the debounce thinks. This
--- is the impatient path — bind it and stop waiting.
--- @param session table|nil
--- @return boolean sent
function M.flush_now(session)
  return M.flush(resolve(session), { interrupt = true })
end

--- @param rev weave.revision.Revision
--- @return string
local function label_for(rev)
  local s = Revision.summary(rev)
  local noun = s.files == 1 and "1 file" or (s.files .. " files")
  local parts = {}
  if s.created > 0 then
    parts[#parts + 1] = s.created .. " new"
  end
  if s.deleted > 0 then
    parts[#parts + 1] = s.deleted .. " deleted"
  end
  local extra = #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""
  return "sent " .. noun .. " you changed" .. extra
end

--- Send the window past this session's cursor, if it has anything in it.
--- @param session table|nil
--- @param opts { interrupt?: boolean }|nil
--- @return boolean sent
function M.flush(session, opts)
  opts = opts or {}
  if not session then
    return false
  end
  local state = states[session]
  if not state then
    return false
  end
  disarm(state)

  local head = Log.head_id()
  local rev = Log.squash_since(state.cursor)
  if not rev then
    -- Step over a window that netted no change: it has nothing to say, but
    -- leaving the cursor behind it means re-squashing the same dead revisions
    -- on every flush, forever.
    state.cursor = head
    state.first_pending_at = nil
    return false
  end

  local conf = cfg()
  local ok, Permissions = pcall(require, "weave.permissions")
  local root = ok and Permissions.project_root() or nil
  local diff = Revision.render(rev, { root = root, max_bytes = conf.max_diff_bytes })
  if not diff then
    state.cursor = head
    state.first_pending_at = nil
    return false
  end

  local interrupt = opts.interrupt
  if interrupt == nil then
    interrupt = (conf.on_flush or "interrupt") == "interrupt"
  end

  -- The cursor advances only when the diff actually reaches the wire. A send
  -- can be ACCEPTED and still die: parked behind an active turn, it is wiped
  -- by cancel//new/restore — precisely the moments the user is editing over
  -- the agent's shoulder, which made those edits vanish from tutoring. On a
  -- drop (or an outright refusal from a not-ready session) the window stays
  -- unsent and a retry is armed; the next flush re-squashes it together with
  -- whatever came after. Better twice than never — sends are state sync, and
  -- squash makes a resend cheap.
  local retry = function()
    local st = states[session]
    if st then
      st.first_pending_at = st.first_pending_at or M._now()
      arm(session, st)
    end
  end
  local accepted = send(session, (conf.edits_prompt or "") .. "\n\n" .. diff, label_for(rev), interrupt, {
    on_sent = function()
      local st = states[session]
      if st and head > st.cursor then
        st.cursor = head
      end
    end,
    on_dropped = retry,
  })
  if not accepted then
    retry()
    return false
  end
  state.first_pending_at = nil
  return true
end

--- @param session table
--- @return integer|nil
function M._cursor(session)
  local state = states[session]
  return state and state.cursor or nil
end

-- test hook
function M._reset()
  for _, state in pairs(states) do
    disarm(state)
  end
  states = setmetatable({}, { __mode = "k" })
  if unsubscribe then
    unsubscribe()
    unsubscribe = nil
  end
end

return M
