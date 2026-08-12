-- w:web_fetch (weave.tools.web_fetch): parity with Claude's WebFetch — https
-- upgrade, HTML→markdown, a 15-minute cache, and cross-host redirects
-- reported rather than followed. curl is scripted here (M._run), so nothing
-- in this spec touches the network.

local Permissions = require("weave.permissions")
local WebFetch = require("weave.tools.web_fetch")

--- Script curl: `answers` maps a URL to { status, headers?, body? }.
--- Returns the capture table (every argv seen, in order).
local function script(answers)
  local calls = {}
  WebFetch._run = function(argv, cb)
    local url = argv[#argv]
    calls[#calls + 1] = { argv = argv, url = url }
    local answer = answers[url]
    if not answer then
      return cb({ code = 6, stdout = "", stderr = "curl: (6) Could not resolve host" })
    end
    local headers = answer.headers or "content-type: text/html\r\n"
    local out = ("HTTP/1.1 %d Whatever\r\n%s\r\n%s"):format(answer.status, headers, answer.body or "")
    cb({ code = 0, stdout = out, stderr = "" })
  end
  return calls
end

--- Call the tool and return its response (sync: the scripted curl answers
--- immediately, and the tool's only async hop is vim.schedule).
local function fetch(args)
  local result
  WebFetch.def.handler(args, function(res)
    result = res
  end)
  vim.wait(1000, function()
    return result ~= nil
  end, 5)
  return result
end

--- The text of a response, whichever shape it came back in.
local function text_of(res)
  if type(res) == "string" then
    return res
  end
  return res and res.content and res.content[1] and res.content[1].text or ""
end

describe("tools.web_fetch", function()
  local saved_run, saved_curl

  before_each(function()
    saved_run, saved_curl = WebFetch._run, WebFetch.curl_path
    WebFetch.curl_path = function()
      return "/usr/bin/curl"
    end
    WebFetch._reset_cache()
  end)

  after_each(function()
    WebFetch._run, WebFetch.curl_path = saved_run, saved_curl
    WebFetch._reset_cache()
    Permissions._reset()
  end)

  describe("url handling", function()
    it("upgrades http to https and defaults a bare host to https", function()
      assert.equal("https://example.com/a", (WebFetch.normalize_url("http://example.com/a")))
      assert.equal("https://example.com", (WebFetch.normalize_url("example.com")))
      assert.equal("https://example.com/a", (WebFetch.normalize_url("  https://example.com/a  ")))
    end)

    it("refuses what it cannot fetch", function()
      local url, err = WebFetch.normalize_url("file:///etc/passwd")
      assert.is_nil(url)
      assert.truthy(err:find("http(s)", 1, true))
      assert.is_nil((WebFetch.normalize_url("")))
      assert.is_nil((WebFetch.normalize_url(nil)))
    end)

    it("resolves a Location against the URL it came from", function()
      assert.equal("https://a.test/x", WebFetch.resolve_location("https://a.test/dir/page", "/x"))
      assert.equal("https://a.test/dir/x", WebFetch.resolve_location("https://a.test/dir/page", "x"))
      assert.equal("https://b.test/x", WebFetch.resolve_location("https://a.test/p", "//b.test/x"))
      assert.equal("https://b.test/x", WebFetch.resolve_location("https://a.test/p", "https://b.test/x"))
    end)
  end)

  describe("fetching", function()
    it("returns the page as markdown, with its URL and title", function()
      script({
        ["https://example.com/docs"] = {
          status = 200,
          body = "<html><head><title>Docs</title></head><body><h1>Hi</h1><p>there</p></body></html>",
        },
      })
      local out = text_of(fetch({ url = "http://example.com/docs" }))
      assert.truthy(out:find("# https://example.com/docs", 1, true))
      assert.truthy(out:find("Title: Docs", 1, true))
      assert.truthy(out:find("# Hi\n\nthere", 1, true))
    end)

    it("passes non-HTML text through untouched", function()
      script({
        ["https://example.com/a.json"] = {
          status = 200,
          headers = "content-type: application/json\r\n",
          body = '{"a": 1}',
        },
      })
      assert.truthy(text_of(fetch({ url = "https://example.com/a.json" })):find('{"a": 1}', 1, true))
    end)

    it("refuses a body it cannot read as text", function()
      script({
        ["https://example.com/x.png"] = { status = 200, headers = "content-type: image/png\r\n", body = "\137PNG" },
      })
      local res = fetch({ url = "https://example.com/x.png" })
      assert.is_true(res.isError)
      assert.truthy(text_of(res):find("image/png", 1, true))
    end)

    it("reports the HTTP status when the server says no", function()
      script({ ["https://example.com/gone"] = { status = 404, body = "nope" } })
      local res = fetch({ url = "https://example.com/gone" })
      assert.is_true(res.isError)
      assert.truthy(text_of(res):find("HTTP 404", 1, true))
    end)

    it("surfaces curl's own failure", function()
      script({})
      local res = fetch({ url = "https://nowhere.invalid" })
      assert.is_true(res.isError)
      assert.truthy(text_of(res):find("Could not resolve host", 1, true))
    end)

    it("says so when curl is missing, and names the config key", function()
      script({})
      WebFetch.curl_path = function()
        return nil
      end
      local res = fetch({ url = "https://example.com" })
      assert.is_true(res.isError)
      assert.truthy(text_of(res):find("tools.curl_path", 1, true))
    end)

    it("truncates a page too large to be context", function()
      script({
        ["https://example.com/big"] = {
          status = 200,
          headers = "content-type: text/plain\r\n",
          body = string.rep("x", WebFetch.MAX_CHARS + 500),
        },
      })
      local out = text_of(fetch({ url = "https://example.com/big" }))
      assert.truthy(out:find("truncated", 1, true))
      assert.is_true(#out < WebFetch.MAX_CHARS + 300)
    end)
  end)

  describe("redirects", function()
    it("follows a same-host redirect", function()
      local calls = script({
        ["https://a.test/old"] = { status = 301, headers = "location: /new\r\n" },
        ["https://a.test/new"] = { status = 200, body = "<p>moved</p>" },
      })
      assert.truthy(text_of(fetch({ url = "https://a.test/old" })):find("moved", 1, true))
      assert.equal(2, #calls)
    end)

    it("reports a cross-host redirect instead of following it", function()
      local calls = script({
        ["https://a.test/out"] = { status = 302, headers = "location: https://b.test/landing\r\n" },
        ["https://b.test/landing"] = { status = 200, body = "<p>should not be read</p>" },
      })
      local out = text_of(fetch({ url = "https://a.test/out" }))
      assert.truthy(out:find("https://b.test/landing", 1, true))
      assert.truthy(out:find("different host", 1, true))
      assert.is_nil(out:find("should not be read", 1, true))
      -- the second host was never contacted: the rule matched the first one
      assert.equal(1, #calls)
    end)

    it("gives up on a redirect loop", function()
      script({
        ["https://a.test/loop"] = { status = 302, headers = "location: /loop\r\n" },
      })
      local res = fetch({ url = "https://a.test/loop" })
      assert.is_true(res.isError)
      assert.truthy(text_of(res):find("redirects", 1, true))
    end)
  end)

  describe("cache", function()
    it("serves a second read of the same URL without fetching again", function()
      local calls = script({ ["https://example.com/p"] = { status = 200, body = "<p>one</p>" } })
      assert.truthy(text_of(fetch({ url = "https://example.com/p" })):find("one", 1, true))
      local again = text_of(fetch({ url = "https://example.com/p" }))
      assert.truthy(again:find("one", 1, true))
      assert.truthy(again:find("cache", 1, true))
      assert.equal(1, #calls)
    end)

    it("refetches once the entry is older than the TTL", function()
      local calls = script({ ["https://example.com/p"] = { status = 200, body = "<p>one</p>" } })
      local now = 1000
      WebFetch._now = function()
        return now
      end
      fetch({ url = "https://example.com/p" })
      now = now + WebFetch.CACHE_TTL_MS + 1
      fetch({ url = "https://example.com/p" })
      assert.equal(2, #calls)
      WebFetch._now = function()
        return vim.uv.now()
      end
    end)
  end)

  describe("confinement", function()
    it("runs curl under the hull for weave:web_fetch — network, no binds", function()
      Permissions.set_mode("on")
      Permissions.set_project_root("/proj/demo")
      Permissions.set_active("ask")
      local hull = Permissions.tool_sandbox(Permissions.get("ask"), "weave:web_fetch")
      assert.same({}, hull.binds)
      assert.is_true(hull.network)
      -- ...while everything else stays on the workspace, off the network
      local tasks = Permissions.tool_sandbox(Permissions.get("ask"), "weave:task_start")
      assert.same({ { path = "/proj/demo", mode = "rw" } }, tasks.binds)
      assert.is_false(tasks.network)
    end)

    it("is a rule of its own in every sandboxed preset (its resource is a URL)", function()
      Permissions.set_mode("on")
      Permissions.set_project_root("/proj/demo")
      for _, name in ipairs({ "ask", "read_only", "edit" }) do
        Permissions.set_active(name)
        assert.equal("ask", Permissions.resolve({ tool = "weave:web_fetch", resource = "https://x.test" }), name)
      end
      Permissions.set_active("auto")
      assert.equal("allow", Permissions.resolve({ tool = "weave:web_fetch", resource = "https://x.test" }))
    end)

    it("can be scoped by host, since the resource IS the url", function()
      Permissions.save_preset({
        name = "docs-only",
        rules = {
          { tool = "weave:web_fetch", resource = "https://docs.example.com/**", decision = "allow" },
          { tool = "weave:web_fetch", decision = "deny", message = "only the docs site" },
          { tool = "*", decision = "allow" },
        },
      })
      Permissions.set_active("docs-only")
      assert.equal("allow", Permissions.resolve({ tool = "weave:web_fetch", resource = "https://docs.example.com/a" }))
      assert.equal("deny", Permissions.resolve({ tool = "weave:web_fetch", resource = "https://evil.test/a" }))
      -- and the URL-shaped resource must not trip the hull lint
      assert.same({}, Permissions.lint_preset(Permissions.get("docs-only")))
    end)
  end)
end)
