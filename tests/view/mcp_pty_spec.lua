local termdraw = require("fibrous.bench.termdraw")

describe("MCP browser terminal rendering", function()
  for _, size in ipairs({ { 80, 24 }, { 36, 14 } }) do
    it(("renders and navigates long catalogues at %dx%d"):format(size[1], size[2]), function()
      local source = debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2)
      local fibrous_root = vim.fn.fnamemodify(source, ":p:h:h:h:h")
      local result_path = vim.fn.tempname()
      local steps = {}
      for i = 1, 6 do
        steps[#steps + 1] = { lua = "FRAME(" .. i .. ")", wait_ms = 200 }
        if i == 3 then steps[#steps + 1] = { wait_ms = 1100 } end
      end
      local draw = termdraw.drive({
        cols = size[1], rows = size[2], rtp = { fibrous_root, vim.fn.getcwd() }, steps = steps,
        init = ([[
          local definitions = {}
          for i = 1, 18 do definitions[i] = {
            name = ("weave_tool_%%02d"):format(i), description = "A useful tool with a readable description.",
            inputSchema = { type = "object", properties = {
              path = { type = "string", description = ("x"):rep(220) .. " readable_tail" },
            } },
          } end
          package.loaded.clankbox = { handle = function(request)
            return { id = request.id, result = { tools = definitions } }
          end }
          require("weave.mcp_proxy").list = function() return {
            { name = "example", command = "example-server", instances = {
              { id = 7, status = "running", pid = 42, started_at = os.time() - 125, tools = {} },
            } },
          } end
          local app = require("weave.view.mcp").open()
          local result = {}
          local function save() vim.fn.writefile({ vim.json.encode(result) }, %q) end
          local function view() return vim.api.nvim_win_call(app.winid, vim.fn.winsaveview) end
          local function screen()
            vim.cmd("redraw")
            local lines = {}
            for y = 1, vim.o.lines do
              local line = ""
              for x = 1, vim.o.columns do line = line .. vim.fn.screenstring(y, x) end
              lines[#lines + 1] = line
            end
            return table.concat(lines, "\n")
          end
          local function press(needle)
            for row, line in ipairs(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)) do
              local col = line:find(needle, 1, true)
              if col then
                vim.api.nvim_win_set_cursor(app.winid, { row, col - 1 })
                vim.api.nvim_exec_autocmds("CursorMoved", { buffer = app.bufnr })
                if needle == "weave_tool_18" then
                  vim.cmd("redraw")
                  result.catalogue_view = view()
                end
                vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
                return
              end
            end
            error("missing control " .. needle)
          end
          local function back()
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<BS>", true, false, true), "xt", false)
          end
          _G.FRAME = function(i)
            if i == 1 then result.list = screen()
            elseif i == 2 then
              press("clankbox")
              -- Capture after scheduled fit/WinResized, not an intermediate draw.
              vim.defer_fn(function()
                result.catalogue = screen()
                result.catalogue_height = vim.api.nvim_win_get_height(app.winid)
                save()
              end, 40)
              return
            elseif i == 3 then
              press("weave_tool_18")
              result.tool_topline = view().topline
              result.tool = screen()
              local lines = vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)
              -- Last schema lines, before the Full definition control and footer.
              for row, line in ipairs(lines) do
                if line:find('"type": "string"', 1, true) then
                  vim.api.nvim_win_set_cursor(app.winid, { row, 2 }); break
                end
              end
              result.schema = screen()
              result.before_tick = view()
            elseif i == 4 then
              result.after_tick = view()
            elseif i == 5 then
              back()
              result.restored = view()
              result.returned = screen()
            elseif i == 6 then
              back(); press("example")
              vim.defer_fn(function()
                for row, line in ipairs(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)) do
                  local col = line:find("[ Restart ]", 1, true)
                  if col then vim.api.nvim_win_set_cursor(app.winid, { row, col - 1 }); break end
                end
                result.connection = screen()
                save()
              end, 40)
              return
            end
            save()
          end
        ]]):format(result_path),
      })
      local result = vim.json.decode(table.concat(vim.fn.readfile(result_path), "\n"))
      vim.fn.delete(result_path)
      if vim.env.WEAVE_MCP_CAPTURE then
        for _, key in ipairs({ "list", "catalogue", "tool", "schema", "returned", "connection" }) do
          io.write("\n" .. key .. " (" .. size[1] .. " cols)\n" .. result[key] .. "\n")
        end
      end
      assert.equal(0, draw.steps[4].bytes) -- Registry polling must not repaint an unchanged page.
      assert.truthy(result.list:find("MCP servers", 1, true))
      assert.truthy(result.list:find("clankbox", 1, true))
      assert.truthy(result.catalogue:find("Tools (18)", 1, true))
      assert.equal(size[2] - 6, result.catalogue_height)
      assert.equal(1, result.tool_topline)
      assert.truthy(result.tool:find("weave_tool_18", 1, true))
      assert.truthy(result.schema:gsub("%s", ""):find("readable_tail", 1, true))
      assert.equal(result.before_tick.topline, result.after_tick.topline)
      assert.equal(result.before_tick.lnum, result.after_tick.lnum)
      assert.equal(result.catalogue_view.topline, result.restored.topline)
      assert.equal(result.catalogue_view.lnum, result.restored.lnum)
      assert.truthy(result.returned:find("weave_tool_18", 1, true))
      assert.truthy(result.connection:find("[ Restart ]", 1, true))
      assert.truthy(result.connection:find("[ Kill ]", 1, true))
    end)
  end
end)
