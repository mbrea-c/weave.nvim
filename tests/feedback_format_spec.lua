-- What the agent actually receives. render() is pure over already-resolved
-- entries, so the wording is pinned here without needing buffers or anchors.

local Format = require("weave.feedback_format")

local function entry(over)
  return vim.tbl_extend("force", {
    path = "lua/weave/session.lua",
    lnum = 461,
    end_lnum = 461,
    quote = { "function Session:submit(text)" },
    body = "why queued rather than steered?",
    source = "weave",
    filetype = "lua",
    orphaned = false,
  }, over or {})
end

describe("feedback formatting", function()
  it("gives the file, the line, the quoted code and the comment", function()
    local text = Format.render({ entry() })
    assert.truthy(text:find("lua/weave/session.lua:461", 1, true))
    assert.truthy(text:find("```lua", 1, true))
    assert.truthy(text:find("function Session:submit(text)", 1, true))
    assert.truthy(text:find("why queued rather than steered?", 1, true))
  end)

  it("writes a span as a line range", function()
    local text = Format.render({ entry({ end_lnum = 463 }) })
    assert.truthy(text:find("lua/weave/session.lua:461-463", 1, true))
  end)

  it("numbers multiple comments and counts them in the header", function()
    local text = Format.render({ entry(), entry({ lnum = 12, body = "and this" }) })
    assert.truthy(text:find("2 comments", 1, true))
    assert.truthy(text:find("1. lua/weave/session.lua:461", 1, true))
    assert.truthy(text:find("2. lua/weave/session.lua:12", 1, true))
  end)

  it("says one comment in the singular", function()
    assert.truthy(Format.render({ entry() }):find("1 comment", 1, true))
  end)

  -- A stale line number the agent trusts is worse than no line number, so an
  -- orphaned comment is labelled rather than quietly sent as if it still fit.
  it("marks an orphaned comment as stale", function()
    local text = Format.render({ entry({ orphaned = true }) })
    assert.truthy(text:lower():find("stale", 1, true))
  end)

  it("attributes a comment that did not come from weave", function()
    local text = Format.render({ entry({ source = "perijove" }) })
    assert.truthy(text:find("[perijove]", 1, true))
    assert.falsy(Format.render({ entry() }):find("[weave]", 1, true))
  end)

  it("calls out the selected fragment of a partial selection", function()
    local text = Format.render({
      entry({ quote = { "local x = compute()" }, col = 11, end_col = 19 }),
    })
    assert.truthy(text:find("compute()", 1, true))
    assert.truthy(text:lower():find("selected", 1, true))
  end)

  it("fences without a language when the filetype is unknown", function()
    local text = Format.render({ entry({ filetype = nil }) })
    assert.truthy(text:find("```\n", 1, true))
  end)

  it("renders nothing for no entries", function()
    assert.equal("", Format.render({}))
  end)
end)
