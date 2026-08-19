-- The client-side permission engine (design-agent-sandbox.md, phase 1): one
-- generic rule set answering "may the agent do THIS to THAT" for every
-- mediated operation, whatever protocol it arrived over. Editor-global and
-- protocol-agnostic on purpose — it lives BESIDE the ACP client, not inside
-- it (partial preparation for weave one day being an agentic provider rather
-- than only an ACP client).
--
-- ── The model ───────────────────────────────────────────────────────────────
--
-- An ACTION is what the agent is attempting: a namespaced tool name plus an
-- optional resource string. The namespace is the extensibility hook — any
-- plugin with client-side tools resolves through the same engine by picking
-- its own prefix:
--   acp:<kind>      an ACP session/request_permission (kind: edit, execute,
--                   read, delete, ... — mapped in acp_bridge)
--   acp:mcp         an ACP request to call a tool WEAVE brokers (resource =
--                   `<server>.<tool>` where the provider named the endpoint,
--                   else the title it used). Split out from
--                   acp:<kind> because it is the agent asking to use our
--                   client-side tools, already gated at the broker — the
--                   opposite of the builtin calls acp:* rules speak to.
--   weave:<tool>    weave's own MCP suite (weave:read, weave:task_start, ...)
--   <plugin>:<tool> any other clankbox tool provider (perijove:run_cell, ...)
-- The resource is the thing acted on: a file path, a command line, a buffer
-- reference — plain text, matched with globs.
--
-- A RULE is (tool glob, optional resource glob, decision allow/deny/ask).
-- A PRESET is a named, ordered rule list. Resolution: first matching rule of
-- the ACTIVE preset wins; a rule carrying a resource glob never matches an
-- action without a resource; when nothing matches the answer is "ask" (the
-- safe default — surfaced where the caller has a user to ask, denied where
-- it does not).
--
-- Presets coexist from three sources, later shadowing earlier BY NAME:
-- builtin (shipped; four shapes — ask/read_only/edit/auto — per sandbox
-- mode, plus `yolo` for mode on only), setup (config.permissions.presets),
-- runtime (created or edited in
-- the config window; in-memory for now — persistence is an open question in
-- the design doc). ;;p cycles the effective list.

local M = {}

--- @alias weave.permissions.Decision "allow"|"deny"|"ask"

--- @class weave.permissions.Rule
--- @field tool string Glob over the namespaced action name (e.g. "acp:*", "weave:read", "*")
--- @field resource? string Glob over the resource; a rule with one never matches an action without one
--- @field decision weave.permissions.Decision
--- @field message? string Said to the AGENT when this rule refuses (appended
--- to the refusal text of a client-side tool call, so a deny can redirect
--- rather than merely block). ACP's permission response carries no text
--- channel, so an acp:* deny reaches the agent as a bare rejection — the
--- message surfaces to the USER instead (weave.acp_bridge), and the
--- agent-facing half of that story is the mode-on steering note.

--- @class weave.permissions.SandboxBind One directory (or file) bound into tool sandboxes
--- @field path string `${project}` expands at spawn time; `~` at mount time
--- @field mode? "rw"|"ro" Default "rw"

--- @class weave.permissions.SandboxSection The preset's confinement section
--- (design-agent-sandbox-v2.md): `binds`/`network` are the kernel hull
--- every TOOL invocation runs under — deliberately ORTHOGONAL to the rules:
--- rules speak globs (fine-grained, per-call, can ask), binds speak
--- directories (the coarse outer hull bounding whatever the gate allows,
--- and bugs in the tools themselves). Neither is derived from the other;
--- lint_preset flags the one confusing combination (a rule no bind reaches).
--- @field binds? weave.permissions.SandboxBind[] Tool-sandbox binds (default: the project, rw)
--- @field network? boolean Tool sandboxes get network (default false)
--- @field tools? table<string, weave.permissions.SandboxOverride> Per-tool overrides,
--- keyed by EXACT namespaced tool name ("weave:task_start") — no globs, so
--- which override applies is never a question of table order. A key present
--- in an override replaces the global one; keys absent inherit it.

--- @class weave.permissions.SandboxOverride One tool's deviation from the hull
--- @field binds? weave.permissions.SandboxBind[] Replaces the global binds for this tool
--- @field network? boolean Replaces the global network flag for this tool

--- @class weave.permissions.Preset
--- @field name string Unique id; a later source shadows an earlier one of the same name
--- @field label? string Human label for the sidebar/UI (defaults to name)
--- @field rules weave.permissions.Rule[] Evaluated in order, first match wins
--- @field sandbox? weave.permissions.SandboxSection Declarative: the engine compares/derives, it never applies anything itself
--- @field for_mode? "on"|"off" Restrict this preset to one sandbox mode; nil = both.
--- A preset's rules are written against a world (mode on: builtin tools are
--- dead ends and weave's tools are the only route out; mode off: the reverse),
--- so a preset tagged for the other mode is not merely unhelpful, it is
--- WRONG there — hence hard exclusion (see M.available) rather than a warning.
--- @field source? "builtin"|"setup"|"runtime" Assigned by the engine, not the caller

--- @class weave.permissions.Action
--- @field tool string Namespaced action name (see the vocabulary above)
--- @field resource? string The thing acted on (path, command line, buffer ref)

local DECISIONS = { allow = true, deny = true, ask = true }

-- Rules are static tables in Lua and in config, so they cannot name the
-- project root literally. `${project}` in a resource glob expands to it at
-- resolve time — without this, "inside the project" is inexpressible and the
-- sandboxed presets below collapse to tool-name-only rules.
local PROJECT_TOKEN = "${project}"

-- The same trick for the directory weave stages user attachments into
-- (weave.attachments): a per-process path no static rule could name, and the
-- one place under mode on where the agent's OWN read tool is useful — that is
-- where the image you attached actually is.
local ATTACHMENTS_TOKEN = "${attachments}"

-- The message an acp:* deny carries under the sandboxed presets. The agent's
-- OWN tools are dead ends in mode on (the project is an empty read-only
-- tmpfs), so approving them would only buy a confusing failure — or, worse
-- for reads, a confident wrong answer off the empty decoy.
local USE_CLIENT_TOOLS = "builtin tools are sandboxed away from the project; use the weave (clankbox) tools instead"

-- Providers also ask permission before calling the MCP tools weave brokers
-- (acp:mcp, see acp_bridge). Those are the way OUT of the sandbox, and every
-- frame is gated at the broker anyway, so the sandboxed presets let the
-- request through rather than prompting for the same call twice — or, with
-- the deny below, refusing the agent the tools we just steered it toward.
local ALLOW_BROKERED = { tool = "acp:mcp", decision = "allow" }

