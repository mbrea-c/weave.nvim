# ACP protocol gaps

Findings from a live-session spike (requests.md → Spikes): drove a real
`opencode acp` session over stdio — full `initialize` handshake, `session/new`,
and a `session/prompt` that read a file and ran a shell command — logging every
message the agent sent, then cross-checked against the client source. Records
what our ACP client does NOT handle today.

_Method:_ `opencode acp` speaks newline-delimited JSON-RPC. The probe sent our
exact `clientCapabilities`, captured all agent→client traffic, and answered
permission requests so a turn completed. Dated 2026-07-07; opencode agentInfo
reported `sessionCapabilities = { close, fork, list, resume }`,
`promptCapabilities = { embeddedContext, image }`.

## Handled today (confirmed live)

- **Outgoing (client→agent):** `initialize`, `session/new`, `session/load`,
  `session/list`, `session/prompt`, `session/set_mode`,
  `session/set_config_option`, `session/set_model`, `session/cancel`.
- **Incoming requests:** `session/request_permission`.
- **Incoming notifications:** `session/update`.
- **`session/update` kinds:** `agent_message_chunk`, `agent_thought_chunk`,
  `user_message_chunk`, `plan`, `available_commands_update`, `tool_call`,
  `tool_call_update`.
- **Config:** both the legacy `models`/`modes` shape AND the modern
  `configOptions[]` (`session.lua` handles both — opencode returned
  `configOptions`).

## Gaps

_Update 2026-07-19:_ gaps 1 and 2 are moot as INTEGRATION paths. The fs and
terminal client capabilities are on the deprecation path and the upcoming ACP
v2 removes them (low adoption). Weave's editor integration goes through MCP
tools plus optional sandboxing instead; see design-agent-sandbox.md in the
superproject. Still real from gap 1: ignoring an incoming `fs/read_text_file`
request without ANY response can hang a strict agent; the fix is to answer
with a JSON-RPC error, not to implement the capability.

### 1. Editor filesystem access is declined — highest editor-integration value

We advertise `fs.readTextFile = false`, `fs.writeTextFile = false`
(`acp_client.lua` ~line 69). Consequences:

- A compliant agent never routes file I/O through the editor. In the live run,
  opencode read `flake.nix` with its OWN tool, not by asking us — so the agent
  can't see unsaved buffer state, and its edits don't flow through weave.
- If an agent sends `fs/read_text_file` / `fs/write_text_file` anyway, we
  `Logger.debug("...ignoring it")` and send **no response** (`acp_client.lua`
  ~line 309). A strict agent waiting on that request id would hang.

_Fix sketch:_ implement `fs/read_text_file` (serve live buffer contents when the
path is open, else disk) and `fs/write_text_file` (route through the buffer/
editor), then flip the advertised capabilities to `true`.

### 2. Terminal capability is declined — already tracked

`terminal = false` (`acp_client.lua` ~line 74). Agent commands (`echo hi` in the
run) execute in the agent's own sandbox, invisible/uncontrollable in the editor.
Tracked separately as "weave: ACP terminal stuff" (needs design discussion).

### 3. `usage_update` is dropped — feeds "Usage metadata in sidebar" — ✅ DONE

opencode emitted `session/update` with `sessionUpdate = "usage_update"` (payload
`{ used, size, cost = { amount, currency } }`) live. Now handled: `acp_bridge`
routes it to `SessionStore:set_usage`, and the sidebar's `UsageSection` renders
`Context: used / size (pct%)` plus a cost line (omitted for zero-cost
free/subscription models).

### 4. `current_mode_update` is dropped

ACP emits this when the agent changes mode server-side. We only track mode from
our own `set_mode` calls, so the sidebar's mode indicator can go stale after an
agent-initiated switch. Same `else` branch as above.

### 5. Unknown incoming REQUESTS get no error reply — robustness

`_handle_notification` routes any message with a `method` (even one carrying an
`id`, i.e. a request). For anything unrecognised it preserves the raw frame in
the unrecognized-ACP log and calls `Logger.notify`, but it still does not reply.
It should answer JSON-RPC `-32601 method not found` so an agent doesn't hang on
an unhandled request. Latent: opencode respects our advertised caps, so it
wasn't triggered, but any agent that sends an out-of-spec or newer request
would stall.

### 6. Unused agent session capabilities — minor

opencode advertises `sessionCapabilities = { close, fork, list, resume }`. We use
`list` (discovery) and `load`; `fork` / `resume` / `close` are unused (advanced
session management, low priority).

## Suggested order

1. Quick wins: `usage_update` (3), `current_mode_update` (4), method-not-found
   reply (5) — small store/bridge/client additions.
2. Filesystem access (1) — highest impact, medium effort (buffer-backed
   `fs/*` handlers + capability flip).
3. Terminal (2) — biggest; needs design (see the tracked ACP-terminal item).
