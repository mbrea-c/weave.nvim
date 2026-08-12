-- Files the USER hands to the agent (images, mostly), staged where the agent
-- can actually open them.
--
-- Under sandbox mode on, the project is an empty read-only tmpfs and $HOME is
-- hidden: a `file://` URI pointing at where the file really lives resolves to
-- nothing inside the agent. Models that read images natively (rather than
-- accepting an inline image block) therefore cannot see an attachment at all
-- unless the bytes exist at that path IN the sandbox.
--
-- So weave COPIES an attachment into one staging directory and binds THAT
-- directory read-only into the agent hull (see weave.sandbox.wrap). Copying,
-- not binding the original: the original may live anywhere — another project,
-- a Downloads folder, a secrets-adjacent directory — and binding arbitrary
-- user paths in would be a far larger grant than "look at this picture". The
-- agent sees exactly the files you attached, at a path it can read, and
-- nothing else.
--
-- The directory lives outside $HOME (which the sandbox hides) and is scoped to
-- this editor process, so two Neovims cannot collide and nothing outlives the
-- session that made it.

local FileSystem = require("weave.utils.file_system")

local M = {}

local uv = vim.uv or vim.loop

--- Max bytes we will copy in. An attachment is context for a model, not a
--- payload; a 40MB TIFF is a mistake, not a request.
M.MAX_BYTES = 20 * 1024 * 1024

--- @type string|nil memoized
local root

--- The staging directory for this editor process. Not created here — see
--- `ensure_root` — so that merely asking (the sandbox bind list does, on every
--- spawn) never litters the filesystem.
--- @return string
function M.root()
  if not root then
    -- XDG_RUNTIME_DIR is a tmpfs outside $HOME that the sandbox's read-only
    -- root already exposes; the cache dir is the fallback for systems without
    -- one (it is under $HOME, which is why the bind in wrap() is explicit).
    local base = vim.env.XDG_RUNTIME_DIR
    if not base or base == "" or not uv.fs_stat(base) then
      base = vim.fn.stdpath("cache")
    end
    root = ("%s/weave/attachments/%d"):format(base, uv.os_getpid())
  end
  return root
end

--- @return string|nil dir, string|nil err
function M.ensure_root()
  local dir = M.root()
  if uv.fs_stat(dir) then
    return dir, nil
  end
  local ok, err = FileSystem.mkdirp(dir)
  if not ok then
    return nil, ("could not create the attachment directory %s: %s"):format(dir, err or "?")
  end
  -- Copies of the user's files should not outlive the editor that made them.
  -- Registered on first use, so an editor that never attaches anything
  -- registers nothing.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("WeaveAttachments", { clear = true }),
    callback = function()
      M.clear()
    end,
  })
  return dir, nil
end

--- The paths the AGENT sandbox should bind read-only. Empty until something
--- has actually been staged, so a session that never attaches anything gets
--- no extra mount.
--- @return string[]
function M.sandbox_paths()
  local dir = M.root()
  return uv.fs_stat(dir) and { dir } or {}
end

--- The mime type for a path, by extension, or nil when we do not know it.
--- @param path string
--- @return string|nil
function M.mime_of(path)
  local ext = FileSystem.get_file_extension(path)
  return FileSystem.IMAGE_MIMES[ext] or FileSystem.AUDIO_MIMES[ext] or nil
end

--- Names already staged, so a second `logo.png` does not silently replace the
--- first (the agent would be looking at the wrong picture).
--- @param dir string
--- @param name string
--- @return string
local function unique_name(dir, name)
  if not uv.fs_stat(dir .. "/" .. name) then
    return name
  end
  local stem = name:match("^(.*)%.[^.]*$") or name
  local ext = name:match("%.([^.]*)$")
  for i = 2, 999 do
    local candidate = ("%s-%d%s"):format(stem, i, ext and ("." .. ext) or "")
    if not uv.fs_stat(dir .. "/" .. candidate) then
      return candidate
    end
  end
  return name .. "-" .. tostring(uv.os_getpid())
end

--- @class weave.Attachment
--- @field name string Base name as staged (unique within the staging dir)
--- @field path string Absolute staged path — the SAME path inside the sandbox
--- @field uri string file:// URI of `path`
--- @field mime string|nil Mime type by extension, when known
--- @field size integer Bytes
--- @field source string The path the user named

--- Copy `path` into the staging directory.
--- @param path string
--- @return weave.Attachment|nil attachment, string|nil err
function M.stage(path)
  if type(path) ~= "string" or path == "" then
    return nil, "attach: needs a file path"
  end
  local abs = FileSystem.to_absolute_path(vim.fn.expand(path))
  local stat = uv.fs_stat(abs)
  if not stat then
    return nil, ("attach: %s does not exist"):format(abs)
  end
  if stat.type == "directory" then
    return nil, ("attach: %s is a directory"):format(abs)
  end
  if stat.size > M.MAX_BYTES then
    return nil,
      ("attach: %s is %.1f MB; the limit is %d MB"):format(abs, stat.size / 1024 / 1024, M.MAX_BYTES / 1024 / 1024)
  end

  local dir, derr = M.ensure_root()
  if not dir then
    return nil, derr
  end
  local name = unique_name(dir, FileSystem.base_name(abs))
  local dest = dir .. "/" .. name
  local ok, cerr = uv.fs_copyfile(abs, dest)
  if not ok then
    return nil, ("attach: could not copy %s: %s"):format(abs, tostring(cerr))
  end

  return {
    name = name,
    path = dest,
    uri = "file://" .. dest,
    mime = M.mime_of(abs),
    size = stat.size,
    source = abs,
  },
    nil
end

--- Remove everything staged by this editor. Called on exit; safe to call when
--- nothing was ever staged.
function M.clear()
  local dir = M.root()
  if not uv.fs_stat(dir) then
    return
  end
  local handle = uv.fs_scandir(dir)
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    pcall(uv.fs_unlink, dir .. "/" .. name)
  end
  pcall(uv.fs_rmdir, dir)
end

--- test seam: forget the memoized root (specs point XDG_RUNTIME_DIR elsewhere)
function M._reset()
  root = nil
end

return M
