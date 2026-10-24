local mount = require("fibrous.inline.mount")
local Prefs = require("weave.view.prefs")
local SessionStore = require("weave.session_store")
local ToolCall = require("weave.view.tool_call")
local ToolIdent = require("weave.tool_ident")
local Transcript = require("weave.view.transcript")

local function diagnostic(i, path, severity)
  return {
    path = path or "/project/example.lua", buffer = vim.NIL,
    range = { start = { line = i, column = 3 }, ["end"] = { line = i, column = 4 } },
    severity = severity or "warning", message = "finding-" .. i,
    source = "lua_ls", code = "test-code",
  }
end

local function report(items)
  return {
    status = "diagnostics_pending", items = items or {}, total = #(items or {}), offset = 0,
    limit = 100, next_offset = vim.NIL, truncated = false, filtered = false,
    diagnostic_scope = "buffer", target = { path = "/project/example.lua", buffer = 1 },
    coverage = "cached", fresh = false, can_conclude_clean = false, analysis_complete = false,
    clients = {
      { name = "null-ls", state = "ready", diagnostics = { state = "not_received" } },
      { name = "lua_ls", state = "initializing", diagnostics = { state = "not_received" } },
    },
    startup = { waited_ms = 30, timeout_ms = 300, timed_out = true },
    diagnostic_wait = { waited_ms = 20, timeout_ms = 100, timed_out = true },
  }
end

local function block(payload)
  return {
    tool_call_id = "diagnostics-1", kind = "other", status = "completed",
    argument = "@clankbox/weave_diagnostics",
    mcp = { server = "clankbox", tool = "weave_diagnostics" },
    input = { path = "/project/example.lua", source = "lua_ls", startup_timeout_ms = 777 },
    output = { content = { { type = "text", text = vim.json.encode(payload) } },
      _meta = { raw_inspection_marker = "SECRET_RAW_ARGUMENT" } },
  }
end

local function contains(text, needle)
  assert(text:find(needle, 1, true), "missing " .. needle .. " in:\n" .. text)
end

