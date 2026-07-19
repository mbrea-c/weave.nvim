-- The permission-engine → fibrous bridge hook: subscribe a component to the
-- editor-global engine (weave.permissions) and hand back the ACTIVE preset.
-- Same version-counter shape as terminal_tasks' use_tasks — the engine's
-- subscribe carries no payload, so a bumped counter drives the re-render and
-- the component re-reads the engine directly.

local Permissions = require("weave.permissions")

--- @param ctx table fibrous ReactiveCtx
--- @return weave.permissions.Preset active
return function(ctx)
  local ver = ctx.use_state(0)
  ctx.use_effect(function()
    return Permissions.subscribe(function()
      ver.set(ver.get() + 1)
    end)
  end, { Permissions })
  ver.get() -- read it: the version bump is what re-renders us
  return Permissions.active()
end
