-- weave.revision: the unit tutor mode collects and sends. A revision is a set
-- of per-file BEFORE/AFTER contents, never a set of hunks — the whole point is
-- that merging two revisions has to be trivial and exactly right, and composing
-- two hunk sets is neither. Hunks are derived at the edge, for display.
--
-- Everything here is pure: no buffers, no autocmds, no clock. The collection
-- side lives in weave.revision_log.

local Revision = require("weave.revision")

--- @param files table<string, { before?: string, after?: string }>
local function rev(id, files)
  return Revision.new({ id = id, at = id * 1000, files = files })
end

describe("revision merge", function()
  it("takes before from the earlier revision and after from the later", function()
    local a = rev(1, { ["/p/a.lua"] = { before = "one", after = "two" } })
    local b = rev(2, { ["/p/a.lua"] = { before = "two", after = "three" } })
    local m = Revision.merge(a, b)
    assert.same({ before = "one", after = "three" }, m.files["/p/a.lua"])
  end)

  it("keeps files only one side touched", function()
    local a = rev(1, { ["/p/a.lua"] = { before = "a1", after = "a2" } })
    local b = rev(2, { ["/p/b.lua"] = { before = "b1", after = "b2" } })
    local m = Revision.merge(a, b)
    assert.same({ before = "a1", after = "a2" }, m.files["/p/a.lua"])
    assert.same({ before = "b1", after = "b2" }, m.files["/p/b.lua"])
  end)

  it("carries the later revision's identity", function()
    local m = Revision.merge(rev(1, {}), rev(7, {}))
    assert.equal(7, m.id)
    assert.equal(7000, m.at)
    -- ...and remembers where the span started, which is what a squashed
    -- revision is a span OF
    assert.equal(1, m.from_id)
  end)

  it("treats a missing side as identity", function()
    local a = rev(1, { ["/p/a.lua"] = { before = "x", after = "y" } })
    assert.same(a, Revision.merge(nil, a))
    assert.same(a, Revision.merge(a, nil))
    assert.is_nil(Revision.merge(nil, nil))
  end)

  it("never mutates its inputs", function()
    local a = rev(1, { ["/p/a.lua"] = { before = "one", after = "two" } })
    local b = rev(2, { ["/p/a.lua"] = { before = "two", after = "three" } })
    Revision.merge(a, b)
    assert.same({ before = "one", after = "two" }, a.files["/p/a.lua"])
    assert.same({ before = "two", after = "three" }, b.files["/p/a.lua"])
  end)

  it("is associative, which is what makes squash order-free", function()
    local a = rev(1, { ["/p/a.lua"] = { before = "1", after = "2" } })
    local b = rev(2, { ["/p/a.lua"] = { before = "2", after = "3" }, ["/p/b.lua"] = { after = "new" } })
    local c = rev(3, { ["/p/a.lua"] = { before = "3", after = "4" } })
    local left = Revision.merge(Revision.merge(a, b), c)
    local right = Revision.merge(a, Revision.merge(b, c))
    assert.same(left.files, right.files)
  end)

  -- Creation and deletion are the SAME operation as an edit here: a nil side.
  -- Merging them is what makes create-then-delete vanish and delete-then-create
  -- collapse to whatever the net change actually was.
  it("collapses create-then-edit into a single creation", function()
    local a = rev(1, { ["/p/n.lua"] = { after = "v1" } })
    local b = rev(2, { ["/p/n.lua"] = { before = "v1", after = "v2" } })
    local m = Revision.merge(a, b)
    assert.is_nil(m.files["/p/n.lua"].before)
    assert.equal("v2", m.files["/p/n.lua"].after)
  end)

  it("collapses edit-then-delete into a single deletion", function()
    local a = rev(1, { ["/p/d.lua"] = { before = "v1", after = "v2" } })
    local b = rev(2, { ["/p/d.lua"] = { before = "v2" } })
    local m = Revision.merge(a, b)
    assert.equal("v1", m.files["/p/d.lua"].before)
    assert.is_nil(m.files["/p/d.lua"].after)
  end)
end)

