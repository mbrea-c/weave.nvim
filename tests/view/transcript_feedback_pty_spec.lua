local termdraw = require("fibrous.bench.termdraw")

describe("transcript feedback in a real terminal", function()
  for _, columns in ipairs({ 80, 44 }) do
    it("keeps highlights and jumps stable across reflow, hiding and stream panes at " .. columns, function()
      local root = vim.fn.fnamemodify(debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2), ":p:h:h:h:h")
      local path, steps = vim.fn.tempname(), {}
      for i = 1, 8 do steps[i] = { lua = "FRAME(" .. i .. ")", wait_ms = 300 } end
      termdraw.drive({ cols = columns, rows = 32, rtp = { root, vim.fn.getcwd() }, steps = steps,
        init = ([[
          require("weave").setup({})
          local Store, Feedback = require("weave.session_store"), require("weave.feedback")
          local Draft = require("weave.feedback_store")
          local store, prefs = Store:new(), require("weave.view.prefs"):new()
          prefs:set("follow", false)
          store:append_entry({ kind = "agent", text = "Before **selected 界é** and more text to wrap across lines." })
          local app = require("fibrous.inline.mount").floating(require("weave.view.transcript").Transcript,
            { store = store, prefs = prefs }, { width = vim.o.columns - 4, height = 22, mode = "scroll" })
          local result, comment, stream_comment = { errors = {} }
          local function select(needle)
            for row, line in ipairs(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)) do
              local col = line:find(needle, 1, true)
              if col then return assert(Feedback.add({ bufnr = app.bufnr, body = "question",
                range = { lnum = row, col = col, end_col = col + #needle - 1 } })) end
            end
            error("missing selection " .. needle)
          end
          local function projected(c)
            local text = {}
            for _, loc in ipairs(Draft.resolve(c).locations) do
              text[#text + 1] = vim.api.nvim_buf_get_text(loc.bufnr, loc.row, loc.start_col, loc.row, loc.end_col, {})[1]
            end
            return table.concat(text)
          end
          local function highlighted(c)
            local ns = vim.api.nvim_create_namespace("WeaveTranscriptFeedback")
            for _, loc in ipairs(Draft.resolve(c).locations) do
              local marks = vim.api.nvim_buf_get_extmarks(loc.bufnr, ns, { loc.row, loc.start_col }, { loc.row, loc.end_col }, {})
              if #marks > 0 then return true end
            end
            return false
          end
          local function frame(i)
            if i == 1 then
              comment = select("selected")
              result.initial = projected(comment) == "selected" and highlighted(comment)
              prefs:set("conceal_markdown", false)
            elseif i == 2 then
              result.raw = projected(comment) == "selected" and highlighted(comment)
              prefs:set("conceal_markdown", true)
              vim.api.nvim_win_set_width(app.winid, 24)
              app.relayout()
            elseif i == 3 then
              result.resize = projected(comment) == "selected" and highlighted(comment)
              for n = 1, 45 do store:append_entry({ kind = "agent", text = "selected later " .. n }) end
              store:follow_window()
            elseif i == 4 then
              result.hidden = Draft.resolve(comment).state == "hidden" and not Draft.resolve(comment).orphaned
              result.jumped = Feedback.goto_comment(comment.id)
            elseif i == 5 then
              result.revealed = projected(comment) == "selected" and highlighted(comment)
                and vim.api.nvim_buf_line_count(app.bufnr) < 100
              store:reset()
              result.reset = Draft.resolve(comment).state == "unavailable"
              store:upsert_tool_call({ tool_call_id = "task", kind = "other", status = "completed",
                mcp = { server = "clankbox", tool = "weave_task_status" }, input = { id = 42 },
                output = { command = "printf command", stdout = "OUT_MARKER\n", stderr = "ERR_MARKER\n" } })
              store:toggle_tool_call("task")
            elseif i == 6 then
              for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.b[buf].weave_task_stream == "stderr" then
                  stream_comment = assert(Feedback.add({ bufnr = buf, body = "error question",
                    range = { lnum = 1, col = 1, end_col = 10 } }))
                  result.stream = stream_comment.target.spans[1].part == "tool.stderr"
                end
              end
              assert(stream_comment, "stderr pane missing")
              store:toggle_tool_call("task")
              result.collapsed = Draft.resolve(stream_comment).state == "hidden"
              result.stream_jump = Feedback.goto_comment(stream_comment.id)
            elseif i == 7 then
              result.stream_revealed = projected(stream_comment) == "ERR_MARKER" and highlighted(stream_comment)
              result.stream_focus = vim.b[vim.api.nvim_get_current_buf()].weave_task_stream == "stderr"
              store:upsert_tool_call({ tool_call_id = "task", output = {
                command = "printf command", stdout = "OUT_MARKER\n", stderr = "changed\n" } })
            elseif i == 8 then
              result.changed = Draft.resolve(stream_comment).state == "changed"
              result.quote_retained = table.concat(stream_comment.quote, "\n") == "ERR_MARKER"
              app.unmount()
              result.finished = true
            end
          end
          _G.FRAME = function(i)
            local ok, err = pcall(frame, i)
            if not ok then result.errors[#result.errors + 1] = tostring(err) end
            vim.fn.writefile({ vim.json.encode(result) }, %q)
          end
        ]]):format(path),
      })
      local result = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      vim.fn.delete(path)
      if vim.env.WEAVE_FEEDBACK_CAPTURE then io.write(vim.inspect(result) .. "\n") end
      assert.same({}, result.errors)
      for _, field in ipairs({ "initial", "raw", "resize", "hidden", "jumped", "revealed", "reset",
        "stream", "collapsed", "stream_jump", "stream_revealed", "stream_focus", "changed", "quote_retained", "finished" }) do
        assert.is_true(result[field], field)
      end
    end)
  end
end)
