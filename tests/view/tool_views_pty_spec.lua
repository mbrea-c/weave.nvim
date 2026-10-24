local termdraw = require("fibrous.bench.termdraw")

describe("expanded tool views in a real terminal", function()
  for _, size in ipairs({ { 90, 28 }, { 42, 18 } }) do
    it(("wraps code, navigates, streams and expands diffs at %dx%d"):format(size[1], size[2]), function()
      local fibrous_root = vim.fn.fnamemodify(debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2), ":p:h:h:h:h")
      local result_path, target_path = vim.fn.tempname(), vim.fn.tempname() .. ".lua"
      vim.fn.writefile({ "first", "target" }, target_path)
      local draw = termdraw.drive({
        cols = size[1], rows = size[2], rtp = { fibrous_root, vim.fn.getcwd() },
        steps = {
          { lua = "FRAME(1)", wait_ms = 250 }, { lua = "FRAME(2)", wait_ms = 250 },
          { lua = "FRAME(3)", wait_ms = 250 }, { lua = "FRAME(4)", wait_ms = 250 },
          { lua = "FRAME(5)", wait_ms = 250 }, { lua = "FRAME(6)", wait_ms = 250 },
          { lua = "FRAME(7)", wait_ms = 250 }, { lua = "FRAME(8)", wait_ms = 250 },
          { lua = "FRAME(9)", wait_ms = 250 }, { lua = "FRAME(10)", wait_ms = 250 },
        },
        init = ([[
          require("weave").setup({})
          local Store, Tasks = require("weave.session_store"), require("weave.task_store")
          local store, prefs = Store:new(), require("weave.view.prefs"):new()
          prefs:set("follow", false)
          local owner = { get_store = function() return store end,
            permissions = function() return { current_mode = function() return "off" end } end }
          local origin = vim.api.nvim_get_current_win()
          local app = require("fibrous.inline.mount").floating(require("weave.view.transcript").Transcript,
            { store = store, prefs = prefs }, { width = vim.o.columns - 4, height = vim.o.lines - 5,
              mode = "scroll", keys = require("weave.keys").lhs_list("peek") })
          local win, buf, result = app.winid, app.bufnr, {}
          local function lines() return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
          local function text() return table.concat(lines(), "\n") end
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
            error("missing control: " .. needle)
          end
          local function put(name, input, body, status)
            store:reset()
            store:upsert_tool_call({ tool_call_id = "view", status = status or "completed",
              kind = "other", input = input, body = { body },
              mcp = { server = "clankbox", tool = "weave_" .. name },
              meta = { raw_marker = "RAW_ONLY_TOOL_VIEW" } })
          end
          local task
          _G.FRAME = function(i)
            if i == 1 then
              put("read", { path = %q }, "20\tlocal value = '" .. ("wrapped-source-"):rep(8) .. "TAIL'\n21\treturn value\n(truncated: continue with offset=22)")
              store:toggle_tool_call("view")
            elseif i == 2 then
              result.read = text()
              result.read_width = 0
              for _, value in ipairs(lines()) do result.read_width = math.max(result.read_width, vim.api.nvim_strwidth(value)) end
              result.width = vim.api.nvim_win_get_width(win)
              result.not_loaded = vim.fn.bufloaded(%q) == 0
              press("return value", "K")
            elseif i == 3 then
              for _, candidate in ipairs(vim.api.nvim_list_wins()) do
                if candidate ~= win and candidate ~= origin then
                  local t = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(candidate), 0, -1, false), "\n")
                  if t:find("RAW_ONLY_TOOL_VIEW", 1, true) then result.peek = t; vim.api.nvim_win_close(candidate, true); break end
                end
              end
              put("grep", { output_mode = "content", ["-n"] = true }, %q .. ":2:target")
              store:toggle_tool_call("view")
            elseif i == 4 then
              result.grep = text()
              press("2 target")
              result.navigation = { path = vim.api.nvim_buf_get_name(0), row = vim.api.nvim_win_get_cursor(0)[1] }
              vim.api.nvim_set_current_win(win)
              task = assert(Tasks.start({ command = "printf out-marker; sleep 0.3; printf err-marker >&2; sleep 0.3; printf final-marker",
                context = { caller = { session = owner, valid = function() return true end } } }))
              put("task_start", { command = task.command .. "\n# " .. ("long-command-"):rep(8) .. "END" },
                "task " .. task.id .. " started (pid 1) [weave task: " .. task.receipt .. "]")
              store:toggle_tool_call("view")
            elseif i == 5 then result.live = text()
            elseif i == 6 then result.live_later = text()
            elseif i == 7 then
              result.terminal = text()
              local old, new = {}, {}
              for n = 1, 100 do old[n] = "old_" .. n; new[n] = "new_" .. n end
              new[100] = "LAST_HUNK"
              store:reset()
              store:upsert_tool_call({ tool_call_id = "view", kind = "edit", status = "completed",
                diff = { old = old, new = new }, file_path = %q })
              result.diff_collapsed = text()
              store:toggle_tool_call("view")
            elseif i == 8 then
              result.diff_expanded = text()
              put("document_symbols", {}, vim.json.encode({ status = "partial", partial = true, items = {
                { path = %q, name = "symbol-name", container = "Container", range_available = true,
                  range = { start = { line = 2, column = 1 } } } },
                clients = { { name = "slow-server", state = "initializing", status = "not_requested" } } }))
              store:toggle_tool_call("view")
            elseif i == 9 then
              result.symbols = text()
              put("subagent_read", {}, vim.json.encode({ subagent_id = 999, run_id = 7, status = "completed",
                output = "**child-response**", has_more = true, next_cursor = 40 }))
              store:toggle_tool_call("view")
            elseif i == 10 then
              result.child = text()
              vim.cmd("redraw")
              result.finished = true
            end
            vim.fn.writefile({ vim.json.encode(result) }, %q)
          end
        ]]):format(target_path, target_path, target_path, target_path, target_path, result_path),
      })
      local result = vim.json.decode(table.concat(vim.fn.readfile(result_path), "\n"))
      vim.fn.delete(result_path); vim.fn.delete(target_path)
      if vim.env.WEAVE_TOOL_VIEWS_CAPTURE then
        for _, key in ipairs({ "read", "grep", "live", "live_later", "terminal", "symbols", "child", "navigation" }) do
          io.write("\n" .. key .. ": " .. vim.inspect(result[key]) .. "\n")
        end
      end
      local compact = function(value) return value:gsub("%s", "") end
      assert.truthy(compact(result.read):find("TAIL", 1, true))
      assert.truthy(compact(result.read):find("21returnvalue", 1, true))
      assert.truthy(compact(result.read):find("offset=22", 1, true))
      assert.is_true(result.read_width <= result.width)
      assert.is_true(result.not_loaded)
      assert.truthy(result.peek:find("RAW_ONLY_TOOL_VIEW", 1, true))
      assert.falsy(result.read:find("RAW_ONLY_TOOL_VIEW", 1, true))
      assert.equal(target_path, result.navigation.path)
      assert.equal(2, result.navigation.row)
      assert.truthy(compact(result.live .. result.live_later):find("out-marker", 1, true))
      assert.truthy(compact(result.terminal):find("err-marker", 1, true))
      assert.truthy(compact(result.terminal):find("final-marker", 1, true))
      assert.falsy(result.diff_collapsed:find("LAST_HUNK", 1, true))
      assert.truthy(result.diff_expanded:find("LAST_HUNK", 1, true))
      assert.truthy(compact(result.symbols):find("slow-server:initializing", 1, true))
      assert.truthy(compact(result.child):find("child-response", 1, true))
      assert.truthy(compact(result.child):find("40", 1, true))
      assert.is_true(result.finished)
      assert.truthy(#draw.steps > 0)
    end)
  end
end)
