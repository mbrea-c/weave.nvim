-- The store→fibrous bridge hook: subscribe a component to a SessionStore so
-- it re-renders (with the fresh snapshot) on every mutation. Because the
-- store reassigns `state` per mutation and keeps unchanged values
-- reference-stable, a re-render driven by this hook composes with
-- `memo = true` children: only components whose props actually changed run.

--- @param ctx table fibrous ReactiveCtx (use_state/use_effect)
--- @param store clanker.store.SessionStore
--- @return clanker.store.State state the current snapshot
return function(ctx, store)
  local snap = ctx.use_state(store.state)
  ctx.use_effect(function()
    -- Effects flush after commit: a mutation may have landed between the
    -- render that captured `snap` and this subscription. Catch up first.
    if snap.get() ~= store.state then
      snap.set(store.state)
    end
    return store:subscribe(function(state)
      snap.set(state)
    end)
  end, { store })
  return snap.get()
end
