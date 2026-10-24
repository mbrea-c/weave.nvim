local Config = require("weave.config")
local Registry = require("weave.registry")
local Session = require("weave.session")
local Settings = require("weave.settings")
local Sync = require("weave.edit_sync")
local Permissions = require("weave.permissions")
local Tools = require("weave.tools")

local function pump()
  vim.wait(40, function() return false end, 2)
end

local function options()
  return {
    { id = "model-opt", category = "model", name = "Model", description = "Choose a model",
      currentValue = "m1", options = {
        { value = "m1", name = "One", description = "Small model" },
        { value = "m2", name = "Two" }, { value = "m3", name = "Three" },
      } },
    { id = "effort-opt", category = "thought_level", name = "Effort", currentValue = "low",
      options = { { value = "low", name = "Low" }, { value = "high", name = "High" } } },
  }
end

local function client_for(id, config)
  local client = { state = "connected", requests = {}, created = 0 }
  function client:create_session(handlers, cb)
    self.created, self.handlers = self.created + 1, handlers
    cb({ sessionId = id, configOptions = config or options() })
  end
  function client:set_config_option(sid, key, value, cb)
    self.requests[#self.requests + 1] = { session_id = sid, id = key, value = value, cb = cb }
  end
  function client:cancel_session() end
  function client:cancel_turn() end
  return client
end

local function entry_for(id, overrides, config)
  local client = client_for(id or "session-a", config)
  local entry = Registry.add({ provider = "introspect-test", config_defaults = overrides,
    get_instance = function(_, cb) cb(client); return client end })
  pump()
  return entry, client
end

local function query(args)
  return vim.json.decode(require("weave.tools.session").introspect.handler(args or {}))
end

local function indexed(items, key)
  local out = {}
  for _, item in ipairs(items) do out[item[key]] = item end
  return out
end

describe("weave_session_introspect", function()
  local saved_provider, saved_settings
  before_each(function()
    Registry.reset()
    Sync._reset()
    Settings._reset()
    Permissions._reset()
    saved_provider, saved_settings = Config.acp_providers["introspect-test"], Config.settings
    Config.acp_providers["introspect-test"] = {
      name = "Introspection test",
      env = { API_KEY = "private-launch-secret" },
      args = { "--secret", "private-argument" },
      session_defaults = { ["model-opt"] = "m2", ["effort-opt"] = "high", future = "on" },
    }
    Config.settings = vim.deepcopy(Config.settings)
    Config.settings.defaults = vim.tbl_extend("force", Config.settings.defaults or {}, {
      debounce_ms = 9000, follow = false,
    })
  end)
  after_each(function()
    Registry.reset()
    Sync._reset()
    Settings._reset()
    Permissions._reset()
    Config.acp_providers["introspect-test"], Config.settings = saved_provider, saved_settings
  end)

  it("reports selected values, choices, descriptions and the effective default sources", function()
    local entry = entry_for("session-a", { ["model-opt"] = "m3" })
    Registry.select(entry.key)
    local out = query()
    assert.equal("session-a", out.session_id)
    assert.equal(entry.key, out.session_key)
    assert.equal("introspect-test", out.provider)
    assert.is_true(out.ready)
    local fields = indexed(out.config.fields, "id")
    local model = fields["model-opt"]
    assert.equal("m1", model.current)
    assert.equal("model", model.key)
    assert.equal("Choose a model", model.description)
    assert.same({ id = "m1", label = "One", description = "Small model" }, model.available[1])
    assert.equal("m3", model.default)
    assert.equal("session", model.default_source)
    assert.is_true(model.default_valid)
    assert.is_false(model.manual)
    assert.equal("provider", fields["effort-opt"].default_source)
    assert.equal("m2", out.config.defaults.provider["model-opt"])
    assert.equal("m3", out.config.defaults.session["model-opt"])
    assert.equal("m3", out.config.defaults.effective["model-opt"])
  end)

  it("includes defaults for fields not yet advertised", function()
    local entry = entry_for()
    Registry.select(entry.key)
    local future = indexed(query().config.fields, "id").future
    assert.is_false(future.advertised)
    assert.equal(vim.NIL, future.current)
    assert.equal("on", future.default)
    assert.is_false(future.default_valid)
    assert.same({}, future.available)
  end)

  it("distinguishes unavailable default values from missing fields and no default", function()
    local fields = options()
    fields[2].options = { { value = "low", name = "Low" } }
    fields[#fields + 1] = { id = "custom", name = "Custom", currentValue = "a",
      options = { { value = "a", name = "A" } } }
    local entry = entry_for("session-a", nil, fields)
    Registry.select(entry.key)
    local by_id = indexed(query().config.fields, "id")
    assert.is_true(by_id["effort-opt"].advertised)
    assert.is_false(by_id["effort-opt"].default_valid)
    assert.equal("high", by_id["effort-opt"].default)
    assert.equal(vim.NIL, by_id.custom.default)
    assert.equal(vim.NIL, by_id.custom.default_source)
  end)

  it("reports manual intent and in-flight/queued writes without callbacks", function()
    local entry, client = entry_for("session-a", { ["model-opt"] = "m3" })
    Registry.select(entry.key)
    entry.session:set_config("thought_level", "low")
    local out = query()
    assert.is_true(indexed(out.config.fields, "id")["effort-opt"].manual)
    assert.same({ id = "model-opt", value = "m3", automatic = true, forced = false }, out.config.in_flight)
    assert.same({ { id = "effort-opt", value = "low", automatic = false, forced = false } }, out.config.queued_manual)
    assert.equal(1, #client.requests)
  end)

  it("reflects later provider changes to selected and available values", function()
    local entry, client = entry_for()
    Registry.select(entry.key)
    local changed = options()
    changed[1].currentValue = "m3"
    changed[1].options = { { value = "m3", name = "Three" } }
    changed[#changed + 1] = { id = "future", name = "Future", currentValue = "off",
      options = { { value = "off", name = "Off" }, { value = "on", name = "On" } } }
    client.handlers.on_session_update({ sessionUpdate = "config_option_update", configOptions = changed })
    local fields = indexed(query().config.fields, "id")
    assert.equal("m3", fields["model-opt"].current)
    assert.same({ { id = "m3", label = "Three" } }, fields["model-opt"].available)
    assert.is_false(fields["model-opt"].default_valid)
    assert.is_true(fields.future.advertised)
    assert.is_true(fields.future.default_valid)
    assert.equal("off", fields.future.current)
    assert.equal(1, #client.requests)
  end)

  it("keeps manual intent visible when a field with no default disappears", function()
    local fields = options()
    fields[#fields + 1] = { id = "custom", name = "Custom", currentValue = "a",
      options = { { value = "a", name = "A" }, { value = "b", name = "B" } } }
    local entry, client = entry_for("session-a", nil, fields)
    Registry.select(entry.key)
    entry.session:set_config("custom", "b")
    client.handlers.on_session_update({ sessionUpdate = "config_option_update", configOptions = {} })
    local custom = indexed(query().config.fields, "id").custom
    assert.is_not_nil(custom)
    assert.is_false(custom.advertised)
    assert.is_true(custom.manual)
    assert.equal(vim.NIL, custom.default)
  end)

  it("preserves the default snapshot used by the conversation when plugin config changes", function()
    local entry = entry_for("session-a", { ["model-opt"] = "m3" })
    Config.acp_providers["introspect-test"].session_defaults["model-opt"] = "m1"
    Registry.select(entry.key)
    local out = query()
    assert.equal("m2", out.config.defaults.provider["model-opt"])
    assert.equal("m3", out.config.defaults.effective["model-opt"])
  end)

  it("returns isolated Lua config snapshots without changing session state", function()
    local entry, client = entry_for()
    local store = entry.session:get_store()
    local before = store.state
    local snapshot = entry.session:config_snapshot()
    snapshot.defaults.provider["model-opt"] = "changed"
    snapshot.defaults.effective["model-opt"] = "changed"
    snapshot.fields[1].available[1].label = "changed"
    local again = entry.session:config_snapshot()
    assert.equal("m2", again.defaults.provider["model-opt"])
    assert.equal("m2", again.defaults.effective["model-opt"])
    assert.equal("One", again.fields[1].available[1].label)
    assert.rawequal(before, store.state)
    assert.equal(1, #client.requests)
  end)

  it("reports runtime settings with current, configured and builtin defaults and constraints", function()
    local entry = entry_for()
    Registry.select(entry.key)
    Settings.for_session(entry.session):set("debounce_ms", 12345)
    entry.prefs:set("follow", true)
    local out = query()
    local session = indexed(out.settings.session, "key")
    assert.equal(12345, session.debounce_ms.current)
    assert.equal(9000, session.debounce_ms.default)
    assert.equal(7000, session.debounce_ms.builtin_default)
    assert.equal(0, session.debounce_ms.min)
    assert.equal("integer", session.debounce_ms.type)
    assert.equal(vim.NIL, session.debounce_ms.available)
    assert.same({ false, true }, session.edit_gate.available)
    assert.truthy(vim.tbl_contains(session.brief.available, "normal"))
    assert.truthy(vim.tbl_contains(session.brief.available, "tutor"))
    local view = indexed(out.settings.view, "key")
    assert.is_true(view.follow.current)
    assert.is_false(view.follow.default)
    assert.is_true(view.follow.builtin_default)
    assert.equal("track_edits", out.settings.global[1].key)
  end)

  it("uses the selected session instead of the first active one", function()
    entry_for("first", { ["model-opt"] = "m1" })
    local second = entry_for("second", { ["model-opt"] = "m3" })
    Registry.select(second.key)
    assert.equal("second", query().session_id)
  end)

  it("resolves an explicit ACP session ID without changing the selection", function()
    local first = entry_for("first")
    local second = entry_for("second")
    Registry.select(first.key)
    local out = query({ session_id = "second" })
    assert.equal(second.key, out.session_key)
    assert.rawequal(first, Registry.selected())
  end)

  it("uses the sole active session if no session is selected", function()
    local entry = entry_for()
    Registry.select(nil)
    assert.equal(entry.key, query().session_key)
  end)

  it("does not guess when multiple sessions are active but none is selected", function()
    entry_for("first")
    entry_for("second")
    Registry.select(nil)
    assert.has_error(function() query() end)
  end)

  it("rejects unknown or closed IDs instead of creating or loading a session", function()
    local entry, client = entry_for("first")
    assert.has_error(function() query({ session_id = "unknown" }) end)
    Registry.close(entry.key)
    assert.has_error(function() query({ session_id = "first" }) end)
    assert.equal(1, client.created)
    assert.equal(0, #Registry.list())
  end)

  it("rejects ambiguous ACP IDs but accepts a stable registry key", function()
    entry_for("duplicate")
    local second = entry_for("duplicate")
    assert.has_error(function() query({ session_id = "duplicate" }) end)
    assert.equal(second.key, query({ session_key = second.key }).session_key)
  end)

  it("can inspect a starting session with no ACP ID through its registry key", function()
    local client = client_for("eventual")
    function client:create_session(_handlers, cb) self.created_cb = cb end
    local entry = Registry.add({ provider = "introspect-test", get_instance = function(_, cb)
      cb(client)
      return client
    end })
    pump()
    local out = query({ session_key = entry.key })
    assert.is_false(out.ready)
    assert.equal(vim.NIL, out.session_id)
    assert.equal(0, #client.requests)
  end)

  it("validates selectors and reports the absence of a current session", function()
    assert.has_error(function() query() end)
    entry_for()
    for _, args in ipairs({
      { session_id = "" }, { session_id = 1 }, { session_key = "1" },
      { session_key = 0 }, { session_key = 1.5 }, { session_id = "session-a", session_key = 1 },
    }) do
      assert.has_error(function() query(args) end)
    end
  end)

  it("does not serialize launch secrets, transcript text or brief prompts", function()
    local entry = entry_for()
    Registry.select(entry.key)
    entry.session:get_store():append_entry({ kind = "user", text = "private-transcript" })
    Config.settings.briefs.tutor.prompt = "private-brief-prompt"
    local out = vim.json.encode(query())
    for _, secret in ipairs({ "private-launch-secret", "private-argument", "private-transcript", "private-brief-prompt" }) do
      assert.is_nil(out:find(secret, 1, true))
    end
  end)

  it("encodes empty default maps as objects and config fields/queues as arrays", function()
    Config.acp_providers["introspect-test"].session_defaults = {}
    local entry = entry_for("empty", nil, {})
    Registry.select(entry.key)
    local raw = require("weave.tools.session").introspect.handler({})
    assert.truthy(raw:find('"provider":{}', 1, true))
    assert.truthy(raw:find('"session":{}', 1, true))
    assert.truthy(raw:find('"effective":{}', 1, true))
    assert.truthy(raw:find('"fields":[]', 1, true))
    assert.truthy(raw:find('"queued_manual":[]', 1, true))
    assert.truthy(raw:find('"in_flight":null', 1, true))
  end)

  it("registers under the weave prefix and respects explicit permission denial", function()
    local entry = entry_for()
    Registry.select(entry.key)
    local server = { tools = {} }
    function server.register_tool(name, def) server.tools[name] = def end
    Tools.register_into(server)
    local def = server.tools.weave_session_introspect
    assert.is_not_nil(def)
    assert.is_nil(server.tools.session_introspect)
    assert.is_true(Tools.OWNS.weave_session_introspect)
    Permissions.save_preset({ name = "deny-introspection", rules = {
      { tool = "weave:session_introspect", decision = "deny" },
    } })
    Permissions.set_active("deny-introspection")
    local out
    def.handler({}, function(result) out = result end)
    assert.is_true(out.isError)
    assert.truthy(out.content[1].text:find("permission denied", 1, true))
    assert.is_nil(out.content[1].text:find("model-opt", 1, true))
  end)
end)
