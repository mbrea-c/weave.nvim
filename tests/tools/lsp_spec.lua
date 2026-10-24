local Tools = require("weave.tools")
local Permissions = require("weave.permissions")
local Session = require("weave.session")

describe("editor language tools", function()
  local root, project, buffers, sessions, defs, ctx, session, clients, saved_clients, live, requests
  local ns = vim.api.nvim_create_namespace("weave-lsp-spec")

  local function file(name, lines)
    local path = root .. "/" .. name
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines or { "aλ😀z", "second line" }, path)
    return path
  end

  local function buffer(name, lines)
    local path = file(name, lines)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    buffers[#buffers + 1] = buf
    return buf, path
  end

  local function context(preset, rules)
    local s = Session:new({ permissions = { preset = preset or "read_only", rules = rules } })
    s:permissions().set_project_root(project)
    sessions[#sessions + 1] = s
    return { caller = { session = s, valid = function() return live end } }, s
  end

  local function start(name, args, call_ctx)
    local out, count
    count = 0
    local def = defs["weave_" .. name]
    assert.is_not_nil(def, "tool not registered: " .. name)
    local ok, err = pcall(def.handler, args or {}, function(value) out, count = value, count + 1 end, call_ctx or ctx)
    if not ok then out = { isError = true, content = { { type = "text", text = tostring(err) } } } end
    return function(wait)
      if wait ~= false then vim.wait(500, function() return out ~= nil end, 2) end
      if type(out) == "string" then return vim.json.decode(out), count end
      return out, count
    end
  end

  local function call(name, args, call_ctx)
    local out = start(name, args, call_ctx)()
    assert.is_not_nil(out, "tool never responded")
    if out.isError then error(vim.inspect(out)) end
    return out
  end

  local function client(id, buf, result, opts)
    opts = opts or {}
    local c = { id = id, name = "test-" .. id, offset_encoding = opts.encoding or "utf-16",
      attached_buffers = { [buf] = true }, cancelled = {} }
    function c:is_stopped() return false end
    function c:supports_method(method) return not opts.unsupported or method ~= opts.unsupported end
    function c:request(method, params, cb, request_buf)
      local req = { client = self, method = method, params = params, cb = cb, buffer = request_buf }
      requests[#requests + 1] = req
      if opts.reject then return false end
      if not opts.pending then cb(opts.error, result) end
      return true, #requests
    end
    function c:cancel_request(id_to_cancel) self.cancelled[#self.cancelled + 1] = id_to_cancel end
    clients[#clients + 1] = c
    return c
  end

  local function range(first, last)
    return { start = { line = 0, character = first or 0 }, ["end"] = { line = 0, character = last or 1 } }
  end

  before_each(function()
    root = vim.fn.tempname()
    project = root .. "/project"
    vim.fn.mkdir(project, "p")
    buffers, sessions, clients, requests, live = {}, {}, {}, {}, true
    Permissions._reset()
    Permissions.set_mode("on")
    Permissions.set_active("yolo") -- selected/global policy must never substitute for the caller
    ctx, session = context()
    defs = {}
    local ok, Runtime = pcall(require, "weave.tools.lsp_runtime")
    if ok then Runtime._reset() end
    Tools.register_into({ register_tool = function(name, def) defs[name] = def end })
    saved_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function(filter)
      local out = {}
      for _, c in ipairs(clients) do
        if not filter or not filter.bufnr or c.attached_buffers[filter.bufnr] then out[#out + 1] = c end
      end
      return out
    end
  end)

  after_each(function()
    vim.lsp.get_clients = saved_clients
    for _, s in ipairs(sessions) do s:stop() end
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end
    vim.fn.delete(root, "rf")
    Permissions._reset()
  end)

  it("cancels pending LSP requests promptly when the caller resets", function()
    local buf = buffer("project/main.lua")
    session:_reset_config_session(true)
    local Context = require("weave.tool_context")
    ctx = { caller = Context.authenticate(Context.bind(session)) }
    local c = client(1, buf, nil, { pending = true })
    local done = start("definition", { buffer = buf, line = 1, column = 1 })
    session:_reset_config_session(true)
    local out, count = done()
    assert.is_not_nil(out)
    assert.is_true(out.isError)
    assert.equal(1, #c.cancelled)
    assert.equal(1, count)
    assert.equal(0, #session._event_listeners)
  end)

  it("omits results from a server which detached while its request was pending", function()
    local buf, path = buffer("project/main.lua")
    local c = client(1, buf, nil, { pending = true })
    local done = start("definition", { buffer = buf, line = 1, column = 1 })
    c.attached_buffers[buf] = nil
    requests[1].cb(nil, { uri = vim.uri_from_fname(path), range = range() })
    local out = done()
    assert.equal(0, #out.items)
    assert.is_true(out.partial)
    assert.equal("unavailable", out.clients[1].status)
  end)

  it("contains per-client parameter errors and still returns other servers' results", function()
    local buf, path = buffer("project/main.lua")
    client(1, buf, nil, { encoding = "unsupported-encoding" })
    client(2, buf, { uri = vim.uri_from_fname(path), range = range() })
    local out = call("definition", { buffer = buf, line = 1, column = 1 })
    assert.equal(1, #out.items)
    assert.is_true(out.partial)
    assert.equal("error", out.clients[1].status)
  end)

  it("supports explicitly permitted unnamed buffers without borrowing another buffer's text", function()
    local other = vim.api.nvim_create_buf(true, false)
    local buf = vim.api.nvim_create_buf(true, false)
    buffers[#buffers + 1], buffers[#buffers + 2] = other, buf
    vim.api.nvim_buf_set_lines(other, 0, -1, false, { "unrelated" })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "aλ😀z" })
    ctx = context("yolo")
    client(1, buf, { { name = "scratch", kind = 12, range = range(4, 5) } })
    local out = call("document_symbols", { buffer = buf })
    assert.equal(vim.NIL, out.items[1].path)
    assert.equal(buf, out.items[1].buffer)
    assert.same({ line = 1, column = 8 }, out.items[1].range.start)
    clients[1] = nil
    client(2, buf, { contents = "markdown *hover*", range = range(4, 5) })
    out = call("hover", { buffer = buf, line = 1, column = 1 })
    assert.equal("markdown", out.items[1].format) -- legacy MarkedString string
    assert.same({ line = 1, column = 8 }, out.items[1].range.start)
  end)

  it("uses the real Neovim client and flushes unsaved text before requesting", function()
    local buf, path = buffer("project/native.lua")
    vim.lsp.get_clients = saved_clients
    local events, closed, serial, dispatcher = {}, false, 0
    local id = vim.lsp.start({
      name = "weave-native-spec", root_dir = project,
      flags = { debounce_text_changes = 60000 },
      cmd = function(dispatch)
        dispatcher = dispatch
        return {
          request = function(method, params, cb)
            serial = serial + 1
            events[#events + 1] = { method = method, params = params }
            if method == "initialize" then
              vim.schedule(function()
                cb(nil, { capabilities = { definitionProvider = true, positionEncoding = "utf-16",
                  textDocumentSync = { openClose = true, change = 1 } } })
              end)
            else
              vim.schedule(function() cb(nil, { uri = vim.uri_from_fname(path), range = range(4, 5) }) end)
            end
            return true, serial
          end,
          notify = function(method, params)
            events[#events + 1] = { method = method, params = params }
            return true
          end,
          is_closing = function() return closed end,
          terminate = function() closed = true; dispatcher.on_exit(0, 0) end,
        }
      end,
    }, { bufnr = buf, reuse_client = function() return false end })
    assert.is_not_nil(id)
    local c = vim.lsp.get_client_by_id(id)
    local ok, err = pcall(function()
      assert.is_true(vim.wait(500, function() return c.initialized and c.attached_buffers[buf] end, 2))
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "bλ😀z", "unsaved second" })
      local out = call("definition", { buffer = buf, line = 1, column = 8 })
      assert.same({ line = 1, column = 8 }, out.items[1].range.start)
      local change, query
      for i, event in ipairs(events) do
        if event.method == "textDocument/didChange" then change = i end
        if event.method == "textDocument/definition" then query = i end
      end
      assert.is_not_nil(change)
      assert.is_true(change < query)
      assert.truthy(events[change].params.contentChanges[1].text:find("bλ😀z", 1, true))
      assert.equal(4, events[query].params.position.character)
      assert.is_true(vim.bo[buf].modified)
      assert.same({ "aλ😀z", "second line" }, vim.fn.readfile(path))
      dispatcher.notification("textDocument/publishDiagnostics", {
        uri = vim.uri_from_fname(path), version = vim.lsp.util.buf_versions[buf], diagnostics = {},
      })
      local Runtime = require("weave.tools.lsp_runtime")
      assert.is_true(vim.wait(300, function()
        return Runtime.diagnostics(c, buf).report_received
      end, 2))
      local diagnostics = call("diagnostics", { buffer = buf, startup_timeout_ms = 0, diagnostic_timeout_ms = 0 })
      assert.equal("current_version", diagnostics.clients[1].diagnostics.state)
      assert.equal(0, diagnostics.clients[1].diagnostics.report_count)
      assert.is_false(diagnostics.can_conclude_clean)
    end)
    c:stop(true)
    vim.wait(100, function() return c:is_stopped() end, 2)
    if not ok then error(err) end
  end)

  it("searches a permitted symlinked directory without excluding canonical server locations", function()
    local buf, path = buffer("project/real/main.lua")
    local alias = project .. "/alias"
    assert(vim.uv.fs_symlink(project .. "/real", alias))
    client(1, buf, { { name = "through-alias", kind = 12,
      location = { uri = vim.uri_from_fname(path), range = range() } } })
    local out = call("workspace_symbols", { root = alias, query = "through" })
    assert.equal(1, #out.items)
    assert.equal(path, out.items[1].path)
  end)

  it("finds a loaded buffer through a permitted file alias", function()
    local buf, path = buffer("project/real.lua")
    local alias = project .. "/alias.lua"
    assert(vim.uv.fs_symlink(path, alias))
    vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, message = "cached through alias" } })
    local out = call("diagnostics", { path = alias })
    assert.equal(1, #out.items)
    assert.equal(buf, out.target.buffer)
  end)

  it("a tool-specific allow cannot bypass an independent file-read denial", function()
    local buf, path = buffer("project/secret.lua")
    client(1, buf, { contents = "private" })
    ctx = context("yolo", {
      { tool = "weave:hover", decision = "allow" },
      { tool = "weave:read", resource = path, decision = "deny" },
    })
    local out = start("hover", { buffer = buf, line = 1, column = 1 })()
    assert.is_true(out.isError)
    assert.equal(0, #requests)
    assert.falsy(vim.json.encode(out):find("private", 1, true))
  end)

  it("an aggregate ask-once approval does not bypass a more specific ask on one result", function()
    local public = buffer("project/public.lua")
    local private = buffer("project/private.lua")
    for _, buf in ipairs({ public, private }) do
      vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, message = "message-" .. buf } })
    end
    ctx, session = context("ask", {
      { tool = "weave:read", resource = project .. "/private.lua", decision = "ask" },
    })
    local done = start("diagnostics")
    session:get_store():pop_permission().respond("allow_once")
    local out = done()
    assert.equal(1, #out.items)
    assert.equal(public, out.items[1].buffer)
    assert.is_true(out.filtered)
  end)

  it("bounds diagnostic message text and marks truncation explicitly", function()
    local buf = buffer("project/main.lua")
    vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, message = string.rep("λ", 5000) } })
    local out = call("diagnostics", { buffer = buf })
    assert.equal(4096, vim.fn.strchars(out.items[1].message))
    assert.is_true(out.items[1].truncated)
    assert.is_true(out.truncated)
  end)

  it("reads each unopened result file once while normalizing multiple references", function()
    local buf = buffer("project/main.lua")
    local path = file("project/target.lua")
    client(1, buf, {
      { uri = vim.uri_from_fname(path), range = range(0, 1) },
      { uri = vim.uri_from_fname(path), range = range(1, 2) },
    })
    local readfile, count = vim.fn.readfile, 0
    vim.fn.readfile = function(name, ...)
      if name == path then count = count + 1 end
      return readfile(name, ...)
    end
    local ok, err = pcall(function()
      local out = call("references", { buffer = buf, line = 1, column = 1 })
      assert.equal(2, #out.items)
      assert.equal(1, count)
    end)
    vim.fn.readfile = readfile
    if not ok then error(err) end
  end)

  it("honors separate ask-once approvals for a canonical alias target", function()
    local buf, path = buffer("outside/canonical.lua")
    local alias = project .. "/alias.lua"
    assert(vim.uv.fs_symlink(path, alias))
    vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, message = "explicitly approved" } })
    ctx, session = context("ask", {
      { tool = "weave:*", resource = path, decision = "ask" },
    })
    local done = start("diagnostics", { path = alias })
    for _ = 1, 3 do
      local pending = session:get_store():pop_permission()
      assert.is_not_nil(pending)
      pending.respond("allow_once")
    end
    local out = done()
    assert.falsy(out.isError, vim.inspect(out))
    assert.equal(1, #out.items)
    assert.equal(0, #session:permissions().grants())
  end)

  local function payload(out)
    if out and out.isError then return vim.json.decode(out.content[1].text) end
    return out
  end

  it("rejects an unloaded diagnostics file with an actionable structured state", function()
    local path = file("project/unopened.lua")
    local before = #vim.api.nvim_list_bufs()
    local out = start("diagnostics", { path = path })()
    assert.is_true(out.isError)
    local info = payload(out)
    assert.equal("buffer_not_loaded", info.status)
    assert.equal("load", info.next_action.argument)
    assert.equal(true, info.next_action.value)
    assert.equal(before, #vim.api.nvim_list_bufs())
    assert.same({}, info.items)
    assert.is_false(info.can_conclude_clean)
  end)

  it("loads only with explicit consent, triggers normal filetype setup, and preserves focus", function()
    local path = file("project/background.lua")
    local current_buf, current_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    local group = vim.api.nvim_create_augroup("weave-lsp-background-spec", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group, pattern = "lua", callback = function(event)
        local c = client(10, event.buf, { contents = { kind = "plaintext", value = "loaded in background" } })
        c.initialized = false
        buffers[#buffers + 1] = event.buf
        vim.defer_fn(function() c.initialized = true end, 30)
      end,
    })
    local ok, err = pcall(function()
      local out = call("hover", { path = path, load = true, startup_timeout_ms = 300, line = 1, column = 1 })
      assert.equal("loaded in background", out.items[1].text)
      assert.is_true(out.target.loaded_by_tool)
      assert.is_true(out.target.loaded)
      assert.equal("lua", vim.bo[out.target.buffer].filetype)
      assert.equal(current_buf, vim.api.nvim_get_current_buf())
      assert.equal(current_win, vim.api.nvim_get_current_win())
      assert.is_false(vim.bo[out.target.buffer].buflisted)
      assert.is_false(vim.bo[out.target.buffer].modified)
    end)
    vim.api.nvim_del_augroup_by_id(group)
    if not ok then error(err) end
  end)

  it("does not load or run FileType autocmds before read authorization", function()
    local path = file("project/denied.lua")
    local calls, group = 0, vim.api.nvim_create_augroup("weave-lsp-denied-spec", { clear = true })
    vim.api.nvim_create_autocmd("FileType", { group = group, callback = function() calls = calls + 1 end })
    ctx = context("yolo", { { tool = "weave:read", resource = path, decision = "deny" } })
    local out = start("hover", { path = path, load = true, line = 1, column = 1 })()
    vim.api.nvim_del_augroup_by_id(group)
    assert.is_true(out.isError)
    assert.is_nil(require("weave.tools.editor_scope").find_buffer(path))
    assert.equal(0, calls)
  end)

  it("reports initializing and ready clients separately, rather than declaring an empty query complete", function()
    local buf = buffer("project/main.lua")
    local fast = client(1, buf, {})
    fast.initialized = true
    local slow = client(2, buf, {})
    slow.initialized = false
    local out = call("definition", { buffer = buf, line = 1, column = 1, startup_timeout_ms = 0 })
    assert.equal("partial", out.status)
    assert.is_true(out.partial)
    assert.is_false(out.analysis_complete)
    assert.equal("ready", out.clients[1].state)
    assert.equal("ok", out.clients[1].status)
    assert.equal("initializing", out.clients[2].state)
    assert.equal("not_requested", out.clients[2].status)
    assert.equal(1, #requests)
    assert.equal("retry", out.next_action.action)
  end)

  it("waits asynchronously for a slow client's initialization before querying it", function()
    local buf, path = buffer("project/main.lua")
    local c = client(1, buf, { uri = vim.uri_from_fname(path), range = range() })
    c.initialized = false
    local done = start("definition", { buffer = buf, line = 1, column = 1, startup_timeout_ms = 300 })
    assert.is_nil(done(false))
    assert.equal(0, #requests)
    vim.defer_fn(function() c.initialized = true end, 40)
    local out = done()
    assert.equal(1, #out.items)
    assert.equal("ready", out.clients[1].state)
    assert.is_true(out.startup.waited_ms >= 20)
    assert.is_false(out.startup.timed_out)
  end)

  it("reports a startup timeout and retains the initializing client's identity", function()
    local buf = buffer("project/main.lua")
    local c = client(1, buf, nil)
    c.initialized = false
    local out = start("hover", { buffer = buf, line = 1, column = 1, startup_timeout_ms = 20 })()
    assert.is_true(out.isError)
    local info = payload(out)
    assert.equal("initializing", info.status)
    assert.equal("initializing", info.clients[1].state)
    assert.is_true(info.startup.timed_out)
    assert.equal("retry", info.next_action.action)
    assert.equal(0, #requests)
  end)

  it("distinguishes no attached server from an initialized unsupported server", function()
    local buf = buffer("project/main.lua")
    local info = payload(start("hover", { buffer = buf, line = 1, column = 1, startup_timeout_ms = 0 })())
    assert.equal("no_server", info.status)
    local c = client(1, buf, nil, { unsupported = "textDocument/hover" })
    c.initialized = true
    info = payload(start("hover", { buffer = buf, line = 1, column = 1, startup_timeout_ms = 0 })())
    assert.equal("unsupported", info.status)
    assert.equal("unsupported", info.clients[1].state)
    assert.is_false(info.clients[1].supports_method)
    assert.equal("unknown", info.clients[1].indexing)
  end)

  it("cancels startup waiting on reset without querying or retaining listeners", function()
    local buf = buffer("project/main.lua")
    session:_reset_config_session(true)
    local Context = require("weave.tool_context")
    ctx = { caller = Context.authenticate(Context.bind(session)) }
    client(1, buf, {}).initialized = false
    local done = start("definition", { buffer = buf, line = 1, column = 1, startup_timeout_ms = 300 })
    session:_reset_config_session(true)
    assert.is_true(done().isError)
    assert.equal(0, #requests)
    assert.equal(0, #session._event_listeners)
  end)

  it("does not treat none-ls readiness as a diagnostic report from initializing jdtls", function()
    local buf = buffer("project/main.java", { "class Main {}" })
    local formatter = client(1, buf, {})
    formatter.name, formatter.initialized = "none-ls", true
    formatter.server_capabilities = { documentFormattingProvider = true }
    local java = client(2, buf, {})
    java.name, java.initialized = "jdtls", false
    local out = call("diagnostics", { buffer = buf, startup_timeout_ms = 0, diagnostic_timeout_ms = 0 })
    assert.same({}, out.items)
    assert.is_false(out.can_conclude_clean)
    assert.is_true(out.partial)
    assert.equal("ready", out.clients[1].state)
    assert.equal("not_received", out.clients[1].diagnostics.state)
    assert.equal("unknown", out.clients[1].diagnostics.push_support)
    assert.equal(vim.NIL, out.clients[1].supports_method) -- push diagnostics cannot be inferred from capabilities
    assert.equal("initializing", out.clients[2].state)
    assert.equal("not_received", out.clients[2].diagnostics.state)
    assert.equal("diagnostics_pending", out.status)
  end)

  it("waits for each diagnostic client, even after another client published an empty report", function()
    local buf = buffer("project/main.java", { "class Main {}" })
    local formatter, java = client(1, buf, {}), client(2, buf, {})
    formatter.initialized, java.initialized = true, true
    local Runtime = require("weave.tools.lsp_runtime")
    vim.lsp.util.buf_versions[buf] = 1
    Runtime.record_diagnostics(1, buf, 1, 0)
    local done = start("diagnostics", { buffer = buf, startup_timeout_ms = 0, diagnostic_timeout_ms = 300 })
    assert.is_nil(done(false))
    vim.defer_fn(function()
      Runtime.record_diagnostics(2, buf, 1, 0)
    end, 40)
    local out = done()
    assert.equal("current_version", out.clients[1].diagnostics.state)
    assert.equal("current_version", out.clients[2].diagnostics.state)
    assert.equal(0, out.clients[2].diagnostics.report_count)
    assert.is_false(out.can_conclude_clean) -- initialization/reporting still does not prove full indexing
    assert.is_false(out.diagnostic_wait.timed_out)
    assert.is_true(out.diagnostic_wait.waited_ms >= 20)
  end)

  it("distinguishes unversioned or stale reports from current-version diagnostics", function()
    local buf = buffer("project/main.lua")
    client(1, buf, {}).initialized = true
    local Runtime = require("weave.tools.lsp_runtime")
    Runtime.record_diagnostics(1, buf, nil, 0)
    local out = call("diagnostics", { buffer = buf, startup_timeout_ms = 0, diagnostic_timeout_ms = 0 })
    assert.equal("version_unknown", out.clients[1].diagnostics.state)
    assert.is_true(out.clients[1].diagnostics.report_received)
    Runtime.record_diagnostics(1, buf, vim.lsp.util.buf_versions[buf], 0)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed since report" })
    out = call("diagnostics", { buffer = buf, startup_timeout_ms = 0, diagnostic_timeout_ms = 0 })
    assert.equal("stale", out.clients[1].diagnostics.state)
    assert.is_false(out.can_conclude_clean)
  end)

  it("retains cached diagnostics on a diagnostic-report timeout and says coverage is incomplete", function()
    local buf = buffer("project/main.lua")
    client(1, buf, {}).initialized = true
    vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, message = "cached error", severity = 1 } })
    local out = call("diagnostics", { buffer = buf, diagnostic_timeout_ms = 20, startup_timeout_ms = 0 })
    assert.equal(1, #out.items)
    assert.equal("diagnostics_pending", out.status)
    assert.is_true(out.diagnostic_wait.timed_out)
    assert.is_true(out.partial)
    assert.is_false(out.can_conclude_clean)
    assert.equal("not_received", out.clients[1].diagnostics.state)
  end)

  it("refuses a buffer which changed its file identity during permission approval", function()
    local buf = buffer("project/original.lua")
    client(1, buf, { contents = "must not query" })
    ctx, session = context("ask")
    local done = start("hover", { buffer = buf, line = 1, column = 1 })
    vim.api.nvim_buf_set_name(buf, project .. "/different.lua")
    session:get_store():pop_permission().respond("allow_once")
    local out = done()
    assert.is_true(out.isError)
    assert.equal(0, #requests)
  end)

  it("does not query a filetype autocmd's redirected buffer without authorizing that file", function()
    local path = file("project/redirect.lua")
    local group = vim.api.nvim_create_augroup("weave-lsp-redirect-spec", { clear = true })
    vim.api.nvim_create_autocmd("FileType", { group = group, pattern = "lua", callback = function(event)
      buffers[#buffers + 1] = event.buf
      vim.api.nvim_buf_set_name(event.buf, root .. "/outside/redirected.lua")
      client(1, event.buf, { contents = "private redirected data" })
    end })
    local out = start("hover", { path = path, load = true, line = 1, column = 1, startup_timeout_ms = 0 })()
    vim.api.nvim_del_augroup_by_id(group)
    assert.is_true(out.isError)
    assert.equal(0, #requests)
  end)

  it("rechecks read permissions while waiting for startup", function()
    local buf, path = buffer("project/main.lua")
    client(1, buf, {}).initialized = false
    local done = start("hover", { buffer = buf, line = 1, column = 1, startup_timeout_ms = 300 })
    session:permissions().add_grant({ tool = "weave:read", resource = path, decision = "deny" })
    assert.is_true(done().isError)
    assert.equal(0, #requests)
    assert.equal(0, #session._event_listeners)
  end)

  it("retains a stopped client's identity when it exits during initialization", function()
    local buf = buffer("project/main.lua")
    local c, stopped = client(1, buf, {}), false
    c.initialized = false
    function c:is_stopped() return stopped end
    local done = start("hover", { buffer = buf, line = 1, column = 1, startup_timeout_ms = 300 })
    vim.defer_fn(function() stopped = true; clients = {} end, 30)
    local info = payload(done())
    assert.equal("stopped", info.status)
    assert.equal("stopped", info.clients[1].state)
    assert.equal(1, info.clients[1].id)
    assert.equal(0, #requests)
  end)

  it("validates an invalid position before waiting for a slow server", function()
    local buf = buffer("project/main.lua")
    client(1, buf, {}).initialized = false
    local done = start("hover", { buffer = buf, line = 99, column = 1, startup_timeout_ms = 300 })
    assert.is_true(done(false).isError)
    assert.equal(0, #requests)
    assert.equal(0, #session._event_listeners)
  end)

  it("contains malformed per-client encoding settings without leaking an active request timer", function()
    local buf, path = buffer("project/main.lua")
    client(1, buf, nil, { encoding = 123 })
    client(2, buf, { uri = vim.uri_from_fname(path), range = range() })
    local out = call("definition", { buffer = buf, line = 1, column = 1 })
    assert.equal("partial", out.status)
    assert.equal(1, #out.items)
    assert.equal("error", out.clients[1].status)
  end)

  it("registers six namespaced read-only tools", function()
    for _, name in ipairs({ "diagnostics", "document_symbols", "workspace_symbols", "definition", "references", "hover" }) do
      assert.is_not_nil(defs["weave_" .. name])
      assert.is_true(Tools.OWNS["weave_" .. name])
      assert.is_nil(defs[name])
      assert.is_true(defs["weave_" .. name].async)
      assert.is_true(defs["weave_" .. name].annotations.readOnlyHint)
    end
  end)

  it("serves cached diagnostics from every namespace with unsaved-buffer metadata", function()
    local buf, path = buffer("project/main.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved", "second" })
    vim.diagnostic.set(ns, buf, {
      { lnum = 0, col = 1, end_lnum = 0, end_col = 3, severity = 1, source = "compiler", code = "E1", message = "bad" },
      { lnum = 1, col = 0, severity = 2, source = "linter", message = "warn" },
    })
    local out = call("diagnostics", { path = path })
    assert.equal(2, #out.items)
    assert.equal("error", out.items[1].severity)
    assert.equal("compiler", out.items[1].source)
    assert.equal("E1", out.items[1].code)
    assert.same({ line = 1, column = 2 }, out.items[1].range.start)
    assert.equal(buf, out.target.buffer)
    assert.is_true(out.target.modified)
    assert.equal("cached", out.coverage)
    assert.is_false(out.fresh)
    assert.equal(0, #requests)
  end)

  it("filters diagnostics before applying a deterministic result limit", function()
    local buf = buffer("project/main.lua")
    vim.diagnostic.set(ns, buf, {
      { lnum = 1, col = 0, severity = 1, source = "lint", message = "second" },
      { lnum = 0, col = 0, severity = 1, source = "lint", message = "first" },
      { lnum = 0, col = 0, severity = 2, source = "lint", message = "warning" },
      { lnum = 0, col = 0, severity = 1, source = "other", message = "other" },
    })
    local out = call("diagnostics", { buffer = buf, severity = "error", source = "lint", limit = 1 })
    assert.equal(2, out.total)
    assert.equal("first", out.items[1].message)
    assert.is_true(out.truncated)
    assert.equal(1, out.next_offset)
    local next_page = call("diagnostics", { buffer = buf, severity = "error", source = "lint", offset = 1, limit = 1 })
    assert.equal("second", next_page.items[1].message)
  end)

  it("defaults diagnostics to the caller workspace and honors per-file read denies", function()
    local a = buffer("project/public.lua")
    local b = buffer("project/private.lua")
    local c = buffer("outside/secret.lua")
    for _, buf in ipairs({ a, b, c }) do
      vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, message = "diagnostic-" .. buf } })
    end
    ctx = context("read_only", { { tool = "weave:read", resource = project .. "/private.lua", decision = "deny" } })
    local out = call("diagnostics")
    assert.equal(1, #out.items)
    assert.equal(a, out.items[1].buffer)
    assert.is_true(out.filtered)
    assert.falsy(vim.json.encode(out):find("secret.lua", 1, true))
    assert.falsy(vim.json.encode(out):find("private.lua", 1, true))
  end)

  it("authorizes resolved buffer paths, not numeric ids or suffixes", function()
    local buf = buffer("outside/secret.lua")
    local out = start("diagnostics", { buffer = buf })()
    assert.is_true(out.isError)
    out = start("diagnostics", { buffer = "secret.lua" })()
    assert.is_true(out.isError)
    assert.equal(0, #requests)
  end)

  it("does not leak names of ambiguous buffers before authorization", function()
    buffer("project/shared.lua")
    local hidden = buffer("outside/shared.lua")
    local out = start("diagnostics", { buffer = "shared.lua" })()
    assert.is_true(out.isError)
    assert.falsy(out.content[1].text:find(root .. "/outside", 1, true))
    assert.falsy(out.content[1].text:find(tostring(hidden) .. ":", 1, true))
  end)

  it("refuses symlinks from the workspace to an unreadable target", function()
    local _, outside = buffer("outside/secret.lua")
    local alias = project .. "/alias.lua"
    assert(vim.uv.fs_symlink(outside, alias))
    local out = start("diagnostics", { path = alias })()
    assert.is_true(out.isError)
  end)

  it("does not load an unopened diagnostics target or imply a fresh successful check", function()
    local path = file("project/unopened.lua")
    local before = #vim.api.nvim_list_bufs()
    local out = start("diagnostics", { path = path })()
    assert.is_true(out.isError)
    assert.equal("buffer_not_loaded", payload(out).status)
    assert.equal(before, #vim.api.nvim_list_bufs())
    assert.equal(0, #requests)
  end)

  it("validates limits, positions and mutually exclusive selectors", function()
    local buf, path = buffer("project/main.lua")
    for _, args in ipairs({ { limit = 0 }, { limit = 1001 }, { offset = -1 }, { severity = "nonsense" },
      { path = path, buffer = buf }, { buffer = "" }, { buffer = 0.5 } }) do
      assert.is_true(start("diagnostics", args)().isError, vim.inspect(args))
    end
    assert.is_true(start("definition", { buffer = buf, line = 0, column = 1 })().isError)
    assert.is_true(start("definition", { buffer = buf, line = 1, column = 3 })().isError) -- middle of lambda
    assert.equal(0, #requests)
  end)

  it("flattens hierarchical document symbols and preserves parents and selection ranges", function()
    local buf, path = buffer("project/main.lua")
    client(1, buf, { { name = "outer", kind = 12, range = range(0, 5), selectionRange = range(0, 1),
      children = { { name = "inner", kind = 13, detail = "local", range = range(1, 2), selectionRange = range(1, 2) } } } })
    local out = call("document_symbols", { buffer = buf })
    assert.equal(2, #out.items)
    assert.equal("outer", out.items[2].container)
    assert.equal(path, out.items[1].path)
    assert.equal("textDocument/documentSymbol", requests[1].method)
    assert.equal(vim.uri_from_fname(path), requests[1].params.textDocument.uri)
    assert.equal(buf, requests[1].buffer)
    assert.equal("ok", out.clients[1].status)
  end)

  it("searches only attached clients with readable buffers in the requested workspace", function()
    local buf, path = buffer("project/main.lua")
    local other = buffer("outside/secret.lua")
    client(1, buf, {
      { name = "safe", kind = 12, location = { uri = vim.uri_from_fname(path), range = range() } },
      { name = "hidden", kind = 12, location = { uri = vim.uri_from_fname(root .. "/outside/secret.lua"), range = range() } },
    })
    client(2, other, {})
    local out = call("workspace_symbols", { query = "sa" })
    assert.equal(1, #requests)
    assert.equal("workspace/symbol", requests[1].method)
    assert.equal("sa", requests[1].params.query)
    assert.equal(1, #out.items)
    assert.equal("safe", out.items[1].name)
    assert.is_true(out.filtered)
    assert.falsy(vim.json.encode(out):find("hidden", 1, true))
  end)

  it("preserves unresolved workspace symbols without inventing a position", function()
    local buf, path = buffer("project/main.lua")
    client(1, buf, { { name = "unresolved", kind = 12, location = { uri = vim.uri_from_fname(path) } } })
    local out = call("workspace_symbols", { query = "" })
    assert.equal("unresolved", out.items[1].name)
    assert.equal(vim.NIL, out.items[1].range)
    assert.is_false(out.items[1].range_available)
  end)

  it("converts UTF-8 byte positions to each client's position encoding", function()
    local buf, path = buffer("project/main.lua")
    client(1, buf, { uri = vim.uri_from_fname(path), range = range(4, 5) })
    client(2, buf, { uri = vim.uri_from_fname(path), range = range(7, 8) }, { encoding = "utf-8" })
    local out = call("definition", { buffer = buf, line = 1, column = 8 })
    assert.equal(4, requests[1].params.position.character)
    assert.equal(7, requests[2].params.position.character)
    assert.equal(1, #out.items) -- identical byte location from two encodings
    assert.same({ line = 1, column = 8 }, out.items[1].range.start)
    assert.same({ 1, 2 }, out.items[1].client_ids)
    assert.equal("utf-8", out.position_encoding)
  end)

  it("normalizes LocationLink definitions without loading their target file", function()
    local buf = buffer("project/main.lua")
    local target = file("project/target.lua")
    client(1, buf, { { targetUri = vim.uri_from_fname(target), targetRange = range(0, 5),
      targetSelectionRange = range(4, 5), originSelectionRange = range(0, 1) } })
    local before = #vim.api.nvim_list_bufs()
    local out = call("definition", { buffer = buf, line = 1, column = 1 })
    assert.equal(target, out.items[1].path)
    assert.same({ line = 1, column = 8 }, out.items[1].range.start)
    assert.same({ line = 1, column = 1 }, out.items[1].target_range.start)
    assert.equal(before, #vim.api.nvim_list_bufs())
  end)

  it("filters forbidden definition results before reading their target file", function()
    local buf = buffer("project/main.lua")
    client(1, buf, { uri = vim.uri_from_fname(root .. "/outside/secret.lua"), range = range() })
    local out = call("definition", { buffer = buf, line = 1, column = 1 })
    assert.equal(0, #out.items)
    assert.is_true(out.filtered)
    assert.falsy(vim.json.encode(out):find("secret", 1, true))
  end)

  it("includes the references declaration flag and bounds the response", function()
    local buf, path = buffer("project/main.lua")
    client(1, buf, { { uri = vim.uri_from_fname(path), range = range(0, 1) },
      { uri = vim.uri_from_fname(path), range = range(1, 2) } })
    local out = call("references", { path = path, line = 1, column = 1, include_declaration = false, limit = 1 })
    assert.is_false(requests[1].params.context.includeDeclaration)
    assert.equal(1, #out.items)
    assert.equal(2, out.total)
    assert.is_true(out.truncated)
  end)

  it("normalizes markup and marked-string hover contents and enforces a text budget", function()
    local buf = buffer("project/main.lua")
    client(1, buf, { contents = { kind = "markdown", value = "hello λ界" }, range = range(1, 2) })
    client(2, buf, { contents = { { language = "lua", value = "local x = 1" }, "more" } })
    local out = call("hover", { buffer = buf, line = 1, column = 1, max_chars = 12 })
    assert.equal("markdown", out.items[1].format)
    assert.equal("hello λ界", out.items[1].text)
    assert.is_true(out.truncated)
    local chars = 0
    for _, item in ipairs(out.items) do chars = chars + vim.fn.strchars(item.text) end
    assert.is_true(chars <= 12)
  end)

  it("returns unavailable for unloaded buffers or unsupported servers without starting any", function()
    local path = file("project/unopened.lua")
    local before = #vim.api.nvim_list_bufs()
    assert.is_true(start("hover", { path = path, line = 1, column = 1 })().isError)
    assert.equal(before, #vim.api.nvim_list_bufs())
    local buf = buffer("project/main.lua")
    client(1, buf, nil, { unsupported = "textDocument/hover" })
    assert.is_true(start("hover", { buffer = buf, line = 1, column = 1 })().isError)
    assert.equal(0, #requests)
  end)

  it("returns partial success, cancels timed-out requests, and ignores late callbacks", function()
    local buf, path = buffer("project/main.lua")
    client(1, buf, { uri = vim.uri_from_fname(path), range = range() })
    local pending = client(2, buf, nil, { pending = true })
    local done = start("definition", { buffer = buf, line = 1, column = 1, timeout_ms = 20 })
    local out, count = done()
    assert.equal(1, #out.items)
    assert.is_true(out.partial)
    assert.equal("timeout", out.clients[2].status)
    assert.equal(1, #pending.cancelled)
    requests[2].cb(nil, { uri = vim.uri_from_fname(path), range = range(1, 2) })
    assert.equal(1, select(2, done(false)))
    assert.equal(1, count)
  end)

  it("reports server errors and request rejection without disclosing raw server messages", function()
    local buf = buffer("project/main.lua")
    client(1, buf, nil, { error = { code = -32603, message = root .. "/outside/secret.lua" } })
    client(2, buf, nil, { reject = true })
    local out = call("definition", { buffer = buf, line = 1, column = 1 })
    assert.is_true(out.partial)
    assert.equal("error", out.clients[1].status)
    assert.equal(-32603, out.clients[1].code)
    assert.equal("error", out.clients[2].status)
    assert.falsy(vim.json.encode(out):find("secret.lua", 1, true))
  end)

  it("does not disclose stale session or changed-buffer responses", function()
    local buf, path = buffer("project/main.lua")
    client(1, buf, nil, { pending = true })
    local done = start("definition", { buffer = buf, line = 1, column = 1 })
    live = false
    requests[1].cb(nil, { uri = vim.uri_from_fname(path), range = range() })
    local out = done()
    assert.is_true(out.isError)
    assert.falsy(vim.json.encode(out):find(path, 1, true))
    live = true
    done = start("definition", { buffer = buf, line = 1, column = 1 })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed" })
    requests[2].cb(nil, { uri = vim.uri_from_fname(path), range = range() })
    assert.is_true(done().isError)
  end)

  it("rechecks per-file permissions after an asynchronous response", function()
    local buf, path = buffer("project/main.lua")
    client(1, buf, nil, { pending = true })
    local done = start("definition", { buffer = buf, line = 1, column = 1 })
    session:permissions().add_grant({ tool = "weave:read", resource = path, decision = "deny" })
    requests[1].cb(nil, { uri = vim.uri_from_fname(path), range = range() })
    local out = done()
    assert.equal(0, #out.items)
    assert.is_true(out.filtered)
  end)

  it("uses session-scoped approval and permits an ordinary ask-once read of its scope", function()
    local buf = buffer("project/main.lua")
    vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, message = "allowed once" } })
    ctx, session = context("ask")
    local done = start("diagnostics", { buffer = buf })
    local pending = session:get_store():pop_permission()
    assert.is_not_nil(pending)
    pending.respond("allow_once")
    local out = done()
    assert.falsy(out.isError, vim.inspect(out))
    assert.equal(1, #out.items)
    assert.equal(0, #session:permissions().grants())
  end)
end)
