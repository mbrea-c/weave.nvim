-- Session discovery (roadmap: Kiro session support). Kiro CLI supports
-- loadSession but NOT session/list, so its restorable sessions are read from
-- the on-disk index (~/.kiro/sessions/cli/<id>.json). SessionSource normalises
-- BOTH that filesystem fallback AND ACP session/list to weave.acp.SessionInfo[],
-- so the restore picker and load_session replay stay provider-agnostic.

local SessionSource = require("weave.session_source")

-- Write a Kiro index file `<id>.json` into `dir`.
local function write_index(dir, id, data)
  vim.fn.writefile({ vim.json.encode(data) }, dir .. "/" .. id .. ".json")
end

describe("weave.session_source kiro filesystem fallback", function()
  local dir
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  it("keeps only cwd-matching, titled sessions and maps their fields", function()
    write_index(dir, "s1", { session_id = "s1", cwd = "/work/proj", title = "Fix the parser", updated_at = "2026-07-01T10:00:00Z" })
    -- different cwd → excluded
    write_index(dir, "s2", { session_id = "s2", cwd = "/work/other", title = "Elsewhere", updated_at = "2026-07-02T10:00:00Z" })
    -- empty (never-prompted) session, no title → excluded
    write_index(dir, "s3", { session_id = "s3", cwd = "/work/proj", title = "", updated_at = "2026-07-03T10:00:00Z" })

    local got = SessionSource._kiro_sessions_for_cwd("/work/proj", dir)
    assert.equal(1, #got)
    assert.equal("s1", got[1].sessionId)
    assert.equal("/work/proj", got[1].cwd)
    assert.equal("Fix the parser", got[1].title)
    assert.equal("2026-07-01T10:00:00Z", got[1].updatedAt)
  end)

  it("skips malformed files and non-.json siblings without erroring", function()
    write_index(dir, "good", { session_id = "good", cwd = "/w", title = "Good", updated_at = "2026-07-01T00:00:00Z" })
    vim.fn.writefile({ "not json {{{" }, dir .. "/bad.json") -- unparseable → skipped
    vim.fn.writefile({ "transcript" }, dir .. "/good.jsonl") -- sibling transcript → ignored

    local got = SessionSource._kiro_sessions_for_cwd("/w", dir)
    assert.equal(1, #got)
    assert.equal("good", got[1].sessionId)
  end)

  it("returns empty for a missing directory", function()
    assert.same({}, SessionSource._kiro_sessions_for_cwd("/w", dir .. "/nope"))
  end)
end)

describe("weave.session_source.list routing", function()
  it("uses ACP session/list when the provider supports it, newest-first", function()
    local client = {
      agent_capabilities = { sessionCapabilities = { list = true } },
      list_sessions = function(_, _cwd, cb)
        cb({
          sessions = {
            { sessionId = "old", updatedAt = "2026-06-01T00:00:00Z" },
            { sessionId = "new", updatedAt = "2026-07-01T00:00:00Z" },
          },
        }, nil)
      end,
    }
    local got
    SessionSource.list(client, "claude-agent-acp", "/w", function(s)
      got = s
    end)
    assert.equal(2, #got)
    assert.equal("new", got[1].sessionId)
  end)

  it("returns empty (never errors) when ACP session/list fails", function()
    local client = {
      agent_capabilities = { sessionCapabilities = { list = true } },
      list_sessions = function(_, _cwd, cb)
        cb(nil, { message = "boom" })
      end,
    }
    local got
    SessionSource.list(client, "claude-agent-acp", "/w", function(s)
      got = s
    end)
    assert.same({}, got)
  end)

  it("falls back to the Kiro filesystem index (newest-first) when the provider is kiro-acp", function()
    local home = vim.fn.tempname()
    local cli = home .. "/.kiro/sessions/cli"
    vim.fn.mkdir(cli, "p")
    write_index(cli, "old", { session_id = "old", cwd = "/w", title = "Older", updated_at = "2026-07-01T00:00:00Z" })
    write_index(cli, "new", { session_id = "new", cwd = "/w", title = "Newer", updated_at = "2026-07-05T00:00:00Z" })
    local saved_home = vim.env.HOME
    vim.env.HOME = home

    local client = { agent_capabilities = {} } -- no sessionCapabilities.list
    local got
    SessionSource.list(client, "kiro-acp", "/w", function(s)
      got = s
    end)
    vim.env.HOME = saved_home

    assert.equal(2, #got)
    assert.equal("new", got[1].sessionId) -- sorted newest-first, from the FS index
    assert.equal("Newer", got[1].title)
  end)

  it("returns empty for a provider with neither list support nor a known fallback", function()
    local client = { agent_capabilities = {} }
    local got
    SessionSource.list(client, "mystery-acp", "/w", function(s)
      got = s
    end)
    assert.same({}, got)
  end)
end)