describe("revision squash", function()
  it("folds a list oldest-first", function()
    local squashed = Revision.squash({
      rev(1, { ["/p/a.lua"] = { before = "1", after = "2" } }),
      rev(2, { ["/p/a.lua"] = { before = "2", after = "3" } }),
      rev(3, { ["/p/a.lua"] = { before = "3", after = "4" } }),
    })
    assert.same({ before = "1", after = "4" }, squashed.files["/p/a.lua"])
    assert.equal(1, squashed.from_id)
    assert.equal(3, squashed.id)
  end)

  it("is nil for an empty list", function()
    assert.is_nil(Revision.squash({}))
  end)

  -- The payoff for storing content instead of hunks: a change the user undid
  -- before the flush is not a change, and no hunk algebra could tell.
  it("drops a file the user edited and then reverted", function()
    local squashed = Revision.squash({
      rev(1, { ["/p/a.lua"] = { before = "orig", after = "typo" } }),
      rev(2, { ["/p/a.lua"] = { before = "typo", after = "orig" } }),
    })
    assert.is_nil(squashed.files["/p/a.lua"])
    assert.is_true(Revision.is_empty(squashed))
  end)

  it("drops a file created and then deleted before it was ever sent", function()
    local squashed = Revision.squash({
      rev(1, { ["/p/scratch.lua"] = { after = "junk" } }),
      rev(2, { ["/p/scratch.lua"] = { before = "junk" } }),
    })
    assert.is_nil(squashed.files["/p/scratch.lua"])
    assert.is_true(Revision.is_empty(squashed))
  end)

  it("keeps the files that did net-change alongside the ones that did not", function()
    local squashed = Revision.squash({
      rev(1, { ["/p/a.lua"] = { before = "x", after = "y" }, ["/p/b.lua"] = { before = "k", after = "k2" } }),
      rev(2, { ["/p/a.lua"] = { before = "y", after = "x" } }),
    })
    assert.is_nil(squashed.files["/p/a.lua"])
    assert.same({ before = "k", after = "k2" }, squashed.files["/p/b.lua"])
    assert.is_false(Revision.is_empty(squashed))
  end)
end)

describe("revision shape", function()
  it("classifies each file as created, deleted or modified", function()
    local r = rev(1, {
      ["/p/new.lua"] = { after = "hi" },
      ["/p/gone.lua"] = { before = "bye" },
      ["/p/same.lua"] = { before = "a", after = "b" },
    })
    assert.equal("created", Revision.kind(r.files["/p/new.lua"]))
    assert.equal("deleted", Revision.kind(r.files["/p/gone.lua"]))
    assert.equal("modified", Revision.kind(r.files["/p/same.lua"]))
  end)

  it("lists paths in a stable order regardless of insertion", function()
    local r = rev(1, { ["/p/z.lua"] = { after = "" }, ["/p/a.lua"] = { after = "" }, ["/p/m.lua"] = { after = "" } })
    assert.same({ "/p/a.lua", "/p/m.lua", "/p/z.lua" }, Revision.paths(r))
  end)

  it("counts what changed", function()
    local r = rev(1, {
      ["/p/new.lua"] = { after = "one\ntwo\n" },
      ["/p/gone.lua"] = { before = "bye\n" },
      ["/p/edit.lua"] = { before = "a\nb\n", after = "a\nc\n" },
    })
    local s = Revision.summary(r)
    assert.equal(1, s.created)
    assert.equal(1, s.deleted)
    assert.equal(1, s.modified)
    assert.equal(3, s.files)
  end)
end)

describe("revision rendering", function()
  it("renders a modification as a unified diff naming the path twice", function()
    local r = rev(1, { ["/p/a.lua"] = { before = "one\ntwo\nthree\n", after = "one\nTWO\nthree\n" } })
    local text = Revision.render(r, { root = "/p" })
    assert.truthy(text:find("--- a/a.lua", 1, true))
    assert.truthy(text:find("+++ b/a.lua", 1, true))
    assert.truthy(text:find("\n-two", 1, true))
    assert.truthy(text:find("\n+TWO", 1, true))
  end)

  it("renders paths relative to the project root, absolute outside it", function()
    -- A path outside the project must LOOK absolute: dressing it in git's a//b/
    -- prefixes would read as project-relative and send the agent looking in the
    -- wrong place.
    local r = rev(1, {
      ["/p/in.lua"] = { before = "a\n", after = "b\n" },
      ["/elsewhere/out.lua"] = { before = "a\n", after = "b\n" },
    })
    local text = Revision.render(r, { root = "/p" })
    assert.truthy(text:find("+++ b/in.lua", 1, true))
    assert.truthy(text:find("+++ /elsewhere/out.lua", 1, true))
    assert.is_nil(text:find("b/elsewhere", 1, true))
  end)

  -- A whole new file as a diff of every line is noise; the agent needs to know
  -- it appeared and what is in it.
  it("marks a creation and a deletion explicitly", function()
    local r = rev(1, { ["/p/new.lua"] = { after = "hi\n" }, ["/p/gone.lua"] = { before = "bye\n" } })
    local text = Revision.render(r, { root = "/p" })
    assert.truthy(text:find("new file", 1, true))
    assert.truthy(text:find("deleted file", 1, true))
  end)

  it("says so when it truncates rather than silently sending half", function()
    local big = string.rep("a line of text\n", 5000)
    local r = rev(1, { ["/p/big.lua"] = { before = "", after = big } })
    local text = Revision.render(r, { root = "/p", max_bytes = 500 })
    assert.is_true(#text < 2000)
    assert.truthy(text:lower():find("truncated"))
  end)

  it("renders an empty revision as nil, so nothing empty is ever sent", function()
    assert.is_nil(Revision.render(rev(1, {}), { root = "/p" }))
  end)
end)
