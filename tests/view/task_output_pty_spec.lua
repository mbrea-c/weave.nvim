local termdraw = require("fibrous.bench.termdraw")

describe("task stream panes in a real terminal", function()
  for _, wrapped in ipairs({ false, true }) do
    it("preserves a mouse-wheel-scrolled " .. (wrapped and "wrapped" or "multiline") .. " view", function()
      local source = debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2)
      local fibrous_root = vim.fn.fnamemodify(source, ":p:h:h:h:h")
      local result_path = vim.fn.tempname()
      termdraw.drive({
        cols = 80, rows = 28, rtp = { fibrous_root, vim.fn.getcwd() },
        steps = { { lua = "FRAME(1)", wait_ms = 250 }, { lua = "FRAME(2)", wait_ms = 250 },
          { lua = "FRAME(3)", wait_ms = 250 }, { lua = "FRAME(4)", wait_ms = 250 } },
        init = ([[
          vim.o.mouse = "a"
          local Output = require("weave.view.task_output")
          local chunks, refresh = { %s and ("wrapped output "):rep(100) or ("history\n"):rep(100) }
          local function Root(ctx)
            local version = ctx.use_state(0)
            refresh = function() version.set(version.get() + 1) end
            return { comp = Output.Pane, props = { chunks = chunks, stream = "stdout" } }
          end
          local app = require("fibrous.inline.mount").floating(Root, {}, { width = 70, height = 20 })
          local result, win = {}
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.b[buf].weave_task_stream == "stdout" then win = vim.fn.win_findbuf(buf)[1] end
          end
          local function view() return vim.api.nvim_win_call(win, vim.fn.winsaveview) end
          _G.FRAME = function(i)
            if i == 1 then result.initial = view()
            elseif i == 2 then
              local pos = vim.api.nvim_win_get_position(win)
              vim.api.nvim_input_mouse("wheel", "up", "", 0, pos[1] + 2, pos[2] + 2)
              vim.api.nvim_input_mouse("wheel", "up", "", 0, pos[1] + 2, pos[2] + 2)
            elseif i == 3 then
              result.before, result.focus = view(), vim.api.nvim_get_current_win()
              chunks[2] = %s and ("more output "):rep(20) or ("new output\n"):rep(10)
              refresh()
            elseif i == 4 then
              result.after, result.focus_after = view(), vim.api.nvim_get_current_win()
              app.unmount()
              result.finished = true
            end
            vim.fn.writefile({ vim.json.encode(result) }, %q)
          end
        ]]):format(tostring(wrapped), tostring(wrapped), result_path),
      })
      local result = vim.json.decode(table.concat(vim.fn.readfile(result_path), "\n"))
      vim.fn.delete(result_path)
      if vim.env.WEAVE_TOOL_VIEWS_CAPTURE then io.write(vim.inspect(result) .. "\n") end
      assert.is_true(result.finished)
      assert.is_true(result.before.topline < result.initial.topline
        or result.before.topline == result.initial.topline and result.before.skipcol < result.initial.skipcol)
      assert.equal(result.before.topline, result.after.topline)
      assert.equal(result.before.skipcol, result.after.skipcol)
      assert.equal(result.focus, result.focus_after)
    end)
  end

  for _, size in ipairs({ { 90, 40 }, { 42, 28 } }) do
    it(("follows each stream independently and preserves focus at %dx%d"):format(size[1], size[2]), function()
      local source = debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2)
      local fibrous_root = vim.fn.fnamemodify(source, ":p:h:h:h:h")
      local result_path, steps = vim.fn.tempname(), {}
      for i = 1, 12 do steps[i] = { lua = "FRAME(" .. i .. ")", wait_ms = 250 } end
      termdraw.drive({
        cols = size[1], rows = size[2], rtp = { fibrous_root, vim.fn.getcwd() }, steps = steps,
        init = ([[
          vim.o.mouse = "a"
          vim.api.nvim_set_hl(0, "Normal", { fg = 0xeeeeee, bg = 0x303030 })
          vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0xeeeeee, bg = 0x303030 })
          local ui, Output = require("fibrous.inline.components"), require("weave.view.task_output")
          local stdout, stderr, show = {}, {}, true
          local root, refresh
          local function Root(ctx)
            local version = ctx.use_state(0)
            refresh = function() version.set(version.get() + 1) end
            return { comp = ui.col, props = {}, children = {
              { comp = ui.container, props = { grow = 1, scroll_x = false,
                on_create = function(buf, win) root = { buf = buf, win = win } end }, children = {
                  { comp = ui.label, props = { text = "Command and task status" } },
                  show and { comp = ui.col, props = { gap = 1 }, children = {
                    { comp = Output.Pane, key = "stdout", props = { stream = "stdout", chunks = stdout } },
                    { comp = Output.Pane, key = "stderr", props = { stream = "stderr", chunks = stderr } },
                  } } or nil,
                  { comp = ui.text, props = { text = ("later transcript entry\n"):rep(40) } },
                } },
              { comp = ui.label, props = { text = "OUTER FOOTER" } },
            } }
          end
          local app = require("fibrous.inline.mount").floating(Root, {},
            { width = vim.o.columns - 4, height = vim.o.lines - 4, mode = "fixed" })
          local result, old_buffers = {}, {}
          local function streams()
            local found = {}
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].weave_task_stream then
                local wins = vim.fn.win_findbuf(buf)
                found[vim.b[buf].weave_task_stream] = { buf = buf, win = wins[1] }
              end
            end
            return found
          end
          local function view(stream)
            return vim.api.nvim_win_call(stream.win, vim.fn.winsaveview)
          end
          local function feed(keys)
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
          end
          local function enter(name)
            vim.api.nvim_set_current_win(root.win)
            for row, text in ipairs(vim.api.nvim_buf_get_lines(root.buf, 0, -1, false)) do
              if text:find(name, 1, true) then
                vim.api.nvim_win_set_cursor(root.win, { row + 1, 3 })
                vim.cmd("normal! zt")
                vim.api.nvim_exec_autocmds("CursorMoved", { buffer = root.buf })
                vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(root.win) })
                vim.cmd("redraw")
                feed("<CR>")
                return
              end
            end
            error("missing stream " .. name)
          end
          local function add(first, last, errors)
            for n = first, last do
              stdout[#stdout + 1] = "out-" .. n .. "\n"
              if errors then stderr[#stderr + 1] = "err-" .. n .. "\n" end
            end
            refresh()
          end
          _G.FRAME = function(i)
            local panes = streams()
            if i == 1 then
              result.empty = next(panes) == nil
              stdout[1] = "out-1\nout-2\n"
              refresh()
            elseif i == 2 then
              result.only_stdout = panes.stdout ~= nil and panes.stderr == nil
              result.short_height = vim.api.nvim_win_get_height(panes.stdout.win)
              add(3, 100, true)
            elseif i == 3 then
              old_buffers = { panes.stdout.buf, panes.stderr.buf }
              result.distinct = panes.stdout.buf ~= panes.stderr.buf
              result.stdout_history = table.concat(vim.api.nvim_buf_get_lines(panes.stdout.buf, 0, -1, false), "\n")
              result.max_height = vim.api.nvim_win_get_height(panes.stdout.win)
              result.background = vim.wo[panes.stdout.win].winhighlight
              enter("stdout")
              result.entered_stdout = vim.api.nvim_get_current_buf() == panes.stdout.buf
              vim.cmd("normal! ggzt")
            elseif i == 4 then
              result.paused_before = view(panes.stdout)
              add(101, 110, true)
            elseif i == 5 then
              result.paused_after = view(panes.stdout)
              result.focus_after_output = vim.api.nvim_get_current_buf() == panes.stdout.buf
              feed("<Esc>")
              result.escaped = vim.api.nvim_get_current_win() == root.win
              enter("stderr")
            elseif i == 6 then
              result.stderr_entered = vim.api.nvim_get_current_buf() == panes.stderr.buf
              result.stderr_followed = vim.fn.getwininfo(panes.stderr.win)[1].botline >= 108
              feed("<C-u>")
              result.page_stays_inside = vim.api.nvim_get_current_buf() == panes.stderr.buf
              result.stderr_paused = view(panes.stderr)
              feed("<Esc>")
              enter("stdout")
              result.stdout_reentered = vim.api.nvim_get_current_buf() == panes.stdout.buf
              vim.cmd("normal! Gzb")
            elseif i == 7 then add(111, 120, true)
            elseif i == 8 then
              result.stdout_resumed = vim.api.nvim_win_get_cursor(panes.stdout.win)[1] >= 120
              result.stderr_after = view(panes.stderr)
              result.focus_preserved = vim.api.nvim_get_current_buf() == panes.stdout.buf
              vim.api.nvim_set_current_win(root.win)
              vim.cmd("normal! Gzb")
            elseif i == 9 then
              result.offscreen_hidden = vim.api.nvim_win_get_config(panes.stdout.win).hide
                and vim.api.nvim_win_get_config(panes.stderr.win).hide
              show = false
              refresh()
            elseif i == 10 then
              result.collapsed_empty = next(panes) == nil
              result.old_buffers_deleted = not vim.api.nvim_buf_is_valid(old_buffers[1])
                and not vim.api.nvim_buf_is_valid(old_buffers[2])
              show = true
              refresh()
            elseif i == 11 then
              result.restored_history = vim.api.nvim_buf_line_count(panes.stdout.buf) == 121
              vim.api.nvim_set_current_win(root.win)
              vim.cmd("normal! ggzt")
            elseif i == 12 then
              vim.cmd("redraw")
              result.rounded = table.concat(vim.api.nvim_buf_get_lines(root.buf, 0, -1, false), "\n"):find("╭", 1, true) ~= nil
              app.unmount()
              result.cleaned_up = next(streams()) == nil
              result.finished = true
            end
            vim.fn.writefile({ vim.json.encode(result) }, %q)
          end
        ]]):format(result_path),
      })
      local result = vim.json.decode(table.concat(vim.fn.readfile(result_path), "\n"))
      vim.fn.delete(result_path)
      if vim.env.WEAVE_TOOL_VIEWS_CAPTURE then io.write(vim.inspect(result) .. "\n") end
      for _, name in ipairs({ "empty", "only_stdout", "distinct", "entered_stdout", "focus_after_output",
        "escaped", "stderr_entered", "stderr_followed", "page_stays_inside", "stdout_resumed",
        "focus_preserved", "offscreen_hidden", "collapsed_empty", "old_buffers_deleted",
        "restored_history", "rounded", "cleaned_up", "finished" }) do
        if result[name] ~= true then error(name .. ": " .. vim.inspect(result)) end
      end
      assert.is_true(result.short_height <= 3)
      assert.is_true(result.max_height <= 10)
      assert.truthy(result.background:find("NormalFloat:WeaveTaskOutput", 1, true))
      assert.truthy(result.stdout_history:find("out-1\nout-2\n", 1, true))
      assert.truthy(result.stdout_history:find("out-100", 1, true))
      assert.equal(result.paused_before.topline, result.paused_after.topline)
      assert.equal(result.paused_before.lnum, result.paused_after.lnum)
      assert.equal(result.stderr_paused.topline, result.stderr_after.topline)
    end)
  end
end)
