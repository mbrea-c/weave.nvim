-- weave.prompts: the agent-facing text, as markdown files rather than Lua
-- string literals. The interesting parts are the resolution order (inline
-- config wins, then the user's file, then the shipped one) and that a missing
-- file is a warning returning nil rather than an error taking a send down.

local Config = require("weave.config")
local Prompts = require("weave.prompts")

describe("prompts", function()
  local dir, saved_prompts, saved_notify, notifications

  local function write(name, lines)
    local path = dir .. "/" .. name
    vim.fn.writefile(lines, path)
    return path
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    saved_prompts = Config.prompts
    Config.prompts = {}
    notifications = {}
    saved_notify = vim.notify
    vim.notify = function(msg)
      notifications[#notifications + 1] = msg
    end
  end)

  after_each(function()
    Config.prompts = saved_prompts
    vim.notify = saved_notify
    vim.fn.delete(dir, "rf")
  end)

  it("ships the prompts its own defaults name", function()
    assert.truthy(Prompts.get("sandbox_steering"):find("request_access", 1, true))
    assert.truthy(Prompts.get("edits"):find("squashed into one diff", 1, true))
    assert.truthy(Prompts.read("briefs/tutor.md"):lower():find("tutor mode", 1, true))
    assert.truthy(Prompts.read("briefs/normal.md"):lower():find("tutor mode is now off", 1, true))
  end)

  it("trims the file's trailing newline, so a prompt is not padded", function()
    local path = write("p.md", { "hello", "" })
    assert.equal("hello", Prompts.read(path))
  end)

  it("reads an absolute path as given, and a bare name from weave's own dir", function()
    local path = write("mine.md", { "my words" })
    assert.equal("my words", Prompts.read(path))
    assert.equal(Prompts.read("edits.md"), Prompts.get("edits"))
  end)

  it("prefers the configured file over the shipped one", function()
    Config.prompts = { edits = write("edits.md", { "look at this" }) }
    assert.equal("look at this", Prompts.get("edits"))
  end)

  it("warns and answers nil for a file that is not there", function()
    assert.is_nil(Prompts.read(dir .. "/nope.md"))
    assert.equal(1, #notifications)
    assert.truthy(notifications[1]:find("nope.md", 1, true))
  end)

  it("treats an empty file as nothing to say", function()
    assert.is_nil(Prompts.read(write("empty.md", { "", "  " })))
  end)

  -- The brief shape: text inline, or a file, and inline wins because it is
  -- the more specific answer (and what config written before files existed
  -- already says).
  it("resolves a prompt/prompt_file pair, inline first", function()
    local path = write("b.md", { "from the file" })
    assert.equal("inline", Prompts.resolve({ prompt = "inline", prompt_file = path }))
    assert.equal("from the file", Prompts.resolve({ prompt_file = path }))
    assert.is_nil(Prompts.resolve({}))
    assert.is_nil(Prompts.resolve(nil))
    assert.is_nil(Prompts.resolve({ prompt = "" }))
  end)

  it("points at the checkout it was loaded from, not the runtimepath", function()
    assert.equal(1, vim.fn.isdirectory(Prompts.dir()))
    assert.equal(1, vim.fn.filereadable(Prompts.dir() .. "/briefs/tutor.md"))
  end)
end)
