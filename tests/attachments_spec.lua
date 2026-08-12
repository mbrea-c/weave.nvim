-- Staging files for a prompt (weave.attachments). The point is the SANDBOX:
-- an attachment has to exist at a path the agent can open from inside its
-- hull, which is why weave copies it into one directory it binds read-only
-- rather than handing over the path the user typed.

local Attachments = require("weave.attachments")

local uv = vim.uv or vim.loop

--- Write `content` to a fresh temp file and return its path.
local function tmpfile(name, content)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. name
  local f = assert(io.open(path, "wb"))
  f:write(content or "bytes")
  f:close()
  return path
end

describe("attachments", function()
  local saved_runtime

  before_each(function()
    saved_runtime = vim.env.XDG_RUNTIME_DIR
    vim.env.XDG_RUNTIME_DIR = vim.fn.tempname()
    vim.fn.mkdir(vim.env.XDG_RUNTIME_DIR, "p")
    Attachments._reset()
  end)

  after_each(function()
    Attachments.clear()
    vim.env.XDG_RUNTIME_DIR = saved_runtime
    Attachments._reset()
  end)

  it("copies the file in and reports where the AGENT will find it", function()
    local src = tmpfile("shot.png", "PNGDATA")
    local att = assert(Attachments.stage(src))

    assert.equal("shot.png", att.name)
    assert.equal(Attachments.root() .. "/shot.png", att.path)
    assert.equal("file://" .. att.path, att.uri)
    assert.equal("image/png", att.mime)
    assert.equal(src, att.source)
    -- a COPY: the agent reads weave's staged file, not the user's original
    assert.is_not_nil(uv.fs_stat(att.path))
    local f = assert(io.open(att.path, "rb"))
    assert.equal("PNGDATA", f:read("*a"))
    f:close()
  end)

  it("does not overwrite a same-named attachment", function()
    local first = assert(Attachments.stage(tmpfile("logo.png", "one")))
    local second = assert(Attachments.stage(tmpfile("logo.png", "two")))
    assert.equal("logo.png", first.name)
    assert.equal("logo-2.png", second.name)
    local f = assert(io.open(first.path, "rb"))
    assert.equal("one", f:read("*a"))
    f:close()
  end)

  it("refuses what it cannot stage", function()
    local _, missing = Attachments.stage("/definitely/not/here.png")
    assert.truthy(missing:find("does not exist", 1, true))

    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local _, is_dir = Attachments.stage(dir)
    assert.truthy(is_dir:find("is a directory", 1, true))

    local _, empty = Attachments.stage("")
    assert.truthy(empty:find("needs a file path", 1, true))
  end)

  it("refuses a file too big to be context", function()
    local saved = Attachments.MAX_BYTES
    Attachments.MAX_BYTES = 4
    local _, err = Attachments.stage(tmpfile("big.png", "more than four bytes"))
    assert.truthy(err:find("the limit is", 1, true))
    Attachments.MAX_BYTES = saved
  end)

  it("offers the sandbox nothing to bind until something is staged", function()
    assert.same({}, Attachments.sandbox_paths())
    Attachments.stage(tmpfile("a.png"))
    assert.same({ Attachments.root() }, Attachments.sandbox_paths())
    Attachments.clear()
    assert.same({}, Attachments.sandbox_paths())
  end)

  it("stages outside $HOME, which the agent sandbox hides", function()
    local home = uv.os_homedir() or "/home/nobody"
    assert.is_nil(Attachments.root():find(home, 1, true))
  end)
end)
