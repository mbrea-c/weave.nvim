-- weave.settings: the declarative setting registry + scoped stores. One home
-- per setting (view/session/global — no resolution cascade), the Prefs/
-- SessionStore store contract (state reassigned per mutation, one notify),
-- and presets as partial {key = value} maps applied in registry order.

local Config = require("weave.config")
local Settings = require("weave.settings")

describe("weave.settings", function()
  local saved_settings

  before_each(function()
    saved_settings = Config.settings
    Settings._reset()
  end)

  after_each(function()
    Config.settings = saved_settings
    Settings._reset()
  end)

  describe("registry", function()
    it("gives every setting exactly one scope", function()
      local seen = {}
      for _, spec in ipairs(Settings.SPECS) do
        assert.is_nil(seen[spec.key], spec.key .. " declared twice")
        seen[spec.key] = true
        assert.equal(1, ({ view = 1, session = 1, global = 1 })[spec.scope])
      end
      assert.equal("view", Settings.spec("show_thoughts").scope)
      assert.equal("session", Settings.spec("auto_send_edits").scope)
      assert.equal("global", Settings.spec("track_edits").scope)
    end)

    it("errors on unknown keys instead of guessing", function()
      assert.has_error(function()
        Settings.spec("show_typos")
      end)
    end)

    it("lists a scope's specs in display order", function()
      local keys = {}
      for _, spec in ipairs(Settings.specs("session")) do
        keys[#keys + 1] = spec.key
      end
      assert.same({ "auto_send_edits", "debounce_ms", "edit_gate", "brief" }, keys)
    end)
  end)

  describe("stores", function()
    it("seeds a store with its scope's defaults and nothing else", function()
      local view = Settings.new_view()
      assert.same({
        show_thoughts = true,
        show_diffs = true,
        conceal_markdown = true,
        follow = true,
      }, view.state)

      local global = Settings.global()
      assert.same({ track_edits = false }, global.state)
    end)

    it("honours Config.settings.defaults overrides", function()
      Config.settings = vim.tbl_deep_extend("force", {}, saved_settings, {
        defaults = { debounce_ms = 1500, follow = false },
      })
      local session = Settings.for_session({})
      assert.equal(1500, session:get("debounce_ms"))
      assert.is_false(Settings.new_view():get("follow"))
    end)

    it("keeps the store contract: reassign + one notify, unchanged keeps identity", function()
      local store = Settings.for_session({})
      local before = store.state
      local seen = {}
      store:subscribe(function(state)
        seen[#seen + 1] = state
      end)

      store:set("auto_send_edits", true)
      assert.equal(1, #seen)
      assert.is_true(store.state.auto_send_edits)
      assert.is_false(before.auto_send_edits) -- old snapshot untouched

      -- same value again: no notify
      store:set("auto_send_edits", true)
      assert.equal(1, #seen)
    end)

    it("rejects values of the wrong shape, loudly", function()
      local session = Settings.for_session({})
      assert.has_error(function()
        session:set("auto_send_edits", "yes")
      end)
      assert.has_error(function()
        session:set("debounce_ms", -5)
      end)
      assert.has_error(function()
        session:set("brief", "no-such-brief")
      end)
      assert.has_error(function()
        session:toggle("debounce_ms") -- not a boolean
      end)
    end)

    it("coerces integer strings from input prompts", function()
      local session = Settings.for_session({})
      session:set("debounce_ms", "2500")
      assert.equal(2500, session:get("debounce_ms"))
    end)

    it("refuses a key from another scope", function()
      assert.has_error(function()
        Settings.global():set("follow", false)
      end)
      assert.has_error(function()
        Settings.new_view():get("track_edits")
      end)
    end)

    it("hands each session its own store, stably", function()
      local a, b = {}, {}
      local sa = Settings.for_session(a)
      sa:set("edit_gate", true)
      assert.equal(sa, Settings.for_session(a))
      assert.is_false(Settings.for_session(b):get("edit_gate"))
    end)
  end)

  describe("enums", function()
    it("offers the configured briefs, default first", function()
      Config.settings = vim.tbl_deep_extend("force", {}, saved_settings, {
        briefs = { normal = { prompt = "n" }, tutor = { prompt = "t" }, architect = { prompt = "a" } },
      })
      assert.same({ "normal", "architect", "tutor" }, Settings.enum_options("brief"))
      local session = Settings.for_session({})
      session:set("brief", "architect")
      assert.equal("architect", session:get("brief"))
    end)
  end)

  describe("sidebar_specs", function()
    it("resolves the configured keys in order and skips unknown ones", function()
      Config.settings = vim.tbl_deep_extend("force", {}, saved_settings, {
        sidebar = { "follow", "show_typos", "auto_send_edits" },
      })
      local notified = {}
      local orig = vim.notify
      vim.notify = function(msg)
        notified[#notified + 1] = msg
      end
      local keys = {}
      for _, spec in ipairs(Settings.sidebar_specs()) do
        keys[#keys + 1] = spec.key
      end
      vim.notify = orig
      assert.same({ "follow", "auto_send_edits" }, keys)
      assert.equal(1, #notified)
      assert.is_not_nil(notified[1]:find("show_typos", 1, true))
    end)
  end)

  describe("presets", function()
    it("applies only the keys a preset names, in registry order", function()
      local order = {}
      local global = Settings.global()
      local session = Settings.for_session({})
      global:subscribe(function()
        order[#order + 1] = "track_edits"
      end)
      session:subscribe(function(state)
        order[#order + 1] = state.brief ~= "normal" and "brief" or "auto_send_edits"
      end)

      Settings.apply_preset({
        name = "tutor",
        settings = { brief = "tutor", auto_send_edits = true, track_edits = true },
      }, { global = global, session = session })

      -- registry order: the global switch lands before the session ones, and
      -- the brief last — effect subscribers see dependencies first
      assert.same({ "track_edits", "auto_send_edits", "brief" }, order)
      assert.equal(7000, session:get("debounce_ms")) -- untouched: presets are partial
      assert.equal("tutor", Settings.last_preset())
    end)

    it("skips scopes it was not handed a store for", function()
      local session = Settings.for_session({})
      Settings.apply_preset({
        name = "tutor",
        settings = { track_edits = true, auto_send_edits = true },
      }, { session = session })
      assert.is_true(session:get("auto_send_edits"))
      assert.is_false(Settings.global():get("track_edits"))
    end)

    it("exposes the configured presets", function()
      local names = {}
      for _, preset in ipairs(Settings.presets()) do
        names[#names + 1] = preset.name
      end
      assert.same({ "tutor", "normal" }, names)
    end)
  end)
end)
