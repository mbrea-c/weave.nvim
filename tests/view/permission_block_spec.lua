-- The transcript's inline permission block. Its option buttons stack in a
-- column, not a row: option labels carry the resource an "always" rule would
-- persist for, and a row lays children out on one line with the overflow
-- clipped (fibrous rows do not flex-wrap), so long labels silently lost their
-- tail off the right edge. A column always fits whatever the width is, and it
-- matches how the sidebar already lists the same options.

local ui = require("fibrous").ui
local transcript = require("weave.view.transcript")

local function render(options, count)
  local answered = {}
  local store = {
    pop_permission = function()
      return {
        respond = function(id)
          answered[#answered + 1] = id
        end,
      }
    end,
  }
  local tree = transcript.PermissionBlock(nil, {
    store = store,
    permission = { request = { toolCall = { title = "weave tool read" }, options = options } },
    count = count or 1,
  })
  return tree, answered
end

-- The button container is the last child; everything before it is text.
local function buttons_of(tree)
  return tree.children[#tree.children]
end

describe("transcript permission block", function()
  local options = {
    { optionId = "allow_once", name = "Allow once", kind = "allow_once" },
    {
      optionId = "allow_always",
      name = "Allow always for /home/manuel/src/nvim-infra/weave.nvim",
      kind = "allow_always",
    },
    { optionId = "reject_once", name = "Reject once", kind = "reject_once" },
  }

  it("stacks the option buttons in a column", function()
    local container = buttons_of(render(options))
    assert.equal(ui.col, container.comp)
    assert.equal(3, #container.children)
  end)

  it("keeps every option's label intact", function()
    local container = buttons_of(render(options))
    assert.equal("Allow always for /home/manuel/src/nvim-infra/weave.nvim", container.children[2].props.label)
  end)

  it("still pops the head and answers with the pressed option", function()
    local tree, answered = render(options)
    buttons_of(tree).children[2].props.on_press()
    assert.same({ "allow_always" }, answered)
  end)
end)
