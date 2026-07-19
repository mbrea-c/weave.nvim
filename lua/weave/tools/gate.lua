-- The permission gate over weave's MCP tool suite (design-agent-sandbox.md,
-- phase 1): every def registered into clankbox is wrapped so the call first
-- resolves through the client-side engine (weave.permissions) as
-- weave:<tool> plus the concrete resource. The wrapped def is ALWAYS async —
-- an "ask" outcome must be able to answer after the user does.
--
--   allow — run the tool unchanged (a sync throw still lands in clankbox's
--           pcall, so error reporting matches an ungated tool).
--   deny  — answer an isError result naming the action and the preset, so
--           the agent knows the client refused and can route around it.
--   ask   — enqueue a synthetic, ACP-shaped permission request into the
--           current session's store: the sidebar renders it and ;;1..;;4
--           answer it exactly like an agent-side request. Anything but an
--           allow option (including a drain's nil) refuses the call, and the
--           two "always" options additionally record a grant.
--
-- Under the three legacy presets everything client-side resolves allow, so
-- the gate is inert there — the agent-side ACP flow already mediates these
-- calls as acp:* actions. It comes alive under the sandboxed_* presets,
-- where weave's tools stop being exempt from the confinement a sandbox
-- profile was turned on for.

local Permissions = require("weave.permissions")

local M = {}

--- The store that surfaces "ask" prompts: the current tab's session, else
--- the first active one. MCP calls arrive over clankbox with no session
--- identity attached, so "the session you are looking at" is the best
--- available owner for the prompt. Overridable seam for specs.
--- @return weave.store.SessionStore|nil
function M._ask_store()
  local ok, Registry = pcall(require, "weave.registry")
  if not ok then
    return nil
  end
  local entry = Registry.selected() or Registry.list()[1]
  return entry and entry.session:get_store() or nil
end

--- @param text string
--- @return table result MCP isError result (clankbox passes it through)
local function refusal(text)
  return { content = { { type = "text", text = text } }, isError = true }
end

--- @param action weave.permissions.Action
--- @return string
local function describe(action)
  if action.resource then
    return ("%s (%s)"):format(action.tool, action.resource)
  end
  return action.tool
end

--- What an "always" answer actually commits to, said in the prompt rather
--- than in documentation nobody reads: the grant is project-wide inside the
--- project and path-exact outside it.
--- @param action weave.permissions.Action
--- @param verb "Allow"|"Reject"
--- @return string
local function always_label(action, verb)
  local rule = Permissions.grant_rule(action, "allow")
  if rule.resource == nil then
    return verb .. " always"
  end
  if rule.resource:find("${project}", 1, true) then
    return verb .. " for project"
  end
  return ("%s for %s"):format(verb, vim.fn.fnamemodify(rule.resource, ":~"))
end

--- Wrap a raw clankbox tool def behind the permission engine.
--- @param name string Bare tool name as registered ("read", "task_start", ...)
--- @param def table The raw def (sync or async)
--- @param opts { resource?: fun(args: table): string|nil, kind?: string }
---   resource extracts the action's resource from the call arguments; kind is
---   the ACP ToolKind shown for ask prompts (read/edit/execute/other).
--- @return table wrapped Always-async def with the same schema/description
function M.wrap(name, def, opts)
  opts = opts or {}
  return {
    description = def.description,
    inputSchema = def.inputSchema,
    async = true,
    handler = function(args, respond)
      local action = { tool = "weave:" .. name, resource = opts.resource and opts.resource(args) or nil }
      local decision = Permissions.resolve(action)

      local function run()
        if def.async then
          def.handler(args, respond)
        else
          respond(def.handler(args))
        end
      end

      if decision == "allow" then
        return run() -- a sync throw propagates into clankbox's pcall
      end

      if decision == "deny" then
        return respond(
          refusal(
            ("permission denied: %s is blocked by the active weave permission preset %q"):format(
              describe(action),
              Permissions.active().name
            )
          )
        )
      end

      -- ask: surface through the session's existing permission queue
      local store = M._ask_store()
      if not store then
        return respond(
          refusal(
            ("permission not granted: %s requires approval but there is no active weave session to ask"):format(
              describe(action)
            )
          )
        )
      end
      store:enqueue_permission({
        request = {
          toolCall = {
            title = ("weave tool %s%s"):format(name, action.resource and (": " .. action.resource) or ""),
            kind = opts.kind,
          },
          -- Four options, in ACP's own `kind` vocabulary so the sidebar
          -- renderer and the ;;1..;;9 answer keys need no changes. The
          -- "always" pair writes a grant into the permission overlay rather
          -- than redefining the active preset — see Permissions.grant_rule
          -- for why the scope is the project and not the exact resource.
          -- reject_always matters more here than in the ACP flow: under a
          -- sandbox profile weave's tools are the agent's only route to the
          -- filesystem, so "stop asking me AND stop trying" is a thing users
          -- want and currently cannot say.
          options = {
            { optionId = "allow_once", name = "Allow once", kind = "allow_once" },
            { optionId = "allow_always", name = always_label(action, "Allow"), kind = "allow_always" },
            { optionId = "reject_once", name = "Reject once", kind = "reject_once" },
            { optionId = "reject_always", name = always_label(action, "Reject"), kind = "reject_always" },
          },
        },
        respond = function(option_id)
          if option_id == "allow_always" then
            Permissions.add_grant(Permissions.grant_rule(action, "allow"))
          elseif option_id == "reject_always" then
            Permissions.add_grant(Permissions.grant_rule(action, "deny"))
          end
          if option_id ~= "allow_once" and option_id ~= "allow_always" then
            return respond(refusal(("permission not granted: the user declined %s"):format(describe(action))))
          end
          -- we're past clankbox's pcall now: contain tool errors ourselves,
          -- in its "Tool error:" isError shape
          local ok, err = pcall(run)
          if not ok then
            respond(refusal("Tool error: " .. tostring(err)))
          end
        end,
      })
    end,
  }
end

return M
