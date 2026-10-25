-- Recorded results must render independently of the editor-global task store.
-- Prefer explicit MCP stream fields; accept only unambiguous legacy reports.
local Output = require("weave.tool_output")
local M = {}

local function once(text, marker, start)
  local first = text:find(marker, start or 1, true)
  if not first or text:find(marker, first + #marker, true) then return nil end
  return first
end

local function without_receipt(text)
  return (text:gsub(" %[%s*weave task: [%w%-]+%]", ""))
end

function M.parse(block)
  local explicit = Output.json(block, function(value)
    return (type(value.stdout) == "string" or type(value.stderr) == "string")
      and #(type(value.stdout) == "string" and value.stdout or "")
        + #(type(value.stderr) == "string" and value.stderr or "") <= Output.MAX_BYTES
  end)
  if explicit then
    return {
      stdout = type(explicit.stdout) == "string" and explicit.stdout or nil,
      stderr = type(explicit.stderr) == "string" and explicit.stderr or nil,
      command = type(explicit.command) == "string" and explicit.command or nil,
      cwd = type(explicit.cwd) == "string" and explicit.cwd or nil,
      status_text = type(explicit.status_text) == "string" and without_receipt(explicit.status_text) or nil,
      note = type(explicit.note) == "string" and explicit.note or nil,
    }
  end
  local text = Output.text(block)
  if not text then return {} end
  local fallback = { recorded = without_receipt(text) }
  local id, status, command_start = text:match("^task (%d+): ([^\n]+)\ncommand: ()")
  if not id then return fallback end
  status = without_receipt(status)
  if not (status:match("^exited %(code %-?%d+%)$") or status:match("^running %(pid %d+%)$")
    or status:match("^killed %(signal %d+%)$")) then return fallback end
  local out_marker, err_marker = "\n\n--- stdout ---\n", "\n\n--- stderr ---\n"
  local out_at, err_at = once(text, out_marker, command_start), once(text, err_marker, command_start)
  if not out_at or not err_at or out_at >= err_at then return fallback end
  local command = text:sub(command_start, out_at - 1)
  if command == "" then return fallback end
  local stdout, stderr = text:sub(out_at + #out_marker, err_at - 1), text:sub(err_at + #err_marker)
  local note
  if status:match("^running ") then
    local at, message = stderr:match("()\n\n(%(still running after %d+ms; it continues in the background[^\n]*%))$")
    if at then stderr, note = stderr:sub(1, at - 1), message end
  end
  return { command = command, status_text = "task " .. id .. ": " .. status, note = note,
    stdout = stdout ~= "(empty)" and stdout or "", stderr = stderr ~= "(empty)" and stderr or "" }
end

return M
