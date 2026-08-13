-- weave.sandbox.seatbelt: the macOS backend. The profile builders are pure
-- string functions of (hull, fs), which is the whole reason they are split
-- out — the SBPL they emit can be pinned exhaustively on any platform, even
-- though whether the kernel ENFORCES it can only be checked on a Mac.
-- Everything below is about what the profile says; nothing here claims the
-- sandbox works.

local Seatbelt = require("weave.sandbox.seatbelt")

-- Identity filesystem: realpath resolves nothing, so the specs see the paths
-- they wrote (firmlink rewriting is normalize's own job, specced below).
local FS = {
  exists = function()
    return true
  end,
  realpath = function()
    return nil
  end,
}

local function agent(extra)
  local hull = { home = "/Users/u", cwd = "/Users/u/proj", grants = {} }
  for k, v in pairs(extra or {}) do
    hull[k] = v
  end
  return Seatbelt.profile_agent(hull, FS)
end

local function tool(extra)
  local hull = { home = "/Users/u", network = false, binds = {} }
  for k, v in pairs(extra or {}) do
    hull[k] = v
  end
  return Seatbelt.profile_tool(hull, FS)
end

--- byte offset of `needle` (a plain string) in `s`, or nil
local function at(s, needle)
  return (s:find(needle, 1, true))
end

describe("seatbelt quoting", function()
  it("wraps a plain path in an SBPL string literal", function()
    assert.equal('"/Users/u/proj"', Seatbelt.quote("/Users/u/proj"))
  end)

  it("escapes the two characters that could end the literal", function()
    assert.equal([["/a/b\"c"]], Seatbelt.quote('/a/b"c'))
    assert.equal([["/a/b\\c"]], Seatbelt.quote("/a/b\\c"))
  end)

  it("refuses a path with a control character rather than guessing", function()
    -- the profile travels as ONE argv string: a newline here would end the
    -- s-expression and let the rest of the path be read as rules
    assert.is_nil(Seatbelt.quote('/a/b\n(allow default)"'))
    assert.is_nil(Seatbelt.quote("/a/\tb"))
  end)

  it("drops an unquotable grant from the profile entirely, failing closed", function()
    local profile = agent({
      grants = { { path = '/Zebra"\n(allow default)', mode = "rw" }, { path = "/ok", mode = "rw" } },
    })
    assert.is_nil(at(profile, "Zebra"))
    assert.truthy(at(profile, '(allow file-read* file-write* (subpath "/ok"))'))
  end)

  it("drops the whole rule when nothing in it survives quoting", function()
    -- an empty filter list is an SBPL syntax error, so a rule with no usable
    -- path must not be emitted at all
    local profile = agent({ grants = { { path = "/Zebra\n", mode = "ro" } } })
    assert.is_nil(at(profile, "(allow file-read* (subpath"))
  end)
end)

describe("seatbelt path normalization", function()
  it("rewrites the firmlinks the kernel matches against", function()
    assert.equal("/private/tmp", Seatbelt.normalize("/tmp", FS))
    assert.equal("/private/tmp/weave", Seatbelt.normalize("/tmp/weave", FS))
    assert.equal("/private/var/folders/x", Seatbelt.normalize("/var/folders/x", FS))
    assert.equal("/private/etc/ssl", Seatbelt.normalize("/etc/ssl", FS))
  end)

  it("leaves an already-private path alone", function()
    assert.equal("/private/tmp/x", Seatbelt.normalize("/private/tmp/x", FS))
  end)

  it("does not rewrite a path that merely starts with the same letters", function()
    assert.equal("/tmpfoo", Seatbelt.normalize("/tmpfoo", FS))
    assert.equal("/variable", Seatbelt.normalize("/variable", FS))
  end)

  it("strips trailing slashes, which break subpath matching", function()
    assert.equal("/Users/u/proj", Seatbelt.normalize("/Users/u/proj/", FS))
    assert.equal("/", Seatbelt.normalize("/", FS))
  end)

  it("resolves symlinks first, then the firmlink", function()
    local fs = {
      exists = function()
        return true
      end,
      realpath = function(path)
        return path == "/Users/u/link" and "/tmp/real" or nil
      end,
    }
    assert.equal("/private/tmp/real", Seatbelt.normalize("/Users/u/link", fs))
  end)
end)

describe("seatbelt agent profile", function()
  it("opens with the version and an allow-everything base", function()
    local profile = agent()
    assert.equal("(version 1)", profile:match("^[^\n]+"))
    -- bwrap's floor binds all of / READ-ONLY, so allow-then-deny-writes is
    -- the faithful translation, not a weakening
    assert.truthy(at(profile, "(allow default)"))
    assert.truthy(at(profile, "(deny file-write*)"))
    assert.is_true(at(profile, "(allow default)") < at(profile, "(deny file-write*)"))
  end)

  it("keeps devices and scratch space writable", function()
    local profile = agent()
    assert.truthy(at(profile, '(allow file-write* (subpath "/dev"))'))
    assert.truthy(at(profile, '(subpath "/private/tmp")'))
  end)

  -- The defining limitation, pinned so it cannot be undone by accident. Two
  -- attempts at read confinement (`file-read*`, then `file-read-data` with
  -- metadata left alone) BOTH killed the agent on a real kernel: getcwd walks
  -- the cwd's path to the root, and denying reads anywhere along it means node
  -- dies in bootstrap on uv_cwd. Read confinement here needs every ancestor of
  -- the cwd enumerated and re-allowed, and getting that wrong fails QUIETLY —
  -- so this backend does not attempt it, and says so.
  it("never denies reads, because the agent cannot boot without its cwd", function()
    local profile = agent({ grants = { { path = "/Users/u/.claude", mode = "rw" } } })
    assert.is_nil(profile:match("%(deny file%-read"))
    assert.is_nil(at(profile, '(deny file-read-data file-write* (subpath "/Users/u"))'))
  end)

  it("never denies reads in the tool hull either", function()
    assert.is_nil(tool():match("%(deny file%-read"))
  end)

  -- What it DOES deliver: nothing on the disk is writable except the grants,
  -- devices and scratch.
  it("denies every write, then grants back only what the hull asked for", function()
    local profile = agent({
      grants = {
        { path = "/Users/u/.claude", mode = "rw" },
        { path = "/Users/u/notes", mode = "ro" },
      },
    })
    local deny = at(profile, "(deny file-write*)")
    local state = at(profile, '(allow file-read* file-write* (subpath "/Users/u/.claude"))')
    assert.truthy(deny and state)
    assert.is_true(deny < state)
    -- a `ro` grant is a no-op: reading was never taken away, so there is
    -- nothing to give back, and emitting an allow would only be noise
    assert.is_nil(at(profile, "/Users/u/notes"))
  end)

  it("preserves grant order, so a later grant out-votes an earlier one", function()
    local profile = agent({
      grants = { { path = "/Users/u/a", mode = "rw" }, { path = "/Users/u/a/b", mode = "rw" } },
    })
    assert.is_true(at(profile, '(subpath "/Users/u/a")') < at(profile, '(subpath "/Users/u/a/b")'))
  end)
end)

describe("seatbelt tool profile", function()
  it("cuts the network unless the hull grants it", function()
    assert.truthy(at(tool(), "(deny network*)"))
    assert.is_nil(at(tool({ network = true }), "(deny network*)"))
  end)

  it("grants the hull's rw binds; ro binds have nothing to grant", function()
    local profile = tool({
      binds = { { path = "/proj/demo", mode = "rw" }, { path = "/data", mode = "ro" } },
    })
    assert.truthy(at(profile, '(allow file-read* file-write* (subpath "/proj/demo"))'))
    assert.is_nil(at(profile, "/data"))
  end)

  it("leaves a read-only bind unwritable under the global write deny", function()
    local profile = tool({ binds = { { path = "/data", mode = "ro" } } })
    local deny = at(profile, "(deny file-write*)")
    assert.truthy(deny)
    assert.is_nil(at(profile, '(allow file-read* file-write* (subpath "/data"))'))
  end)
end)

describe("seatbelt wrap", function()
  it("hands the profile to sandbox-exec inline, command and args after it", function()
    local cmd, args = Seatbelt.wrap_agent("gemini", { "--acp" }, {
      home = "/Users/u",
      cwd = "/Users/u/proj",
      grants = {},
    }, FS)
    assert.equal("sandbox-exec", cmd)
    assert.equal("-p", args[1])
    assert.truthy(args[2]:find("(version 1)", 1, true))
    assert.same({ "gemini", "--acp" }, { args[3], args[4] })
  end)

  it("wraps a tool the same way", function()
    local cmd, args = Seatbelt.wrap_tool("sh", { "-c", "x" }, {
      home = "/Users/u",
      network = false,
      binds = {},
    }, FS)
    assert.equal("sandbox-exec", cmd)
    assert.same({ "sh", "-c", "x" }, { args[3], args[4], args[5] })
  end)
end)

describe("seatbelt availability", function()
  it("is macOS-only", function()
    if vim.fn.has("mac") == 1 then
      assert.equal(vim.fn.executable("sandbox-exec") == 1, Seatbelt.available())
    else
      assert.is_false(Seatbelt.available())
    end
  end)
end)
