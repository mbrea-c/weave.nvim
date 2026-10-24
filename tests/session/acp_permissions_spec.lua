local Session = require("weave.session")
local Permissions = require("weave.permissions")
local function request()
  return { toolCall = { toolCallId = "read", title = "Read", kind = "read" },
    options = {
      { optionId = "yes", kind = "allow_once", name = "Allow" },
      { optionId = "no", kind = "reject_once", name = "Reject" },
    } }
end

describe("ACP session permission ownership", function()
  local sessions
  local function session(preset)
    local s = Session:new()
    s:permissions().set_mode("off")
    s:permissions().set_active(preset)
    s:_reset_config_session(true)
    sessions[#sessions + 1] = s
    return s
  end
  before_each(function() sessions = {}; Permissions._reset() end)
  after_each(function() for _, s in ipairs(sessions) do s:stop() end; Permissions._reset() end)

  it("resolves and queues using the receiving Session, not the editor default", function()
    local a, b = session("unsandboxed_auto"), session("unsandboxed_ask")
    local accepted, asked
    a:_build_handlers().on_request_permission(request(), function(id) accepted = id end)
    b:_build_handlers().on_request_permission(request(), function(id) asked = id end)
    assert.equal("yes", accepted)
    assert.is_nil(asked)
    assert.equal(0, a:get_store().state.permission_count)
    assert.equal(1, b:get_store().state.permission_count)
  end)

  it("rejects delayed stale approvals and answers each ACP request only once", function()
    local s, answers = session("unsandboxed_ask"), {}
    s:_build_handlers().on_request_permission(request(), function(id) answers[#answers + 1] = { option = id } end)
    local pending = s:get_store():pop_permission()
    s:_reset_config_session(true)
    pending.respond("yes")
    pending.respond("yes")
    assert.equal(1, #answers)
    assert.is_nil(answers[1].option)
  end)
end)
