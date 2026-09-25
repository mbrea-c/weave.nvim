local Config = require("weave.config")

--- @class weave.utils.Logger
local Logger = {}

function Logger.get_timestamp()
  return os.date("%Y-%m-%d %H:%M:%S")
end

local function format_debug_message(...)
  if not Config.debug then
    return nil
  end

  local args = { ... }

  if #args == 0 then
    return nil
  end

  local info = debug.getinfo(3, "Sl")
  local caller_source = info.source:match("@(.+)$") or "unknown"
  local caller_module = caller_source:gsub("^.*/lua/", ""):gsub("%.lua$", ""):gsub("/", ".")

  local timestamp = Logger.get_timestamp()
  local log_parts = {
    string.format("[%s] [%s:%d]", timestamp, caller_module, info.currentline),
  }

  for _, arg in ipairs(args) do
    if type(arg) == "string" then
      table.insert(log_parts, arg)
    else
      table.insert(log_parts, vim.inspect(arg))
    end
  end

  return log_parts
end

--- @param msg string Content of the notification to show to the user.
--- @param level vim.log.levels|nil One of the values from `vim.log.levels`. Defaults to WARN
--- @param opts table|nil Optional parameters. Unused by default.
function Logger.notify(msg, level, opts)
  vim.schedule(function()
    local ok, res = pcall(vim.notify, msg, level or vim.log.levels.WARN, opts or {})

    if not ok then
      print("Notification error: " .. tostring(res) .. " - Original message: " .. msg)
    end
  end)
end

--- Print a debug message that can be read by `:messages`
function Logger.debug(...)
  local formatted_message = format_debug_message(...)

  if formatted_message then
    print(unpack(formatted_message))
  end
end

--- Append a debug message to a log file in the cache directory
--- Usually at `~/.cache/nvim/weave_debug.log` on Mac/Linux
function Logger.debug_to_file(...)
  local log_parts = format_debug_message(...)
  if not log_parts then
    return
  end

  local log_message = table.concat(log_parts, " ") .. "\n\n" .. string.rep("=", 5) .. "\n\n"

  local cache_dir = vim.fn.stdpath("cache")
  local log_file_path = cache_dir .. "/weave_debug.log"

  local file = io.open(log_file_path, "a")
  if file then
    file:write(log_message)
    file:close()
  else
    Logger.notify("Failed to write to log file: " .. log_file_path)
  end
end

--- @return string
function Logger.unrecognized_acp_path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "weave", "acp-unrecognized.jsonl")
end

local reported_acp_log_failure = false

--- @param path string
--- @param err any
local function report_acp_log_failure(path, err)
  if reported_acp_log_failure then
    return
  end
  reported_acp_log_failure = true
  Logger.notify(
    ("Failed to write unrecognized ACP log %s: %s"):format(path, tostring(err)),
    vim.log.levels.WARN
  )
end

--- Persist a wire message that Weave could not recognize or apply.
---
--- This log is intentionally independent of Config.debug: unknown protocol
--- traffic is rare and is exactly the evidence needed to support a new provider
--- or ACP extension. JSONL keeps each raw message independently parseable.
--- @param reason string
--- @param message any
--- @param provider? string
--- @return boolean ok
--- @return string? err
function Logger.unrecognized_acp(reason, message, provider)
  local path = Logger.unrecognized_acp_path()
  local record = {
    version = 1,
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    reason = reason,
    provider = provider,
    message = message,
  }

  local encoded_ok, encoded = pcall(vim.json.encode, record)
  if not encoded_ok then
    report_acp_log_failure(path, encoded)
    return false, tostring(encoded)
  end

  local mkdir_ok, mkdir_err = pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  if not mkdir_ok then
    report_acp_log_failure(path, mkdir_err)
    return false, tostring(mkdir_err)
  end

  local file, open_err = io.open(path, "a")
  if not file then
    report_acp_log_failure(path, open_err)
    return false, tostring(open_err)
  end

  -- Unknown frames can contain prompts, paths, and source text. Tighten the
  -- file before writing the first byte rather than relying on the user's umask.
  local uv = vim.uv or vim.loop
  if vim.fn.has("win32") == 0 then
    local chmod_ok, chmod_err = uv.fs_chmod(path, 384)
    if not chmod_ok then
      file:close()
      report_acp_log_failure(path, chmod_err)
      return false, tostring(chmod_err)
    end
  end

  local wrote, write_err = file:write(encoded, "\n")
  local closed, close_err = file:close()
  if not wrote or not closed then
    local err = write_err or close_err or "unknown write error"
    report_acp_log_failure(path, err)
    return false, tostring(err)
  end

  return true
end

return Logger
