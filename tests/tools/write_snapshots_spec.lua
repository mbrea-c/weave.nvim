-- A full-content write ({path, content}) carries only the NEW side. The old
-- side has to be read before the handler runs, because by the time the
-- transcript draws, the write has landed and reading the file back just
-- returns `content` again -- an empty diff. This is that pre-write capture.

local Snapshots = require("weave.tools.write_snapshots")

local function tmpfile(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  return path
end

describe("write snapshots", function()
  before_each(function()
    Snapshots.reset()
  end)

  it("hands back the content the file had before the write", function()
    local path = tmpfile({ "one", "two" })
    Snapshots.capture(path, "one\ntwo\nthree\n")
    -- The write lands between capture and take, exactly as it does live.
    vim.fn.writefile({ "one", "two", "three" }, path)
    assert.same({ "one", "two" }, Snapshots.get(path, "one\ntwo\nthree\n"))
  end)

  it("treats a write to a new file as an empty old side", function()
    local path = vim.fn.tempname()
    Snapshots.capture(path, "hello\n")
    assert.same({}, Snapshots.get(path, "hello\n"))
  end)

  it("matches on content too, so two writes to one path do not cross", function()
    local path = tmpfile({ "base" })
    Snapshots.capture(path, "first\n")
    vim.fn.writefile({ "first" }, path)
    Snapshots.capture(path, "second\n")

    assert.same({ "first" }, Snapshots.get(path, "second\n"))
    assert.same({ "base" }, Snapshots.get(path, "first\n"))
  end)

  -- A transcript entry re-renders on every view flush and its matcher reruns
  -- on every resolve. A single-use snapshot would draw the diff once and then
  -- silently drop the entry back to the builtin rendering.
  it("survives repeated lookups, so a re-render still finds its diff", function()
    local path = tmpfile({ "a" })
    Snapshots.capture(path, "b\n")
    assert.same({ "a" }, Snapshots.get(path, "b\n"))
    assert.same({ "a" }, Snapshots.get(path, "b\n"))
    assert.same({ "a" }, Snapshots.get(path, "b\n"))
  end)

  it("returns nil for a write it never saw", function()
    assert.is_nil(Snapshots.get("/nope", "x"))
  end)

  it("prefers a live buffer over what is on disk", function()
    local path = tmpfile({ "saved" })
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved edit" })

    Snapshots.capture(path, "new\n")
    assert.same({ "unsaved edit" }, Snapshots.get(path, "new\n"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("bounds what it retains, so a long session cannot grow without limit", function()
    for i = 1, Snapshots.LIMIT + 5 do
      Snapshots.capture("/tmp/f" .. i, "c" .. i)
    end
    assert.equal(Snapshots.LIMIT, Snapshots.count())
    -- The oldest were dropped; the newest survive.
    assert.is_nil(Snapshots.get("/tmp/f1", "c1"))
    assert.is_not_nil(Snapshots.get("/tmp/f" .. (Snapshots.LIMIT + 5), "c" .. (Snapshots.LIMIT + 5)))
  end)
end)
