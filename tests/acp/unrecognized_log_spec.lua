-- Unknown ACP traffic is valuable protocol evidence. It is persisted even when
-- general debug logging is disabled, as one JSON object per line under
-- stdpath("state"), without changing the existing user-facing warnings.

local ACPClient = require("weave.acp.acp_client")
local AcpBridge = require("weave.acp_bridge")
local Logger = require("weave.utils.logger")

local root
local saved_path
local saved_notify
local saved_unrecognized

before_each(function()
  root = vim.fn.tempname()
  saved_path = Logger.unrecognized_acp_path
  saved_notify = Logger.notify
  saved_unrecognized = Logger.unrecognized_acp
  Logger.notify = function() end
end)

after_each(function()
  Logger.unrecognized_acp_path = saved_path
  Logger.notify = saved_notify
  Logger.unrecognized_acp = saved_unrecognized
  vim.fn.delete(root, "rf")
end)

describe("unrecognized ACP log", function()
  it("lives under Neovim's state directory", function()
    assert.equal(
      vim.fs.joinpath(vim.fn.stdpath("state"), "weave", "acp-unrecognized.jsonl"),
      Logger.unrecognized_acp_path()
    )
  end)

  it("appends owner-only JSONL records with the raw message", function()
    local path = vim.fs.joinpath(root, "weave", "acp-unrecognized.jsonl")
    Logger.unrecognized_acp_path = function()
      return path
    end

    local first = {
      jsonrpc = "2.0",
      method = "future/event",
      params = { nested = { value = 7 } },
    }
    local ok, err = Logger.unrecognized_acp("unknown_notification_method", first, "kiro")
    assert.is_true(ok, tostring(err))
    ok, err = Logger.unrecognized_acp("unknown_message_type", { strange = true }, "kiro")
    assert.is_true(ok, tostring(err))

    local lines = vim.fn.readfile(path)
    assert.equal(2, #lines)

    local record = vim.json.decode(lines[1], { luanil = { object = true, array = true } })
    assert.equal(1, record.version)
    assert.equal("unknown_notification_method", record.reason)
    assert.equal("kiro", record.provider)
    assert.same(first, record.message)
    assert.truthy(record.timestamp:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))

    if vim.fn.has("win32") == 0 then
      local stat = assert(vim.uv.fs_stat(path))
      assert.equal(384, stat.mode % 512)
    end
  end)

  it("records every unrecognized client dispatch and no recognized ignored method", function()
    local captured = {}
    Logger.unrecognized_acp = function(reason, message, provider)
      captured[#captured + 1] = {
        reason = reason,
        message = message,
        provider = provider,
      }
      return true
    end

    local client = setmetatable({
      provider_config = { name = "kiro" },
      callbacks = {},
      subscribers = {},
    }, { __index = ACPClient })

    client:_dispatch_message({
      jsonrpc = "2.0",
      method = "fs/read_text_file",
      params = {},
    })

    local notification = {
      jsonrpc = "2.0",
      method = "future/event",
      params = { value = 1 },
    }
    local response = {
      jsonrpc = "2.0",
      id = 41,
      result = { value = 2 },
    }
    local message = {
      jsonrpc = "2.0",
      strange = true,
    }
    local tool_params = {
      sessionId = "session-1",
      update = {
        sessionUpdate = "tool_call",
        toolCallId = "call-1",
        kind = "future-kind",
      },
    }
    local invalid_update = {
      update = {
        sessionUpdate = "agent_message_chunk",
      },
    }

    client:_dispatch_message(notification)
    client:_dispatch_message(response)
    client:_dispatch_message(message)
    client:__handle_session_update(tool_params)
    client:__handle_session_update(invalid_update)

    assert.same({
      "unknown_notification_method",
      "unmatched_response_id",
      "unknown_message_type",
      "unknown_tool_call_kind",
      "invalid_session_update",
    }, vim.tbl_map(function(item)
      return item.reason
    end, captured))
    assert.is_true(captured[1].message == notification)
    assert.is_true(captured[2].message == response)
    assert.is_true(captured[3].message == message)
    assert.is_true(captured[4].message == tool_params)
    assert.is_true(captured[5].message == invalid_update)
    assert.equal("kiro", captured[1].provider)
  end)

  it("records session update kinds the bridge cannot apply", function()
    local captured
    Logger.unrecognized_acp = function(reason, message, provider)
      captured = {
        reason = reason,
        message = message,
        provider = provider,
      }
      return true
    end

    local update = {
      sessionUpdate = "future_update",
      payload = { value = 3 },
    }
    AcpBridge.build_handlers({}).on_session_update(update)

    assert.equal("unhandled_session_update", captured.reason)
    assert.is_true(captured.message == update)
  end)
end)
