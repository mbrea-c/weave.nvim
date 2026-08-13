-- The `annotate` tool suite: how the agent leaves feedback ON the user's code
-- rather than only in chat. Four tools, because a model picks a narrow tool
-- far more reliably than it picks an `action` parameter.
--
-- The store's behaviour (anchoring, drift, wrapping) is specced in
-- annotations_spec; here it is the tool surface — what the agent can say, what
-- comes back, and what it is told when it gets it wrong.

local Annotate = require("weave.tools.annotate")
local Annotations = require("weave.annotations")

--- Call a tool def's handler and return the text it responded with.
local function call(def, args)
  local result = def.handler(args)
  if type(result) == "table" then
    local text = {}
    for _, block in ipairs(result.content or {}) do
      text[#text + 1] = block.text
    end
    return table.concat(text, "\n"), result.isError == true
  end
  return tostring(result), false
end

describe("annotate tool", function()
  local root, path, bufnr

  before_each(function()
    Annotations._reset()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    path = root .. "/a.lua"
    vim.fn.writefile({ "local x = 1", "return x" }, path)
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
  end)

  after_each(function()
    Annotations._reset()
    vim.fn.delete(root, "rf")
  end)

  it("places an annotation and says where it landed", function()
    local text, err = call(Annotate.annotate, { path = path, lnum = 1, message = "shadowed" })
    assert.is_false(err)
    assert.truthy(text:find("a.lua", 1, true))
    assert.equal(1, #Annotations.list())
    assert.equal("shadowed", Annotations.list()[1].message)
  end)

  it("reports back the id, which is how it edits or dismisses it later", function()
    local text = call(Annotate.annotate, { path = path, lnum = 1, message = "m" })
    local id = tonumber(text:match("#(%d+)"))
    assert.equal(Annotations.list()[1].id, id)
  end)

  -- Manuel's shortcut: the same tool, no span, is just a notification.
  it("with no span, only notifies — no extmark, nothing to dismiss", function()
    local notified = {}
    local orig = vim.notify
    vim.notify = function(msg, level)
      notified[#notified + 1] = { msg = msg, level = level }
    end
    local _, err = call(Annotate.annotate, { message = "heads up" })
    vim.notify = orig

    assert.is_false(err)
    assert.same({}, Annotations.list())
    assert.equal(1, #notified)
    assert.truthy(notified[1].msg:find("heads up", 1, true))
  end)

  it("also notifies alongside the annotation when asked", function()
    local notified = 0
    local orig = vim.notify
    vim.notify = function()
      notified = notified + 1
    end
    call(Annotate.annotate, { path = path, lnum = 1, message = "m", notify = true })
    vim.notify = orig

    assert.equal(1, notified)
    assert.equal(1, #Annotations.list())
  end)

  it("stays quiet by default, so a review does not become a popup storm", function()
    local notified = 0
    local orig = vim.notify
    vim.notify = function()
      notified = notified + 1
    end
    call(Annotate.annotate, { path = path, lnum = 1, message = "m" })
    vim.notify = orig
    assert.equal(0, notified)
  end)

  it("refuses a message with no span and no notification value", function()
    local text, err = call(Annotate.annotate, { path = path, lnum = 1 })
    assert.is_true(err)
    assert.truthy(text:lower():find("message"))
  end)

  -- The drift contract, from the agent's side: it is told WHY, and told what
  -- to do about it, rather than getting a bare failure.
  it("explains itself when the code it quoted has moved on", function()
    local text, err = call(Annotate.annotate, {
      path = path,
      lnum = 1,
      expect = { "this line never existed" },
      message = "m",
    })
    assert.is_true(err)
    assert.truthy(text:find("no longer", 1, true))
  end)

  it("honours above/below", function()
    call(Annotate.annotate, { path = path, lnum = 1, message = "m", position = "above" })
    assert.equal("above", Annotations.list()[1].position)
  end)
end)

describe("annotate_list tool", function()
  local root, path

  before_each(function()
    Annotations._reset()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    path = root .. "/a.lua"
    vim.fn.writefile({ "one", "two", "three" }, path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
  end)

  after_each(function()
    Annotations._reset()
    vim.fn.delete(root, "rf")
  end)

  it("says so plainly when there are none", function()
    local text = call(Annotate.annotate_list, {})
    assert.truthy(text:lower():find("no annotations"))
  end)

  it("lists id, location and message so the agent can act on them", function()
    call(Annotate.annotate, { path = path, lnum = 2, message = "the middle one" })
    local text = call(Annotate.annotate_list, {})
    assert.truthy(text:find("the middle one", 1, true))
    assert.truthy(text:find("a.lua:2", 1, true))
  end)

  it("reports where an annotation sits NOW, not where it was placed", function()
    call(Annotate.annotate, { path = path, lnum = 3, message = "m" })
    local bufnr = vim.fn.bufnr(path)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted" })
    assert.truthy(call(Annotate.annotate_list, {}):find("a.lua:4", 1, true))
  end)

  it("filters by path", function()
    local other = root .. "/b.lua"
    vim.fn.writefile({ "x" }, other)
    vim.fn.bufload(vim.fn.bufadd(other))
    call(Annotate.annotate, { path = path, lnum = 1, message = "in a" })
    call(Annotate.annotate, { path = other, lnum = 1, message = "in b" })

    local text = call(Annotate.annotate_list, { path = other })
    assert.truthy(text:find("in b", 1, true))
    assert.is_nil(text:find("in a", 1, true))
  end)
end)

describe("annotate_update and annotate_dismiss tools", function()
  local root, path

  before_each(function()
    Annotations._reset()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    path = root .. "/a.lua"
    vim.fn.writefile({ "one", "two" }, path)
    vim.fn.bufload(vim.fn.bufadd(path))
  end)

  after_each(function()
    Annotations._reset()
    vim.fn.delete(root, "rf")
  end)

  it("rewrites a message the agent thought better of", function()
    call(Annotate.annotate, { path = path, lnum = 1, message = "first take" })
    local id = Annotations.list()[1].id
    local _, err = call(Annotate.annotate_update, { id = id, message = "second take" })
    assert.is_false(err)
    assert.equal("second take", Annotations.get(id).message)
  end)

  it("removes one the user no longer needs to see", function()
    call(Annotate.annotate, { path = path, lnum = 1, message = "m" })
    local id = Annotations.list()[1].id
    local _, err = call(Annotate.annotate_dismiss, { id = id })
    assert.is_false(err)
    assert.same({}, Annotations.list())
  end)

  it("clears them all at once", function()
    call(Annotate.annotate, { path = path, lnum = 1, message = "a" })
    call(Annotate.annotate, { path = path, lnum = 2, message = "b" })
    call(Annotate.annotate_dismiss, { all = true })
    assert.same({}, Annotations.list())
  end)

  it("tells the agent when it names an id that is gone, rather than failing silently", function()
    local text, err = call(Annotate.annotate_update, { id = 999, message = "m" })
    assert.is_true(err)
    assert.truthy(text:find("999", 1, true))

    local dtext, derr = call(Annotate.annotate_dismiss, { id = 999 })
    assert.is_true(derr)
    assert.truthy(dtext:find("999", 1, true))
  end)
end)
