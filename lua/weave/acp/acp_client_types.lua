--[[
  CRITICAL: Type annotations in this file are essential for Lua Language Server support.
  DO NOT REMOVE them. Only update them if the underlying types change.
--]]

--- @class weave.acp.ClientInfo
--- @field name string
--- @field version string

--- @class weave.acp.ClientCapabilities
--- @field fs weave.acp.FileSystemCapability
--- @field terminal boolean

--- @class weave.acp.InitializeParams
--- @field protocolVersion number
--- @field clientInfo weave.acp.ClientInfo
--- @field clientCapabilities weave.acp.ClientCapabilities

--- @class weave.acp.InitializeResponse
--- @field protocolVersion number
--- @field agentCapabilities weave.acp.AgentCapabilities
--- @field agentInfo weave.acp.AgentInfo
--- @field authMethods? weave.acp.AuthMethod[]

--- @class weave.acp.FileSystemCapability
--- @field readTextFile boolean
--- @field writeTextFile boolean

--- @class weave.acp.SessionCapabilities
--- @field list? boolean

--- @class weave.acp.AgentCapabilities
--- @field loadSession boolean
--- @field sessionCapabilities? weave.acp.SessionCapabilities
--- @field promptCapabilities weave.acp.PromptCapabilities

--- @class weave.acp.SessionInfo
--- @field sessionId string
--- @field cwd string
--- @field title? string
--- @field updatedAt? string
--- @field _meta? table<string, any>

--- @class weave.acp.SessionListResponse
--- @field sessions weave.acp.SessionInfo[]
--- @field nextCursor? string

--- @class weave.acp.PromptCapabilities
--- @field image boolean
--- @field audio boolean
--- @field embeddedContext boolean

--- @class weave.acp.AgentInfo
--- @field name? string
--- @field version? string
--- @field title? string

--- @class weave.acp.AuthMethod
--- @field id string
--- @field name string
--- @field description? string

--- @class weave.acp.McpServer
--- @field name string
--- @field command string
--- @field args string[]
--- @field env weave.acp.EnvVariable[]

--- @class weave.acp.EnvVariable
--- @field name string
--- @field value string

--- @alias weave.acp.StopReason
--- | "end_turn"
--- | "max_tokens"
--- | "max_turn_requests"
--- | "refusal"
--- | "cancelled"

--- @alias weave.acp.ToolKind
--- | "read"
--- | "edit"
--- | "delete"
--- | "move"
--- | "search"
--- | "execute"
--- | "think"
--- | "fetch"
--- | "WebSearch"
--- | "SlashCommand"
--- | "SubAgent"
--- | "other"
--- | "create"
--- | "write"
--- | "Skill"
--- | "switch_mode"

--- @alias weave.acp.ToolCallStatus
--- | "pending"
--- | "in_progress"
--- | "completed"
--- | "failed"

--- @alias weave.acp.PlanEntryStatus
--- | "pending"
--- | "in_progress"
--- | "completed"

--- @alias weave.acp.PlanEntryPriority
--- | "high"
--- | "medium"
--- | "low"

--- @class weave.acp.RawInput
--- @field file_path? string
--- @field filePath? string OpenCode was sending it camelCase
--- @field new_string? string
--- @field newString? string OpenCode was sending it camelCase
--- @field old_string? string
--- @field oldString? string OpenCode was sending it camelCase
--- @field replace_all? boolean
--- @field description? string
--- @field command? string
--- @field url? string Usually from the fetch tool
--- @field prompt? string Usually accompanying the fetch tool, not the web_search
--- @field query? string Usually from the web_search tool
--- @field timeout? number

--- @class weave.acp.ToolCallRegularContent
--- @field type "content"
--- @field content weave.acp.Content

--- @class weave.acp.ToolCallDiffContent
--- @field type "diff"
--- @field path string
--- @field oldText? string
--- @field newText string

--- @alias weave.acp.ACPToolCallContent
--- | weave.acp.ToolCallRegularContent
--- | weave.acp.ToolCallDiffContent

