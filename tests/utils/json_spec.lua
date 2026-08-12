-- Indented JSON for the peek float (weave.utils.json): vim.json.encode emits
-- one line, which is the one shape an inspection window cannot use.

local Json = require("weave.utils.json")

describe("utils.json.pretty", function()
  it("indents objects and sorts their keys", function()
    assert.equal(
      table.concat({
        "{",
        '  "kind": "execute",',
        '  "status": "completed"',
        "}",
      }, "\n"),
      Json.pretty({ status = "completed", kind = "execute" })
    )
  end)

  it("keeps array order and nests", function()
    assert.equal(
      table.concat({
        "{",
        '  "body": [',
        '    "one",',
        '    "two"',
        "  ],",
        '  "input": {',
        '    "command": "ls -la"',
        "  }",
        "}",
      }, "\n"),
      Json.pretty({ input = { command = "ls -la" }, body = { "one", "two" } })
    )
  end)

  it("renders scalars as JSON, including null and escapes", function()
    assert.equal("null", Json.pretty(nil))
    assert.equal("null", Json.pretty(vim.NIL))
    assert.equal("true", Json.pretty(true))
    assert.equal("42", Json.pretty(42))
    assert.equal('"a \\"quoted\\" line\\nbroken"', Json.pretty('a "quoted" line\nbroken'))
  end)

  it("renders an empty table as {} (Lua cannot tell it from an empty array)", function()
    assert.equal("{}", Json.pretty({}))
    assert.equal('{\n  "input": {}\n}', Json.pretty({ input = {} }))
  end)

  it("survives a cycle instead of hanging the editor", function()
    local t = { name = "self" }
    t.me = t
    assert.equal('{\n  "me": "<cycle>",\n  "name": "self"\n}', Json.pretty(t))
  end)

  it("describes a value JSON has no place for, rather than erroring", function()
    assert.equal('{\n  "fn": "<function>"\n}', Json.pretty({ fn = function() end }))
  end)
end)
