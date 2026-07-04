# Open Tasks & Issues

Canonical task list — keep ticked/updated as work lands.

## Design decisions (2026-07-04)

- **Transcript = per-entry components** (tool call, thought, prompt, output
  block…), NOT a raw managed buffer. agentic's ADR 0008 documents the bug
  class (stale trailing lines, fold loss, auto-scroll races, permission
  reanchors) that a pure state→render projection structurally precludes;
  fibrous is that projection.
- **Performance**: fibrous grew the transcript-scale machinery for exactly
  this workload (see fibrous `open_tasks_and_issues.md`, "Transcript-scale
  perf" M1–M4): entry vnodes carry `memo = true` (reconciler render bailout
  on shallow-equal props), the paint tier descends through re-rendered list
  containers, and the canvas grows in place on append. Native numbers at
  N=1000 entries: append ~1.0ms, stream tick ~0.7ms, mid-list change ~0.6ms.
  NO virtual scrolling — the buffer + scroll-mode viewport already virtualize
  the display; if truly monstrous sessions ever hurt (N≈4000 ⇒ ~10ms/op),
  the escape hatch is app-level windowing (mount the last K entries behind an
  "older messages" expander).
- **Store**: plain Lua table + subscriber list — NOT nui-components signals.
  Mutations reassign references (fresh arrays; untouched entry objects keep
  identity — that's what the memo bailout keys on). Carry agentic's
  permission FIFO queue pattern verbatim (never a single-slot pending
  request; every queued respond closure eventually answered or cancelled).
- **Highlighting**: per-entry "parse once when the stream settles, cache the
  spans" with the detached treesitter string parser — replaces agentic's
  viewport-throttled whole-buffer repaint. Candidate for upstreaming into
  fibrous as a markdown component.
- **Panel dock**: fibrous `mount.split()` (native split pane + covering
  float, resize-synced). **Prompt**: `ui.text_input` subwin. **Tool-call
  fold**: conditional render on store `expanded` — no real folds to lose.
- **Module namespace**: `clanker` (rename is a mechanical sed once the plugin
  name lands).

## Roadmap

- [x] R1. Scaffold (2026-07-04): ACP layer + utils copied from agentic with
  `agentic` → `clanker` rename — acp_client / acp_transport /
  acp_client_types / acp_payloads / agent_instance / agent_models /
  agent_modes + logger / file_system / list / buf_helpers. Minimal config
  (debug + provider + acp_providers + mcp_servers only; ALL view config left
  behind). fibrous-style test harness (tests/harness.lua + run.lua + Makefile
  copied); tests/acp/load_spec.lua pins the dependency closure + payload
  smoke. 3/3 green.
  - Left behind deliberately: `slash_commands` (old-config-coupled),
    `agent_config_options` (a keymap/picker UI — rebuilt in fibrous later),
    `acp_health` (floating_message dep), `acp_bridge` (165 lines, coupled to
    the SessionStore API — rewritten WITH the new store, its logic is the
    spec).
- [x] R1b. Nix flake (2026-07-04): package (vimUtils.buildVimPlugin), apps
  `test`/`bench`/`demo` (default = demo), devShell, `checks.tests`. fibrous is
  a PINNED input (github:mbrea-c/fibrous.nvim) — sibling changes invisible
  until commit+push+`nix flake update fibrous`; every runner honors
  FIBROUS_PATH and the Makefile defaults it to ../nui-reactive, so `make *`
  always sees the working tree. New: bench/run.lua (discovers
  bench/*_bench.lua; none yet), demo/init.lua (floating provider list as a
  wiring proof until R5; resolves paths from its own file location so the nix
  store copy works). tests/run.lua now puts fibrous on package.path
  (FIBROUS_PATH or sibling) — the R4 prerequisite, done early. Verified:
  `nix run .#test` 3/3, `nix flake check` green, demo renders headless.
- [x] R2. Store (2026-07-04): `lua/clanker/session_store.lua`, red-green
  (33 specs in tests/store/session_store_spec.lua). Plain snapshots: every
  mutation funnels through `_commit(mutate)` — shallow-copy state, reassign
  changed fields with fresh tables, swap, notify — so "one mutation, one
  notify" and the reassign discipline hold by construction. Specs rawequal-
  assert reference stability of unchanged entry objects/sibling tool blocks
  (the `memo = true` contract) and that streaming REPLACES the growing entry.
  Carried from agentic: permission FIFO (+ drain-cancelled, remove-by-tool-
  call), permission modes + pure `auto_option_for` (allow_once preference),
  source-aware set_plan (acp > tool), stateful kiro task commands, prompt
  queue, meta merge (persists across reset). Left out per scope: `hint`
  (R5 sidebar) and `commands` (slash-command completion — prompt work).
- [x] R3. Bridge (2026-07-04): `lua/clanker/acp_bridge.lua`, red-green (13
  specs in tests/acp/bridge_spec.lua — agentic's routing logic IS the spec).
  Handlers: session updates (message/thought streaming + status, user chunks,
  authoritative acp plan, restore suppresses status but not text), tool calls
  (upsert + kiro mirror; updates re-apply the MERGED input; terminal status
  cancels that tool's queued permission + back to generating when queue
  empty), permissions (auto modes answer with the agent's own option and skip
  the queue; respond answers ONLY the agent — no double-pop), on_error →
  transcript entry. `available_commands_update` logs as unhandled until the
  prompt's slash-command completion lands (R5; store has no `commands` yet).
- [x] R4. Transcript view (2026-07-04): `lua/clanker/view/{theme,use_store,
  transcript}.lua`, red-green (15 specs in tests/view/transcript_spec.lua,
  green on first pass). Per-entry components — UserEntry (❯ prefix, blue
  italic), ThoughtEntry ([thinking] block), AgentEntry (flush-left for the
  R6 markdown region), QueuedEntry (⏳ dimmed), ToolCallEntry (span header:
  chevron/status/kind-tag/title-chain, header is a chrome-less button
  toggling store.expanded on <CR>/click; inline interleaved vim.diff preview
  with Diff* hls; expanded metadata + capped vim.inspect raw I/O + body),
  PermissionBlock (head request + "1 of N" + option buttons that pop-then-
  respond) — all mounted `memo = true` from the timeline; `use_store` hook
  (subscribe→set_state, catches up on mutations racing the effect flush,
  unsubscribes on unmount). Specs pin buffer lines + Diff extmarks +
  awaiting_permission override + host-node reference stability across
  mutations. bench/transcript_bench.lua (the first `make bench` scenario)
  drives the REAL store→view pipeline: N=1000 append 2.3ms / stream tick
  2.2ms / mid status flip 1.8ms (40ms debounce budget: plenty); toggle
  15.8ms (height change shifts everything below — user-paced, fine).
  Deferred: show_thoughts/show_diffs UI toggles + follow-mode autoscroll
  (window/panel concerns) → R5; markdown/diff treesitter → R6.
- [x] ~~BLOCKED on fibrous push~~ (resolved 2026-07-04): fibrous pushed
  (215edfe "feat: optionally memoize props"), `nix flake update fibrous` run,
  flake.lock re-staged — `nix flake check` green (all 64 specs).
- [x] R5. Panel shell + controller (2026-07-04), red-green throughout
  (suite 64 → 112). Pieces:
  - fibrous text_input grew `clear_on_submit` + `on_create(bufnr)` (2 specs
    in fibrous input_spec; suite there 287/0) — needed for a chat prompt and
    for wiring buffer-local completion/keymaps.
  - Store: `hint` + `rotate_hint` (HINTS exported, rotated on turn end),
    `commands` + `set_commands`/`get_commands` (normalised completion items,
    /new always present, `clear` + spaced names skipped); reset restores the
    default command list. Bridge routes `available_commands_update`.
  - `view/prefs.lua`: per-panel UI prefs (show_thoughts/show_diffs/
    conceal_markdown/follow), same snapshot+subscribe contract as the session
    store so use_store works on both. Transcript takes `prefs` as a REQUIRED
    prop (hooks must be unconditional): thought entries filtered, diff
    preview gated via a scalar `show_diff` ToolCallEntry prop (memo-correct).
  - `view/sidebar.lua`: Session meta, the four pref checkboxes (ui.checkbox),
    Hint, Tasks (STATUS_ICON + ClankerTaskDone strikethrough via derived-fg
    groups), Permissions (mode label + head request + numbered options).
  - `view/prompt.lua`: text_input with clear_on_submit, empty-submit no-op,
    <C-x> steer map + slash-command completion (completefunc off a
    buffer-local mirror, auto-trigger on leading `/`) wired in on_create,
    border colour tracks permission mode (ClankerPromptBorder*), status row
    ALWAYS rendered (blank when idle) — a row that comes and goes would move
    the input positionally and recreate the subwin, discarding typed text
    (caught by spec).
  - `view/panel.lua`: the dock is a column of REAL windows (transcript =
    scroll-mode root, prompt fixed, sidebar fixed, each mount.window over its
    own pane) — native scrolling + <C-w> motions for free vs agentic's ~200
    lines of float focus-forwarding. Panel keymaps on all panel buffers
    (;;t/d/c/f prefs, ;;p cycle, ;;m/;;M pickers, ;;1-9 permissions, zR/zM,
    za→<CR> remap, <C-c>); follow-mode autoscroll (deferred, coalesced,
    jump-on-enable); closing ANY pane closes the panel.
  - `session.lua` (controller, agentic's session.lua semantics as spec, fake
    client injected via opts.get_instance): start/create_session/meta
    publishing, model+mode capture (Kiro models/modes AND ACP configOptions),
    config pickers, submit (queue mid-turn), steer (cancel-then-resend),
    cancel (drop queue + drain permissions), respond_permission,
    turn end (steer > queue drain, hint rotation, error entries), /new.
  - `init.lua`: setup() merges Config IN PLACE + :Clanker; open/close/toggle/
    stop; the session outlives the panel (reopen binds the same store).
  - demo/init.lua rewritten: the real panel against a scripted agent
    (streaming prose/thoughts, tool calls, an edit + permission request every
    second turn, plan updates). Verified headless end-to-end.
- [x] R5b. Panel reworked onto fibrous multi-container (2026-07-04), replacing
  the rejected three-native-windows design. fibrous grew `ui.container` (one
  fiber tree, N buffers: a subwindow leaf whose children flush into the
  container's own buffer, shown in an always-on float with its own recursive
  subwin manager + interaction layer — see fibrous's tracker entry; suite
  there 298/0). The panel is now ONE docked pane + ONE mount:
  `row [ col (transcript container grow/scroll + Prompt) | Sidebar col ]` —
  transcript scrolls natively in its float (page motions stay inside;
  <CR>/edge-exits hop the boundary), tool-call toggles ride the container's
  own interact layer, prompt + sidebar render inline in the root canvas.
  Shell keeps only: keymaps (root/transcript/input buffers via on_create
  hooks — container's hands over (bufnr, winid), Prompt chains its own),
  follow autoscroll (cursor-to-bottom on the container float), teardown +
  origin restore (one unmount; fibrous walks focus out innermost-first).
  panel_spec reworked (8, incl. "<CR> toggles a tool call through the
  container"); Prompt gained `height` + `on_create` passthrough; init/demo
  untouched (handle API: bufnr/winid/host_winid/transcript/focus_prompt/
  close/is_open). Suite 113/113; demo verified headless end-to-end.
  Perf through the FULL panel (ad-hoc bench, N=500): append 3.3ms / stream
  tick 3.1ms — after a fibrous fix (viewport containers skip the inner
  measure; the first cut re-wrapped all entries twice per tick, 10.7ms).
  Gotcha inherited from fibrous: a transcript-style container in a ROW needs
  height/grow (ours has grow=1) — an auto-sized one would double-measure
  per flush.
- [x] R5b dogfooding fixes (2026-07-04, user bug reports from the demo):
  - **Toggle yanked the cursor to the bottom of the tool-call metadata:** the
    follow-mode store subscriber fired on EVERY mutation, including
    `toggle_tool_call` (expanding grows the transcript, follow jumped to its
    last line). Snapshots are immutable, so the subscriber now reference-diffs
    `entries`/`tool_calls` against the last-followed snapshot and only content
    growth autoscrolls; visibility flips (expanded, permissions, modes) never
    move the cursor. Spec: "toggling a tool call keeps the cursor on its
    header". (fibrous's splice was verified innocent — spec'd there too.)
  - **`<C-w>l` selected the blank pane behind the panel** and **the root
    canvas could scroll into blank space** — both fixed in fibrous mount.lua
    (pane focus forwarding + fixed-mode view pinning; see fibrous tracker,
    suite 301/0). No clanker code involved. Suite 114/114.
- [x] Sidebar made idiomatic + task-list restyle (2026-07-04, user request):
  every section is now a SELF-CONTAINED component (Session/Prefs/Hint/Tasks/
  PermissionsSection — each owns its header, rows and use_store subscription;
  Sidebar is pure composition, and each section mounts standalone). Task rows
  are `row [icon label | paragraph]` with the new vocabulary: □ pending
  (plain), ■ in-progress (amber icon), ✔ done (green icon), ✖ failed (red
  icon; not in ACP's plan enum, mapped defensively) — done/failed TEXT dims +
  strikes through (Theme.TASK_ICON / TASK_ICON_HL; TASK_DONE_HL now
  text-only, the icon is never struck). Wrapped task text hangs under itself.
  Exposed a fibrous layout bug (fixed there, suite 302/0): an explicit
  `width` didn't pin the measuring constraint, so the sidebar's paragraphs
  wrapped at the panel row's remaining width and painted clipped. Sidebar
  specs reworked (+ standalone-section spec); suite 115/115; verified in the
  live demo.
- [ ] BLOCKED on fibrous push (again): `nix flake check` runs against pinned
  fibrous 215edfe, which predates the text_input `clear_on_submit`/`on_create`
  hooks AND the whole multi-container `ui.container` primitive — prompt/panel/
  init specs fail there. Working tree: 113/113. Unblock: push fibrous,
  `nix flake update fibrous`, re-stage flake.lock.
- [ ] R5 leftovers:
  - Session restore: port session_source.lua (ACP session/list + Kiro fs
    fallback), Session:restore + show_restore_picker (bridge already takes
    is_restoring), ;;r binding.
  - conceal_markdown is a stored pref with no effect yet — lands with R6.
  - Multi-session / registry (agentic's ARCHITECTURE-multisession) — later.
- [ ] R6. Markdown/diff highlighting component (parse-on-settle, cached
  spans).
