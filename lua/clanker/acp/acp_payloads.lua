local FileSystem = require("clanker.utils.file_system")

--- @class clanker.acp.ACPPayloads
local M = {}

--- @param text string|string[]
--- @return clanker.acp.UserMessageChunk
function M.generate_user_message(text)
  return M._generate_message_chunk(text, "user_message_chunk") --[[@as clanker.acp.UserMessageChunk]]
end

--- @param text string|string[]
--- @return clanker.acp.AgentMessageChunk
function M.generate_agent_message(text)
  return M._generate_message_chunk(text, "agent_message_chunk") --[[@as clanker.acp.AgentMessageChunk]]
end

--- @param text string|string[]
--- @param role "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk"
function M._generate_message_chunk(text, role)
  local content_text

  if type(text) == "string" then
    content_text = text
  elseif type(text) == "table" then
    content_text = table.concat(text, "\n")
  else
    content_text = vim.inspect(text)
  end

  return { --- @type clanker.acp.UserMessageChunk|clanker.acp.AgentMessageChunk|clanker.acp.AgentThoughtChunk
    sessionUpdate = role,
    content = {
      type = "text",
      text = content_text,
    },
  }
end

--- @param path string
--- @return clanker.acp.Content
function M.create_file_content(path)
  local abs_path = FileSystem.to_absolute_path(path)
  local uri = "file://" .. abs_path
  local ext = FileSystem.get_file_extension(path)

  local mime = FileSystem.IMAGE_MIMES[ext]

  -- It's an image file
  if mime then
    --- @type clanker.acp.ImageContent
    local content = {
      type = "image",
      mimeType = mime,
      uri = uri,
      data = FileSystem.read_file_base64(abs_path),
    }

    return content
  end

  mime = FileSystem.AUDIO_MIMES[ext]

  -- It's an audio file
  if mime then
    --- @type clanker.acp.AudioContent
    local content = {
      type = "audio",
      mimeType = mime,
      uri = uri,
      data = FileSystem.read_file_base64(abs_path),
    }

    return content
  end

  return M.create_resource_link_content(path)
end

--- @param path string
--- @return clanker.acp.ResourceLinkContent
function M.create_resource_link_content(path)
  local uri = "file://" .. FileSystem.to_absolute_path(path)
  local name = FileSystem.base_name(path)

  --- @type clanker.acp.ResourceLinkContent
  local resource = {
    type = "resource_link",
    uri = uri,
    name = name,
  }

  return resource
end

return M

--- @class clanker.acp.UserMessageChunk
--- @field sessionUpdate "user_message_chunk"
--- @field content clanker.acp.Content

--- @class clanker.acp.AgentMessageChunk
--- @field sessionUpdate "agent_message_chunk"
--- @field content clanker.acp.Content

--- @class clanker.acp.AgentThoughtChunk
--- @field sessionUpdate "agent_thought_chunk"
--- @field content clanker.acp.Content

--- @class clanker.acp.ResourceLinkContent
--- @field type "resource_link"
--- @field uri string
--- @field name string
--- @field description? string
--- @field mimeType? string
--- @field size? number
--- @field title? string
--- @field annotations? clanker.acp.Annotations

--- @class clanker.acp.ResourceContent
--- @field type "resource"
--- @field resource clanker.acp.EmbeddedResource
--- @field annotations? clanker.acp.Annotations

--- @class clanker.acp.EmbeddedResource
--- @field uri string
--- @field text string
--- @field blob? string
--- @field mimeType? string

--- @alias clanker.acp.Annotations.Audience "user" | "assistant"

--- @class clanker.acp.Annotations
--- @field audience? clanker.acp.Annotations.Audience[]
--- @field lastModified? string
--- @field priority? number

--- @class clanker.acp.TextContent
--- @field type "text"
--- @field text string
--- @field annotations? clanker.acp.Annotations

--- @class clanker.acp.ImageContent
--- @field type "image"
--- @field data string
--- @field mimeType string
--- @field uri? string
--- @field annotations? clanker.acp.Annotations

--- @class clanker.acp.AudioContent
--- @field type "audio"
--- @field data string
--- @field mimeType string
--- @field annotations? clanker.acp.Annotations

--- @alias clanker.acp.Content
--- | clanker.acp.TextContent
--- | clanker.acp.ImageContent
--- | clanker.acp.AudioContent
--- | clanker.acp.ResourceLinkContent
--- | clanker.acp.ResourceContent
