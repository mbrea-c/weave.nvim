-- The session state container: a plain-Lua single source of truth. The ACP
-- bridge mutates this store; the fibrous view subscribes and re-renders as a
-- pure projection of `state`. Contract carried over from agentic's
-- reactive/session_store.lua, with nui-components signals replaced by plain
-- snapshots + a subscriber list.
--
-- ── The reassign discipline ─────────────────────────────────────────────────
--
-- Every mutation REASSIGNS `store.state` (a shallow copy with the changed
-- fields replaced by fresh tables); nothing reachable from a published
-- snapshot is ever mutated in place. Consequences the view relies on:
--   * old snapshots stay valid — a subscriber can diff prev vs next by
--     reference (`prev.entries ~= next.entries` means the transcript changed).
--   * UNCHANGED values keep their identity, down to individual entry objects.
--     fibrous's `memo = true` bailout shallow-compares props, so a transcript
--     of N entries where one streamed re-renders exactly one component — but
--     only if the other N-1 entry tables are the same references as last
--     frame. The specs assert this with rawequal.
-- Subscribers fire synchronously, once per mutation, with the new state;
-- coalescing bursts (streaming!) into frames is the view's job, not ours.

--- A chat entry as rendered by the view. Tool calls keep their data in the
--- parallel keyed `tool_calls` table (so live updates are O(1)), but appear
--- in this ordered list as a lightweight `tool_call` marker so they render at
--- the point in the conversation where they occurred — not bunched at the end.
--- @class weave.store.ChatEntry
--- @field kind "user" | "agent" | "thought" | "tool_call"
--- @field text? string Present for user/agent/thought entries
--- @field tool_call_id? string Present for tool_call markers; key into tool_calls

--- @class weave.store.State
--- @field entries weave.store.ChatEntry[] Ordered chat transcript
--- @field tool_calls table<string, table> Tool call blocks keyed by tool_call_id
--- @field tool_call_order string[] Insertion order for stable rendering
--- @field expanded table<string, boolean> Per-tool-call expansion, keyed by tool_call_id (absent/false = collapsed)
--- @field plan table[] Latest plan snapshot (ACP PlanEntry[])
--- @field status "idle" | "thinking" | "generating" | "busy" Spinner/activity state
--- @field permission weave.store.PendingPermission|nil HEAD of the permission queue (the one shown); nil when none pending
--- @field permission_count integer Pending permission requests (head + waiting), for "1 of N" display
--- @field queued string[] Prompts queued while a turn is in flight (sent in order on turn end)
--- @field meta weave.store.SessionMeta Provider/agent/model/mode metadata
--- @field permission_mode weave.store.PermissionMode How incoming permission requests are answered
--- @field hint string Rotating UI hint shown in the sidebar (rotated each turn)
--- @field commands table[] Slash-command completion items (always includes /new)
--- @field usage weave.store.Usage|nil Session usage (context tokens + cost) from usage_update; nil until first reported

--- @class weave.store.SessionMeta
--- @field provider? string Provider display name (e.g. "Kiro ACP")
--- @field agent? string Agent name + version
--- @field model? string Current model id
--- @field mode? string Current mode / agent id
--- @field session_id? string

--- @class weave.store.Usage
--- @field used? integer Context tokens used
--- @field size? integer Context window size (total tokens)
--- @field cost? { amount: number, currency: string } Session cost so far, when the agent reports it

--- @class weave.store.PendingPermission
--- @field request table The ACP session/request_permission params
--- @field respond fun(option_id: string|nil): nil

