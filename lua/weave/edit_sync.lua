-- weave.edit_sync: keeps conversations in sync with the USER's edits. What
-- used to be "tutor mode" decomposed into orthogonal settings (weave.settings)
-- — the tutor is now just a preset that flips several of these at once:
--
--   track_edits (global)       collection on/off. There is ONE revision log
--                              (weave.revision_log), so its switch is global.
--   auto_send_edits (session)  debounced squashed diffs to this conversation.
--   debounce_ms (session)      the quiet window before a batch goes.
--   edit_gate (session)        agent writes held behind unseen edits — the
--                              refusal itself lives with the tools; it asks
--                              pending()/consume() here.
--
-- Per session there is ONE cursor into the log — "what this conversation has
-- seen" — shared by auto-send and the gate, because "seen" is one concept:
-- a diff that reached the agent by either road needs no second delivery.
-- The cursor advances only when a send actually dispatches (on_sent) or a
-- consume() hands the window to a tool result; a send that dies in a wiped
-- steer queue keeps its window unsent and re-squashed into the next one.
-- Better twice than never — sends are state sync, and squash makes a resend
-- cheap.
--
-- The debounce is "quiet for a while OR waited long enough". Idle alone would
-- never fire for someone who types continuously, which is precisely the user
-- auto-send is for.
--
-- Settings drive everything: watch(session) subscribes to the session's
-- settings store, and the sidebar checkbox, the settings window and presets
-- are then all the same door. Flipping auto_send_edits or edit_gate on while
-- tracking is off turns track_edits on too (with a notify) — a dead toggle
-- that silently does nothing would be worse than a dependency resolved out
-- loud.

local Config = require("weave.config")
local Log = require("weave.revision_log")
local Revision = require("weave.revision")
local Settings = require("weave.settings")

local M = {}

--- @class weave.edit_sync.State
--- @field cursor integer last revision id DELIVERED to this session
--- @field first_pending_at integer|nil ms when the oldest unsent change landed
--- @field timer uv.uv_timer_t|nil

--- Per-session state, weak-keyed: a session that goes away takes its sync
--- state with it without anything having to remember to unregister.
--- @type table<table, weave.edit_sync.State>
local states = setmetatable({}, { __mode = "k" })
--- Sessions already subscribed to their settings store.
--- @type table<table, boolean>
local watched = setmetatable({}, { __mode = "k" })
local log_unsubscribe = nil
local global_effect_attached = false

--- @return weave.EditsConfig
local function cfg()
  return Config.edits or {}
end

--- @return integer ms
function M._now()
  return math.floor(vim.uv and vim.uv.now() or vim.loop.now())
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

--- @param state weave.edit_sync.State
local function disarm(state)
  if state.timer then
    pcall(function()
      state.timer:stop()
    end)
    state.timer = nil
  end
end

--- @param session table
--- @param state weave.edit_sync.State
local function arm(session, state)
  disarm(state)
  local delay = M._delay(state, M._now(), {
    debounce_ms = Settings.for_session(session):get("debounce_ms"),
    max_wait_ms = cfg().max_wait_ms or 60000,
  })
  state.timer = vim.defer_fn(function()
    state.timer = nil
    M.flush(session)
  end, delay)
end

--- Every auto-sending session hears about every revision; each decides for
--- itself when its own window is worth sending. Gate-only sessions keep
--- their cursor but never a timer — the gate is pulled, not pushed.
local function on_revision()
  local now = M._now()
  for session, state in pairs(states) do
    if Settings.for_session(session).state.auto_send_edits then
      state.first_pending_at = state.first_pending_at or now
      arm(session, state)
    end
  end
end

local function ensure_log_subscription()
  if next(states) ~= nil then
    if not log_unsubscribe then
      log_unsubscribe = Log.subscribe(on_revision)
    end
  elseif log_unsubscribe then
    log_unsubscribe()
    log_unsubscribe = nil
  end
end

