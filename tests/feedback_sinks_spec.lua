-- Sinks are the extension point for "where does a sent feedback item go". weave
-- ships one that prompts the current session; perijove (or anything else) can
-- register its own and become the target without weave knowing about it.

local Sinks = require("weave.feedback_sinks")

describe("feedback sinks", function()
  before_each(function()
    Sinks._reset()
  end)

  it("ships a weave sink as the default", function()
    assert.equal("weave", Sinks.default().name)
  end)

  it("registers and resolves a sink by name", function()
    Sinks.register({ name = "perijove", label = "notebook", send = function() end })
    assert.equal("notebook", Sinks.get("perijove").label)
  end)

  it("replaces a sink registered under the same name rather than stacking", function()
    Sinks.register({ name = "perijove", send = function() end })
    Sinks.register({ name = "perijove", label = "second", send = function() end })
    assert.equal("second", Sinks.get("perijove").label)
    assert.equal(2, #Sinks.list())
  end)

  it("rejects a sink with no name or no send", function()
    assert.is_nil(Sinks.register({ send = function() end }))
    assert.is_nil(Sinks.register({ name = "x" }))
    assert.equal(1, #Sinks.list())
  end)

  it("dispatches to the named sink with the formatted text and the item", function()
    local got
    Sinks.register({
      name = "perijove",
      send = function(text, item)
        got = { text = text, item = item }
        return true
      end,
    })
    local item = { id = 7, comments = {} }
    assert.is_true(Sinks.dispatch("perijove", "hello", item))
    assert.equal("hello", got.text)
    assert.equal(7, got.item.id)
  end)

  it("reports an unknown sink instead of silently dropping the feedback", function()
    local ok, err = Sinks.dispatch("nope", "hello", {})
    assert.falsy(ok)
    assert.truthy(err:find("nope", 1, true))
  end)

  it("surfaces a sink error rather than reporting success", function()
    Sinks.register({
      name = "broken",
      send = function()
        return nil, "no session"
      end,
    })
    local ok, err = Sinks.dispatch("broken", "hello", {})
    assert.falsy(ok)
    assert.equal("no session", err)
  end)

  it("turns a throwing sink into an error instead of unwinding the caller", function()
    Sinks.register({
      name = "throws",
      send = function()
        error("boom")
      end,
    })
    local ok, err = Sinks.dispatch("throws", "hello", {})
    assert.falsy(ok)
    assert.truthy(err:find("boom", 1, true))
  end)
end)
