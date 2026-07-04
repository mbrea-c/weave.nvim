--[[
  CRITICAL: Type annotations in this file are essential for Lua Language Server support.
  DO NOT REMOVE them. Only update them if the underlying types change.
--]]

--- @class clanker.acp.ClientInfo
--- @field name string
--- @field version string

--- @class clanker.acp.ClientCapabilities
--- @field fs clanker.acp.FileSystemCapability
--- @field terminal boolean

--- @class clanker.acp.InitializeParams
--- @field protocolVersion number
--- @field clientInfo clanker.acp.ClientInfo
--- @field clientCapabilities clanker.acp.ClientCapabilities

--- @class clanker.acp.InitializeResponse
--- @field protocolVersion number
--- @field agentCapabilities clanker.acp.AgentCapabilities
--- @field agentInfo clanker.acp.AgentInfo
--- @field authMethods? clanker.acp.AuthMethod[]

--- @class clanker.acp.FileSystemCapability
--- @field readTextFile boolean
--- @field writeTextFile boolean

--- @class clanker.acp.SessionCapabilities
--- @field list? boolean

--- @class clanker.acp.AgentCapabilities
--- @field loadSession boolean
--- @field sessionCapabilities? clanker.acp.SessionCapabilities
--- @field promptCapabilities clanker.acp.PromptCapabilities

--- @class clanker.acp.SessionInfo
--- @field sessionId string
--- @field cwd string
--- @field title? string
--- @field updatedAt? string
--- @field _meta? table<string, any>

--- @class clanker.acp.SessionListResponse
--- @field sessions clanker.acp.SessionInfo[]
--- @field nextCursor? string

--- @class clanker.acp.PromptCapabilities
--- @field image boolean
--- @field audio boolean
--- @field embeddedContext boolean

--- @class clanker.acp.AgentInfo
--- @field name? string
--- @field version? string
--- @field title? string

--- @class clanker.acp.AuthMethod
--- @field id string
--- @field name string
--- @field description? string

--- @class clanker.acp.McpServer
--- @field name string
--- @field command string
--- @field args string[]
--- @field env clanker.acp.EnvVariable[]

--- @class clanker.acp.EnvVariable
--- @field name string
--- @field value string

--- @alias clanker.acp.StopReason
--- | "end_turn"
--- | "max_tokens"
--- | "max_turn_requests"
--- | "refusal"
--- | "cancelled"

--- @alias clanker.acp.ToolKind
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

--- @alias clanker.acp.ToolCallStatus
--- | "pending"
--- | "in_progress"
--- | "completed"
--- | "failed"

--- @alias clanker.acp.PlanEntryStatus
--- | "pending"
--- | "in_progress"
--- | "completed"

--- @alias clanker.acp.PlanEntryPriority
--- | "high"
--- | "medium"
--- | "low"

--- @class clanker.acp.RawInput
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

--- @class clanker.acp.ToolCallRegularContent
--- @field type "content"
--- @field content clanker.acp.Content

--- @class clanker.acp.ToolCallDiffContent
--- @field type "diff"
--- @field path string
--- @field oldText? string
--- @field newText string

--- @alias clanker.acp.ACPToolCallContent
--- | clanker.acp.ToolCallRegularContent
--- | clanker.acp.ToolCallDiffContent

--- @class clanker.acp.ToolCallLocation
--- @field path string
--- @field line? number

--- @class clanker.acp.PlanEntry
--- @field content string
--- @field priority clanker.acp.PlanEntryPriority
--- @field status clanker.acp.PlanEntryStatus

--- @class clanker.acp.AvailableCommand
--- @field name string
--- @field description string
--- @field input? table<string, any>

--- @class clanker.acp.AgentMode
--- @field id string
--- @field name string
--- @field description? string

--- @class clanker.acp.Model
--- @field modelId string
--- @field name string
--- @field description string

--- @class clanker.acp.ModesInfo
--- @field availableModes clanker.acp.AgentMode[]
--- @field currentModeId string

--- @class clanker.acp.ModelsInfo
--- @field availableModels clanker.acp.Model[]
--- @field currentModelId string

--- @class clanker.acp.ConfigOption.Option
--- @field description string
--- @field name string
--- @field value string

--- @alias clanker.acp.ConfigOption.Category
--- | "mode"
--- | "model"
--- | "thought_level"

--- @class clanker.acp.ConfigOption
--- @field id string
--- @field category clanker.acp.ConfigOption.Category
--- @field currentValue string
--- @field description string
--- @field name string
--- @field options clanker.acp.ConfigOption.Option[]

--- @class clanker.acp.SessionCreationResponse
--- @field sessionId string
--- @field modes? clanker.acp.ModesInfo
--- @field models? clanker.acp.ModelsInfo
--- @field configOptions? clanker.acp.ConfigOption[]

--- @alias clanker.acp.ResponseRawParams
--- | { sessionId: string, update: clanker.acp.SessionUpdateMessage }
--- | clanker.acp.RequestPermission

--- @class clanker.acp.ResponseRaw
--- @field id? number
--- @field jsonrpc string
--- @field method? string
--- @field result? table
--- @field error? clanker.acp.ACPError
--- @field params? clanker.acp.ResponseRawParams

--- Shared base fields for ToolCall and ToolCallUpdate.
--- In the ACP spec, ToolCallUpdate is a partial version where all fields
--- except toolCallId are optional. ToolCall (initial) additionally requires title.
--- @class clanker.acp.ToolCallBase
--- @field toolCallId string
--- @field title? string
--- @field kind? clanker.acp.ToolKind
--- @field status? clanker.acp.ToolCallStatus
--- @field content? clanker.acp.ACPToolCallContent[]
--- @field locations? clanker.acp.ToolCallLocation[]
--- @field rawInput? clanker.acp.RawInput
--- @field rawOutput? table
--- @field _meta? table<string, any>