--- @class weave.acp.ToolCallLocation
--- @field path string
--- @field line? number

--- @class weave.acp.PlanEntry
--- @field content string
--- @field priority weave.acp.PlanEntryPriority
--- @field status weave.acp.PlanEntryStatus

--- @class weave.acp.AvailableCommand
--- @field name string
--- @field description string
--- @field input? table<string, any>

--- @class weave.acp.AgentMode
--- @field id string
--- @field name string
--- @field description? string

--- @class weave.acp.Model
--- @field modelId string
--- @field name string
--- @field description string

--- @class weave.acp.ModesInfo
--- @field availableModes weave.acp.AgentMode[]
--- @field currentModeId string

--- @class weave.acp.ModelsInfo
--- @field availableModels weave.acp.Model[]
--- @field currentModelId string

--- @class weave.acp.ConfigOption.Option
--- @field description string
--- @field name string
--- @field value string

--- @alias weave.acp.ConfigOption.Category
--- | "mode"
--- | "model"
--- | "thought_level"

--- @class weave.acp.ConfigOption
--- @field id string
--- @field category? weave.acp.ConfigOption.Category some agents omit it; key on id instead
--- @field currentValue string
--- @field description string
--- @field name string
--- @field options weave.acp.ConfigOption.Option[]

--- @class weave.acp.SessionCreationResponse
--- @field sessionId string
--- @field modes? weave.acp.ModesInfo
--- @field models? weave.acp.ModelsInfo
--- @field configOptions? weave.acp.ConfigOption[]

--- @alias weave.acp.ResponseRawParams
--- | { sessionId: string, update: weave.acp.SessionUpdateMessage }
--- | weave.acp.RequestPermission

--- @class weave.acp.ResponseRaw
--- @field id? number
--- @field jsonrpc string
--- @field method? string
--- @field result? table
--- @field error? weave.acp.ACPError
--- @field params? weave.acp.ResponseRawParams

--- Shared base fields for ToolCall and ToolCallUpdate.
--- In the ACP spec, ToolCallUpdate is a partial version where all fields
--- except toolCallId are optional. ToolCall (initial) additionally requires title.
--- @class weave.acp.ToolCallBase
--- @field toolCallId string
--- @field title? string
--- @field kind? weave.acp.ToolKind
--- @field status? weave.acp.ToolCallStatus
--- @field content? weave.acp.ACPToolCallContent[]
--- @field locations? weave.acp.ToolCallLocation[]
--- @field rawInput? weave.acp.RawInput
--- @field rawOutput? table
--- @field _meta? table<string, any>

--- Initial tool call notification (sessionUpdate="tool_call").
--- Per ACP JSON schema, only toolCallId and title are required.
--- @class weave.acp.ToolCallMessage : weave.acp.ToolCallBase
--- @field sessionUpdate "tool_call"

--- Tool call progress update (sessionUpdate="tool_call_update").
--- Only toolCallId is required. All other fields are optional — only changed fields are sent.
--- @class weave.acp.ToolCallUpdate : weave.acp.ToolCallBase
--- @field sessionUpdate "tool_call_update"

--- @class weave.acp.PlanUpdate
--- @field sessionUpdate "plan"
--- @field entries weave.acp.PlanEntry[]

--- @class weave.acp.AvailableCommandsUpdate
--- @field sessionUpdate "available_commands_update"
--- @field availableCommands weave.acp.AvailableCommand[]

--- @class weave.acp.CurrentModeUpdate
--- @field sessionUpdate "current_mode_update"
--- @field currentModeId string

--- @class weave.acp.UsageUpdate
--- @field sessionUpdate "usage_update"
--- @field used number Tokens currently in context
--- @field size number Total context window size in tokens
--- @field cost? { amount: number, currency: string } Cumulative session cost

--- @class weave.acp.SessionInfoUpdate
--- @field sessionUpdate "session_info_update"
--- @field title? string
--- @field updatedAt? string

