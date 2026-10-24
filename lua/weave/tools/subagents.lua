local Context = require("weave.tool_context")
local Registry = require("weave.registry")
local Subagents = require("weave.subagents")
local Permissions = require("weave.permissions")
local Gate = require("weave.tools.gate")
local M = { _create = Subagents.create }

local function schema(properties, required)
  return { type = "object", properties = properties, required = required }
end
local id = { type = "integer", description = "Stable subagent ID returned by weave_subagent_create/list" }
local run_id = { type = "integer", description = "Delegated run ID; omit for the active or latest run" }
local permissions_schema = {
  type = "object", description = "Child permission preset and local rule/tool-sandbox overrides. Explicit policy requests require user approval.",
  properties = {
    preset = { type = "string", description = "Configured permission preset name" },
    rules = { type = "array", description = "Ordered rule overrides, before the preset rules", items = {
      type = "object", properties = {
        tool = { type = "string", description = "Namespaced tool glob" },
        resource = { type = "string", description = "Optional resource glob" },
        decision = { type = "string", enum = { "allow", "deny", "ask" }, description = "Permission decision" },
        message = { type = "string", description = "Optional denial explanation" },
      }, required = { "tool", "decision" },
    } },
    sandbox = { type = "object", description = "Tool-sandbox overrides, independently of the agent sandbox",
      properties = {
        enabled = { type = "boolean", description = "Whether tool subprocesses are wrapped" },
        network = { type = "boolean", description = "Whether wrapped tool subprocesses have network access" },
        binds = { type = "array", description = "Replacement directory bind list", items = {
          type = "object", properties = {
            path = { type = "string", description = "Directory path, supporting ${project}" },
            mode = { type = "string", enum = { "ro", "rw" }, description = "Access mode" },
          }, required = { "path" },
        } },
        tools = { type = "object", description = "Per-tool sandbox overrides", additionalProperties = { type = "object" } },
      },
    },
  },
}

local function failure(text)
  return { content = { { type = "text", text = text } }, isError = true }
end

local function record(entry, run)
  return vim.json.encode({ subagent_id = entry.key, parent_id = entry.parent_key,
    provider = entry.provider, run_id = run.id, status = run.status,
    permissions = entry.session:permissions().snapshot() })
end

M.create = {
  description = "Create a child session and delegate an initial prompt. Returns immediately with subagent_id and run_id. "
    .. "Parent is the authenticated calling session, never an argument or UI selection. Optional provider must be configured. "
    .. "config_defaults uses provider field/value IDs and is applied before prompting. Explicit permission policies and provider "
    .. "changes require user approval; omitted permissions inherit the parent's snapshot. Limits bound recursive creation.",
  inputSchema = schema({
    prompt = { type = "string", description = "Initial task and explicitly supplied context; no automatic transcript inheritance" },
    name = { type = "string", description = "Optional short child label" },
    provider = { type = "string", description = "Configured provider key; defaults to the parent provider" },
    config_defaults = { type = "object", description = "Per-child provider configuration default overrides",
      additionalProperties = { type = "string" } },
    permissions = permissions_schema,
  }, { "prompt" }),
  async = true,
  handler = function(args, respond, ctx)
    local session = Context.require_caller(ctx)
    local allowed = { prompt = true, name = true, provider = true, config_defaults = true, permissions = true }
    for key in pairs(args) do if not allowed[key] then error("unknown subagent creation argument: " .. tostring(key), 0) end end
    if type(args.prompt) ~= "string" or args.prompt == "" then error("prompt must be nonempty", 0) end
    if args.name ~= nil and type(args.name) ~= "string" then error("name must be a string", 0) end
    if args.provider ~= nil and type(args.provider) ~= "string" then error("provider must be a configured key", 0) end
    if args.config_defaults ~= nil then
      if type(args.config_defaults) ~= "table" then error("config_defaults must be a field/value map", 0) end
      for key, value in pairs(args.config_defaults) do
        if type(key) ~= "string" or type(value) ~= "string" then error("config_defaults must map field IDs to value IDs", 0) end
      end
    end
    if args.permissions ~= nil then
      if type(args.permissions) ~= "table" then error("permissions must be an object", 0) end
      for key in pairs(args.permissions) do
        if key ~= "preset" and key ~= "rules" and key ~= "sandbox" then error("unknown child permission setting", 0) end
      end
      Permissions.new(args.permissions, session:permissions()) -- validate before asking or spawning
    end
    local owner = assert(Registry.entry_for(session))
    local approval = args.permissions ~= nil or (args.provider ~= nil and args.provider ~= owner.provider)
    if args.config_defaults then
      if session:permissions().current_mode() == "off" and next(args.config_defaults) then approval = true end
      for key in pairs(args.config_defaults) do
        if key:lower():find("mode") or key:lower():find("permission") or key:lower():find("sandbox") then approval = true end
      end
    end
    local function start()
      if not Gate.valid(ctx) then return respond(failure("subagent creation refused: stale caller")) end
      local ok, entry, run = pcall(M._create, session, args)
      if not ok then return respond(failure(tostring(entry))) end
      respond(record(entry, run))
    end
    if not approval then return start() end
    local answered = false
    session:get_store():enqueue_permission({
      client_side = true,
      request = {
        toolCall = { title = "Create subagent with explicit configuration/policy: "
          .. (args.provider or owner.provider) .. " / " .. ((args.permissions or {}).preset or "inherited"),
          kind = "other", rawInput = vim.deepcopy(args) },
        options = {
          { optionId = "allow_once", name = "Approve this child configuration", kind = "allow_once" },
          { optionId = "reject_once", name = "Reject", kind = "reject_once" },
        },
      },
      respond = function(option_id)
        if answered then return end
        answered = true
        if option_id ~= "allow_once" then return respond(failure("subagent creation declined")) end
        start()
      end,
    })
  end,
}

