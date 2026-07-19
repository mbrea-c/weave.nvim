-- Sidebar section + comment editor. Both are plain components, so the layout
-- and the button wiring are exercised here without mounting a window.

local ui = require("fibrous.inline.components")
local View = require("weave.view.feedback")
local Store = require("weave.feedback_store")

--- The fibrous ReactiveCtx surface these components actually use. use_state
--- returns a { get, set } handle (see fibrous use_store), use_ref a stable
--- { current } container.
local function fake_ctx()
  local refs, states = {}, {}
  local n = 0
  return {
    use_state = function(initial)
      n = n + 1
      local slot = n
      if states[slot] == nil then
        states[slot] = initial
      end
      return {
        get = function()
          return states[slot]
        end,
        set = function(v)
          states[slot] = v
        end,
      }
    end,
    use_ref = function()
      n = n + 1
      refs[n] = refs[n] or {}
      return refs[n]
    end,
    use_effect = function() end,
  }
end

-- Buffer names must be unique within the nvim instance, and before_each runs
-- this per test, so the caller's name gets a serial suffix.
local seq = 0
local function scratch(lines, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if name then
    seq = seq + 1
    -- parenthesised: gsub's second return would otherwise land in format
    vim.api.nvim_buf_set_name(buf, ("%s.%d.lua"):format((name:gsub("%.lua$", "")), seq))
  end
  return buf
end

--- Every node in a tree, depth first.
local function flatten(node, out)
  out = out or {}
  out[#out + 1] = node
  for _, child in ipairs(node.children or {}) do
    flatten(child, out)
  end
  return out
end

local function find_button(tree, label)
  for _, node in ipairs(flatten(tree)) do
    if node.comp == ui.button and (node.props or {}).label == label then
      return node
    end
  end
  return nil
end

local function labels(tree)
  local out = {}
  for _, node in ipairs(flatten(tree)) do
    local p = node.props or {}
    out[#out + 1] = p.label or p.text
  end
  return table.concat(out, "\n")
end

describe("feedback sidebar section", function()
  before_each(function()
    Store._reset()
  end)

  it("shows the header and an empty note before any comment exists", function()
    local tree = View.Section(fake_ctx(), { width = 40 })
    assert.truthy(labels(tree):find("Code feedback", 1, true))
    assert.truthy(labels(tree):find("(no comments)", 1, true))
  end)

  it("offers no send button with nothing to send", function()
    assert.is_nil(find_button(View.Section(fake_ctx(), { width = 40 }), "send feedback"))
  end)

  it("lists each comment with its file, line and body", function()
    local buf = scratch({ "alpha", "beta" }, "/tmp/weave-fb-section.lua")
    Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "rename this" })
    local text = labels(View.Section(fake_ctx(), { width = 60 }))
    assert.truthy(text:find("weave%-fb%-section%.%d+%.lua:2"))
    assert.truthy(text:find("rename this", 1, true))
  end)

  it("offers send and discard once a draft exists", function()
    local buf = scratch({ "alpha" }, "/tmp/weave-fb-buttons.lua")
    Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "x" })
    local tree = View.Section(fake_ctx(), { width = 40 })
    assert.is_not_nil(find_button(tree, "send feedback"))
    assert.is_not_nil(find_button(tree, "discard"))
  end)

  it("warns on a comment whose code is gone", function()
    local buf = scratch({ "alpha", "beta" }, "/tmp/weave-fb-orphan.lua")
    Store.add({ bufnr = buf, range = { lnum = 2, end_lnum = 2 }, body = "x" })
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    assert.truthy(labels(View.Section(fake_ctx(), { width = 40 })):find("⚠", 1, true))
  end)
end)

describe("feedback comment editor", function()
  local buf, comment

  before_each(function()
    Store._reset()
    buf = scratch({ "local x = compute()", "return x" }, "/tmp/weave-fb-editor.lua")
    comment = Store.add({ bufnr = buf, range = { lnum = 1, end_lnum = 1 }, body = "" })
  end)

  it("heads with the location and shows the quoted code", function()
    local text = labels(View.Editor(fake_ctx(), { id = comment.id }))
    assert.truthy(text:find("weave%-fb%-editor%.%d+%.lua:1"))
    assert.truthy(text:find("local x = compute()", 1, true))
  end)

  it("seeds the input with the existing body", function()
    Store.update(comment.id, "already written")
    for _, node in ipairs(flatten(View.Editor(fake_ctx(), { id = comment.id }))) do
      if node.comp == ui.text_input then
        assert.equal("already written", node.props.value)
        return
      end
    end
    error("no text_input in the editor")
  end)

  it("saves the typed body and closes", function()
    local ctx = fake_ctx()
    local closed = false
    local tree = View.Editor(ctx, {
      id = comment.id,
      on_close = function()
        closed = true
      end,
    })
    for _, node in ipairs(flatten(tree)) do
      if node.comp == ui.text_input then
        node.props.on_change("this needs a guard")
      end
    end
    find_button(tree, "save").props.on_press()
    assert.equal("this needs a guard", Store.get(comment.id).body)
    assert.is_true(closed)
  end)

  it("saving an empty body removes the comment rather than bundling a blank", function()
    local tree = View.Editor(fake_ctx(), { id = comment.id })
    find_button(tree, "save").props.on_press()
    assert.is_nil(Store.get(comment.id))
  end)

  it("delete drops the comment", function()
    Store.update(comment.id, "written")
    local tree = View.Editor(fake_ctx(), { id = comment.id })
    find_button(tree, "delete").props.on_press()
    assert.is_nil(Store.get(comment.id))
  end)

  it("cancel restores the body the editor opened with", function()
    Store.update(comment.id, "original")
    local ctx = fake_ctx()
    local tree = View.Editor(ctx, { id = comment.id })
    for _, node in ipairs(flatten(tree)) do
      if node.comp == ui.text_input then
        node.props.on_change("scribbled over")
      end
    end
    find_button(tree, "cancel").props.on_press()
    assert.equal("original", Store.get(comment.id).body)
  end)

  -- Backing out of a fresh ;;cc must not strand a highlighted span with no
  -- comment attached to it.
  it("cancel on a never-written comment removes it", function()
    local tree = View.Editor(fake_ctx(), { id = comment.id })
    find_button(tree, "cancel").props.on_press()
    assert.is_nil(Store.get(comment.id))
  end)

  it("survives the comment being deleted under it", function()
    Store.remove(comment.id)
    assert.truthy(labels(View.Editor(fake_ctx(), { id = comment.id })):find("gone", 1, true))
  end)
end)
