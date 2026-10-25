local termdraw = require("fibrous.bench.termdraw")

describe("entry-wide tool folds in a real terminal", function()
  for _, size in ipairs({ { 90, 32 }, { 42, 28 } }) do
    it(("folds wrapped entries and focused stream panes at %dx%d"):format(size[1], size[2]), function()
      local root = vim.fn.fnamemodify(debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2), ":p:h:h:h:h")
      local result_path, steps = vim.fn.tempname(), {}
      for i = 1, 6 do steps[i] = { lua = "FRAME(" .. i .. ")", wait_ms = 300 } end
      termdraw.drive({ cols = size[1], rows = size[2], rtp = { root, vim.fn.getcwd() }, steps = steps,
        init = ([[
          require("weave").setup({})
          local store, prefs = require("weave.session_store"):new(), require("weave.view.prefs"):new()
          prefs:set("follow", false)
          local handle = require("weave.view.panel").open({ store = store, prefs = prefs,
            width = vim.o.columns - 2, sidebar_width = 10, prompt_height = 4 })
          local win, buf, result = handle.transcript.winid, handle.transcript.bufnr, { errors = {} }
          local function press(key)
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
          end
          local function at(needle, key)
            for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
              local col = line:find(needle, 1, true)
              if col then
                vim.api.nvim_set_current_win(win)
                vim.api.nvim_win_set_cursor(win, { row, col - 1 })
                vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
                if key then press(key) end
                return row
              end
            end
            error("missing transcript text: " .. needle)
          end
          local function scroll_to(name)
            at(name:sub(1, 4)) -- border titles can be truncated in a narrow pane
            vim.cmd("normal! zt")
          end
          local function focus_stream(name)
            for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
              if vim.b[candidate].weave_task_stream == name then
                local target = assert(vim.fn.win_findbuf(candidate)[1], "stream has no window")
                assert(not vim.api.nvim_win_get_config(target).hide, "stream is hidden")
                vim.api.nvim_set_current_win(target)
                vim.api.nvim_win_set_cursor(target, { 1, 3 })
                return candidate
              end
            end
            error("missing stream: " .. name)
          end
          store:upsert_tool_call({ tool_call_id = "first", kind = "other", status = "completed",
            argument = "FOLD_ME" .. (" long wrapped header"):rep(8), body = { "BODY_MARKER" } })
          store:append_entry({ kind = "agent", text = "OUTSIDE" })
          local function frame(i)
            if i == 1 then
              at("FOL", "<CR>")
              result.header_cr = not store.state.expanded.first
              at("FOL", "za")
              result.header_fold = store.state.expanded.first == true
            elseif i == 2 then
              at("BOD", "<CR>")
              result.body_cr = store.state.expanded.first == true
              at("BOD", "za")
              result.body_fold = not store.state.expanded.first
              at("OUTSIDE", "za")
              result.outside = not store.state.expanded.first
              local row = at("FOL")
              vim.api.nvim_win_set_cursor(win, { row + 1, 3 })
              press("za")
              result.wrapped_fold = store.state.expanded.first == true
            elseif i == 3 then
              store:reset()
              store:upsert_tool_call({ tool_call_id = "task", kind = "other", status = "completed",
                mcp = { server = "clankbox", tool = "weave_task_status" }, input = { id = 42 },
                output = { command = "printf streams", stdout = "STDOUT_MARKER", stderr = "STDERR_MARKER" } })
              store:upsert_tool_call({ tool_call_id = "second", kind = "other", status = "completed", argument = "SECOND" })
              at("[w:", "za")
              scroll_to("stdout")
            elseif i == 4 then
              local stream = focus_stream("stdout")
              press("<CR>")
              result.stream_cr = store.state.expanded.task == true
              press("za")
              result.stdout_fold = not store.state.expanded.task and not vim.api.nvim_buf_is_valid(stream)
                and vim.api.nvim_get_current_win() == win
              at("[w:", "za")
              scroll_to("stderr")
            elseif i == 5 then
              local stream = focus_stream("stderr")
              press("za")
              result.stderr_fold = not store.state.expanded.task and not vim.api.nvim_buf_is_valid(stream)
                and vim.api.nvim_get_current_win() == win
              at("SEC", "<CR>")
              result.second_cr = not store.state.expanded.second
              at("SEC", "za")
              result.only_second = store.state.expanded.second == true and not store.state.expanded.task
            elseif i == 6 then
              result.finished = true
              handle.close()
            end
          end
          _G.FRAME = function(i)
            local ok, err = pcall(frame, i)
            if not ok then
              result.errors[#result.errors + 1] = tostring(err)
                .. "\n" .. table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            end
            vim.fn.writefile({ vim.json.encode(result) }, %q)
          end
        ]]):format(result_path),
      })
      local result = vim.json.decode(table.concat(vim.fn.readfile(result_path), "\n"))
      vim.fn.delete(result_path)
      if vim.env.WEAVE_TOOL_FOLD_CAPTURE then io.write(vim.inspect(result) .. "\n") end
      assert.same({}, result.errors)
      for _, field in ipairs({ "header_cr", "header_fold", "body_cr", "body_fold", "outside",
        "wrapped_fold", "stream_cr", "stdout_fold", "stderr_fold", "second_cr", "only_second", "finished" }) do
        assert.is_true(result[field], field)
      end
    end)
  end
end)
