-- Filesystem probes the sandbox backends need. A module of its own so the
-- backends stay pure functions of (hull, fs): weave.sandbox hands them the
-- `_exists`/`_realpath` test seams, and a backend spec can hand them a fake
-- filesystem without touching the dispatcher.

local M = {}

local uv = vim.uv or vim.loop

--- @param path string
--- @return boolean
function M.exists(path)
  return uv.fs_lstat(path) ~= nil
end

--- @param path string
--- @return string|nil
function M.realpath(path)
  return uv.fs_realpath(path)
end

return M
