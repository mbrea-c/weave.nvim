-- Option labels carry the resource they persist a rule for ("Allow always for
-- /home/manuel/src/nvim-infra/weave.nvim"), so they routinely exceed the
-- sidebar width. A nowrap label truncates, and a truncated "always" label is
-- the one row a user most needs to read in full before answering: it hides
-- WHICH path the rule is about. The option rows therefore wrap.

local ui = require("fibrous").ui
local sidebar = require("weave.view.sidebar")

local function options_of(tree)
  local out = {}
  for _, row in ipairs(tree.children or {}) do
    local text = (row.props or {}).text
    if type(text) == "string" and text:match("^%[%d%]") then
      out[#out + 1] = row
    end
  end
  return out
end

describe("permission option rows", function()
  local store = {
    permission = {
      client_side = true,
      request = {
        toolCall = { title = "weave tool read: /etc/hostname" },
        options = {
          { optionId = "allow_once", name = "Allow once", kind = "allow_once" },
          {
            optionId = "allow_always",
            name = "Allow always for /home/manuel/src/nvim-infra/weave.nvim",
            kind = "allow_always",
          },
        },
      },
    },
    permission_count = 1,
  }

  -- A minimal fibrous ReactiveCtx: use_state hands back a get/set handle and
  -- effects never flush, which is all PermissionsSection's two hooks touch.
  local function render()
    local ctx = {
      use_state = function(initial)
        local v = initial
        return {
          get = function()
            return v
          end,
          set = function(next)
            v = next
          end,
        }
      end,
      use_effect = function() end,
    }
    return sidebar.PermissionsSection(ctx, { store = { state = store } })
  end

  it("renders each option as a wrapping paragraph, not a nowrap label", function()
    local opts = options_of(render())
    assert.equal(2, #opts)
    for _, row in ipairs(opts) do
      assert.equal(ui.paragraph, row.comp)
    end
  end)

  it("keeps the persist highlight on the wrapped option", function()
    local opts = options_of(render())
    assert.equal("WeavePermissionPersist", opts[2].props.style.text_hl)
  end)
end)
