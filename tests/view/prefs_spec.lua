-- Per-panel view preferences (roadmap R5): UI-only state, deliberately
-- separate from the SessionStore (which mirrors ACP). Same store contract —
-- `.state` snapshots reassigned per mutation + subscribe/notify — so the
-- view's use_store hook works on it unchanged.

local Prefs = require("weave.view.prefs")

describe("view prefs", function()
  it("starts with everything on", function()
    local prefs = Prefs:new()
    assert.same({
      show_thoughts = true,
      show_diffs = true,
      conceal_markdown = true,
      follow = true,
    }, prefs.state)
  end)

  it("toggle flips a key, reassigning state and notifying once", function()
    local prefs = Prefs:new()
    local before = prefs.state
    local seen = {}
    prefs:subscribe(function(state)
      seen[#seen + 1] = state
    end)

    prefs:toggle("show_thoughts")
    assert.equal(1, #seen)
    assert.is_false(prefs.state.show_thoughts)
    assert.is_true(prefs.state.show_diffs)
    -- reassigned, not mutated: the old snapshot still reads true
    assert.is_true(before.show_thoughts)

    prefs:toggle("show_thoughts")
    assert.is_true(prefs.state.show_thoughts)
  end)

  it("set assigns a key; unknown keys error", function()
    local prefs = Prefs:new()
    prefs:set("follow", false)
    assert.is_false(prefs.state.follow)

    assert.has_error(function()
      prefs:toggle("show_typos")
    end)
    assert.has_error(function()
      prefs:set("show_typos", true)
    end)
  end)

  it("unsubscribe stops notifications", function()
    local prefs = Prefs:new()
    local count = 0
    local unsubscribe = prefs:subscribe(function()
      count = count + 1
    end)
    prefs:toggle("follow")
    unsubscribe()
    prefs:toggle("follow")
    assert.equal(1, count)
  end)
end)