--- Initial tool call notification (sessionUpdate="tool_call").
--- Per ACP JSON schema, only toolCallId and title are required.
--- @class clanker.acp.ToolCallMessage : clanker.acp.ToolCallBase
--- @field sessionUpdate "tool_call"

--- Tool call progress update (sessionUpdate="tool_call_update").
--- Only toolCallId is required. All other fields are optional — only changed fields are sent.
--- @class clanker.acp.ToolCallUpdate : clanker.acp.ToolCallBase
--- @field sessionUpdate "tool_call_update"

--- @class clanker.acp.PlanUpdate
--- @field sessionUpdate "plan"
--- @field entries clanker.acp.PlanEntry[]

--- @class clanker.acp.AvailableCommandsUpdate
--- @field sessionUpdate "available_commands_update"
--- @field availableCommands clanker.acp.AvailableCommand[]

--- @class clanker.acp.CurrentModeUpdate
--- @field sessionUpdate "current_mode_update"
--- @field currentModeId string

--- @class clanker.acp.UsageUpdate
--- @field sessionUpdate "usage_update"
--- @field used number Tokens currently in context
--- @field size number Total context window size in tokens
--- @field cost? { amount: number, currency: string } Cumulative session cost

--- @class clanker.acp.SessionInfoUpdate
--- @field sessionUpdate "session_info_update"
--- @field title? string
--- @field updatedAt? string

--- @class clanker.acp.ConfigOptionsUpdate
--- @field sessionUpdate "config_option_update"
--- @field configOptions clanker.acp.ConfigOption[]

--- @alias clanker.acp.SessionUpdateMessage
--- | clanker.acp.UserMessageChunk
--- | clanker.acp.AgentMessageChunk
--- | clanker.acp.AgentThoughtChunk
--- | clanker.acp.ToolCallMessage
--- | clanker.acp.ToolCallUpdate
--- | clanker.acp.PlanUpdate
--- | clanker.acp.AvailableCommandsUpdate
--- | clanker.acp.CurrentModeUpdate
--- | clanker.acp.UsageUpdate
--- | clanker.acp.SessionInfoUpdate
--- | clanker.acp.ConfigOptionsUpdate

--- @class clanker.acp.PermissionOption
--- @field optionId string
--- @field name string
--- @field kind "allow_once" | "allow_always" | "reject_once" | "reject_always"

--- Permission request (session/request_permission JSON-RPC request).
--- Per ACP spec, toolCall is a ToolCallUpdate (partial) — same shape used in tool_call_update.
--- @class clanker.acp.RequestPermission
--- @field sessionId string
--- @field options clanker.acp.PermissionOption[]
--- @field toolCall clanker.acp.ToolCallBase

--- @class clanker.acp.RequestPermissionOutcome
--- @field outcome "cancelled" | "selected"
--- @field optionId? string

--- @alias clanker.acp.ClientConnectionState
--- | "disconnected"
--- | "connecting"
--- | "connected"
--- | "initializing"
--- | "ready"
--- | "error"

--- @class clanker.acp.ACPError
--- @field code number
--- @field message string
--- @field data? any

--- @alias clanker.acp.ClientHandlers.on_session_update fun(update: clanker.acp.SessionUpdateMessage): nil
--- @alias clanker.acp.ClientHandlers.on_request_permission fun(request: clanker.acp.RequestPermission, callback: fun(option_id: string | nil)): nil
--- @alias clanker.acp.ClientHandlers.on_error fun(err: clanker.acp.ACPError): nil

--- @class clanker.Selection
--- @field lines string[] The selected code lines
--- @field start_line integer Starting line number (1-indexed)
--- @field end_line integer Ending line number (1-indexed, inclusive)
--- @field file_path string Relative file path
--- @field file_type string File type/extension

--- Handlers for a specific session. Each session subscribes with its own handlers.
--- @class clanker.acp.ClientHandlers
--- @field on_session_update clanker.acp.ClientHandlers.on_session_update
--- @field on_request_permission clanker.acp.ClientHandlers.on_request_permission
--- @field on_error clanker.acp.ClientHandlers.on_error
--- @field on_tool_call fun(tool_call: clanker.ui.MessageWriter.ToolCallBlock): nil
--- @field on_tool_call_update fun(tool_call: clanker.ui.MessageWriter.ToolCallBlock): nil

--- @class clanker.acp.ACPProviderConfig
--- @field name? string Provider name
--- @field transport_type? clanker.acp.TransportType
--- @field command? string Command to spawn agent (for stdio)
--- @field args? string[] Arguments for agent command
--- @field env? table<string, string|nil> Environment variables
--- @field mcpServers? clanker.acp.McpServer[] MCP servers to hand the agent for this provider. When present, OVERRIDES the global config.mcp_servers (not merged); absent means the global list applies. The agent spawns/connects these; see Session and create_session.
--- @field timeout? number Request timeout in milliseconds
--- @field reconnect? boolean Enable auto-reconnect
--- @field max_reconnect_attempts? number Maximum reconnection attempts
--- @field auth_method? string Authentication method
--- @field default_mode? string Default mode ID to set on session creation
--- @field initial_model? string Default model ID to set on session creation. When also setting default_thought_level, the thought level is applied AFTER the model change response (because effort/thought_level options can be model-dependent, e.g. Claude rebuilds them on model switch).
--- @field default_thought_level? string Default thought_level / effort value to set on session creation. Validated against the model's options. If `initial_model` is also set, applied after the model change completes.
