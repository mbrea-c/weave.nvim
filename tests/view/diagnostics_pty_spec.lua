local termdraw = require("fibrous.bench.termdraw")

describe("diagnostics transcript terminal rendering", function()
  for _, size in ipairs({ { 90, 28 }, { 42, 18 } }) do
    it(("wraps, expands, peeks and navigates at %dx%d"):format(size[1], size[2]), function()
      local source = debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2)
      local fibrous_root = vim.fn.fnamemodify(source, ":p:h:h:h:h")
      local result_path, target_path = vim.fn.tempname(), vim.fn.tempname() .. " target.lua"
      vim.fn.writefile({ "first", "λxyz" }, target_path)
      local draw = termdraw.drive({
        cols = size[1], rows = size[2], rtp = { fibrous_root, vim.fn.getcwd() },
        steps = {
          { lua = "FRAME(1)", wait_ms = 250 },
          { lua = "FRAME(2)", wait_ms = 250 },
          { lua = "FRAME(3)", wait_ms = 250 },
          { lua = "FRAME(4)", wait_ms = 250 },
          { lua = "FRAME(5)", wait_ms = 250 },
          { lua = "FRAME(6)", wait_ms = 250 },
        },
        init = ([[
          require("weave").setup({})
          local store = require("weave.session_store"):new()
          local prefs = require("weave.view.prefs"):new()
          prefs:set("follow", false)
          local payload = {
            status = "diagnostics_pending", can_conclude_clean = false,
            diagnostic_scope = "buffer", total = 2, offset = 0,
            clients = {
              { name = "null-ls", state = "ready", diagnostics = { state = "not_received" } },
              { name = "jdtls", state = "initializing", diagnostics = { state = "not_received" } },
            },
            items = {
              { path = %q, severity = "warning", message = ("wrapped-message-"):rep(9) .. "tail-marker",
                source = "lua_ls", code = "test-code", range = { start = { line = 2, column = 3 } } },
              { path = %q, severity = "error", message = "primary-finding",
                range = { start = { line = 1, column = 1 } } },
            },
          }
          local block = {
            tool_call_id = "d1", kind = "other", status = "completed",
            mcp = { server = "clankbox", tool = "weave_diagnostics" },
            input = { path = %q, load = true },
            body = { vim.json.encode(payload) },
            output = { content = { { type = "text", text = vim.json.encode(payload) } },
              _meta = { marker = "RAW_INSPECTION_ONLY" } },
          }
          store:upsert_tool_call(block)
          local origin = vim.api.nvim_get_current_win()
          local app = require("fibrous.inline.mount").floating(
            require("weave.view.transcript").Transcript, { store = store, prefs = prefs },
            { width = vim.o.columns - 4, height = vim.o.lines - 5, mode = "scroll",
              keys = require("weave.keys").lhs_list("peek") })
          local win, buf = app.winid, app.bufnr
          vim.api.nvim_set_current_win(win)
          local result = {}
          local function lines() return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
          local function press(needle, key)
            for row, value in ipairs(lines()) do
              local col = value:find(needle, 1, true)
              if col then
                vim.api.nvim_set_current_win(win)
                vim.api.nvim_win_set_cursor(win, { row, col - 1 })
                vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
                vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key or "<CR>", true, false, true), "xt", false)
                return
              end
            end
            error("control missing: " .. needle)
          end
          local function screen()
            vim.cmd("redraw")
            local out = {}
            for y = 1, vim.o.lines do
              local value = ""
              for x = 1, vim.o.columns do value = value .. vim.fn.screenstring(y, x) end
              out[#out + 1] = value
            end
            return table.concat(out, "\n")
          end
          local function save() vim.fn.writefile({ vim.json.encode(result) }, %q) end
          _G.FRAME = function(i)
            if i == 1 then
              result.collapsed = table.concat(lines(), "\n")
              result.screen = screen()
              result.loaded_before = vim.fn.bufloaded(%q) == 1
              result.max_width, result.width = 0, vim.api.nvim_win_get_width(win)
              for _, value in ipairs(lines()) do
                result.max_width = math.max(result.max_width, vim.api.nvim_strwidth(value))
              end
            elseif i == 2 then
              press("[+]")
              result.expanded = table.concat(lines(), "\n")
              result.is_expanded = store.state.expanded.d1 == true
            elseif i == 3 then
              press("W 2:3", "K")
              for _, candidate in ipairs(vim.api.nvim_list_wins()) do
                if candidate ~= win and candidate ~= origin then
                  local content = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(candidate), 0, -1, false), "\n")
                  if content:find("RAW_INSPECTION_ONLY", 1, true) then
                    result.peek = content
                    vim.api.nvim_win_close(candidate, true)
                    break
                  end
                end
              end
            elseif i == 4 then
              press("W 2:3")
              result.navigation = { path = vim.api.nvim_buf_get_name(0), cursor = vim.api.nvim_win_get_cursor(0),
                origin = vim.api.nvim_get_current_win() == origin, modified = vim.bo.modified }
            elseif i == 5 then
              vim.api.nvim_set_current_win(win)
              press("[-]")
              result.collapsed_again = store.state.expanded.d1 ~= true
            elseif i == 6 then
              result.finished = screen()
            end
            save()
          end
        ]]):format(target_path, target_path, target_path, result_path, target_path),
      })
      local result = vim.json.decode(table.concat(vim.fn.readfile(result_path), "\n"))
      vim.fn.delete(result_path)
      vim.fn.delete(target_path)
      if vim.env.WEAVE_DIAGNOSTICS_CAPTURE then
        io.write("\n" .. size[1] .. " columns:\n" .. vim.inspect(result) .. "\n")
      end
      assert.truthy(result.collapsed:gsub("%s", ""):find("coverageincomplete", 1, true))
      assert.truthy(result.screen:find("Cached snapshot", 1, true))
      assert.is_false(result.loaded_before)
      assert.is_true(result.max_width <= result.width)
      assert.is_true(result.is_expanded)
      assert.truthy(result.expanded:find("jdtls", 1, true))
      assert.truthy(result.expanded:find("initializing", 1, true))
      assert.truthy(result.expanded:gsub("%s", ""):find("tail-marker", 1, true))
      assert.falsy(result.expanded:find("RAW_INSPECTION_ONLY", 1, true))
      assert.falsy(result.expanded:find("output:", 1, true))
      assert.truthy(result.peek:find("RAW_INSPECTION_ONLY", 1, true))
      assert.equal(target_path, result.navigation.path)
      assert.same({ 2, 2 }, result.navigation.cursor)
      assert.is_true(result.navigation.origin)
      assert.is_false(result.navigation.modified)
      assert.is_true(result.collapsed_again)
      assert.truthy(#draw.steps > 0)
    end)
  end
end)