describe("diagnostics transcript renderer", function()
  local handles, files, original_win
  before_each(function()
    ToolCall.reset()
    ToolIdent.reset()
    require("weave").setup({})
    handles, files = {}, {}
    original_win = vim.api.nvim_get_current_win()
  end)
  after_each(function()
    for _, handle in ipairs(handles) do handle.unmount() end
    if vim.api.nvim_win_is_valid(original_win) then vim.api.nvim_set_current_win(original_win) end
    for _, path in ipairs(files) do
      local buf = vim.fn.bufnr(path)
      if buf ~= -1 then vim.api.nvim_buf_delete(buf, { force = true }) end
      vim.fn.delete(path)
    end
    ToolCall.reset()
    ToolIdent.reset()
  end)

  local function draw(tc, expanded, width)
    local store = SessionStore:new()
    store:upsert_tool_call(tc)
    if expanded then store:toggle_tool_call(tc.tool_call_id) end
    local handle = mount.floating(Transcript.Transcript, { store = store, prefs = Prefs:new() },
      { width = width or 100, height = 22, mode = "scroll" })
    handles[#handles + 1] = handle
    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
    end
    return text, store, handle
  end

  it("is installed by setup, but does not claim foreign or unrelated tools", function()
    local tc = block(report())
    assert.equal("weave.lsp.diagnostics", assert(ToolCall.resolve(tc)).name)
    tc.mcp.server = "external"
    assert.is_nil(ToolCall.resolve(tc))
    tc.mcp = { server = "clankbox", tool = "weave_document_symbols" }
    assert.equal("weave.lsp.navigation", assert(ToolCall.resolve(tc)).name)
  end)

  it("uses the target as its title and shows a bounded severity preview", function()
    local items = {}
    for i = 1, 6 do items[i] = diagnostic(i) end
    local tc = block(report(items))
    local text = draw(tc)
    contains(text(), "[w:diagnostics] /project/example.lua")
    contains(text(), "6 warnings")
    contains(text(), "Cached snapshot")
    contains(text(), "coverage incomplete")
    contains(text(), "finding-1")
    contains(text(), "3 more")
    assert.falsy(text():find("finding-6", 1, true))
    assert.falsy(text():find("SECRET_RAW_ARGUMENT", 1, true))
    assert.equal("@clankbox/weave_diagnostics", tc.argument)
    assert.equal(-1, vim.fn.bufnr("/project/example.lua"))
  end)

  it("shows the most severe returned diagnostics first without changing the payload", function()
    local p = report({ diagnostic(1, nil, "hint"), diagnostic(2, nil, "information"),
      diagnostic(3, nil, "warning"), diagnostic(4, nil, "error") })
    local original = vim.deepcopy(p)
    local text = draw(block(p))
    contains(text(), "finding-4")
    assert.falsy(text():find("finding-1", 1, true))
    assert.same(original, p)
  end)

  it("expands into file groups and independent client report states, not raw I/O", function()
    local p = report({ diagnostic(1), diagnostic(2, "/project/other.lua") })
    p.clients[2].state = "ready"
    p.clients[2].diagnostics = { state = "current_version", report_count = 0 }
    local text = draw(block(p), true)
    contains(text(), "/project/other.lua")
    contains(text(), "lua_ls")
    contains(text(), "current-version report")
    contains(text(), "0 diagnostics")
    contains(text(), "null-ls")
    contains(text(), "no report received")
    contains(text(), "Startup")
    contains(text(), "timed out")
    assert.falsy(text():find("SECRET_RAW_ARGUMENT", 1, true))
    assert.falsy(text():find("input:", 1, true))
    assert.falsy(text():find("output:", 1, true))
    assert.falsy(text():find("analysis_complete", 1, true))
  end)

  it("keeps initializing, stale and unversioned reports distinct", function()
    local p = report()
    p.clients = {
      { name = "jdtls", state = "initializing", diagnostics = { state = "not_received" } },
      { name = "stale_ls", state = "ready", diagnostics = { state = "stale" } },
      { name = "legacy_ls", state = "ready", diagnostics = { state = "version_unknown" } },
    }
    local text = draw(block(p), true)
    contains(text(), "jdtls")
    contains(text(), "initializing")
    contains(text(), "stale report")
    contains(text(), "unversioned report")
  end)

  it("never calls an empty or fully-reported snapshot clean", function()
    local p = report()
    p.status = "ok"
    p.clients = { { name = "lua_ls", state = "ready",
      diagnostics = { state = "current_version", report_count = 0 } } }
    local text = draw(block(p), true)
    contains(text(), "No diagnostics in this snapshot")
    contains(text(), "coverage incomplete")
    assert.falsy(text():find("File is clean", 1, true))
  end)

  it("labels workspace coverage, filters and page counts honestly", function()
    local p = report({ diagnostic(3, "/project/one.lua", "error") })
    p.diagnostic_scope, p.target, p.root = "workspace_cache", nil, "/project"
    p.total, p.offset, p.next_offset, p.filtered, p.truncated = 40, 10, 11, true, true
    local tc = block(p)
    tc.input = { root = "/project", severity = "error" }
    local text = draw(tc, true)
    contains(text(), "11-11 of 40")
    contains(text(), "returned page")
    contains(text(), "Workspace cache")
    contains(text(), "omitted")
    contains(text(), "severity=error")
    contains(text(), "next offset: 11")
  end)

  it("handles direct, structured, MCP text and Kiro content-body results", function()
    local p = report({ diagnostic(1) })
    local variants = {
      { output = p },
      { output = { structuredContent = p } },
      { output = { content = { { type = "text", text = vim.json.encode(p) } } } },
      { body = { vim.json.encode(p) } },
      { output = { result = vim.json.encode(p) } },
    }
    for _, fields in ipairs(variants) do
      local tc = block(p)
      tc.output, tc.body = fields.output, fields.body
      local text = draw(tc)
      contains(text(), "finding-1")
    end
  end)

  it("uses correlation when a provider omits MCP identity", function()
    local tc = block(report({ diagnostic(1) }))
    ToolIdent.record("diagnostics", tc.input)
    tc.mcp = nil
    local text = draw(tc)
    contains(text(), "finding-1")
  end)

  it("treats an initial call without status as pending, not as a failed decode", function()
    local tc = block(report())
    tc.output, tc.status = nil, nil
    local rendered = draw(tc)
    contains(rendered(), "Waiting for diagnostics result")
    assert.falsy(rendered():find("unavailable", 1, true))
  end)

  it("updates when the result arrives, without consulting the live diagnostic cache", function()
    local tc = block(report())
    tc.output, tc.status = nil, "in_progress"
    local text, store = draw(tc, true)
    contains(text(), "Waiting for diagnostics result")
    store:upsert_tool_call({
      tool_call_id = tc.tool_call_id, status = "completed",
      body = { vim.json.encode(report({ diagnostic(1) })) },
    })
    contains(text(), "finding-1")
    local buf = vim.api.nvim_create_buf(false, true)
    local ns = vim.api.nvim_create_namespace("renderer-snapshot-test")
    vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, message = "LIVE_CACHE_MUST_NOT_APPEAR" } })
    store:toggle_tool_call(tc.tool_call_id)
    assert.falsy(text():find("LIVE_CACHE_MUST_NOT_APPEAR", 1, true))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("renders a failed query as not checked rather than a successful empty report", function()
    local p = { status = "buffer_not_loaded", items = {}, clients = {},
      message = "File is not loaded. Retry with load=true.", can_conclude_clean = false }
    local tc = block(p)
    tc.output.isError = true
    local text = draw(tc, true)
    contains(text(), "Not checked")
    contains(text(), "File is not loaded")
    assert.falsy(text():find("No diagnostics in this snapshot", 1, true))
  end)

  it("keeps malformed results out of the expanded UI while preserving raw peek", function()
    local tc = block(report())
    tc.output = { content = { { type = "text", text = "RAW_MALFORMED_PAYLOAD" } } }
    local text = draw(tc, true)
    contains(text(), "K for raw details")
    assert.falsy(text():find("RAW_MALFORMED_PAYLOAD", 1, true))
    assert.falsy(text():find("SECRET_RAW_ARGUMENT", 1, true))
  end)

  it("caps expanded results and reports the omitted count", function()
    local items = {}
    for i = 1, 140 do items[i] = diagnostic(i) end
    local text = draw(block(report(items)), true)
    contains(text(), "finding-100")
    assert.falsy(text():find("finding-101", 1, true))
    contains(text(), "40 more")
    contains(text(), "K for")
  end)

  it("decodes only once per result, including across expansion changes", function()
    local renderer = require("weave.view.renderers.diagnostics")
    local ref, calls = {}, 0
    local ctx = { use_ref = function() return ref end }
    local props = { block = block(report({ diagnostic(1) })), store = SessionStore:new(),
      expanded = false, awaiting = false, show_diff = true }
    local saved_decode = vim.json.decode
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.json.decode = function(...)
      calls = calls + 1
      return saved_decode(...)
    end
    local ok, err = pcall(function()
      renderer.Render(ctx, props)
      props.expanded = true
      renderer.Render(ctx, props)
      assert.equal(1, calls)
      props.block = block(report({ diagnostic(2) }))
      renderer.Render(ctx, props)
      assert.equal(2, calls)
    end)
    vim.json.decode = saved_decode
    if not ok then error(err) end
  end)

  it("rejects malformed and cyclic result objects without exposing a raw dump", function()
    for _, output in ipairs({
      { status = "ok", can_conclude_clean = false, items = { false } },
      { status = "ok", can_conclude_clean = false, items = { { message = {} } } },
      { structuredContent = { items = {} } },
    }) do
      local tc = block(report())
      tc.output = output
      local rendered = draw(tc, true)
      contains(rendered(), "K for raw details")
    end
    local tc = block(report())
    tc.output = {}
    tc.output.result = tc.output
    local rendered = draw(tc, true)
    contains(rendered(), "K for raw details")
  end)

  it("does not show returned diagnostics as a successful query when transport failed", function()
    local tc = block(report({ diagnostic(1) }))
    tc.status = "failed"
    local rendered = draw(tc, true)
    contains(rendered(), "Not checked")
    assert.falsy(rendered():find("finding-1", 1, true))
  end)

  it("does not create a file when a historical diagnostic target has disappeared", function()
    local path = vim.fn.tempname() .. " removed.lua"
    files[#files + 1] = path
    local d = diagnostic(1, path)
    vim.fn.bufadd(path)
    assert.is_false(require("weave.view.renderers.diagnostics").open_location(d))
    assert.equal(0, vim.fn.filereadable(path))
  end)

  it("does not navigate to a regex-matched buffer instead of the recorded path", function()
    local base = vim.fn.tempname()
    local existing, missing = base .. "1.lua", base .. "[12].lua"
    files[#files + 1] = existing
    vim.fn.writefile({ "wrong target" }, existing)
    local buf = vim.fn.bufadd(existing)
    vim.fn.bufload(buf)
    assert.is_false(require("weave.view.renderers.diagnostics").open_location(diagnostic(1, missing)))
  end)

  it("navigates only on explicit activation and preserves UTF-8 byte columns", function()
    local path = vim.fn.tempname() .. " diagnostic target.lua"
    files[#files + 1] = path
    vim.fn.writefile({ "first", "λxyz" }, path)
    local d = diagnostic(2, path)
    local buf = vim.fn.bufadd(path)
    assert.is_false(vim.api.nvim_buf_is_loaded(buf))
    draw(block(report({ d })), true)
    assert.is_false(vim.api.nvim_buf_is_loaded(buf))
    assert.is_true(require("weave.view.renderers.diagnostics").open_location(d))
    assert.equal(original_win, vim.api.nvim_get_current_win())
    assert.equal(path, vim.api.nvim_buf_get_name(0))
    assert.same({ 2, 2 }, vim.api.nvim_win_get_cursor(0))
    assert.is_false(vim.bo.modified)
  end)
end)