--- Rotating sidebar hints: short, keybind-oriented tips; one shown at a time,
--- rotated on each turn end (see rotate_hint / the session's turn-end handler).
local HINTS = {
  "za toggles a tool call · zR expand all · zM collapse all",
  "<CR> on a tool-call header toggles it",
  "<C-s> submits · <C-x> steers (interrupts the current turn)",
  "<C-c> cancels the running turn",
  ";;t thinking · ;;d edit diffs · ;;c prettify markdown · ;;f follow",
  "Prompts sent mid-turn are queued and run when the turn ends",
  ";;1..;;9 answer a permission prompt by its option number",
  ";;p cycles permission mode (ask · auto · allow-edits)",
  "/new starts a fresh conversation",
}

--- A random hint from HINTS. Varying by call (not deterministic) is intended —
--- this is UI flavour, not workflow logic.
--- @return string hint
local function random_hint()
  return HINTS[math.random(#HINTS)]
end

--- The always-present `/new` command, in Neovim completion-item shape. Agents
--- may also send `new`; to_completion_items dedupes so it appears once.
local NEW_COMMAND = {
  word = "new",
  menu = "Start a new session",
  info = "Start a new session",
  kind = "/",
  icase = 1,
}

--- Normalise ACP available-commands into Neovim completion items: require
--- name+description, skip names with spaces and the agent-internal `clear`,
--- and guarantee `/new` is present.
--- @param available table[] ACP AvailableCommand[]
--- @return table[] items
local function to_completion_items(available)
  local items = {}
  local has_new = false
  for _, cmd in ipairs(available or {}) do
    if cmd.name and cmd.description and not cmd.name:match("%s") and cmd.name ~= "clear" then
      if cmd.name == "new" then
        has_new = true
      end
      items[#items + 1] = {
        word = cmd.name,
        menu = cmd.description,
        info = cmd.description,
        kind = "/",
        icase = 1,
      }
    end
  end
  if not has_new then
    items[#items + 1] = NEW_COMMAND
  end
  return items
end

-- ── Response-bearing requests: the queue pattern ────────────────────────────
--
-- Some agent→client ACP requests REQUIRE a response: the agent blocks on its
-- JSON-RPC id until we answer. `session/request_permission` is the only one
-- the UI mediates (fs/read|write are answered directly in ACPClient). The
-- agent can fire MANY at once — a read tool without trusted permission
-- reading 5 files spawns 5 concurrent permission requests.
--
-- THE BUG THIS PREVENTS: a single-slot `permission` field made each new
-- request overwrite the previous one. The overwritten request's `respond`
-- closure was lost, so its agent-side id was never answered → that tool call
-- hung in `pending` forever, and the prompt for it never reached the user.
--
-- THE PATTERN: hold ALL unanswered requests in a FIFO queue. Each carries its
-- own `respond` closure (which closes over the correct JSON-RPC id), so none
-- is ever dropped. Exactly one — the head — is surfaced at a time
-- (`state.permission`); answering it pops the head, fires that one's respond,
-- and promotes the next. Removal-by-id (terminal tool status) answers the
-- removed request `cancelled` so the agent is never left waiting.
--
-- This is the reusable shape for ANY future response-bearing request the UI
-- mediates: never store a single in-flight obligation in a scalar slot; queue
-- them, surface one, and guarantee every queued closure is eventually called
-- (answered or cancelled).

-- ── Permission modes ────────────────────────────────────────────────────────
--
-- A session-level policy for how incoming `session/request_permission`
-- requests are answered. Lives in the store (session-scoped, shared across
-- views, rendered in the sidebar); consulted by the bridge via
-- `auto_option_for`.
--
--   normal      — every request is surfaced to the user.
--   auto        — auto-allow ALL requests.
--   allow_edits — auto-allow EDIT tool calls; everything else is surfaced.
--
-- Auto-allowing never fabricates an outcome: it selects one of the request's
-- OWN options (preferring kind "allow_once", else "allow_always"). If a
-- request carries no allow option, it falls through to the user regardless of
-- mode — we never invent an optionId the agent didn't offer.
--
-- WHY allow_ONCE, not allow_always: "allow_always" tells the AGENT to persist
-- a standing grant for that tool. If the mode auto-selected it, switching
-- back to Normal would NOT restore prompting — the agent keeps the permanent
-- grant forever. "allow_once" grants exactly this invocation, so the mode is
-- the only thing keeping tools auto-allowed: turn it off and the next request
-- prompts again. The mode must be fully reversible.
--- @alias weave.store.PermissionMode "normal" | "auto" | "allow_edits"

--- Ordered for cycling in the UI.
--- @type weave.store.PermissionMode[]
local PERMISSION_MODES = { "normal", "auto", "allow_edits" }

--- Short human label per mode for the sidebar.
--- @type table<weave.store.PermissionMode, string>
local PERMISSION_MODE_LABEL = {
  normal = "Normal (ask)",
  auto = "Auto (allow all)",
  allow_edits = "Allow edits",
}

--- Pick the agent-offered option to auto-select for `request` under `mode`,
--- or nil to surface the request to the user. Pure (no store access) so it's
--- unit-testable. Prefers "allow_once", then "allow_always" (see the WHY note
--- above); returns nil if the mode doesn't auto-allow this request or no
--- allow option exists.
--- @param request table The ACP RequestPermission params
--- @param mode weave.store.PermissionMode
--- @return string|nil option_id
local function auto_option_for(request, mode)
  if mode == "normal" or not request then
    return nil
  end

  if mode == "allow_edits" then
    local tc = request.toolCall
    if not (tc and tc.kind == "edit") then
      return nil -- only edits auto-allow in this mode
    end
  end
  -- mode == "auto" allows everything; allow_edits has passed the edit gate.

  -- Match on the ACP-standard PermissionOptionKind (allow_once/allow_always/
  -- reject_once/reject_always). The spec calls `kind` a "hint", so a provider
  -- COULD omit or mis-set it: if no allow_* kind is found we return nil and
  -- surface the request to the user — never guess an option to auto-allow.
  local fallback
  for _, opt in ipairs(request.options or {}) do
    if opt.kind == "allow_once" then
      return opt.optionId -- reversible grant, prefer it (see WHY note)
    elseif opt.kind == "allow_always" and not fallback then
      fallback = opt.optionId -- only if the agent offers no once-option
    end
  end
  return fallback
end

--- @class weave.store.SessionStore
--- @field state weave.store.State The current snapshot (never mutated in place)
--- @field _subscribers fun(state: weave.store.State)[]
--- @field _permission_queue weave.store.PendingPermission[] FIFO of pending permission requests; state.permission mirrors the head
local SessionStore = {}
SessionStore.__index = SessionStore

-- Mode metadata + the pure decision, exposed for the bridge, the view, and
-- unit tests.
SessionStore.PERMISSION_MODES = PERMISSION_MODES
SessionStore.PERMISSION_MODE_LABEL = PERMISSION_MODE_LABEL
SessionStore.auto_option_for = auto_option_for
SessionStore.HINTS = HINTS

--- @return weave.store.SessionStore store
function SessionStore:new()
  local instance = {
    --- @type weave.store.State
    state = {
      entries = {},
      tool_calls = {},
      tool_call_order = {},
      expanded = {},
      plan = {},
      status = "idle",
      permission = nil,
      permission_count = 0,
      queued = {},
      meta = {},
      permission_mode = "normal",
      hint = random_hint(),
      commands = to_completion_items({}),
      usage = nil,
    },
    _subscribers = {},
    _permission_queue = {},
  }
  return setmetatable(instance, self)
end

--- Subscribe to state changes. `fn(state)` fires synchronously after every
--- mutation with the new snapshot. Returns an unsubscribe function.
--- @param fn fun(state: weave.store.State)
--- @return fun() unsubscribe
function SessionStore:subscribe(fn)
  local subs = self._subscribers
  subs[#subs + 1] = fn
  return function()
    for i, f in ipairs(subs) do
      if f == fn then
        table.remove(subs, i)
        return
      end
    end
  end
end

--- Publish the next snapshot: shallow-copy the current state, let `mutate`
--- reassign fields on the draft (fresh tables only — never touch values the
--- old snapshot reaches), swap it in, notify. Every mutation funnels through
--- here, so "one mutation, one notify" holds by construction.
--- @private
--- @param mutate fun(draft: weave.store.State)
function SessionStore:_commit(mutate)
  local draft = {}
  for k, v in pairs(self.state) do
    draft[k] = v
  end
  mutate(draft)
  self.state = draft
  -- iterate a copy so subscribers may unsubscribe (themselves) mid-notify
  for _, fn in ipairs({ unpack(self._subscribers) }) do
    fn(draft)
  end
end

--- Append a chat entry (reassigning the list — see the discipline note).
--- @param entry weave.store.ChatEntry
function SessionStore:append_entry(entry)
  self:_commit(function(draft)
    local entries = vim.list_extend({}, draft.entries)
    entries[#entries + 1] = entry
    draft.entries = entries
  end)
end

--- Append text to the last entry when it matches `kind`, else start a new
--- one. Agent/thought chunks stream token-by-token; coalescing avoids one
--- entry per token. The growing entry is REPLACED with a new object (its
--- siblings keep their identity), so a memo'd per-entry view re-renders
--- exactly the streaming component.
--- @param kind "agent" | "thought"
--- @param text string
function SessionStore:append_streaming_text(kind, text)
  if text == "" then
    return
  end
  self:_commit(function(draft)
    local entries = vim.list_extend({}, draft.entries)
    local last = entries[#entries]
    if last and last.kind == kind then
      entries[#entries] = { kind = kind, text = last.text .. text }
    else
      entries[#entries + 1] = { kind = kind, text = text }
    end
    draft.entries = entries
  end)
end

--- Insert or update a tool call block by id, preserving first-seen order.
--- First sight also places a `tool_call` marker in the transcript timeline at
--- the point the call appeared, so it renders inline with surrounding
--- messages; subsequent updates only touch the keyed block.
--- @param block table Must carry `tool_call_id`
function SessionStore:upsert_tool_call(block)
  local id = block.tool_call_id
  self:_commit(function(draft)
    local calls = vim.tbl_extend("force", {}, draft.tool_calls)
    local existing = calls[id]
    if existing then
      calls[id] = vim.tbl_deep_extend("force", existing, block)
    else
      calls[id] = block

      local order = vim.list_extend({}, draft.tool_call_order)
      order[#order + 1] = id
      draft.tool_call_order = order

      local entries = vim.list_extend({}, draft.entries)
      entries[#entries + 1] = { kind = "tool_call", tool_call_id = id }
      draft.entries = entries
    end
    draft.tool_calls = calls
  end)
end

--- Flip one tool call's expansion.
--- @param tool_call_id string
function SessionStore:toggle_tool_call(tool_call_id)
  self:_commit(function(draft)
    local expanded = vim.tbl_extend("force", {}, draft.expanded)
    expanded[tool_call_id] = not expanded[tool_call_id] or nil
    draft.expanded = expanded
  end)
end

--- Expand or collapse every known tool call at once. Collapsing resets to an
--- empty table; expanding seeds every ordered id true.
--- @param value boolean
function SessionStore:set_all_expanded(value)
  self:_commit(function(draft)
    local expanded = {}
    if value then
      for _, id in ipairs(draft.tool_call_order) do
        expanded[id] = true
      end
    end
    draft.expanded = expanded
  end)
end

--- Set the task/plan list, recording its SOURCE so two providers of plan data
--- don't clobber each other. The standard ACP plan channel ("acp") is
--- authoritative: once an agent has sent a real ACP plan, the Kiro tool-call
--- mirror ("tool") must NOT overwrite it. Same-source updates always replace
--- (ACP's contract is "send the full list each time").
--- @param entries table[] ACP PlanEntry[]
--- @param source "acp" | "tool" | nil Defaults to "acp" (the standard channel)
--- @return boolean applied false if a lower-priority source was ignored
function SessionStore:set_plan(entries, source)
  source = source or "acp"
  if source == "tool" and self._plan_source == "acp" then
    return false
  end
  self._plan_source = source
  self:_commit(function(draft)
    draft.plan = entries
  end)
  return true
end

-- ── Kiro task-list tool (stateful) ──────────────────────────────────────────
--
-- Kiro doesn't use ACP's plan channel; it drives a STATEFUL task-list tool
-- with commands. We keep the canonical task list here (id-ordered) and
-- re-project it into the plan (source "tool") after each command, so
-- completion deltas are applied against remembered state:
--   create   — input.tasks = [{ task_description, ... }]; (re)establishes the
--              list. ids are assigned 1..N (Kiro's output uses string ids).
--   complete — input.completed_task_ids = ["1","3"]; marks those done. Output
--              is EMPTY on this command, so it MUST be applied from input
--              against the remembered list (the bug this fixes).
--   update   — input.tasks may replace/extend; treated like create if present.
-- Unknown/!tool commands are ignored. Defers to an ACP plan via set_plan.

--- Apply a Kiro task-list tool-call input to the remembered task state and
--- re-project the plan. Returns true if this was a recognized task command.
--- @param input table The tool call's rawInput (.command, .tasks, .completed_task_ids)
--- @return boolean handled
function SessionStore:apply_kiro_task_command(input)
  if type(input) ~= "table" or type(input.command) ~= "string" then
    return false
  end
  local cmd = input.command

  if cmd == "create" or cmd == "update" then
    local tasks = input.tasks
    if type(tasks) ~= "table" then
      return false
    end
    -- (Re)build the id-ordered task list. Kiro numbers tasks "1".."N".
    local list = {}
    for i, t in ipairs(tasks) do
      list[#list + 1] = {
        id = tostring(i),
        content = t.task_description or t.content or "(task)",
        completed = t.completed == true,
      }
    end
    self._kiro_tasks = list
  elseif cmd == "complete" then
    local ids = input.completed_task_ids
    if type(ids) ~= "table" or not self._kiro_tasks then
      return false
    end
    local done = {}
    for _, id in ipairs(ids) do
      done[tostring(id)] = true
    end
    -- _kiro_tasks is private (never published), so in-place is fine here
    for _, t in ipairs(self._kiro_tasks) do
      if done[t.id] then
        t.completed = true
      end
    end
  else
    return false -- unrecognized command (e.g. delete/clear not yet modeled)
  end

  -- Project to PlanEntry[] and publish via the source-aware setter.
  local plan = {}
  for _, t in ipairs(self._kiro_tasks or {}) do
    plan[#plan + 1] = {
      content = t.content,
      status = t.completed and "completed" or "pending",
      priority = "medium",
    }
  end
  self:set_plan(plan, "tool")
  return true
end

--- @param status "idle" | "thinking" | "generating" | "busy"
function SessionStore:set_status(status)
  self:_commit(function(draft)
    draft.status = status
  end)
end

--- Merge fields into the session metadata (provider/agent/model/mode).
--- @param meta weave.store.SessionMeta
function SessionStore:set_meta(meta)
  self:_commit(function(draft)
    draft.meta = vim.tbl_extend("force", {}, draft.meta, meta)
  end)
end

--- Replace the session usage snapshot (from ACP usage_update). Replaced
--- wholesale, not merged — each usage_update carries the full current totals.
--- @param usage weave.store.Usage
function SessionStore:set_usage(usage)
  self:_commit(function(draft)
    draft.usage = usage
  end)
end

--- Mirror the head of the permission queue into the snapshot so the view
--- shows the current request + a "1 of N" count. Every queue mutation ends by
--- calling this. See the queue-pattern note above.
--- @private
function SessionStore:_publish_permission_head()
  self:_commit(function(draft)
    draft.permission = self._permission_queue[1]
    draft.permission_count = #self._permission_queue
  end)
end

--- Current permission mode (read synchronously by the bridge).
--- @return weave.store.PermissionMode
function SessionStore:get_permission_mode()
  return self.state.permission_mode
end

--- Set the permission mode (validated against PERMISSION_MODES; ignored if not).
--- @param mode weave.store.PermissionMode
function SessionStore:set_permission_mode(mode)
  if PERMISSION_MODE_LABEL[mode] then
    self:_commit(function(draft)
      draft.permission_mode = mode
    end)
  end
end

--- Advance to the next permission mode (for a cycle keybind) and return it.
--- @return weave.store.PermissionMode mode The new mode
function SessionStore:cycle_permission_mode()
  local current = self.state.permission_mode
  local idx = 1
  for i, m in ipairs(PERMISSION_MODES) do
    if m == current then
      idx = i
      break
    end
  end
  local next_mode = PERMISSION_MODES[(idx % #PERMISSION_MODES) + 1]
  self:set_permission_mode(next_mode)
  return next_mode
end

--- Enqueue a permission request (FIFO). Never overwrites an in-flight request
--- — that was the bug. The head is surfaced; the rest wait their turn.
--- @param permission weave.store.PendingPermission
function SessionStore:enqueue_permission(permission)
  self._permission_queue[#self._permission_queue + 1] = permission
  self:_publish_permission_head()
end

--- The currently-shown (head) permission, or nil when the queue is empty.
--- @return weave.store.PendingPermission|nil
function SessionStore:get_permission()
  return self._permission_queue[1]
end

--- Remove the head permission (answered by the caller) and promote the next.
--- The caller is responsible for having invoked the head's `respond`; this
--- only manages the queue. Returns the removed head, or nil if empty.
--- @return weave.store.PendingPermission|nil removed
function SessionStore:pop_permission()
  if #self._permission_queue == 0 then
    return nil
  end
  local removed = table.remove(self._permission_queue, 1)
  self:_publish_permission_head()
  return removed
end

--- Remove (and return) the queued permission whose tool call matches `id`,
--- wherever it sits in the queue — used when a tool reaches a terminal status
--- before the user answered. The caller answers the removed request
--- `cancelled` so the agent is never left waiting. Returns nil if none matched.
--- @param tool_call_id string
--- @return weave.store.PendingPermission|nil removed
function SessionStore:remove_permission_for_tool_call(tool_call_id)
  for i, p in ipairs(self._permission_queue) do
    local tc = p.request and p.request.toolCall
    if tc and tc.toolCallId == tool_call_id then
      local removed = table.remove(self._permission_queue, i)
      self:_publish_permission_head()
      return removed
    end
  end
  return nil
end

--- Answer every queued permission `cancelled` and empty the queue. Used on
--- reset/teardown so no agent-side request is left waiting (its id would hang
--- forever). respond(nil) sends the cancelled outcome.
function SessionStore:drain_permissions()
  for _, p in ipairs(self._permission_queue) do
    pcall(p.respond, nil)
  end
  self._permission_queue = {}
  self:_publish_permission_head()
end

--- Append a prompt to the queue (held while a turn is in flight). The
--- transcript renders queued prompts distinctly.
--- @param text string
function SessionStore:enqueue_prompt(text)
  self:_commit(function(draft)
    local queued = vim.list_extend({}, draft.queued)
    queued[#queued + 1] = text
    draft.queued = queued
  end)
end

--- Remove and return the oldest queued prompt, or nil when the queue is empty.
--- @return string|nil text
function SessionStore:dequeue_prompt()
  local current = self.state.queued
  if #current == 0 then
    return nil
  end
  local text = current[1]
  self:_commit(function(draft)
    local queued = vim.list_extend({}, draft.queued)
    table.remove(queued, 1)
    draft.queued = queued
  end)
  return text
end

--- Pick a fresh random hint for the sidebar. Called on each turn end.
function SessionStore:rotate_hint()
  self:_commit(function(draft)
    draft.hint = random_hint()
  end)
end

--- Replace the slash-command list from an ACP available_commands_update.
--- Normalised + always includes /new (see to_completion_items).
--- @param available table[] ACP AvailableCommand[]
function SessionStore:set_commands(available)
  self:_commit(function(draft)
    draft.commands = to_completion_items(available)
  end)
end

--- Current completion items. Read synchronously by the prompt's completefunc.
--- @return table[] items
function SessionStore:get_commands()
  return self.state.commands
end

--- Drop all queued prompts (e.g. on explicit cancel / reset).
function SessionStore:clear_queue()
  self:_commit(function(draft)
    draft.queued = {}
  end)
end

--- Clear all session state back to the initial snapshot (e.g. on /new).
--- meta persists across reset: it belongs to the client, not the session,
--- and is re-applied when a new session is created.
function SessionStore:reset()
  self._plan_source = nil -- forget which source owned the plan
  self._kiro_tasks = nil -- forget remembered Kiro task-list state
  self:_commit(function(draft)
    draft.entries = {}
    draft.tool_calls = {}
    draft.tool_call_order = {}
    draft.expanded = {}
    draft.plan = {}
    draft.status = "idle"
    draft.queued = {}
    -- a fresh session re-announces its commands; back to just /new meanwhile
    draft.commands = to_completion_items({})
    draft.usage = nil -- forget the previous conversation's token/cost tally
  end)
  -- Cancel + clear pending permissions so the agent isn't left waiting; this
  -- also resets state.permission / permission_count via _publish.
  self:drain_permissions()
end

return SessionStore
