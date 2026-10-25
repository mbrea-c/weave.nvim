local Registry = require("weave.registry")
local Config = require("weave.config")
local Context = require("weave.tool_context")
local Permissions = require("weave.permissions")

describe("authenticated transcript recall", function()
  local provider
  before_each(function()
    Registry.reset(); Permissions._reset()
    provider = Config.acp_providers["recall-test"]
    Config.acp_providers["recall-test"] = { name = "Recall test", command = "unused" }
  end)
  after_each(function()
    Registry.reset(); Permissions._reset()
    Config.acp_providers["recall-test"] = provider
  end)
  local function session(parent)
    local entry = Registry.add({ provider = "recall-test", parent_key = parent and parent.key,
      get_instance = function(_, cb)
        local client = { state = "connected" }
        function client:create_session(_, reply) reply({ sessionId = tostring(self) }) end
        function client:cancel_session() end
        function client:cancel_turn() end
        cb(client); return client
      end })
    assert.is_true(vim.wait(1000, function() return entry.session:is_ready() end, 5))
    return entry, { caller = Context.authenticate(Context.bind(entry.session)) }
  end
  local function query(name, args, ctx)
    return vim.json.decode(require("weave.tools.transcript")[name].handler(args or {}, ctx))
  end

  it("uses the authenticated conversation, not UI selection, and requires identity", function()
    local a, ctx = session()
    local b = session()
    a.session:get_store():append_entry({ kind = "user", text = "OWN_SECRET" })
    b.session:get_store():append_entry({ kind = "user", text = "OTHER_SECRET" })
    Registry.select(b.key)
    local out = query("search", { query = "SECRET" }, ctx)
    assert.equal(a.key, out.session_key)
    assert.equal(1, #out.items)
    assert.equal("OWN_SECRET", out.items[1].text)
    assert.has_error(function() query("search", { query = "SECRET" }) end)
    Context.revoke(a.session)
    assert.has_error(function() query("search", { query = "SECRET" }, ctx) end)
  end)

  it("permits descendants but refuses parents, siblings, unrelated roots and forged IDs", function()
    local root, root_ctx = session()
    local child, child_ctx = session(root)
    local sibling = session(root)
    local unrelated = session()
    child.session:get_store():append_entry({ kind = "agent", text = "CHILD_ANSWER" })
    assert.equal(1, #query("search", { query = "ANSWER", session_key = child.key }, root_ctx).items)
    for _, key in ipairs({ root.key, sibling.key, unrelated.key, 999999 }) do
      assert.has_error(function() query("search", { query = "SECRET", session_key = key }, child_ctx) end)
    end
    assert.has_error(function() query("search", { query = "x", caller = root.key }, child_ctx) end)
  end)

  it("finds hidden entries, but never thoughts, drafts, or previous recall outputs", function()
    local entry, ctx = session()
    local store = entry.session:get_store()
    store:append_entry({ kind = "user", text = "needle from long ago" })
    store:append_streaming_text("thought", "needle PRIVATE_THOUGHT")
    store:upsert_tool_call({ tool_call_id = "recall", mcp = { server = "clankbox", tool = "weave_transcript_read" },
      body = { "needle recursive previous result" } })
    for i = 1, 40 do store:append_entry({ kind = "agent", text = "later " .. i }) end
    store:follow_window()
    local out = query("search", { query = "needle", include_tool_output = true }, ctx)
    assert.equal(1, #out.items)
    assert.equal("needle from long ago", out.items[1].text)
    assert.has_error(function() query("search", { query = "needle", kinds = { "thought" } }, ctx) end)
  end)

  it("paginates a fixed entry boundary while new messages arrive", function()
    local entry, ctx = session()
    local store = entry.session:get_store()
    for i = 1, 4 do store:append_entry({ kind = "user", text = "needle " .. i }) end
    local first = query("search", { query = "needle", limit = 2 }, ctx)
    assert.equal(2, #first.items)
    assert.is_not_nil(first.next_cursor)
    store:append_entry({ kind = "user", text = "needle new" })
    local second = query("search", { query = "needle", limit = 2, cursor = first.next_cursor }, ctx)
    assert.equal(2, #second.items)
    assert.is_false(first.items[2].entry_id == second.items[1].entry_id)
    assert.is_nil(second.next_cursor)
    store:reset()
    assert.has_error(function() query("search", { query = "needle", cursor = first.next_cursor }, ctx) end)
  end)

  it("reads exact entries with bounded Unicode pagination and context", function()
    local entry, ctx = session()
    local store = entry.session:get_store()
    store:append_entry({ kind = "user", text = "preceding" })
    store:append_entry({ kind = "agent", text = ("界é"):rep(200) })
    store:append_entry({ kind = "user", text = "following" })
    local id = store:transcript().records[2].id
    local out = query("read", { entry_id = id, max_chars = 64 }, ctx)
    assert.equal(64, vim.fn.strchars(out.entry.text))
    assert.equal(64, out.entry.next_offset)
    local next_page = query("read", { entry_id = id, offset = out.entry.next_offset, max_chars = 64 }, ctx)
    assert.equal(("界é"):rep(32), next_page.entry.text)
    local full = query("read", { entry_id = id, before = 1, after = 1 }, ctx)
    assert.equal("preceding", full.context_before[1].text)
    assert.equal("following", full.context_after[1].text)
    assert.is_false(full.complete_provider_history)
    assert.has_error(function() query("read", { entry_id = "unrelated:e1" }, ctx) end)
  end)

  it("requires explicit tool output retrieval and validates all bounds", function()
    local entry, ctx = session()
    local store = entry.session:get_store()
    store:upsert_tool_call({ tool_call_id = "t", kind = "read", argument = "a.lua",
      body = { "OUTPUT_ONLY_NEEDLE" } })
    assert.equal(0, #query("search", { query = "OUTPUT_ONLY_NEEDLE" }, ctx).items)
    assert.equal(1, #query("search", { query = "OUTPUT_ONLY_NEEDLE", include_tool_output = true }, ctx).items)
    for _, args in ipairs({ { query = "" }, { query = "x", limit = 0 }, { query = "x", max_chars = 999999 },
      { query = "x", cursor = {} }, { query = "x", session_key = 0 } }) do
      assert.has_error(function() query("search", args, ctx) end)
    end
  end)

  it("registers prefixed tools behind normal permission checks", function()
    local tools, server = require("weave.tools"), { defs = {} }
    function server.register_tool(name, def) server.defs[name] = def end
    tools.register_into(server)
    assert.is_not_nil(server.defs.weave_transcript_search)
    assert.is_not_nil(server.defs.weave_transcript_read)
    assert.is_true(tools.OWNS.weave_transcript_search)
    local entry, ctx = session()
    entry.session:permissions().save_preset({ name = "deny-recall", rules = {
      { tool = "weave:transcript_*", decision = "deny" },
    } })
    entry.session:permissions().set_active("deny-recall")
    local out
    server.defs.weave_transcript_search.handler({ query = "secret" }, function(value) out = value end, ctx)
    assert.is_true(out.isError)
  end)
end)
