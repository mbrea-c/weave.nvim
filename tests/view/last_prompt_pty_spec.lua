local termdraw = require("fibrous.bench.termdraw")

describe("pinned last prompt", function()
  for _, mode in ipairs({ "button", "auto" }) do
    it("tracks the reading position through a long prompt in " .. mode .. " mode", function()
      local source = debug.getinfo(require("fibrous.inline.mount").split, "S").source:sub(2)
      local fibrous = vim.fn.fnamemodify(source, ":p:h:h:h:h")
      local path = vim.fn.tempname()
      -- Each checkpoint names the actual top row and the prompt (if any)
      -- that should be painted outside the transcript at that position.
      local framespec = {
        { at = "First ask" },
        { at = "Between prompts", pin = "First ask" },
        { at = "Second ask", offset = -2, pin = "First ask" }, -- gap before bubble
        { at = "Second ask", offset = -1 }, -- top border
        { at = "Second ask" },
        { at = "Prompt detail" },
        { at = "Last prompt line", offset = 1 }, -- bottom border
        { at = "Last prompt line", offset = 2, cursor_at_bottom = true, pin = "Second ask" }, -- first row outside
        { at = "After prompt", pin = "Second ask" },
        { action = "narrow", anchor = "After prompt", pin = "Second ask" },
        { at = "Last prompt line" },
        { at = "Between prompts", pin = "First ask" },
        { action = "append", anchor = "Between prompts", pin = "First ask" },
        { at = "First ask" },
        { action = "reset", anchor = "no messages yet" },
      }
      local steps = {}
      for i = 1, #framespec do
        steps[i] = { lua = ("FRAME(%d)"):format(i), wait_ms = 180 }
      end
      termdraw.drive({
        cols = 105, rows = 24, rtp = { fibrous, vim.fn.getcwd() }, steps = steps,
        init = ([[
          local api = vim.api
          local store = require("weave.session_store"):new()
          local prefs = require("weave.view.prefs"):new()
          prefs:set("follow", false)
          prefs:set("conceal_markdown", false)
          local panel = require("weave.view.panel").open({
            store = store, prefs = prefs, width = 68, sidebar_width = 19, content_visibility = %q,
          })
          local win, buf = panel.transcript.winid, panel.transcript.bufnr
          local frames, requested_row = {}, nil
          local prompt = "Second ask " .. ("wide 界界 example "):rep(12)
          store:append_entry({ kind = "user", text = "First ask" })
          store:append_entry({ kind = "agent", text = "Between prompts\n" .. ("Middle reply\n"):rep(4) })
          store:append_entry({ kind = "user", text = prompt .. "\n" .. ("Prompt detail\n"):rep(28) .. "Last prompt line" }, prompt)
          store:append_entry({ kind = "agent", text = "After prompt\n" .. ("Later reply\n"):rep(24) })
          store:enqueue_prompt("not sent")
          local function capture(i)
            vim.cmd("redraw")
            local pos = api.nvim_win_get_position(panel.host_winid)
            local current_win = panel.transcript.winid
            local width = api.nvim_win_get_width(current_win)
            local header_rows = api.nvim_win_get_position(current_win)[1] - pos[1]
            local rows = {}
            for y = pos[1] + 1, pos[1] + header_rows do
              local cells = {}
              for x = pos[2] + 1, pos[2] + width do cells[#cells + 1] = vim.fn.screenstring(y, x) end
              rows[#rows + 1] = vim.trim(table.concat(cells))
            end
            local top = api.nvim_win_call(current_win, vim.fn.winsaveview).topline
            frames[i] = { header = rows, top = top, line = api.nvim_buf_get_lines(buf, top - 1, top, false)[1],
              width = width, requested_row = requested_row, same_window = current_win == win and api.nvim_win_is_valid(win) }
            vim.fn.writefile({ vim.json.encode(frames) }, %q)
          end
          local function go(target, delta, cursor_at_bottom)
            for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
              if line:find(target, 1, true) then
                local row = i + (delta or 0)
                requested_row = row
                api.nvim_set_current_win(win)
                local cursor = cursor_at_bottom and row + api.nvim_win_get_height(win) - 1 or row
                vim.fn.winrestview({ topline = row, lnum = cursor, col = 0 })
                vim.cmd("redraw")
                return
              end
            end
            error("missing transcript row: " .. target)
          end
          local specs = %s
          _G.FRAME = function(i)
            local spec = specs[i]
            requested_row = nil
            if spec.at then go(spec.at, spec.offset, spec.cursor_at_bottom)
            elseif spec.action == "narrow" then api.nvim_win_set_width(panel.host_winid, 45)
            elseif spec.action == "append" then store:append_entry({ kind = "user", text = "A new ask" })
            elseif spec.action == "reset" then store:reset() end
            vim.defer_fn(function() capture(i) end, 80)
          end
        ]]):format(mode, path, vim.inspect(framespec)),
      })
      local frames = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      vim.fn.delete(path)
      assert.equal(#framespec, #frames)
      for i, frame in ipairs(frames) do
        local spec = framespec[i]
        local info = ("frame %d (%s)"):format(i, spec.at or spec.action)
        assert.is_true(frame.same_window, info)
        if spec.pin then
          assert.equal(2, #frame.header, info)
          assert.truthy(frame.header[1]:find("Last prompt: " .. spec.pin, 1, true), info)
        else
          assert.same({}, frame.header, info)
        end
        if frame.requested_row then assert.equal(frame.requested_row, frame.top, info) end
        if spec.anchor then assert.truthy(frame.line:find(spec.anchor, 1, true), info .. ": " .. frame.line) end
      end
      assert.is_true(frames[10].width < frames[9].width)
      assert.truthy(vim.endswith(frames[9].header[2], "…"))
      assert.truthy(vim.endswith(frames[10].header[2], "…"))
    end)
  end
end)
