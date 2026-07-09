-- The plain-Lua session store (roadmap R2): the single source of truth the
-- ACP bridge mutates and the fibrous view projects. Contract carried over
-- from agentic's reactive/session_store.lua, minus nui-components signals:
--
--   * state snapshots: every mutation REASSIGNS store.state (and the changed
--     field inside it); unchanged values — including individual entry objects
--     — stay reference-stable. That reference stability is what fibrous's
--     `memo = true` bailout keys on, so the specs assert it with rawequal.
--   * subscribe/notify: subscribers fire once per mutation with the new
--     state; no-op calls don't notify.
--   * the permission FIFO: response-bearing requests are queued, never
--     overwritten — every respond closure is eventually called.

local SessionStore = require("weave.session_store")

local function collecting(store)
  local seen = {}
  local unsubscribe = store:subscribe(function(state)
    seen[#seen + 1] = state
  end)
  return seen, unsubscribe
end

local function permission(id, options)
  return {
    request = {
      toolCall = { toolCallId = id, kind = "execute" },
      options = options or { { optionId = "allow", kind = "allow_once" } },
    },
    respond = function() end,
  }
end

describe("session_store initial state", function()
  it("starts from the documented snapshot", function()
    local store = SessionStore:new()
    local s = store.state
    assert.same({}, s.entries)
    assert.same({}, s.tool_calls)
    assert.same({}, s.tool_call_order)
    assert.same({}, s.expanded)
    assert.same({}, s.plan)
    assert.equal("idle", s.status)
    assert.is_nil(s.permission)
    assert.equal(0, s.permission_count)
    assert.same({}, s.queued)
    assert.same({}, s.meta)
    assert.equal("normal", s.permission_mode)
  end)
end)

describe("session_store subscribe/notify", function()
  it("fires once per mutation with the new state, until unsubscribed", function()
    local store = SessionStore:new()
    local seen, unsubscribe = collecting(store)

    store:append_entry({ kind = "user", text = "hi" })
    assert.equal(1, #seen)
    assert.rawequal(store.state, seen[1])

    store:set_status("thinking")
    assert.equal(2, #seen)

    unsubscribe()
    store:set_status("idle")
    assert.equal(2, #seen)
  end)

  it("supports several independent subscribers", function()
    local store = SessionStore:new()
    local a = collecting(store)
    local b = collecting(store)
    store:append_entry({ kind = "user", text = "hi" })
    assert.equal(1, #a)
    assert.equal(1, #b)
  end)
end)

describe("session_store entries", function()
  it("append_entry reassigns state and the entries array", function()
    local store = SessionStore:new()
    local before = store.state
    store:append_entry({ kind = "user", text = "hi" })
    assert.is_false(rawequal(before, store.state))
    assert.is_false(rawequal(before.entries, store.state.entries))
    -- the old snapshot is untouched (reassign, not mutate)
    assert.equal(0, #before.entries)
    assert.same({ { kind = "user", text = "hi" } }, store.state.entries)
  end)

  it("keeps unchanged entry objects reference-stable across appends", function()
    local store = SessionStore:new()
    store:append_entry({ kind = "user", text = "hi" })
    local first = store.state.entries[1]
    store:append_entry({ kind = "agent", text = "hello" })
    assert.rawequal(first, store.state.entries[1])
  end)

  it("append_streaming_text coalesces same-kind chunks into a NEW last entry", function()
    local store = SessionStore:new()
    store:append_entry({ kind = "user", text = "hi" })
    local user_entry = store.state.entries[1]

    store:append_streaming_text("agent", "hel")
    local streamed = store.state.entries[2]
    store:append_streaming_text("agent", "lo")

    assert.same({ kind = "agent", text = "hello" }, store.state.entries[2])
    -- the streamed entry is REPLACED, not mutated: memo'd siblings stay
    -- stable, the growing one changes reference
    assert.is_false(rawequal(streamed, store.state.entries[2]))
    assert.rawequal(user_entry, store.state.entries[1])
    assert.equal(2, #store.state.entries)
  end)

  it("append_streaming_text starts a new entry on kind change", function()
    local store = SessionStore:new()
    store:append_streaming_text("thought", "hmm")
    store:append_streaming_text("agent", "so")
    assert.same({
      { kind = "thought", text = "hmm" },
      { kind = "agent", text = "so" },
    }, store.state.entries)
  end)

  it("append_streaming_text with empty text is a silent no-op", function()
    local store = SessionStore:new()
    local seen = collecting(store)
    local before = store.state
    store:append_streaming_text("agent", "")
    assert.equal(0, #seen)
    assert.rawequal(before, store.state)
  end)
end)

describe("session_store tool calls", function()
  it("first upsert inserts the block, the order entry, and a transcript marker", function()
    local store = SessionStore:new()
    store:append_entry({ kind = "user", text = "run it" })
    store:upsert_tool_call({ tool_call_id = "t1", title = "ls" })

    assert.same({ tool_call_id = "t1", title = "ls" }, store.state.tool_calls.t1)
    assert.same({ "t1" }, store.state.tool_call_order)
    assert.same({ kind = "tool_call", tool_call_id = "t1" }, store.state.entries[2])
  end)

  it("updates deep-merge by id without a second marker, keeping other blocks stable", function()
    local store = SessionStore:new()
    store:upsert_tool_call({ tool_call_id = "t1", title = "ls" })
    store:upsert_tool_call({ tool_call_id = "t2", title = "cat" })
    local t1 = store.state.tool_calls.t1
    local entries = store.state.entries

    store:upsert_tool_call({ tool_call_id = "t2", status = "completed" })

    assert.same({ tool_call_id = "t2", title = "cat", status = "completed" }, store.state.tool_calls.t2)
    assert.same({ "t1", "t2" }, store.state.tool_call_order)
    assert.rawequal(entries, store.state.entries) -- no new marker
    assert.rawequal(t1, store.state.tool_calls.t1) -- untouched sibling block
  end)

  it("toggle_tool_call flips per-id expansion, reassigning the map", function()
    local store = SessionStore:new()
    store:upsert_tool_call({ tool_call_id = "t1" })
    local before = store.state.expanded
    store:toggle_tool_call("t1")
    assert.is_true(store.state.expanded.t1)
    assert.is_false(rawequal(before, store.state.expanded))
    store:toggle_tool_call("t1")
    assert.falsy(store.state.expanded.t1)
  end)

  it("set_all_expanded seeds every ordered id / clears to empty", function()
    local store = SessionStore:new()
    store:upsert_tool_call({ tool_call_id = "t1" })
    store:upsert_tool_call({ tool_call_id = "t2" })
    store:set_all_expanded(true)
    assert.same({ t1 = true, t2 = true }, store.state.expanded)
    store:set_all_expanded(false)
    assert.same({}, store.state.expanded)
  end)
end)

describe("session_store plan sources", function()
  it("acp is authoritative: a later tool plan is ignored", function()
    local store = SessionStore:new()
    assert.is_true(store:set_plan({ { content = "a" } }, "acp"))
    assert.is_false(store:set_plan({ { content = "b" } }, "tool"))
    assert.same({ { content = "a" } }, store.state.plan)
  end)

  it("acp overrides an earlier tool plan; same source always replaces", function()
    local store = SessionStore:new()
    assert.is_true(store:set_plan({ { content = "t1" } }, "tool"))
    assert.is_true(store:set_plan({ { content = "t2" } }, "tool"))
    assert.same({ { content = "t2" } }, store.state.plan)
    assert.is_true(store:set_plan({ { content = "a" } }, "acp"))
    assert.same({ { content = "a" } }, store.state.plan)
  end)

  it("source defaults to acp", function()
    local store = SessionStore:new()
    store:set_plan({ { content = "a" } })
    assert.is_false(store:set_plan({ { content = "b" } }, "tool"))
  end)
end)

describe("session_store kiro task commands", function()
  it("create then complete applies deltas against remembered state", function()
    local store = SessionStore:new()
    assert.is_true(store:apply_kiro_task_command({
      command = "create",
      tasks = { { task_description = "one" }, { task_description = "two" } },
    }))
    -- complete has EMPTY output; it must be applied from input against the
    -- remembered list (the agentic bug this models)
    assert.is_true(store:apply_kiro_task_command({ command = "complete", completed_task_ids = { "2" } }))
    assert.same({
      { content = "one", status = "pending", priority = "medium" },
      { content = "two", status = "completed", priority = "medium" },
    }, store.state.plan)
  end)

  it("rejects unknown commands and complete-before-create", function()
    local store = SessionStore:new()
    assert.is_false(store:apply_kiro_task_command({ command = "delete" }))
    assert.is_false(store:apply_kiro_task_command({ command = "complete", completed_task_ids = { "1" } }))
    assert.is_false(store:apply_kiro_task_command("not a table"))
  end)

  it("defers to an established acp plan", function()
    local store = SessionStore:new()
    store:set_plan({ { content = "acp" } }, "acp")
    assert.is_true(store:apply_kiro_task_command({
      command = "create",
      tasks = { { task_description = "kiro" } },
    }))
    assert.same({ { content = "acp" } }, store.state.plan)
  end)
end)

describe("session_store status and meta", function()
  it("set_status replaces, set_meta merges", function()
    local store = SessionStore:new()
    store:set_status("generating")
    assert.equal("generating", store.state.status)
    store:set_meta({ provider = "Claude Agent ACP" })
    store:set_meta({ model = "claude-fable-5" })
    assert.same({ provider = "Claude Agent ACP", model = "claude-fable-5" }, store.state.meta)
  end)

  it("set_usage replaces the usage snapshot; reset clears it", function()
    local store = SessionStore:new()
    assert.is_nil(store.state.usage)
    store:set_usage({ used = 7837, size = 200000, cost = { amount = 0.42, currency = "USD" } })
    assert.equal(7837, store.state.usage.used)
    assert.equal(200000, store.state.usage.size)
    assert.equal(0.42, store.state.usage.cost.amount)
    -- replaced wholesale (not merged) by the next usage_update
    store:set_usage({ used = 9000, size = 200000 })
    assert.equal(9000, store.state.usage.used)
    assert.is_nil(store.state.usage.cost)
    -- a fresh conversation forgets it
    store:reset()
    assert.is_nil(store.state.usage)
  end)
end)

describe("session_store permission option ordering", function()
  local function ids(options)
    local out = {}
    for i, o in ipairs(options) do
      out[i] = o.optionId
    end
    return out
  end

  it("orders allow first (allow_once before allow_always), the rest kept stable", function()
    local ordered = SessionStore.order_permission_options({
      { optionId = "reject", kind = "reject_once" },
      { optionId = "always", kind = "allow_always" },
      { optionId = "once", kind = "allow_once" },
      { optionId = "reject_all", kind = "reject_always" },
    })
    assert.same({ "once", "always", "reject", "reject_all" }, ids(ordered))
  end)

  it("leaves order unchanged when there's no allow option", function()
    assert.same(
      { "a", "b" },
      ids(SessionStore.order_permission_options({
        { optionId = "a", kind = "reject_once" },
        { optionId = "b", kind = "reject_always" },
      }))
    )
  end)
end)

describe("session_store permission queue", function()
  it("enqueues FIFO, surfacing the head and the count", function()
    local store = SessionStore:new()
    local p1, p2 = permission("t1"), permission("t2")
    store:enqueue_permission(p1)
    store:enqueue_permission(p2)
    assert.rawequal(p1, store.state.permission)
    assert.rawequal(p1, store:get_permission())
    assert.equal(2, store.state.permission_count)
  end)

  it("surfaces the allow option at slot 1 (;;1) even when the agent sends it later", function()
    local store = SessionStore:new()
    store:enqueue_permission(permission("t1", {
      { optionId = "reject", kind = "reject_once" },
      { optionId = "allow", kind = "allow_once" },
    }))
    -- muscle memory: ;;1 must always approve, whatever order the provider used
    local opts = store.state.permission.request.options
    assert.equal("allow", opts[1].optionId)
    assert.equal("reject", opts[2].optionId)
  end)

  it("pop returns the head and promotes the next", function()
    local store = SessionStore:new()
    local p1, p2 = permission("t1"), permission("t2")
    store:enqueue_permission(p1)
    store:enqueue_permission(p2)
    assert.rawequal(p1, store:pop_permission())
    assert.rawequal(p2, store.state.permission)
    assert.equal(1, store.state.permission_count)
    assert.rawequal(p2, store:pop_permission())
    assert.is_nil(store:pop_permission())
    assert.is_nil(store.state.permission)
    assert.equal(0, store.state.permission_count)
  end)

  it("remove_permission_for_tool_call plucks from anywhere in the queue", function()
    local store = SessionStore:new()
    local p1, p2, p3 = permission("t1"), permission("t2"), permission("t3")
    store:enqueue_permission(p1)
    store:enqueue_permission(p2)
    store:enqueue_permission(p3)
    assert.rawequal(p2, store:remove_permission_for_tool_call("t2"))
    assert.rawequal(p1, store.state.permission) -- head untouched
    assert.equal(2, store.state.permission_count)
    assert.is_nil(store:remove_permission_for_tool_call("t9"))
  end)

  it("drain answers every queued respond with nil (cancelled) and empties", function()
    local store = SessionStore:new()
    local answered = {}
    for i = 1, 3 do
      store:enqueue_permission({
        request = { toolCall = { toolCallId = "t" .. i } },
        respond = function(option_id)
          answered[#answered + 1] = { i, option_id }
        end,
      })
    end
    store:drain_permissions()
    assert.same({ { 1 }, { 2 }, { 3 } }, answered)
    assert.is_nil(store.state.permission)
    assert.equal(0, store.state.permission_count)
  end)
end)

describe("session_store permission modes", function()
  it("set validates against the known modes", function()
    local store = SessionStore:new()
    store:set_permission_mode("auto")
    assert.equal("auto", store.state.permission_mode)
    store:set_permission_mode("yolo")
    assert.equal("auto", store.state.permission_mode)
  end)

  it("cycle steps normal → auto → allow_edits → normal", function()
    local store = SessionStore:new()
    assert.equal("auto", store:cycle_permission_mode())
    assert.equal("allow_edits", store:cycle_permission_mode())
    assert.equal("normal", store:cycle_permission_mode())
    assert.equal("normal", store.state.permission_mode)
  end)

  it("exposes the mode list and labels on the module", function()
    assert.same({ "normal", "auto", "allow_edits" }, SessionStore.PERMISSION_MODES)
    assert.equal("string", type(SessionStore.PERMISSION_MODE_LABEL.normal))
  end)
end)

describe("session_store auto_option_for (pure)", function()
  local auto_option_for = SessionStore.auto_option_for
  local function req(kind, options)
    return { toolCall = { toolCallId = "t", kind = kind }, options = options }
  end
  local ALLOW = {
    { optionId = "once", kind = "allow_once" },
    { optionId = "always", kind = "allow_always" },
  }

  it("normal surfaces everything", function()
    assert.is_nil(auto_option_for(req("edit", ALLOW), "normal"))
  end)

  it("auto prefers allow_once, falls back to allow_always", function()
    assert.equal("once", auto_option_for(req("execute", ALLOW), "auto"))
    assert.equal("always", auto_option_for(req("execute", { ALLOW[2] }), "auto"))
  end)

  it("never invents an option the agent didn't offer", function()
    assert.is_nil(auto_option_for(req("execute", { { optionId = "no", kind = "reject_once" } }), "auto"))
    assert.is_nil(auto_option_for(req("execute", nil), "auto"))
  end)

  it("allow_edits gates on the tool call kind", function()
    assert.equal("once", auto_option_for(req("edit", ALLOW), "allow_edits"))
    assert.is_nil(auto_option_for(req("execute", ALLOW), "allow_edits"))
  end)
end)

describe("session_store queued prompts", function()
  it("enqueue/dequeue is FIFO with a reassigned list", function()
    local store = SessionStore:new()
    store:enqueue_prompt("first")
    local before = store.state.queued
    store:enqueue_prompt("second")
    assert.is_false(rawequal(before, store.state.queued))
    assert.same({ "first", "second" }, store.state.queued)
    assert.equal("first", store:dequeue_prompt())
    assert.same({ "second" }, store.state.queued)
    assert.equal("second", store:dequeue_prompt())
    assert.is_nil(store:dequeue_prompt())
  end)

  it("clear_queue drops everything", function()
    local store = SessionStore:new()
    store:enqueue_prompt("a")
    store:clear_queue()
    assert.same({}, store.state.queued)
  end)
end)

describe("session_store reset", function()
  it("returns to the initial snapshot but keeps meta, cancelling permissions", function()
    local store = SessionStore:new()
    local cancelled = false
    store:append_entry({ kind = "user", text = "hi" })
    store:upsert_tool_call({ tool_call_id = "t1" })
    store:toggle_tool_call("t1")
    store:set_plan({ { content = "a" } }, "acp")
    store:set_status("busy")
    store:enqueue_prompt("later")
    store:set_meta({ provider = "P" })
    store:enqueue_permission({
      request = { toolCall = { toolCallId = "t1" } },
      respond = function(option_id)
        cancelled = option_id == nil
      end,
    })

    store:reset()

    assert.same({}, store.state.entries)
    assert.same({}, store.state.tool_calls)
    assert.same({}, store.state.tool_call_order)
    assert.same({}, store.state.expanded)
    assert.same({}, store.state.plan)
    assert.equal("idle", store.state.status)
    assert.same({}, store.state.queued)
    assert.is_nil(store.state.permission)
    assert.equal(0, store.state.permission_count)
    assert.is_true(cancelled)
    -- meta belongs to the client, not the session
    assert.same({ provider = "P" }, store.state.meta)
    -- plan ownership is forgotten: a tool plan applies again
    assert.is_true(store:set_plan({ { content = "k" } }, "tool"))
  end)
end)

describe("session_store hints", function()
  it("starts with a hint drawn from the exported HINTS list", function()
    local store = SessionStore:new()
    assert.is_true(vim.tbl_contains(SessionStore.HINTS, store.state.hint))
  end)

  it("rotate_hint commits a fresh hint from HINTS, one notify", function()
    local store = SessionStore:new()
    local seen = collecting(store)
    store:rotate_hint()
    assert.equal(1, #seen)
    assert.is_true(vim.tbl_contains(SessionStore.HINTS, store.state.hint))
  end)
end)

describe("session_store slash commands", function()
  it("starts with just the built-in /new", function()
    local store = SessionStore:new()
    assert.equal(1, #store.state.commands)
    assert.equal("new", store.state.commands[1].word)
  end)

  it("set_commands normalises ACP commands into completion items", function()
    local store = SessionStore:new()
    local seen = collecting(store)
    store:set_commands({
      { name = "plan", description = "Make a plan" },
      { name = "has space", description = "skipped: spaces" },
      { name = "clear", description = "skipped: agent-internal" },
      { name = "nodesc" },
    })
    assert.equal(1, #seen)
    local words = vim.tbl_map(function(item)
      return item.word
    end, store.state.commands)
    -- /new is always appended when the agent didn't send one
    assert.same({ "plan", "new" }, words)
    assert.equal("Make a plan", store.state.commands[1].menu)
    assert.equal("/", store.state.commands[1].kind)
  end)

  it("an agent-sent `new` is not duplicated", function()
    local store = SessionStore:new()
    store:set_commands({ { name = "new", description = "agent new" } })
    local words = vim.tbl_map(function(item)
      return item.word
    end, store.state.commands)
    assert.same({ "new" }, words)
  end)

  it("get_commands returns the raw list; reset restores the default", function()
    local store = SessionStore:new()
    store:set_commands({ { name = "plan", description = "d" } })
    assert.rawequal(store.state.commands, store:get_commands())
    store:reset()
    assert.equal(1, #store.state.commands)
    assert.equal("new", store.state.commands[1].word)
  end)
end)

describe("session_store transcript window", function()
  -- Bulk-append n user entries; returns the store.
  local function with_entries(n)
    local store = SessionStore:new()
    for i = 1, n do
      store:append_entry({ kind = "user", text = "e" .. i })
    end
    return store
  end

  local K = SessionStore.WINDOW

  it("exposes a positive window constant", function()
    assert.is_true(type(K) == "number" and K > 0)
  end)

  it("starts windowed at the first entry", function()
    assert.equal(1, SessionStore:new().state.window_start)
  end)

  it("follow_window keeps only the last WINDOW entries when following past K", function()
    local store = with_entries(K + 10)
    store:follow_window()
    -- oldest rendered index = total - K + 1
    assert.equal(11, store.state.window_start)
    assert.equal(K, #store.state.entries - store.state.window_start + 1)
  end)

  it("follow_window is a no-op (no collapse, no notify) at or below K entries", function()
    local store = with_entries(5)
    local seen, unsub = collecting(store)
    store:follow_window()
    assert.equal(1, store.state.window_start)
    assert.equal(0, #seen)
    unsub()
  end)

  it("follow_window only moves forward and doesn't renotify when already tight", function()
    local store = with_entries(K + 10)
    store:follow_window()
    local seen, unsub = collecting(store)
    store:follow_window()
    assert.equal(11, store.state.window_start)
    assert.equal(0, #seen)
    unsub()
  end)

  it("reveal_older steps back by WINDOW and clamps at 1", function()
    local store = with_entries(3 * K)
    store:follow_window() -- window_start = 2K + 1
    assert.equal(2 * K + 1, store.state.window_start)
    store:reveal_older()
    assert.equal(K + 1, store.state.window_start)
    store:reveal_older()
    assert.equal(1, store.state.window_start)
    -- clamped: another reveal changes nothing and doesn't notify
    local seen, unsub = collecting(store)
    store:reveal_older()
    assert.equal(1, store.state.window_start)
    assert.equal(0, #seen)
    unsub()
  end)

  it("reset returns the window to the first entry", function()
    local store = with_entries(3 * K)
    store:follow_window()
    assert.is_true(store.state.window_start > 1)
    store:reset()
    assert.equal(1, store.state.window_start)
  end)

  it("window mutations keep entry objects reference-stable (the memo contract)", function()
    local store = with_entries(K + 5)
    local before = store.state.entries[K + 5]
    store:follow_window()
    assert.rawequal(before, store.state.entries[K + 5])
  end)
end)
