local termdraw = require("fibrous.bench.termdraw")

describe("recorded tool reports in a real terminal", function()
  for _, size in ipairs({ { 90, 30 }, { 42, 22 } }) do
    it(("renders task streams and write previews after snapshot loss at %dx%d"):format(size[1], size[2]), function()
      local source = debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2)
      local fibrous_root = vim.fn.fnamemodify(source, ":p:h:h:h:h")
      local result_path, target_path, steps = vim.fn.tempname(), vim.fn.tempname() .. ".lua", {}
      for i = 1, 6 do steps[i] = { lua = "FRAME(" .. i .. ")", wait_ms = 250 } end
      termdraw.drive({
        cols = size[1], rows = size[2], rtp = { fibrous_root, vim.fn.getcwd() }, steps = steps,
        init = ([[
          require("weave").setup({})
          local Store, Tasks = require("weave.session_store"), require("weave.task_store")
          local store, prefs = Store:new(), require("weave.view.prefs"):new()
          prefs:set("follow", false)
          local app = require("fibrous.inline.mount").floating(require("weave.view.transcript").Transcript,
            { store = store, prefs = prefs }, { width = vim.o.columns - 4, height = vim.o.lines - 5, mode = "scroll" })
          local result, task = {}, nil
          local function text() return table.concat(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false), "\n") end
          local function put(name, input, output)
            store:reset()
            store:upsert_tool_call({ tool_call_id = "recorded", kind = "other", status = "completed",
              mcp = { server = "clankbox", tool = "weave_" .. name }, input = input, body = { output } })
          end
          _G.FRAME = function(i)
            if i == 1 then
              task = assert(Tasks.start({ command = "printf 'legacy stdout\\n'; printf 'legacy stderr\\n' >&2" }))
            elseif i == 2 then
              local report = require("weave.tools.tasks").status.handler({ id = task.id })
              local recorded = type(report) == "string" and report or report.content[1].text
              Tasks._reset()
              put("task_status", { id = task.id }, recorded)
              store:toggle_tool_call("recorded")
            elseif i == 3 then
              result.task = text()
              for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                local stream = vim.api.nvim_buf_is_valid(buf) and vim.b[buf].weave_task_stream
                if stream then result[stream] = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
              end
              local lines = {}
              for n = 1, 100 do lines[n] = "CREATE_LINE_" .. n end
              lines[100] = "CREATE_LAST"
              local input = { path = %q, content = table.concat(lines, "\n") .. "\n" }
              local output = require("weave.tools.fs").write.handler(input,
                { caller = { session = { get_store = function() return store end } } })
              put("write", input, output) -- clears the live change snapshot before rendering
            elseif i == 4 then
              result.created_collapsed = text()
              store:toggle_tool_call("recorded")
            elseif i == 5 then
              result.created_expanded = text()
              put("write", { path = %q, content = "HISTORICAL_CONTENT\nreturn true\n" }, "wrote 2 lines to historical file")
              store:toggle_tool_call("recorded")
            elseif i == 6 then
              result.unknown = text()
              result.render_did_not_write = vim.fn.readfile(%q)[1] == "CREATE_LINE_1"
              app.unmount()
              result.finished = true
            end
            vim.fn.writefile({ vim.json.encode(result) }, %q)
          end
        ]]):format(target_path, target_path, target_path, result_path),
      })
      local result = vim.json.decode(table.concat(vim.fn.readfile(result_path), "\n"))
      vim.fn.delete(result_path); vim.fn.delete(target_path)
      if vim.env.WEAVE_TOOL_VIEWS_CAPTURE then io.write(vim.inspect(result) .. "\n") end
      local compact = function(value) return value:gsub("%s", "") end
      assert.equal("legacy stdout\n", result.stdout)
      assert.equal("legacy stderr\n", result.stderr)
      assert.is_nil(result["recorded result"])
      assert.truthy(compact(result.task):find("Shellcommand(bash)", 1, true))
      assert.truthy(result.task:find("╭", 1, true))
      assert.falsy(result.created_collapsed:find("CREATE_LAST", 1, true))
      assert.truthy(result.created_expanded:find("CREATE_LAST", 1, true))
      assert.falsy(result.created_expanded:find("Diff unavailable", 1, true))
      assert.truthy(result.unknown:find("HISTORICAL_CONTENT", 1, true))
      assert.truthy(compact(result.unknown):find("notabefore/afterdiff", 1, true))
      assert.is_true(result.render_did_not_write)
      assert.is_true(result.finished)
    end)
  end
end)