M.list = {
  description = "List only the authenticated caller's children, or descendants with recursive=true. Includes run state and IDs. "
    .. "No sibling, ancestor or unrelated-root access. Defaults to status=all and limit=10.",
  inputSchema = schema({
    recursive = { type = "boolean", description = "Include the whole owned subtree, instead of direct children" },
    status = { type = "string", enum = { "all", "running", "completed", "failed", "cancelled", "idle" }, description = "Run status filter (default all)" },
    limit = { type = "integer", description = "Maximum entries returned (default 10)" },
  }),
  handler = function(args, ctx) return vim.json.encode(Subagents.list(Context.require_caller(ctx), args)) end,
}

M.send = {
  description = "Delegate another task to a descendant. Returns a new run_id; tasks run sequentially in that child.",
  inputSchema = schema({ subagent_id = id, prompt = { type = "string", description = "Task text and explicit context" } }, { "subagent_id", "prompt" }),
  handler = function(args, ctx)
    local parent = Context.require_caller(ctx)
    local run = Subagents.send(parent, args.subagent_id, args.prompt)
    return record(Subagents.target(parent, args.subagent_id), run)
  end,
}

M.read = {
  description = "Read descendant assistant output for one run. cursor/next_cursor count Unicode characters; max_chars defaults to 16384 "
    .. "(maximum 65536). Returns bounded output, status, error and has_more. No thoughts or parent transcript are copied.",
  inputSchema = schema({
    subagent_id = id, run_id = run_id,
    cursor = { type = "integer", description = "Output character cursor, initially 0" },
    max_chars = { type = "integer", description = "Maximum Unicode characters returned" },
  }, { "subagent_id" }),
  handler = function(args, ctx) return vim.json.encode(Subagents.read(Context.require_caller(ctx), args.subagent_id, args)) end,
}

M.wait = {
  description = "Wait asynchronously for a descendant run. timeout_ms defaults to 30000, maximum 120000; a timeout leaves work running. "
    .. "Completion means the ACP turn ended, not proof the task's answer is correct. Output is bounded and readable with weave_subagent_read.",
  inputSchema = schema({ subagent_id = id, run_id = run_id,
    timeout_ms = { type = "integer", description = "Wait timeout in milliseconds; 0 polls" } }, { "subagent_id" }),
  async = true,
  handler = function(args, respond, ctx)
    Subagents.wait(Context.require_caller(ctx), args.subagent_id, args.run_id, args.timeout_ms, function(result)
      if not Gate.valid(ctx) then return respond(failure("stale caller")) end
      respond(vim.json.encode(result))
    end)
  end,
}

M.cancel = {
  description = "Cancel a descendant's active or specified run and work it delegated, retaining the session and completed output.",
  inputSchema = schema({ subagent_id = id, run_id = run_id }, { "subagent_id" }),
  handler = function(args, ctx) return vim.json.encode(Subagents.cancel(Context.require_caller(ctx), args.subagent_id, args.run_id)) end,
}

M.close = {
  description = "Close a descendant and its entire subtree, cancelling work and releasing retained runs. Never stops a shared provider process.",
  inputSchema = schema({ subagent_id = id }, { "subagent_id" }),
  handler = function(args, ctx)
    Subagents.close(Context.require_caller(ctx), args.subagent_id)
    return "Subagent subtree closed."
  end,
}

return M