--- @class weave.acp.ConfigOptionsUpdate
--- @field sessionUpdate "config_option_update"
--- @field configOptions weave.acp.ConfigOption[]

--- @alias weave.acp.SessionUpdateMessage
--- | weave.acp.UserMessageChunk
--- | weave.acp.AgentMessageChunk
--- | weave.acp.AgentThoughtChunk
--- | weave.acp.ToolCallMessage
--- | weave.acp.ToolCallUpdate
--- | weave.acp.PlanUpdate
--- | weave.acp.AvailableCommandsUpdate
--- | weave.acp.CurrentModeUpdate
--- | weave.acp.UsageUpdate
--- | weave.acp.SessionInfoUpdate
--- | weave.acp.ConfigOptionsUpdate

--- @class weave.acp.PermissionOption
--- @field optionId string
--- @field name string
--- @field kind "allow_once" | "allow_always" | "reject_once" | "reject_always"

--- Permission request (session/request_permission JSON-RPC request).
--- Per ACP spec, toolCall is a ToolCallUpdate (partial) — same shape used in tool_call_update.
--- @class weave.acp.RequestPermission
--- @field sessionId string
--- @field options weave.acp.PermissionOption[]
--- @field toolCall weave.acp.ToolCallBase

--- @class weave.acp.RequestPermissionOutcome
--- @field outcome "cancelled" | "selected"
--- @field optionId? string

--- @alias weave.acp.ClientConnectionState
--- | "disconnected"
--- | "connecting"
--- | "connected"
--- | "initializing"
--- | "ready"
--- | "error"

--- @class weave.acp.ACPError
--- @field code number
--- @field message string
--- @field data? any

--- @alias weave.acp.ClientHandlers.on_session_update fun(update: weave.acp.SessionUpdateMessage): nil
--- @alias weave.acp.ClientHandlers.on_request_permission fun(request: weave.acp.RequestPermission, callback: fun(option_id: string | nil)): nil
--- @alias weave.acp.ClientHandlers.on_error fun(err: weave.acp.ACPError): nil

--- @class weave.Selection
--- @field lines string[] The selected code lines
--- @field start_line integer Starting line number (1-indexed)
--- @field end_line integer Ending line number (1-indexed, inclusive)
--- @field file_path string Relative file path
--- @field file_type string File type/extension

--- Handlers for a specific session. Each session subscribes with its own handlers.
--- @class weave.acp.ClientHandlers
--- @field on_session_update weave.acp.ClientHandlers.on_session_update
--- @field on_request_permission weave.acp.ClientHandlers.on_request_permission
--- @field on_error weave.acp.ClientHandlers.on_error
--- @field on_tool_call fun(tool_call: weave.ui.MessageWriter.ToolCallBlock): nil
--- @field on_tool_call_update fun(tool_call: weave.ui.MessageWriter.ToolCallBlock): nil

--- @class weave.acp.ACPProviderConfig
--- @field name? string Provider name
--- @field transport_type? weave.acp.TransportType
--- @field command? string Command to spawn agent (for stdio)
--- @field args? string[] Arguments for agent command
--- @field env? table<string, string|nil> Environment variables
--- @field mcpServers? weave.acp.McpServer[] MCP servers to hand the agent for this provider. When present, OVERRIDES the global config.mcp_servers (not merged); absent means the global list applies. The agent spawns/connects these; see Session and create_session.
--- @field timeout? number Request timeout in milliseconds
--- @field reconnect? boolean Enable auto-reconnect
--- @field max_reconnect_attempts? number Maximum reconnection attempts
--- @field auth_method? string Authentication method
--- @field default_mode? string Default mode ID to set on session creation
--- @field initial_model? string Default model ID to set on session creation. When also setting default_thought_level, the thought level is applied AFTER the model change response (because effort/thought_level options can be model-dependent, e.g. Claude rebuilds them on model switch).
--- @field default_thought_level? string Default thought_level / effort value to set on session creation. Validated against the model's options. If `initial_model` is also set, applied after the model change completes.
