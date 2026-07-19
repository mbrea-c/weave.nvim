-- Where a sent code-feedback item goes. This is the extension point: weave
-- ships a sink that prompts the current session, and anything else (perijove,
-- a scratch buffer, a review tool) registers its own and becomes selectable as
-- a target without weave knowing it exists.
--
-- Kept separate from the producer side on purpose. "who can CREATE a comment"
-- needs no registry at all — call weave.feedback_store.add — but "who RECEIVES
-- the bundle" is a real choice the user makes at send time, so it needs names,
-- labels and a default.
--
-- Same shape as the tool-renderer registry (weave.view.tool_call.register):
-- register by name, re-registering a name replaces it rather than stacking.

local M = {}

--- @class weave.feedback.Sink
--- @field name string unique key
--- @field label string|nil human label for the UI (defaults to the name)
--- @field send fun(text: string, item: weave.feedback.Item): boolean|nil, string|nil

--- @type weave.feedback.Sink[]
local sinks = {}

--- The builtin: hand the formatted feedback to the current tab's session as a
--- prompt. Goes through Session:submit rather than the ACP client directly, so
--- feedback sent mid-turn is queued exactly like anything the user types.
local WEAVE_SINK = {
  name = "weave",
  label = "the current weave session",
  send = function(text)
    local session = require("weave").get_session()
    if not session then
      return nil, "no weave session in this tab to send feedback to"
    end
    session:submit(text)
    return true
  end,
}

--- @param spec weave.feedback.Sink
--- @return weave.feedback.Sink|nil registered spec, nil when rejected
function M.register(spec)
  if type(spec) ~= "table" or type(spec.name) ~= "string" or type(spec.send) ~= "function" then
    return nil
  end
  for i, s in ipairs(sinks) do
    if s.name == spec.name then
      sinks[i] = spec
      return spec
    end
  end
  sinks[#sinks + 1] = spec
  return spec
end

--- @param name string
--- @return weave.feedback.Sink|nil
function M.get(name)
  for _, s in ipairs(sinks) do
    if s.name == name then
      return s
    end
  end
  return nil
end

--- @return weave.feedback.Sink[]
function M.list()
  return { unpack(sinks) }
end

--- @return weave.feedback.Sink
function M.default()
  return M.get("weave") or sinks[1]
end

--- Hand `text` to the named sink. A sink that throws is reported as a failed
--- send rather than unwinding into the button press that triggered it — the
--- draft is only cleared on a genuine success, so a broken sink loses nothing.
--- @param name string
--- @param text string
--- @param item weave.feedback.Item
--- @return boolean|nil ok, string|nil err
function M.dispatch(name, text, item)
  local sink = M.get(name)
  if not sink then
    return nil, ("no feedback sink named %q"):format(tostring(name))
  end
  local ok, res, err = pcall(sink.send, text, item)
  if not ok then
    return nil, ("feedback sink %q failed: %s"):format(sink.name, tostring(res))
  end
  if not res then
    return nil, err or ("feedback sink %q declined to send"):format(sink.name)
  end
  return true
end

-- test hook: drop user registrations, keep the builtin
function M._reset()
  sinks = { WEAVE_SINK }
end

M._reset()

return M
