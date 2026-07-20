-- weave.tool_ident: the args -> weave-tool-name correlation the transcript
-- header uses to tag a call `w:<tool>`. A bounded, non-consuming ring keyed on
-- a canonical (order-independent) serialization of the call arguments.

local ToolIdent = require("weave.tool_ident")

describe("weave.tool_ident", function()
  before_each(function()
    ToolIdent.reset()
  end)
  after_each(function()
    ToolIdent.reset()
  end)

  it("looks a call up by the exact arguments it was recorded with", function()
    ToolIdent.record("edit", { path = "/a.lua", old_string = "x", new_string = "y" })
    assert.equal("edit", ToolIdent.lookup({ path = "/a.lua", old_string = "x", new_string = "y" }))
  end)

  it("does not match arguments it never saw", function()
    ToolIdent.record("edit", { path = "/a.lua", old_string = "x", new_string = "y" })
    assert.is_nil(ToolIdent.lookup({ path = "/other.lua", old_string = "x", new_string = "y" }))
    assert.is_nil(ToolIdent.lookup({ command = "ls" }))
  end)

  it("matches regardless of key order (rawInput and args enumerate differently)", function()
    -- Same pairs, but build the lookup table so its hash order can differ from
    -- the recorded one; canon sorts keys, so the key is identical either way.
    ToolIdent.record("grep", { pattern = "foo", ["-i"] = true, output_mode = "content", path = "/src" })
    assert.equal("grep", ToolIdent.lookup({ output_mode = "content", path = "/src", pattern = "foo", ["-i"] = true }))
  end)

  it("keys on nested arg tables too", function()
    ToolIdent.record("task_start", { command = "make", env = { CI = "1", FOO = "bar" } })
    assert.equal("task_start", ToolIdent.lookup({ command = "make", env = { FOO = "bar", CI = "1" } }))
    assert.is_nil(ToolIdent.lookup({ command = "make", env = { CI = "2", FOO = "bar" } }))
  end)

  it("returns the newest tool for identical arguments", function()
    ToolIdent.record("read", { path = "/a.lua" })
    ToolIdent.record("write", { path = "/a.lua" }) -- (contrived: same key, later name wins)
    assert.equal("write", ToolIdent.lookup({ path = "/a.lua" }))
  end)

  it("ignores junk input", function()
    ToolIdent.record("edit", nil)
    ToolIdent.record("", { path = "/a" })
    assert.equal(0, ToolIdent.count())
    assert.is_nil(ToolIdent.lookup(nil))
    assert.is_nil(ToolIdent.lookup("not a table"))
  end)

  it("bounds the ring, dropping the oldest first", function()
    for i = 1, ToolIdent.LIMIT + 5 do
      ToolIdent.record("read", { path = "/f" .. i .. ".lua" })
    end
    assert.equal(ToolIdent.LIMIT, ToolIdent.count())
    -- the first five recorded have been evicted; a recent one still resolves
    assert.is_nil(ToolIdent.lookup({ path = "/f1.lua" }))
    assert.equal("read", ToolIdent.lookup({ path = "/f" .. (ToolIdent.LIMIT + 5) .. ".lua" }))
  end)
end)