-- The one place the agent's OWN read tool still reaches something real under
-- mode on: the directory weave stages attachments into and binds read-only
-- into the hull. Denying it would mean the user attaches an image and the
-- model cannot open the file we just put in front of it — and reading an
-- image is precisely what a builtin read tool does better than w:read, which
-- returns text.
local ALLOW_ATTACHMENTS = { tool = "acp:read", resource = ATTACHMENTS_TOKEN .. "/**", decision = "allow" }

-- Every sandboxed preset ends its weave:* run with a deny carrying this: the
-- workspace is the whole world by default, and the way out is to ASK, not to
-- try a wider path and hope. Saying so in the refusal is what turns a dead
-- end into the next step — the agent reads it and calls request_access.
--
-- The deny is safe to state absolutely because elevation grants land in the
-- OVERLAY, which resolve() consults before the active preset: an approved
-- /data grant out-votes this line without editing the preset.
local OUTSIDE_WORKSPACE = "outside the workspace: call request_access to ask the user for this path"

-- What a read-only preset says when it turns back a write or a command.
local READ_ONLY = "this preset is read-only; switch presets to write or run commands"

-- The builtins: four policy shapes — ask, read-only, edit, auto — shipped
-- twice, once per sandbox mode, in that cycle order, plus `yolo`, which
-- exists only for mode on (with the sandbox off, `unsandboxed_auto` already
-- allows everything there is to allow).
--
-- The SANDBOXED four come first and hold the plain names, because sandbox
-- mode on is the default. `edit` is the confined shape; `unsandboxed_edit`
-- is the one that hands the agent the real filesystem. Naming the safe world
-- plainly and marking the unsafe one is the only arrangement where a typo,
-- an old config or a half-remembered name fails toward confinement.
--
-- Every builtin is mode-tagged, because each is written against a world: the
-- sandboxed four assume the agent's own tools cannot reach the project, the
-- unsandboxed four assume they can. Only the sandboxed four carry a
-- `sandbox` hull — mode off disables the tool sandbox outright
-- (tool_sandboxing_on), so a hull there would document something weave never
-- builds.
--
-- Three things are true of the four scoped sandboxed presets. Only the first
-- also holds for `yolo`, which scopes nothing and so needs none of the rules
-- that scoping implies:
--
--   * they open with acp:mcp ALLOW then a blanket acp:* DENY. The agent's own
--     tools are turned back (they reach only the empty decoy) while the tools
--     weave brokers stay reachable. Denying rather than auto-approving is
--     deliberate: a live opencode run approved its way into the decoy, read
--     "no files", and reported the project as empty. A deny on the first such
--     call is a redirection the model acts on, and it costs nothing real —
--     the tool it wanted could not have worked.
--
--   * they close their weave:* run with a deny carrying OUTSIDE_WORKSPACE.
--     The workspace is the whole world by default; reaching past it is a
--     request the user answers, not a path the agent can simply take.
--
--   * the task QUERY tools are listed one by one, above every
--     resource-bearing catch-all. tools/init.lua registers them with no
--     resource extractor, and a resource-bearing rule never matches a
--     resourceless action, so a `{ tool = "weave:*", resource =
--     "${project}/**" }` line would sail straight past them — into an ask
--     that makes the agent beg to read a task's exit code, or into the
--     closing deny.
--- @type weave.permissions.Preset[]
local BUILTIN = {
  {
    name = "ask",
    label = "Ask",
    source = "builtin",
    for_mode = "on",
    rules = {
      ALLOW_BROKERED,
      ALLOW_ATTACHMENTS,
      { tool = "acp:*", decision = "deny", message = USE_CLIENT_TOOLS },
      { tool = "weave:task_status", decision = "allow" },
      { tool = "weave:task_wait", decision = "allow" },
      { tool = "weave:task_kill", decision = "allow" },
      -- Annotating changes nothing — a virtual-text overlay on the user's
      -- screen, no file touched — and it is the agent's whole feedback channel
      -- in tutor mode, where one review leaves a dozen notes. Approving each
      -- would make the mode unusable, so every preset allows it. Still
      -- workspace-scoped: the note is free, pointing it at a file outside the
      -- project is a path to ask for like any other. The other three carry no
      -- resource (they name an annotation id), so they need rules of their own
      -- above any resource-bearing catch-all.
      { tool = "weave:annotate", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:annotate_list", decision = "allow" },
      { tool = "weave:annotate_update", decision = "allow" },
      { tool = "weave:annotate_dismiss", decision = "allow" },
      -- task_start's resource is the COMMAND LINE and web_fetch's is a URL,
      -- neither of which can match a ${project} glob — without rules of their
      -- own they fall through to the closing deny, and no command could ever
      -- run nor any page be read.
      { tool = "weave:task_start", decision = "ask" },
      { tool = "weave:web_fetch", decision = "ask" },
      { tool = "weave:*", resource = PROJECT_TOKEN .. "/**", decision = "ask" },
      { tool = "weave:*", decision = "deny", message = OUTSIDE_WORKSPACE },
      -- Tools weave does not own (clankbox's exec_lua, other plugins'):
      -- unmediated they undo the confinement this preset exists for.
      { tool = "mcp:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
    -- The hull every TOOL subprocess runs under, stated rather than derived:
    -- the workspace read-write, nothing else, no network. `binds` REPLACES
    -- the default (a preset binding only /data really does exclude the
    -- project). Elevation grants land on top of whatever is here, globally —
    -- see M.tool_sandbox.
    --
    -- `tools` overrides the keys it sets for ONE tool. web_fetch is the case
    -- it exists for: fetching is the one job that needs the network and no
    -- filesystem whatever, so curl runs with the net and an empty hull rather
    -- than the whole session having to be granted network to read a page.
    sandbox = {
      binds = { { path = PROJECT_TOKEN, mode = "rw" } },
      network = false,
      tools = {
        ["weave:web_fetch"] = { binds = {}, network = true },
      },
    },
  },
  {
    name = "read_only",
    label = "Read-only",
    source = "builtin",
    for_mode = "on",
    rules = {
      ALLOW_BROKERED,
      ALLOW_ATTACHMENTS,
      { tool = "acp:*", decision = "deny", message = USE_CLIENT_TOOLS },
      { tool = "weave:read", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:glob", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:grep", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:task_status", decision = "allow" },
      { tool = "weave:task_wait", decision = "allow" },
      { tool = "weave:task_kill", decision = "allow" },
      -- Feedback ON the code is not a write TO it: read-only is the preset
      -- tutor mode normally runs under, and denying its one output channel
      -- would leave the agent able to review and unable to say anything.
      { tool = "weave:annotate", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:annotate_list", decision = "allow" },
      { tool = "weave:annotate_update", decision = "allow" },
      { tool = "weave:annotate_dismiss", decision = "allow" },
      -- Resourceless denies: read-only holds wherever the call points, so
      -- these must not be written as ${project}-scoped rules.
      { tool = "weave:write", decision = "deny", message = READ_ONLY },
      { tool = "weave:edit", decision = "deny", message = READ_ONLY },
      { tool = "weave:task_start", decision = "deny", message = READ_ONLY },
      -- Reading a page changes nothing, so read-only does not forbid it — but
      -- it leaves the machine, so it asks.
      { tool = "weave:web_fetch", decision = "ask" },
      { tool = "weave:*", resource = PROJECT_TOKEN .. "/**", decision = "ask" },
      { tool = "weave:*", decision = "deny", message = OUTSIDE_WORKSPACE },
      { tool = "mcp:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
    -- Read-only at the kernel too, not just at the gate: anything weave
    -- spawns under this preset gets the workspace mounted ro, so a tool that
    -- slips past the rules still cannot write.
    sandbox = {
      binds = { { path = PROJECT_TOKEN, mode = "ro" } },
      network = false,
      tools = {
        ["weave:web_fetch"] = { binds = {}, network = true },
      },
    },
  },
  {
    name = "edit",
    label = "Edit",
    source = "builtin",
    for_mode = "on",
    rules = {
      ALLOW_BROKERED,
      ALLOW_ATTACHMENTS,
      { tool = "acp:*", decision = "deny", message = USE_CLIENT_TOOLS },
      { tool = "weave:read", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:glob", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:grep", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:write", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:edit", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:task_status", decision = "allow" },
      { tool = "weave:task_wait", decision = "allow" },
      { tool = "weave:task_kill", decision = "allow" },
      { tool = "weave:annotate", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:annotate_list", decision = "allow" },
      { tool = "weave:annotate_update", decision = "allow" },
      { tool = "weave:annotate_dismiss", decision = "allow" },
      -- Editing files is not running commands: task_start still asks, and so
      -- does leaving the machine.
      { tool = "weave:task_start", decision = "ask" },
      { tool = "weave:web_fetch", decision = "ask" },
      { tool = "weave:*", resource = PROJECT_TOKEN .. "/**", decision = "ask" },
      { tool = "weave:*", decision = "deny", message = OUTSIDE_WORKSPACE },
      { tool = "mcp:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
    sandbox = {
      binds = { { path = PROJECT_TOKEN, mode = "rw" } },
      network = false,
      tools = {
        ["weave:web_fetch"] = { binds = {}, network = true },
      },
    },
  },
  {
    name = "auto",
    label = "Auto",
    source = "builtin",
    for_mode = "on",
    rules = {
      ALLOW_BROKERED,
      ALLOW_ATTACHMENTS,
      { tool = "acp:*", decision = "deny", message = USE_CLIENT_TOOLS },
      -- The one thing "auto" does not automate: widening the sandbox itself.
      -- request_access is registered UNgated (its handler is the asking
      -- mechanism, so wrapping it would prompt twice), which is what makes
      -- this hold today; the rule states the policy where a reader looks for
      -- it, and keeps holding if the tool is ever put behind the gate.
      { tool = "weave:request_access", decision = "ask" },
      { tool = "weave:task_status", decision = "allow" },
      { tool = "weave:task_wait", decision = "allow" },
      { tool = "weave:task_kill", decision = "allow" },
      { tool = "weave:annotate", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:annotate_list", decision = "allow" },
      { tool = "weave:annotate_update", decision = "allow" },
      { tool = "weave:annotate_dismiss", decision = "allow" },
      -- Resource = a command line / a URL, not a path: these need their own
      -- rules, and both are confined by the hull however they are spelled.
      { tool = "weave:task_start", decision = "allow" },
      { tool = "weave:web_fetch", decision = "allow" },
      { tool = "weave:*", resource = PROJECT_TOKEN .. "/**", decision = "allow" },
      { tool = "weave:*", decision = "deny", message = OUTSIDE_WORKSPACE },
      -- Tools weave does not own — clankbox's exec_lua, another plugin's
      -- registrations, a proxied third-party server — run unprompted too.
      -- These used to ask, on the grounds that they execute in the
      -- UNSANDBOXED editor; but "auto" is the user saying do not ask me, and
      -- `unsandboxed_auto` has always allowed exactly these calls, so the
      -- sandboxed shape asking was the odd one out. The three shapes above
      -- keep the ask, and what actually confines the agent — its own process
      -- sandbox — is not a preset's to give away.
      { tool = "mcp:*", decision = "allow" },
      { tool = "*", decision = "allow" },
    },
    -- "Auto" is about how much weave PROMPTS, not about how much the tools
    -- can reach: the hull stays the workspace, no network. Widening is the
    -- elevation path (w:request_access), or an edited copy of this preset.
    sandbox = {
      binds = { { path = PROJECT_TOKEN, mode = "rw" } },
      network = false,
      tools = {
        ["weave:web_fetch"] = { binds = {}, network = true },
      },
    },
  },
  {
    name = "yolo",
    label = "YOLO",
    source = "builtin",
    for_mode = "on",
    -- The maximal sandboxed preset: nothing is asked and nothing is scoped.
    -- Every other sandboxed preset treats the workspace as the world and
    -- makes anything past it a request; this one hands the tools the whole
    -- filesystem, read-write, with the network, and gets out of the way.
    --
    -- What it does NOT do is un-sandbox the AGENT. Mode on confines the agent
    -- process invariantly — that hull is not a preset's to widen — so its
    -- builtin tools still meet the empty project stand-in, and the acp:* deny
    -- above stays exactly as it is in the other four. That deny is not
    -- strictness here, it is the truth about where those tools point: letting
    -- them through would trade a redirection the agent acts on for a
    -- confident wrong answer read off an empty directory.
    --
    -- So the honest summary is "your tools can do anything, through weave".
    -- Everything the agent does still arrives as a tool call in the
    -- transcript, which is the property worth keeping when the rules are
    -- gone.
    rules = {
      ALLOW_BROKERED,
      ALLOW_ATTACHMENTS,
      { tool = "acp:*", decision = "deny", message = USE_CLIENT_TOOLS },
      { tool = "*", decision = "allow" },
    },
    -- `/` rw is the whole filesystem writable — the backends read it as the
    -- ROOT bind's mode rather than as one more grant (see sandbox/bwrap.lua),
    -- so the private /dev, /proc and /tmp still land on top of it. $HOME is
    -- listed separately because it is a tmpfs in the floor: only a bind back
    -- over it returns the real one.
    sandbox = {
      binds = { { path = "/", mode = "rw" }, { path = "~", mode = "rw" } },
      network = true,
    },
  },
  -- ── The unsandboxed variants ──────────────────────────────────────────────
  --
  -- The same four shapes for mode off, where the agent's own tools reach the
  -- real filesystem and weave's tools run unconfined. Policy here is written
  -- against acp:* — the agent-side permission flow — because that is the only
  -- point where its builtin read/edit/execute pass through weave at all.
  --
  -- weave's OWN tools stay `allow` unless the preset's promise needs
  -- otherwise (read-only denies the writing ones). That is not laxity: a
  -- provider raises an ACP permission request for the MCP tools it calls
  -- (acp:mcp), so gating them again at the gate would ask the same question
  -- twice for one call.
  {
    name = "unsandboxed_ask",
    label = "Unsandboxed (ask)",
    source = "builtin",
    for_mode = "off",
    rules = {
      { tool = "acp:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
  },
  {
    name = "unsandboxed_read_only",
    label = "Unsandboxed (read-only)",
    source = "builtin",
    for_mode = "off",
    rules = {
      { tool = "acp:read", decision = "allow" },
      { tool = "acp:edit", decision = "deny", message = READ_ONLY },
      { tool = "acp:delete", decision = "deny", message = READ_ONLY },
      { tool = "acp:move", decision = "deny", message = READ_ONLY },
      { tool = "acp:execute", decision = "deny", message = READ_ONLY },
      { tool = "acp:*", decision = "ask" },
      -- The same promise on weave's side, or the agent just switches tools.
      { tool = "weave:write", decision = "deny", message = READ_ONLY },
      { tool = "weave:edit", decision = "deny", message = READ_ONLY },
      { tool = "weave:task_start", decision = "deny", message = READ_ONLY },
      { tool = "*", decision = "allow" },
    },
  },
  {
    name = "unsandboxed_edit",
    label = "Unsandboxed (edit)",
    source = "builtin",
    for_mode = "off",
    rules = {
      { tool = "acp:read", decision = "allow" },
      { tool = "acp:edit", decision = "allow" },
      { tool = "acp:*", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
  },
  {
    name = "unsandboxed_auto",
    label = "Unsandboxed (auto)",
    source = "builtin",
    for_mode = "off",
    rules = {
      -- Grants are never automatic, in either world: with the sandbox off
      -- there is no hull to widen, but request_access still writes allow
      -- rules into the overlay, and those outlive a preset switch.
      { tool = "weave:request_access", decision = "ask" },
      { tool = "*", decision = "allow" },
    },
  },
}

--- @type weave.permissions.Preset[] from setup(); shadows builtin by name
local setup_presets = {}
--- @type weave.permissions.Preset[] from save_preset(); shadows both
local runtime_presets = {}
local active_name = "ask"
--- @type weave.permissions.Rule[] the grant overlay; consulted BEFORE the active preset
local overlay = {}
--- @type weave.permissions.SandboxBind[] elevation grants: binds ADDED to the
--- active preset's hull for every subsequent tool spawn (weave.tools.access)
local bind_overlay = {}
--- @type boolean elevation grant: tool sandboxes get network this session
local network_granted = false
--- @type string|nil project root for ${project}; nil = ask the editor
local project_root = nil
--- @type string|nil the RUNNING session's sandbox mode; nil = ask the config
local current_mode = nil
--- @type fun()[]
local subscribers = {}

local function notify()
  for _, fn in ipairs({ unpack(subscribers) }) do
    fn()
  end
end

--- Subscribe to engine changes (active preset, preset definitions). Fires
--- synchronously, payload-free — read the engine back. Returns unsubscribe.
--- @param fn fun()
--- @return fun() unsubscribe
function M.subscribe(fn)
  subscribers[#subscribers + 1] = fn
  return function()
    for i, f in ipairs(subscribers) do
      if f == fn then
        table.remove(subscribers, i)
        return
      end
    end
  end
end

--- Whole-string glob match: `*` any run (including none), `?` exactly one
--- char, everything else literal. Deliberately tiny and predictable — `*`
--- crosses `/`, so "/etc/*" covers the whole subtree and "git *" is a
--- command prefix.
--- @param glob string
--- @param text string
--- @return boolean
function M.glob_match(glob, text)
  local pat = glob:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".")
  return text:match("^" .. pat .. "$") ~= nil
end

--- The project root `${project}` expands to. Defaults to the editor's cwd;
--- the session layer sets it explicitly so a rule means the same thing
--- whatever the user has :cd'd to since.
--- @return string
function M.project_root()
  return project_root or vim.fn.getcwd()
end

--- @param root string|nil nil restores the cwd default
function M.set_project_root(root)
  project_root = root
end

--- Expand `${project}` and `${attachments}` in a resource glob. Cheap enough
--- to do per resolve, and doing it lazily is what keeps presets serialisable.
--- @param resource string
--- @return string
local function expand(resource)
  if resource:find(PROJECT_TOKEN, 1, true) then
    resource = resource:gsub("%${project}", (M.project_root():gsub("%%", "%%%%")))
  end
  if resource:find(ATTACHMENTS_TOKEN, 1, true) then
    local ok, Attachments = pcall(require, "weave.attachments")
    local dir = ok and Attachments.root() or "/nonexistent"
    resource = resource:gsub("%${attachments}", (dir:gsub("%%", "%%%%")))
  end
  return resource
end

--- Match a rule's resource pattern against an action's resource.
---
--- `dir/**` means the directory AND everything under it. Plain glob matching
--- gives only the latter, which reads fine until a tool's resource IS a
--- directory: `grep` with no `path` resources at the project root, so
--- `${project}/**` would miss the single most common search there is and drop
--- it to "ask". Nobody writing that rule meant "everything except the
--- directory itself".
--- @param pattern string already expanded
--- @param resource string
--- @return boolean
local function resource_matches(pattern, resource)
  if M.glob_match(pattern, resource) then
    return true
  end
  local dir = pattern:match("^(.*)/%*%*$")
  return dir ~= nil and dir == resource
end

--- @param rule weave.permissions.Rule
--- @param action weave.permissions.Action
--- @return boolean
local function rule_matches(rule, action)
  if not M.glob_match(rule.tool, action.tool) then
    return false
  end
  if rule.resource == nil then
    return true
  end
  return action.resource ~= nil and resource_matches(expand(rule.resource), action.resource)
end

--- Deep-copy a preset so engine state never aliases caller tables.
--- @param preset weave.permissions.Preset
--- @param source "builtin"|"setup"|"runtime"
--- @return weave.permissions.Preset
local function own(preset, source)
  local rules = {}
  for i, r in ipairs(preset.rules or {}) do
    rules[i] = { tool = r.tool, resource = r.resource, decision = r.decision, message = r.message }
  end
  local function own_binds(list)
    if not list then
      return nil
    end
    local out = {}
    for i, b in ipairs(list) do
      out[i] = { path = b.path, mode = b.mode }
    end
    return out
  end
  local sandbox = nil
  if preset.sandbox then
    local tools = nil
    if preset.sandbox.tools then
      tools = {}
      for name, o in pairs(preset.sandbox.tools) do
        tools[name] = { binds = own_binds(o.binds), network = o.network }
      end
    end
    sandbox = { binds = own_binds(preset.sandbox.binds), network = preset.sandbox.network, tools = tools }
  end
  return {
    name = preset.name,
    label = preset.label,
    rules = rules,
    sandbox = sandbox,
    for_mode = preset.for_mode,
    source = source,
  }
end

--- Validate one rule in isolation (shared by presets and grants).
--- @param rule table
--- @param where string prefix for the error message
local function validate_rule(rule, where)
  if type(rule.tool) ~= "string" or rule.tool == "" then
    error(("weave.permissions: %s: `tool` must be a glob string"):format(where), 0)
  end
  if rule.resource ~= nil and type(rule.resource) ~= "string" then
    error(("weave.permissions: %s: `resource` must be a glob string"):format(where), 0)
  end
  if not DECISIONS[rule.decision] then
    error(
      ("weave.permissions: %s: `decision` must be allow/deny/ask, got %s"):format(where, vim.inspect(rule.decision)),
      0
    )
  end
  if rule.message ~= nil and type(rule.message) ~= "string" then
    error(("weave.permissions: %s: `message` must be a string"):format(where), 0)
  end
end

--- Validate a binds list (a preset's global hull or one tool's override).
--- @param binds any
--- @param where string prefix for the error message
local function validate_binds(binds, where)
  if type(binds) ~= "table" then
    error(("weave.permissions: %s must be a list"):format(where), 0)
  end
  for i, b in ipairs(binds) do
    if type(b) ~= "table" or type(b.path) ~= "string" or b.path == "" then
      error(("weave.permissions: %s[%d].path must be a string"):format(where, i), 0)
    end
    if b.mode ~= nil and b.mode ~= "rw" and b.mode ~= "ro" then
      error(("weave.permissions: %s[%d].mode must be rw/ro, got %s"):format(where, i, vim.inspect(b.mode)), 0)
    end
  end
end

--- Validate a caller-supplied preset, loudly (a typo'd decision must not
--- silently become "no rule").
--- @param preset table
local function validate(preset)
  if type(preset) ~= "table" or type(preset.name) ~= "string" or preset.name == "" then
    error("weave.permissions: a preset needs a non-empty `name`", 0)
  end
  if preset.rules ~= nil and type(preset.rules) ~= "table" then
    error(("weave.permissions: preset %q: `rules` must be a list"):format(preset.name), 0)
  end
  for i, rule in ipairs(preset.rules or {}) do
    validate_rule(rule, ("preset %q rule %d"):format(preset.name, i))
  end
  local sandbox = preset.sandbox
  if sandbox ~= nil then
    if type(sandbox) ~= "table" then
      error(("weave.permissions: preset %q: `sandbox` must be a table, got %s"):format(preset.name, type(sandbox)), 0)
    end
    -- The v1 requirement fields died with the profile machinery. Loud, not
    -- ignored: a preset that names a confinement requirement weave no
    -- longer honours must not silently load as if it were honoured.
    if sandbox.profile ~= nil or sandbox.mode ~= nil then
      error(
        ("weave.permissions: preset %q: sandbox `profile`/`mode` requirements were removed (sandbox v2); the section now carries `binds`/`network`"):format(
          preset.name
        ),
        0
      )
    end
    if sandbox.binds ~= nil then
      validate_binds(sandbox.binds, ("preset %q: sandbox.binds"):format(preset.name))
    end
    if sandbox.network ~= nil and type(sandbox.network) ~= "boolean" then
      error(("weave.permissions: preset %q: `sandbox.network` must be a boolean"):format(preset.name), 0)
    end
    if sandbox.tools ~= nil then
      if type(sandbox.tools) ~= "table" then
        error(("weave.permissions: preset %q: `sandbox.tools` must be a table"):format(preset.name), 0)
      end
      for name, o in pairs(sandbox.tools) do
        local where = ("preset %q: sandbox.tools[%q]"):format(preset.name, tostring(name))
        if type(name) ~= "string" or name == "" then
          error(("weave.permissions: preset %q: `sandbox.tools` keys must be tool names"):format(preset.name), 0)
        end
        if type(o) ~= "table" then
          error(("weave.permissions: %s must be a table"):format(where), 0)
        end
        if o.binds ~= nil then
          validate_binds(o.binds, where .. ".binds")
        end
        if o.network ~= nil and type(o.network) ~= "boolean" then
          error(("weave.permissions: %s.network must be a boolean"):format(where), 0)
        end
      end
    end
  end
  if preset.for_mode ~= nil and preset.for_mode ~= "on" and preset.for_mode ~= "off" then
    error(
      ('weave.permissions: preset %q: `for_mode` must be "on" or "off", got %s'):format(
        preset.name,
        vim.inspect(preset.for_mode)
      ),
      0
    )
  end
end

--- @param list weave.permissions.Preset[]
--- @param name string
--- @return weave.permissions.Preset|nil, integer|nil
local function find(list, name)
  for i, p in ipairs(list) do
    if p.name == name then
      return p, i
    end
  end
  return nil, nil
end

--- The effective preset list: builtins in shipped order, then setup, then
--- runtime — each name appearing ONCE, at its first-source position, defined
--- by its last source (runtime > setup > builtin).
--- @return weave.permissions.Preset[]
function M.presets()
  local out, seen = {}, {}
  for _, list in ipairs({ BUILTIN, setup_presets, runtime_presets }) do
    for _, p in ipairs(list) do
      if not seen[p.name] then
        seen[p.name] = #out + 1
        out[#out + 1] = p
      else
        out[seen[p.name]] = p -- a later source shadows in place
      end
    end
  end
  return out
end

--- The effective definition of `name`, or nil.
--- @param name string
--- @return weave.permissions.Preset|nil
function M.get(name)
  return find(runtime_presets, name) or find(setup_presets, name) or find(BUILTIN, name)
end

--- Is this preset usable under `mode`? Untagged presets are usable under
--- both; a tagged one only under its own mode.
--- @param preset weave.permissions.Preset
--- @param mode "on"|"off"
--- @return boolean
function M.preset_allowed(preset, mode)
  return preset.for_mode == nil or preset.for_mode == mode
end

--- The presets selectable under `mode` — the effective list minus everything
--- tagged for the other mode. This is THE list every chooser walks (;;p, the
--- config window, the setup default): a preset written for the other world
--- is not offered, so the ;;p cycle can never land on one.
--- @param mode? "on"|"off" default: the mode in force right now
--- @return weave.permissions.Preset[]
function M.available(mode)
  mode = mode or M.current_mode()
  local out = {}
  for _, p in ipairs(M.presets()) do
    if M.preset_allowed(p, mode) then
      out[#out + 1] = p
    end
  end
  return out
end

--- The active preset (never nil). Falls back to the first preset available
--- under the current mode if the active name stops existing — mode-aware,
--- because falling back to `unsandboxed_ask` under mode on would hand the
--- agent a preset whose whole shape assumes an unsandboxed world.
--- @return weave.permissions.Preset
function M.active()
  local preset = M.get(active_name)
  if preset then
    return preset
  end
  return M.available()[1] or find(BUILTIN, "ask")
end

--- Make `name` the active preset. Unknown names — and presets belonging to
--- the other sandbox mode — fail loudly.
--- @param name string
function M.set_active(name)
  local preset = M.get(name)
  if not preset then
    error(("weave.permissions: unknown preset %q"):format(name), 0)
  end
  local mode = M.current_mode()
  if not M.preset_allowed(preset, mode) then
    error(
      ("weave.permissions: preset %q is for sandbox mode %q; the sandbox is %q"):format(name, preset.for_mode, mode),
      0
    )
  end
  if active_name == name then
    return
  end
  active_name = name
  notify()
end

--- ── Sandbox mode ────────────────────────────────────────────────────────────

--- The mode in force RIGHT NOW: the one the session you are looking at was
--- actually spawned under.
---
--- Agent processes are keyed (provider, mode), so two sessions can be
--- running at different confinements at the same time and "the current
--- mode" is only meaningful relative to one of them. The selected session
--- is the one the permissions UI describes, so it is the one that answers
--- here. Falling back, in order: the last spawn (set_mode, for the window
--- between spawn and a registered session) and the configured default
--- (before anything spawns at all).
--- @return "on"|"off"
function M.current_mode()
  local ok, Registry = pcall(require, "weave.registry")
  if ok then
    local entry = Registry.selected() or Registry.list()[1]
    local session = entry and entry.session
    local client = session and session.client and session:client()
    if client and client.sandbox_mode then
      return client.sandbox_mode
    end
  end
  if current_mode then
    return current_mode
  end
  local sok, sandbox = pcall(require, "weave.sandbox")
  return (sok and sandbox.resolve().mode) or "off"
end

--- The preset `name` becomes under `mode`, by the unsandboxed_ naming
--- convention the builtins ship: the counterpart if one exists, else nil.
--- Sandbox mode on holds the plain names, so going OFF adds the prefix and
--- going ON strips it (`edit` <-> `unsandboxed_edit`).
--- @param name string
--- @param mode "on"|"off"
--- @return string|nil
local function counterpart(name, mode)
  local other = mode == "off" and ("unsandboxed_" .. name) or name:match("^unsandboxed_(.+)$")
  local preset = other and M.get(other)
  if preset and M.preset_allowed(preset, mode) then
    return other
  end
  return nil
end

--- Record the mode a session was spawned under, and RECONCILE the active
--- preset with it: a preset tagged for the mode we just left is wrong here,
--- so it is replaced by its plain/unsandboxed_ counterpart (or, failing that,
--- the first preset the new mode allows). Silent-but-correct beats an error
--- nobody can act on — this fires from the spawn path, where refusing to
--- proceed would just strand the session.
--- @param mode string|nil nil restores the config default
function M.set_mode(mode)
  local changed = current_mode ~= mode
  current_mode = mode
  if mode and not M.preset_allowed(M.active(), mode) then
    local was = active_name
    active_name = counterpart(active_name, mode) or (M.available(mode)[1] or {}).name or active_name
    if active_name ~= was then
      changed = true
      require("weave.utils.logger").debug(("permissions: preset %s -> %s (sandbox %s)"):format(was, active_name, mode))
    end
  end
  if changed then
    notify()
  end
end

--- Advance to the next preset in the effective order (the ;;p cycle) and
--- return it. Cycling is cheap, frequent and non-destructive: it never
--- restarts an agent and never prompts. It walks only the presets AVAILABLE
--- under the mode in force, so ;;p cannot land on one written for the other
--- world (a sandboxed preset with the sandbox off would gate weave's tools
--- while leaving the agent's own — the confinement it assumes absent —
--- wide open).
--- @return weave.permissions.Preset
function M.cycle()
  local list = M.available()
  if #list == 0 then
    return M.active()
  end
  local idx = 0
  for i, p in ipairs(list) do
    if p.name == active_name then
      idx = i
      break
    end
  end
  local next_preset = list[(idx % #list) + 1]
  M.set_active(next_preset.name)
  return next_preset
end

--- ── The tool-sandbox hull ───────────────────────────────────────────────────

-- What a preset without a sandbox section means: the project, read-write,
-- no network. Explicit binds REPLACE this (they do not extend it), so a
-- preset binding only /data genuinely excludes the project.
local DEFAULT_BINDS = { { path = PROJECT_TOKEN, mode = "rw" } }

--- A bind path as the backends should receive it: `${project}` and a leading
--- `~` resolved here, in the policy layer, exactly as the AGENT hull already
--- resolves its grants (weave.sandbox.wrap). Leaving `~` to the backend meant
--- only bwrap understood it — its mounter expands one — while the seatbelt
--- profile emitted a literal "~" subpath that matches nothing, so a hull
--- written with `~/.cache` silently granted nothing on macOS.
--- @param path string
--- @return string
local function bind_path(path)
  local home = vim.uv.os_homedir() or vim.env.HOME
  path = expand(path)
  if home and home ~= "" then
    path = (path:gsub("^~", (home:gsub("%%", "%%%%"))))
  end
  return path
end

--- The kernel hull TOOL invocations run under (design-agent-sandbox-v2):
--- binds with `${project}` and `~` expanded now, modes defaulted, plus the
--- network flag. Consumed by the task/tool spawn path on EVERY invocation, so an
--- active-preset switch or an elevation grant applies to the next spawn with
--- no restart anywhere.
---
--- Three layers, outermost last:
---   1. the preset's global sandbox section (or the project-rw default),
---   2. `sandbox.tools[tool]`, replacing whichever keys it sets — the
---      per-tool escape hatch (one tool needing the network, say, without
---      handing it to every task),
---   3. the elevation grants, which are GLOBAL by design: an agent that
---      asked for and was given /data gets it everywhere, overridden tools
---      included, since a grant answers "may we reach this at all".
--- @param preset? weave.permissions.Preset default: the active one
--- @param tool? string namespaced tool name, e.g. "weave:task_start"
--- @return { binds: weave.permissions.SandboxBind[], network: boolean }
function M.tool_sandbox(preset, tool)
  preset = preset or M.active()
  local section = preset.sandbox or {}
  local override = (tool and section.tools and section.tools[tool]) or {}
  local binds = {}
  for i, b in ipairs(override.binds or section.binds or DEFAULT_BINDS) do
    binds[i] = { path = bind_path(b.path), mode = b.mode or "rw" }
  end
  -- Elevation grants sit ON TOP of the preset's hull, exactly like the rule
  -- overlay sits on top of its rules: session-scoped, revocable, never
  -- rewriting the preset.
  for _, b in ipairs(bind_overlay) do
    binds[#binds + 1] = { path = bind_path(b.path), mode = b.mode or "rw" }
  end
  local network = override.network
  if network == nil then
    network = section.network
  end
  return { binds = binds, network = network == true or network_granted }
end

--- Does a bind's path plausibly reach a resource glob's static prefix?
--- Prefix containment with a path-boundary guard: /a/b covers /a/b/c and
--- /a/b, never /a/bc.
local function bind_covers(bind, prefix)
  local function contains(outer, inner)
    if inner:sub(1, #outer) ~= outer then
      return false
    end
    local nxt = inner:sub(#outer + 1, #outer + 1)
    return nxt == "" or nxt == "/" or outer:sub(-1) == "/"
  end
  return contains(bind, prefix) or contains(prefix, bind)
end

--- Rules and binds are orthogonal by design, which leaves one confusing
--- combination: a non-deny rule whose resource no bind can reach — the gate
--- says yes, the tool then dies at the kernel wall. Flag it at definition
--- time instead of letting it read as a tool bug at call time. A heuristic
--- (static glob prefixes, path-shaped resources only — command strings and
--- buffer refs are not filesystem places), so it WARNS, never errors.
--- @param preset weave.permissions.Preset
--- @return string[] warnings
function M.lint_preset(preset)
  local warnings = {}
  -- The reachable set is the global hull PLUS every per-tool override's
  -- binds: a rule whose resource only some overridden tool can reach is
  -- deliberate, not a mistake. Only a resource NO hull reaches is worth a
  -- warning.
  local hull = M.tool_sandbox(preset)
  for name in pairs((preset.sandbox or {}).tools or {}) do
    vim.list_extend(hull.binds, M.tool_sandbox(preset, name).binds)
  end
  local home = vim.uv.os_homedir() or ""
  local function norm(p)
    return (home ~= "" and p:gsub("^~", home)) or p
  end
  for i, rule in ipairs(preset.rules or {}) do
    -- Only the TOOL layer is governed by the hull. An acp:* rule speaks about
    -- the agent's own tools inside the AGENT sandbox, whose binds are not
    -- these — the attachments allowance is exactly such a rule, and it is
    -- reachable there by construction.
    local tool_layer = not vim.startswith(rule.tool or "", "acp:")
    if tool_layer and rule.resource ~= nil and rule.decision ~= "deny" then
      local res = norm(expand(rule.resource))
      if res:sub(1, 1) == "/" then
        local prefix = res:match("^([^*?]*)")
        local reachable = false
        for _, b in ipairs(hull.binds) do
          if bind_covers(norm(b.path), prefix) then
            reachable = true
            break
          end
        end
        if not reachable then
          warnings[#warnings + 1] = ("rule %d (%s %s): resource %q lies outside every sandbox bind"):format(
            i,
            rule.decision,
            rule.tool,
            rule.resource
          )
        end
      end
    end
  end
  return warnings
end

--- Resolve an action: the grant overlay first, then the active preset, then
--- the engine-wide "ask". First matching rule's decision wins.
--- @param action weave.permissions.Action
--- @return weave.permissions.Decision decision, weave.permissions.Rule|nil rule
function M.resolve(action)
  for _, list in ipairs({ overlay, M.active().rules or {} }) do
    for _, rule in ipairs(list) do
      if rule_matches(rule, action) then
        return rule.decision, rule
      end
    end
  end
  return "ask", nil
end

--- ── The grant overlay ───────────────────────────────────────────────────────
---
--- Answering "allow for project" on a gate prompt writes here, NOT into the
--- active preset. Redefining `normal` as a side effect of one keystroke would
--- mean `normal` no longer means what it means in the docs or on anyone
--- else's machine, and cycling away and back would not clear it. A separate
--- overlay keeps preset semantics exactly as shipped and keeps grants visibly
--- a thing sitting on top, with somewhere to list and revoke them.
---
--- Session-scoped: discarded on exit, promoted to a named preset by an
--- explicit action. A durable filesystem grant created by pressing `;;2` is
--- how people end up with a permission set whose origin they cannot account
--- for.

--- @return weave.permissions.Rule[] a copy; mutate through add/revoke
function M.grants()
  local out = {}
  for i, r in ipairs(overlay) do
    out[i] = { tool = r.tool, resource = r.resource, decision = r.decision }
  end
  return out
end

--- Append a grant. Newest last, so an older grant keeps winning — a grant is
--- an answer to a question, and re-answering it the same way is a no-op.
--- @param rule weave.permissions.Rule
function M.add_grant(rule)
  validate_rule(rule, "grant")
  overlay[#overlay + 1] = { tool = rule.tool, resource = rule.resource, decision = rule.decision }
  notify()
end

--- @param index integer 1-based, as listed by grants()
function M.revoke_grant(index)
  if not overlay[index] then
    error(("weave.permissions: no grant at index %d"):format(index), 0)
  end
  table.remove(overlay, index)
  notify()
end

function M.clear_overlay()
  if #overlay == 0 and #bind_overlay == 0 and not network_granted then
    return
  end
  overlay = {}
  bind_overlay = {}
  network_granted = false
  notify()
end

--- ── Elevation grants (design-agent-sandbox-v2.md, phase H) ──────────────────
---
--- The bind-shaped counterpart of the rule overlay: session-scoped widenings
--- of the TOOL sandboxes, granted through w:request_access. They apply on
--- the very next tool spawn (hulls are re-derived per invocation) — no
--- restart anywhere, which is the entire point of confining tools instead
--- of the agent process.

--- @return weave.permissions.SandboxBind[] a copy; mutate through add/revoke
function M.bind_grants()
  local out = {}
  for i, b in ipairs(bind_overlay) do
    out[i] = { path = b.path, mode = b.mode }
  end
  return out
end

--- @param bind weave.permissions.SandboxBind
function M.add_bind_grant(bind)
  if type(bind) ~= "table" or type(bind.path) ~= "string" or bind.path == "" then
    error("weave.permissions: a bind grant needs a `path`", 0)
  end
  if bind.mode ~= nil and bind.mode ~= "rw" and bind.mode ~= "ro" then
    error("weave.permissions: bind grant `mode` must be rw/ro", 0)
  end
  bind_overlay[#bind_overlay + 1] = { path = bind.path, mode = bind.mode or "rw" }
  notify()
end

--- @param index integer 1-based, as listed by bind_grants()
function M.revoke_bind_grant(index)
  if not bind_overlay[index] then
    error(("weave.permissions: no bind grant at index %d"):format(index), 0)
  end
  table.remove(bind_overlay, index)
  notify()
end

--- @return boolean
function M.network_granted()
  return network_granted
end

--- @param granted boolean
function M.set_network_granted(granted)
  if network_granted == granted then
    return
  end
  network_granted = granted
  notify()
end

--- The rule an "always" answer to `action` should produce. Granting exactly
--- what was asked is close to worthless for fs and search tools — an agent
--- rarely reads the same path twice, so the user is asked again on the next
--- file. The useful unit is the one the sandbox already reasons in: the
--- project. Outside it we fall back to the exact resource, so a grant over
--- ~/.config does not silently generalise to all of ~.
--- @param action weave.permissions.Action
--- @param decision weave.permissions.Decision
--- @return weave.permissions.Rule
function M.grant_rule(action, decision)
  if action.resource == nil then
    return { tool = action.tool, decision = decision }
  end
  local root = M.project_root()
  local inside = action.resource:sub(1, #root + 1) == root .. "/"
  return {
    tool = action.tool,
    resource = inside and (PROJECT_TOKEN .. "/**") or action.resource,
    decision = decision,
  }
end

--- Create or replace a RUNTIME preset (the config window's save path). A
--- runtime preset with a builtin/setup name shadows it — deleting the
--- runtime def restores the original, so "editing" a shipped preset is
--- always reversible.
--- @param preset weave.permissions.Preset
--- Surface lint findings for a preset entering the engine. Advisory only
--- (design-agent-sandbox-v2 open question 6 resolved as warn-not-error): the
--- preset still lands, the user learns why a gate-allowed tool would fail.
--- @param preset weave.permissions.Preset
local function warn_lint(preset)
  for _, w in ipairs(M.lint_preset(preset)) do
    vim.notify(("weave: preset %q: %s"):format(preset.name, w), vim.log.levels.WARN)
  end
end

function M.save_preset(preset)
  validate(preset)
  warn_lint(preset)
  local owned = own(preset, "runtime")
  local _, i = find(runtime_presets, preset.name)
  if i then
    runtime_presets[i] = owned
  else
    runtime_presets[#runtime_presets + 1] = owned
  end
  notify()
end

--- Delete the RUNTIME definition of `name` (only runtime defs are deletable;
--- shipped and setup presets are permanent). If that name still exists in an
--- earlier source, the shadowed definition takes over; if not and it was
--- active, the active preset falls back to normal.
--- @param name string
function M.delete_preset(name)
  local _, i = find(runtime_presets, name)
  if not i then
    error(("weave.permissions: %q has no runtime definition to delete"):format(name), 0)
  end
  table.remove(runtime_presets, i)
  if active_name == name and not M.get(name) then
    -- Deleting the definition you are standing on: fall back to the first
    -- preset the mode in force allows, not to a fixed name that may belong
    -- to the other world.
    active_name = (M.available()[1] or {}).name or "ask"
  end
  notify()
end

--- Ingest the setup() config: `presets` become the setup source (validated
--- loudly), `preset` picks the active one.
--- @param cfg { preset?: string, presets?: weave.permissions.Preset[] }|nil
function M.setup(cfg)
  cfg = cfg or {}
  setup_presets = {}
  for _, p in ipairs(cfg.presets or {}) do
    validate(p)
    warn_lint(p)
    setup_presets[#setup_presets + 1] = own(p, "setup")
  end
  local mode = M.current_mode()
  if cfg.preset then
    local preset = M.get(cfg.preset)
    if not preset then
      error(("weave.permissions: unknown active preset %q in setup"):format(cfg.preset), 0)
    end
    if not M.preset_allowed(preset, mode) then
      error(
        ("weave.permissions: setup preset %q is for sandbox mode %q; the configured mode is %q"):format(
          cfg.preset,
          preset.for_mode,
          mode
        ),
        0
      )
    end
    active_name = cfg.preset
  elseif not M.preset_allowed(M.active(), mode) then
    -- No stated preference and the default preset belongs to the other
    -- world: take its counterpart (ask <-> unsandboxed_ask), which is
    -- the same policy shape written for the mode actually in force.
    active_name = counterpart(active_name, mode) or (M.available(mode)[1] or {}).name or active_name
  end
  notify()
end

-- test hook: back to the shipped state
function M._reset()
  setup_presets = {}
  runtime_presets = {}
  overlay = {}
  bind_overlay = {}
  network_granted = false
  active_name = "ask"
  project_root = nil
  current_mode = nil
  subscribers = {}
end

return M
