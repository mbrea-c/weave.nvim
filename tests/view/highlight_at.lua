-- Resolve the canvas highlight at the first byte matched by a Lua pattern.
return function(bufnr, pattern)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local col = line:find(pattern)
    if col then
      local pos = { row - 1, col - 1 }
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, pos, pos, {
        type = "highlight", overlap = true, details = true,
      })
      for _, mark in ipairs(marks) do
        if mark[4].end_col > pos[2] then
          return vim.api.nvim_get_hl(0, { name = mark[4].hl_group, link = false })
        end
      end
      break
    end
  end
  return {}
end
