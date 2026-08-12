-- w:request_access — the elevation tool (design-agent-sandbox-v2.md,
-- phase H). Under sandbox mode on the agent has no direct reach and its
-- tools run inside the preset's hull; this is the agent's explicit, visible
-- way to ask for MORE: a folder beyond the hull, or network for its tasks.
--
-- An accepted grant is SESSION-SCOPED and lands in the permission engine's
-- overlays, never in the preset:
--   * a folder grant writes BOTH sections — a bind (so the kernel hull
--     reaches it on the very next tool spawn) and allow rules (so the gate
--     agrees): weave:* for rw, the read-shaped tools for ro;
--   * a network grant flips the tool-sandbox network flag.
-- No restart anywhere: hulls are re-derived per invocation.
--
-- Deliberately NOT Gate.wrap'd: this tool IS the asking mechanism — it
-- always prompts, so wrapping it would prompt twice for one question. It
-- still rides the broker like every other weave tool.

local M = {}

--- The rule grants a folder elevation writes beside its bind: what the gate
--- should now allow there. rw = everything weave can do under the path; ro
--- = only the read-shaped tools.
--- @param path string absolute
--- @param mode "rw"|"ro"
--- @return weave.permissions.Rule[]
local function rules_for(path, mode)
  local resource = path .. "/**"
  if mode == "rw" then
    return { { tool = "weave:*", resource = resource, decision = "allow" } }
  end
  return {
    { tool = "weave:read", resource = resource, decision = "allow" },
    { tool = "weave:glob", resource = resource, decision = "allow" },
    { tool = "weave:grep", resource = resource, decision = "allow" },
  }
end

M.def = {
  description = "Request access beyond the current sandbox: a directory (read-only or read-write) or network "
    .. "for executed tasks. The user is asked; a grant lasts for this editor session and applies to your "
    .. "next tool call — no restart. Provide `reason` so the user knows why.",
  inputSchema = {
    type = "object",
    properties = {
      path = { type = "string", description = "Directory to reach (absolute); omit when asking for network" },
      mode = { type = "string", enum = { "rw", "ro" }, description = "Access level for `path` (default rw)" },
      network = { type = "boolean", description = "Ask for network access in executed tasks" },
      reason = { type = "string", description = "Why you need this; shown to the user" },
    },
  },
  async = true,
  handler = function(args, respond)
    local Permissions = require("weave.permissions")
    local Gate = require("weave.tools.gate")

    local wants_path = type(args.path) == "string" and args.path ~= ""
    local wants_network = args.network == true
    if not wants_path and not wants_network then
      return respond({
        content = { { type = "text", text = "request_access needs `path` and/or `network = true`" } },
        isError = true,
      })
    end
    local mode = args.mode == "ro" and "ro" or "rw"
    local path = wants_path and vim.fn.fnamemodify(args.path, ":p"):gsub("/$", "") or nil

    local asks = {}
    if path then
      asks[#asks + 1] = ("%s access to %s"):format(mode == "ro" and "read-only" or "read-write", path)
    end
    if wants_network then
      asks[#asks + 1] = "network access for executed tasks"
    end
    local title = "Agent requests " .. table.concat(asks, " and ")
    if type(args.reason) == "string" and args.reason ~= "" then
      title = title .. " — " .. args.reason
    end

    local store = Gate._ask_store()
    if not store then
      return respond({
        content = { { type = "text", text = "access not granted: no active weave session to ask" } },
        isError = true,
      })
    end
    store:enqueue_permission({
      client_side = true,
      request = {
        toolCall = { title = title, kind = "other" },
        options = {
          { optionId = "allow_once", name = "Grant for this session", kind = "allow_once" },
          { optionId = "reject_once", name = "Reject", kind = "reject_once" },
        },
      },
      respond = function(option_id)
        if option_id ~= "allow_once" then
          return respond({
            content = { { type = "text", text = "access not granted: the user declined" } },
            isError = true,
          })
        end
        local granted = {}
        if path then
          Permissions.add_bind_grant({ path = path, mode = mode })
          for _, rule in ipairs(rules_for(path, mode)) do
            Permissions.add_grant(rule)
          end
          granted[#granted + 1] = ("%s %s"):format(mode, path)
        end
        if wants_network then
          Permissions.set_network_granted(true)
          granted[#granted + 1] = "network"
        end
        respond(
          ("access granted for this session: %s. It applies from your next tool call."):format(
            table.concat(granted, ", ")
          )
        )
      end,
    })
  end,
}

return M
