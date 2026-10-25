local Store = require("weave.session_store")

describe("canonical transcript history", function()
  it("assigns distinct stable identities independently of rendering", function()
    local store = Store:new()
    store:append_entry({ kind = "user", text = "same" })
    store:append_entry({ kind = "user", text = "same" })
    local history = store:transcript()
    local a, b = history.records[1], history.records[2]
    assert.truthy(history.id)
    assert.is_false(a.id == b.id)
    assert.equal("same", a.entry.text)
    store:follow_window()
    assert.equal(a.id, store:transcript().records[1].id)
  end)

  it("preserves identity and increments revision as a message streams", function()
    local store = Store:new()
    store:append_streaming_text("agent", "first")
    local history = store:transcript()
    local before = history.records[1]
    store:append_streaming_text("agent", " second")
    local after = history.records[1]
    assert.equal(before.id, after.id)
    assert.equal(before.revision + 1, after.revision)
    assert.equal("first", before.entry.text)
    assert.equal("first second", after.entry.text)
    assert.is_false(rawequal(before, after))
  end)

  it("tracks tool revisions without creating another timeline entry", function()
    local store = Store:new()
    store:upsert_tool_call({ tool_call_id = "t", status = "in_progress" })
    local before = store:transcript().records[1]
    store:upsert_tool_call({ tool_call_id = "t", status = "completed", body = { "done" } })
    local after = store:transcript().records[1]
    assert.equal(1, #store:transcript().records)
    assert.equal(before.id, after.id)
    assert.equal(before.revision + 1, after.revision)
  end)

  it("starts a new identity on reset and never reuses an old entry id", function()
    local store = Store:new()
    store:append_entry({ kind = "user", text = "before" })
    local old = store:transcript()
    local id = old.records[1].id
    store:reset()
    store:append_entry({ kind = "user", text = "after" })
    assert.is_false(old.id == store:transcript().id)
    assert.is_nil(store:transcript():get(id))
    assert.equal("before", old:get(id).entry.text)
  end)

  it("keeps all entries when the view hides old history", function()
    local store = Store:new()
    for i = 1, 65 do store:append_entry({ kind = "user", text = "message " .. i }) end
    store:follow_window()
    assert.is_true(store.state.window_start > 1)
    assert.equal(65, #store:transcript().records)
    assert.equal("message 1", store:transcript().records[1].entry.text)
  end)
end)
