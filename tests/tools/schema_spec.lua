-- Wire-safety of the announced tool schemas. Not about what the tools DO —
-- about whether a client can read the advertisement at all.
--
-- Two ways a perfectly good tool disappears before it is ever called:
--
--   * `properties = {}` in Lua encodes as `[]`, which is not a valid JSON
--     Schema object. A validating client rejects the tool, and some reject the
--     entire tools/list along with it — one no-argument tool takes down the
--     whole suite. vim.empty_dict() is the fix; this spec is the tripwire.
--   * The JSON Schema combinators (anyOf/oneOf/allOf/not/$ref). Several ACP
--     providers translate MCP schemas into their own function-call format and
--     have no representation for these, so instead of ignoring the keyword
--     they drop the tool. Constraints that cannot be expressed in flat
--     properties + required belong in the DESCRIPTION, where every model reads
--     them and no validator can trip over them.
--
-- Both are invisible in Lua and invisible in the handler tests; they only show
-- up as a tool that quietly is not there.

local Tools = require("weave.tools")

--- A clankbox double exposing just the provider API, so the suite under test
--- is exactly the suite an agent is handed.
local function collect()
  local server = { tools = {} }
  function server.register_tool(name, def)
    server.tools[name] = def
  end
  function server.use() end
  Tools.register_into(server)
  return server.tools
end

local COMBINATORS = { "anyOf", "oneOf", "allOf", "not", "$ref" }

--- Every combinator keyword found under `node`, as dotted paths. Walks with
--- knowledge of the schema shape: the keys under `properties` are argument
--- NAMES, so an argument innocently called "not" is not a finding.
--- @param node any
--- @param path string
--- @param out string[]
local function combinators(node, path, out)
  if type(node) ~= "table" then
    return out
  end
  for _, key in ipairs(COMBINATORS) do
    if node[key] ~= nil then
      out[#out + 1] = path .. "." .. key
    end
  end
  for _, slot in ipairs({ "properties", "patternProperties", "definitions", "$defs" }) do
    for name, sub in pairs(node[slot] or {}) do
      combinators(sub, ("%s.%s.%s"):format(path, slot, name), out)
    end
  end
  combinators(node.items, path .. ".items", out)
  return out
end

describe("tool schema wire safety", function()
  local tools

  before_each(function()
    Tools._reset()
    tools = collect()
  end)

  after_each(function()
    Tools._reset()
  end)

  it("registers the suite it claims to own", function()
    for name in pairs(Tools.OWNS) do
      assert.truthy(tools[name], name .. " is in OWNS but was never registered")
    end
  end)

  it("encodes every object-valued schema slot as an object, never an array", function()
    for name, def in pairs(tools) do
      local json = vim.json.encode(def.inputSchema)
      for _, slot in ipairs({ "properties", "patternProperties", "definitions", "$defs" }) do
        assert.is_nil(
          json:find('"' .. slot .. '":[', 1, true),
          ("%s.%s encodes as [] — use vim.empty_dict()"):format(name, slot)
        )
      end
    end
  end)

  it("announces no JSON Schema combinators", function()
    for name, def in pairs(tools) do
      local found = combinators(def.inputSchema, name, {})
      assert.equal(
        "",
        table.concat(found, ", "),
        ("%s announces combinators some ACP providers cannot translate; state the constraint in the description"):format(
          name
        )
      )
    end
  end)

  it("gives every tool a described object schema", function()
    for name, def in pairs(tools) do
      local s = def.inputSchema
      assert.truthy(s, name .. " has no inputSchema")
      assert.equal("object", s.type, name .. " must announce an object schema")
      assert.truthy(type(def.description) == "string" and def.description ~= "", name .. " has no description")
      for arg, prop in pairs(s.properties or {}) do
        assert.truthy(prop.type, ("%s.%s has no type"):format(name, arg))
        assert.truthy(prop.description, ("%s.%s has no description"):format(name, arg))
      end
    end
  end)
end)
