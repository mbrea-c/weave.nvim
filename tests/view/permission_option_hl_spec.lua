-- Permission prompt options are not equally consequential: the "always" pair
-- writes a rule into weave's client-side permission store, so answering one
-- changes how every future call resolves, not just this one. The sidebar
-- highlights exactly those, and only for prompts weave itself raised — an
-- agent-side ACP request's "always" is the agent's business and leaves our
-- store untouched, so colouring it would be a lie.

local sidebar = require("weave.view.sidebar")
local Theme = require("weave.view.theme")

local function opt(kind)
  return { optionId = kind, name = kind, kind = kind }
end

describe("permission option highlight", function()
  it("marks the options that write to weave's permission store", function()
    local perm = { client_side = true }
    assert.equal(Theme.PERMISSION_PERSIST_HL, sidebar.permission_option_hl(perm, opt("allow_always")))
    assert.equal(Theme.PERMISSION_PERSIST_HL, sidebar.permission_option_hl(perm, opt("reject_always")))
  end)

  it("leaves one-shot options unmarked", function()
    local perm = { client_side = true }
    assert.is_nil(sidebar.permission_option_hl(perm, opt("allow_once")))
    assert.is_nil(sidebar.permission_option_hl(perm, opt("reject_once")))
  end)

  it("leaves agent-side requests unmarked, store untouched either way", function()
    local perm = { client_side = nil }
    assert.is_nil(sidebar.permission_option_hl(perm, opt("allow_always")))
    assert.is_nil(sidebar.permission_option_hl(perm, opt("reject_always")))
  end)

  it("tolerates an option with no kind", function()
    assert.is_nil(sidebar.permission_option_hl({ client_side = true }, { optionId = "x", name = "x" }))
  end)
end)