--- Attach the track_edits effect: the one global setting with a body — the
--- revision log's collection switch. Idempotent; called from setup() and
--- from the first watch(), whichever comes first.
function M.init()
  if global_effect_attached then
    return
  end
  global_effect_attached = true
  local global = Settings.global()
  local last = global.state.track_edits
  global:subscribe(function(state)
    if state.track_edits ~= last then
      last = state.track_edits
      if last then
        Log.start()
      else
        Log.stop()
      end
    end
  end)
  if last then
    Log.start()
  end
end

--- @param state table<string, any> a session settings snapshot
--- @return boolean
local function is_active(state)
  return state.auto_send_edits == true or state.edit_gate == true
end

--- React to a session settings snapshot (prev == nil on first sight). The
--- cursor starts at the log's head on activation: what the user did BEFORE
--- this conversation cared is not its business.
--- @param session table
--- @param prev table<string, any>|nil
--- @param state table<string, any>
function M._on_settings(session, prev, state)
  local was = prev ~= nil and is_active(prev)
  local active = is_active(state)

  if active and not states[session] then
    states[session] = { cursor = Log.head_id() }
  elseif not active and states[session] then
    disarm(states[session])
    states[session] = nil
  end
  ensure_log_subscription()

  if active and not was then
    local global = Settings.global()
    if not global:get("track_edits") then
      global:set("track_edits", true)
      vim.notify("weave: edit sync needs collection — Track user edits is now on", vim.log.levels.INFO)
    end
  end
end

--- Start driving this session from its settings store. Idempotent. The
--- subscriber holds the session through a WEAK ref: the settings store lives
--- in a weak-keyed map keyed by the session, so a strong capture here would
--- pin the key via its own value and the session could never be collected.
--- @param session table
function M.watch(session)
  if watched[session] then
    return
  end
  watched[session] = true
  M.init()
  local store = Settings.for_session(session)
  local ref = setmetatable({ session }, { __mode = "v" })
  local last = store.state
  store:subscribe(function(state)
    local s = ref[1]
    if not s then
      return
    end
    local prev = last
    last = state
    M._on_settings(s, prev, state)
  end)
  M._on_settings(session, nil, store.state)
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
  -- Doubles (and anything else driving a Session-shaped object) may return
  -- nothing; treat only an explicit false as a refusal.
  return accepted ~= false
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

--- Send this session's unsent window now, whatever the debounce thinks. This
--- is the impatient path — bind it and stop waiting.
--- @param session table|nil
--- @return boolean sent
function M.flush_now(session)
  return M.flush(session, { interrupt = true })
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
  -- whatever came after.
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

--- Whether this session has edits it has not seen — the gate's question.
--- Closes the burst first so what the user is typing RIGHT NOW counts: the
--- middle of their thought is exactly the wrong moment for an agent write.
--- @param session table|nil
--- @return boolean
function M.pending(session)
  local state = session and states[session]
  if not state then
    return false
  end
  Log.close_burst()
  return Log.head_id() > state.cursor
end

--- Hand the unseen window over as a rendered diff (a tool result), advancing
--- the cursor. Advancing at hand-off is safe HERE because a tool result
--- reaches the conversation synchronously — unlike a send, it cannot be
--- wiped out of a queue; the residual risk (turn cancelled after the tool
--- ran) is accepted, and the next gate refusal would surface it again.
--- Returns nil when there is nothing unseen.
--- @param session table|nil
--- @return string|nil diff
function M.consume(session)
  local state = session and states[session]
  if not state then
    return nil
  end
  Log.close_burst()
  local head = Log.head_id()
  local rev = Log.squash_since(state.cursor)
  state.cursor = head
  state.first_pending_at = nil
  if not rev then
    return nil
  end
  local ok, Permissions = pcall(require, "weave.permissions")
  local root = ok and Permissions.project_root() or nil
  return Revision.render(rev, { root = root, max_bytes = cfg().max_diff_bytes })
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
  watched = setmetatable({}, { __mode = "k" })
  if log_unsubscribe then
    log_unsubscribe()
    log_unsubscribe = nil
  end
  global_effect_attached = false
end

return M
