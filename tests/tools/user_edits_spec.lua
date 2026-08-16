-- The edit gate: write/edit/task_start refused while the acting session has
-- edit_gate on and unseen user edits; check_user_edits pulls the window and
-- lifts the gate. The acting session is a stubbed seam here (MCP calls carry
-- no session identity; resolution is the selected-or-first convention).

local Log = require("weave.revision_log")
local Permissions = require("weave.permissions")
local Settings = require("weave.settings")
local Sync = require("weave.edit_sync")
local UserEdits = require("weave.tools.user_edits")

describe("edit gate", function()
  local root, saved_session, saved_notify, session

  local function open(name, lines)
    local path = root .. "/" .. name
    vim.fn.writefile(lines, path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    Log.track(bufnr)
    return bufnr, path
  end

  local function edit(bufnr, lines)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    Log.note_change(bufnr)
    Log.close_burst()
  end

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    saved_notify = vim.notify
    vim.notify = function() end
    Permissions._reset()
    Permissions.set_project_root(root)
    Sync._reset()
    Settings._reset()
    Log._reset()

    session = {
      is_ready = function()
        return true
      end,
      send_system = function()
        return true
      end,
    }
    saved_session = UserEdits._session
    UserEdits._session = function()
      return session
    end
    Sync.watch(session)
  end)

  after_each(function()
    UserEdits._session = saved_session
    Sync._reset()
    Settings._reset()
    Log._reset()
    vim.notify = saved_notify
    Permissions._reset()
    vim.fn.delete(root, "rf")
  end)

  it("stays open with the setting off, whatever the user edited", function()
    Settings.for_session(session):set("auto_send_edits", true) -- tracking, no gate
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    assert.is_nil(UserEdits.gate_reason())
  end)

  it("stays open with the gate on but nothing unseen", function()
    Settings.for_session(session):set("edit_gate", true)
    assert.is_nil(UserEdits.gate_reason())
  end)

  it("stays open when no session is acting at all", function()
    UserEdits._session = function()
      return nil
    end
    assert.is_nil(UserEdits.gate_reason())
  end)

  it("closes on unseen edits and names the way out", function()
    Settings.for_session(session):set("edit_gate", true)
    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })

    local reason = UserEdits.gate_reason()
    assert.truthy(reason:find("check_user_edits", 1, true))
  end)

  it("guard refuses a wrapped tool while closed, passes it through when open", function()
    Settings.for_session(session):set("edit_gate", true)
    local ran = false
    local guarded = UserEdits.guard({
      description = "d",
      inputSchema = {},
      handler = function()
        ran = true
        return "ok"
      end,
    })

    local bufnr = open("a.lua", { "one" })
    edit(bufnr, { "two" })
    assert.has_error(function()
      guarded.handler({})
    end)
    assert.is_false(ran)

    UserEdits.check.handler({}) -- pull the edits: the gate lifts
    assert.equal("ok", guarded.handler({}))
    assert.is_true(ran)
  end)

  it("guard preserves the async calling convention", function()
    Settings.for_session(session):set("edit_gate", true)
    local got
    local guarded = UserEdits.guard({
      description = "d",
      inputSchema = {},
      async = true,
      handler = function(_, respond)
        respond("done")
      end,
    })
    assert.is_true(guarded.async)
    guarded.handler({}, function(ret)
      got = ret
    end)
    assert.equal("done", got)
  end)

  describe("check_user_edits", function()
    it("says so when tracking is not enabled for the session", function()
      local out = UserEdits.check.handler({})
      assert.truthy(out:find("not enabled", 1, true))
    end)

    it("reports clean when there is nothing unseen", function()
      Settings.for_session(session):set("edit_gate", true)
      assert.equal("no pending user edits.", UserEdits.check.handler({}))
    end)

    it("hands the squashed window over once, advancing the shared cursor", function()
      Settings.for_session(session):set("edit_gate", true)
      local bufnr = open("a.lua", { "one" })
      edit(bufnr, { "two" })
      edit(bufnr, { "three" })

      local out = UserEdits.check.handler({})
      assert.truthy(out:find("\n-one", 1, true))
      assert.truthy(out:find("\n+three", 1, true))
      assert.is_nil(out:find("\n+two", 1, true))

      assert.equal("no pending user edits.", UserEdits.check.handler({}))
      assert.is_nil(UserEdits.gate_reason())
    end)

    it("counts an open burst — what the user is typing right now", function()
      Settings.for_session(session):set("edit_gate", true)
      local bufnr = open("a.lua", { "one" })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "two" })
      Log.note_change(bufnr) -- mid-burst, no close
      assert.is_not_nil(UserEdits.gate_reason())
      assert.truthy(UserEdits.check.handler({}):find("\n+two", 1, true))
    end)

    it("errors honestly with no acting session", function()
      UserEdits._session = function()
        return nil
      end
      assert.has_error(function()
        UserEdits.check.handler({})
      end)
    end)
  end)
end)
