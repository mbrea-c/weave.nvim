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
- [x] ~~BLOCKED on fibrous push (again)~~ (resolved 2026-07-05): fibrous
  pushed (c8724b7 "fix: fix ignored width" — container + mount + layout
  work), lock updated — `nix run .#test` against the PIN is 134/134. NB
  fibrous's working tree has since grown Tab-navigation (uncommitted);
  clanker doesn't depend on it yet.
- [x] Session restore (2026-07-05), red-green (suite 115 → 122):
  `Session:restore(id)` = /new-shaped teardown (cancel old session, reset
  store, meta persists) + `client:load_session` — the provider REPLAYS the
  history through the ordinary handlers DURING the request, with the bridge's
  `is_restoring` predicate (now wired in `_build_handlers`) suppressing the
  spinner flaps; on complete the session id is adopted, config recaptured
  (session/load may return models/modes like session/new) and meta
  republished. `Session:show_restore_picker()` = `client:list_sessions(cwd)`
  → vim.ui.select ("date - title") → clobber confirmation when the transcript
  is non-empty → restore. `;;r` panel chord → `on_restore_picker` (flows
  through view_handlers). Demo agent grew canned list/load so ;;r is
  dogfoodable. SCOPE: ACP-native only — the tracker's old "Kiro fs fallback"
  idea was dropped: upstream agentic removed its local-persistence fallback
  (47386a7's ChatHistory JSON store is gone from main), there is no
  session_source.lua to port, and kiro-cli isn't installed here to
  reverse-engineer a format; providers without `sessionCapabilities.list`
  get the client's capability-check notify.
- [x] R6. Markdown/diff components (2026-07-05), red-green (suite 122 → 134).
  Built as CLANKER-LOCAL reusable components (user decision: don't widen the
  pinned-flake gap; they're store/prefs/theme-free — props in, vnodes out —
  so upstreaming into fibrous later is a file move):
  - `view/markdown.lua`: `parse(text, {conceal})` → per-line fibrous span
    lists via the detached STRING parser (no scratch buffers), full injection
    stack (markdown → markdown_inline → fenced-code langs, trees applied
    parent-first so deeper captures win); capture names become
    "@<name>.<lang>" and nvim's dotted-group fallback resolves them. Conceal
    is NOT extmark conceal: concealed bytes (from query `conceal` metadata /
    @conceal captures) are OMITTED from the spans — no conceallevel anywhere,
    wrap measures the visible text, fully-concealed lines (fence delimiters)
    drop. GOTCHA: parse newline-terminated input — the bundled queries skip
    the closing-fence conceal otherwise (normalized inside parse, line count
    preserved). Code-block lines emit nowrap labels; prose wraps.
    `Markdown` component: "parse on settle" — while `live`, plain paragraphs,
    zero parsing; settled parses ONCE per (text, conceal), cached on a ref.
  - `view/diff.lua`: the transcript's interleaved unified-diff preview
    extracted into `Diff{old,new,max_lines,indent}` (vim.diff cached per
    old/new pair; @@ headers dim, +/- → DiffAdd/DiffDelete). Syntax UNDER the
    Diff* colors is out of scope: spans carry one hl per run — stacking would
    need combined groups.
  - Transcript wiring: AgentEntry renders through Markdown with
    `live = (tail entry AND status generating)` and `conceal =
    prefs.conceal_markdown` (both scalars — memo invalidates exactly on
    flip); the conceal_markdown pref now has its effect. ToolCallEntry's diff
    preview is the Diff component (existing specs pin identical output).
  - Bench unchanged-or-better (N=1000: append 0.9ms, stream tick 0.7ms —
    live tail never parses). Demo REPLY now streams real markdown (heading +
    fence); fixed the demo chunker eating newlines (`%S+ ?` → `%S+%s*`) —
    markdown block structure IS the whitespace. Verified live: injected
    @keyword.lua etc. in the transcript container buffer.
- [x] R5 leftovers:
  - ~~Multi-session / registry (agentic's ARCHITECTURE-multisession) —
    later.~~ Done, see the providers & sessions entry below.
- [x] Providers & sessions / multi-session (2026-07-05, user-directed
  design), red-green (suite 134 → 150). The layers below init were already
  multi-session-shaped (ACPClient routes per sessionId via `subscribers`,
  AgentInstance keeps one process per provider, Session/store are
  instance-scoped) — the work was bookkeeping + UI:
  - `registry.lua` (NEW): the editor-GLOBAL list of active sessions
    (`{key, session, prefs, provider}`, monotonic keys) + the PER-TABPAGE
    selection map (user's model: selected-per-tab, active-globally).
    Different entries may use different providers (user decision: yes —
    it's free, processes are per-provider anyway). `add()` accepts
    `restore = <saved id>` to activate a saved session into a FRESH entry
    (vs ;;r's in-place restore) via the new `Session:start({restore})`,
    which swaps session/load in for session/new after connect. `close()`
    cancels+stops and clears every tab selection pointing at it;
    `on_close` listeners survive `reset()` ON PURPOSE (init registers its
    panel-teardown hook once at module load; suite spec-order must not be
    able to sever it).
  - init.lua rewired: the session/panel/prefs singleton became registry +
    per-tab panel handles (each remembers its open geometry so a session
    swap reopens at the same size). toggle/open bind the CURRENT tab's
    selection (creating+selecting on first use); get_session() = the tab's
    selection; stop() closes every session and the on_close hook takes all
    its panels down (any tab). The get_instance injection handed to open()
    is REMEMBERED and reused by the modal's new/load flows — the demo and
    specs script the agent once and every later session stays scripted.
  - `view/session_modal.lua` (NEW): floating fibrous mount (`;;s`, or
    `:Clanker sessions`) — one row per active session (● = this tab's
    selection; label = provider · first user message · status), rows are
    fibrous BUTTONS so <CR> activation, hover and <Tab> cycling come from
    the framework; per-row ✕ closes that session everywhere (modal
    re-renders via set_props); `+ new session` → provider picker (● marks
    the config default) → add+select+swap; `↺ load saved…` → provider pick
    → session/list → pick → activate into a fresh entry. q/<Esc> close.
    NB the <Tab> cycling needs fibrous's tab-navigation (committed locally
    as d5568cb, not yet pushed/pinned; under the pin the modal also
    rendered behind the transcript — see the modal-chrome entry and the
    BLOCKED item below).
  - Demo: the scripted client now keeps handlers PER session id (one client,
    many sessions — replies must stream into the transcript that asked);
    create_session mints demo-session-N. Verified live over --listen RPC:
    modal renders, + new session swaps the panel, and a prompt in session 2
    lands ONLY in session 2's store (session 1 stays at 0 entries).
  - Not done (deliberate): background-session event surfacing — a parked
    session hitting a permission request or finishing a turn is invisible
    except in the modal's status column. Needs a notify + attention marker
    design; folded into shell/UX niceties.
- [x] Modal chrome + z-order fix (2026-07-05, user request), suite → 151.
  The modal rendered BEHIND the transcript: fibrous stacked every float at
  ≥50 (subwin levels 60+), so the panel's container floats covered the
  modal's root. Fixed at the fibrous level (see its tracker): pane-anchored
  mounts now stack low (root 10, +1/level) and float mounts root at nvim's
  default 50 — genuine floats (ours or any plugin's) always clear the
  panel. The modal now passes the new mount.floating opts:
  `border = "rounded"` + `backdrop = true` (Snacks-style editor dim, a
  fibrous-owned full-screen float at z=49). Verified live: stack is
  panel 10 / subwins 11 / backdrop 49 / modal 50.
- [x] Modal bug pair (2026-07-05, user reports), suite → 153:
  - "Panel blanked out under the modal": the backdrop float (z=49, above
    the panel's 10/11 stack) hid the panel — nvim's compositor hides
    floats under a winblend float and blends against the base grid only
    (full diagnosis in fibrous's tracker). First fix moved the backdrop
    to z=5 (panel visible, undimmed); USER DECISION reverted: the modal
    SHOULD obscure the panel rather than sit over a bright one, so the
    backdrop is back at root-1 (49) and hiding the furniture is the
    intended effect. Verified against the composed screen (demo inside a
    :terminal of a headless host).
  - "✕ in the modal moves focus to the main buffer": panel close()
    unconditionally restored origin-window focus; the registry on_close
    hook closes the panel while the user sits in the MODAL. close() now
    restores origin focus only when focus is actually inside the panel
    (win or buffer match — NB a bare vsplit of the focused prompt still
    SHOWS a panel buffer, hence the buffer check AND the spec's enew).
    Specs: panel_spec close-from-outside; init_spec modal-✕ keeps modal
    focused + registry intact. Verified live.
- [x] ~~BLOCKED on fibrous push (again)~~ (resolved 2026-07-05): the user
  pushed tab-navigation (d5568cb) + the stacking policy and modal chrome
  (e899700, 72494dd) mid-session; `nix run .#test` auto-bumped the lock to
  72494dd and the suite is 153/153 against the pin.
- [x] Mark-gravity inversion fix landed: committed as fibrous `dde1e2a`
  ("fix: disappearing exmarks on resize"), pushed, and it IS the pinned rev
  — `nix run .#test` green against it.
- [x] Two follow-up UI bugs fixed after the user retested the demo
  (2026-07-05, both in fibrous — see its tracker):
  - Prompt showed as focused (blue border) on panel creation without the
    cursor in it. subwin.lua drove `_focus` off buffer WinEnter/WinLeave,
    but startup re-enters the first window with autocmds off after `-u init`
    sourcing, stranding the accent ON. Fixed in fibrous (manager-level
    WinEnter reconciliation) AND clanker (panel.lua now defers its focus
    grab past VimEnter). Spec: panel_spec "opened during startup, the prompt
    is genuinely focused after VimEnter" (drives a real child nvim).
  - Incorrect extmarks on HORIZONTAL resize. The gravity fix re-placed marks
    at canvas byte offsets, wrong for byte-divergent mirrored rows
    (multibyte box-drawing content); a checkbox sharing rows with the moved
    transcript-container box got its highlight misplaced. Fixed in fibrous
    (`repaint_row_marks` now translates through display cells). clanker
    suite 154/154 against the working tree.
- [ ] SMALL fibrous-push gap: the two follow-up fixes above (subwin.lua +
  style_state_spec + subwin_spec) are uncommitted in fibrous. No clanker
  spec depends on them (`nix run .#test` green regardless), but the PINNED
  demo keeps the focus-highlight + horizontal-resize bugs until fibrous is
  committed + pushed + `nix flake update fibrous`.

### Phase 2 — Shell/UX niceties (user-ordered, 2026-07-05)

- [x] Animated "thinking" wave (2026-07-05, user request), red-green (suite
  154 → 164). A 12-char traveling sine wave in the prompt's status row while
  a turn is active, replacing the old `⟳ status…` spinner glyph.
  - `view/wave.lua` (NEW, CLANKER-LOCAL like markdown/diff — props in, vnodes
    out, no fibrous change so the pinned gap stays put). Drawn with Unicode-16
    **block-octant** glyphs (2 cols × 4 rows per cell ⇒ 24 horizontal samples,
    4 vertical levels across 12 chars); **braille** offered as a universal
    fallback via the `set` prop. Glyph tables borrowed verbatim from
    neominimap (~/src/neominimap.nvim); bit layout (from its
    `map_point_to_flag`): left column = bits 0-3 (1,2,4,8 top→bottom), right =
    bits 4-7 (16,32,64,128). Landmarks pinned in the spec (0=space, 255=█,
    204=▄, 15=▌, 240=▐, 51=▀).
  - THIN wave (user follow-up 2026-07-05): a single lit cell per column at the
    height — a crest LINE, never filled below it (row q 0=bottom..3=top → one
    bit per column; rising thin ramp = `▂𜴧𜴆🮂`). Every column carries a dot, so
    there are no blanks.
  - BOUNCING single crest (user follow-up 2026-07-05): dropped the repeating
    traveling sine for ONE raised-cosine hump (`bump_row`, half-width SPREAD=6
    sub-cols) whose centre bounces wall-to-wall — `centre = ½(1-cos φ)·(2W-1)`,
    cosine-eased so it slows at the ends. `phase` now drives POSITION, not
    spatial phase (0 = left end, π = right). Baseline row-0 dots elsewhere.
    Specs pin the left/middle/right crest frames + the symmetric return
    (φ=3π/2 == π/2).
  - Colour-by-height (user's bonus ask): each dot coloured by its row via a
    4-group dim-blue→bright-cyan ramp `Theme.WAVE_HL[1..4]` (row 0→group 1 …
    row 3→group 4); all `default = true` so a user restyle wins.
  - Pure `frame(phase)` returns the fibrous span list; the `Wave` component
    drives it off a uv timer in `use_effect` (started while `active`, stopped
    + closed on unmount / deactivate) bumping a `use_state` frame counter —
    no new fibrous primitive needed. Specs pin the phase-0/½π/π frames, the
    travel, the colour ramp, active/inactive render, real-timer animation, and
    clean teardown.
  - Wired in `prompt.lua`: the status row is now `ui.row{ Wave, status label }`
    — the Wave stays MOUNTED always (only `active` toggles) and its width is
    constant, so the input subwin below never moves or gets recreated as the
    wave ticks. Verified live (TUI-in-terminal): three distinct animating
    frames, thinking→generating word tracking, input win/buf STABLE across
    animation while typing mid-turn, idle blanks the wave, no timer errors.
- [ ] Background-session event surfacing (carried from the multi-session
  work): a parked session hitting a permission request / finishing a turn is
  invisible outside the modal's status column — needs a notify + attention
  marker (e.g. a badge on modal rows + `vim.notify`).
