local termdraw = require("fibrous.bench.termdraw")

describe("pinned last prompt", function()
  for _, mode in ipairs({ "button", "auto" }) do
    it("stays above the scrolling transcript in " .. mode .. " mode", function()
      local source = debug.getinfo(require("fibrous.inline.mount").split, "S").source:sub(2)
      local fibrous = vim.fn.fnamemodify(source, ":p:h:h:h:h")
      local path = vim.fn.tempname()
      local steps = {}
      for i = 1, 6 do steps[i] = { lua = "FRAME(" .. i .. ")", wait_ms = 220 } end
      termdraw.drive({
        cols = 105, rows = 24, rtp = { fibrous, vim.fn.getcwd() }, steps = steps,
        init = ([[
          local api = vim.api
          local store = require("weave.session_store"):new()
          local prefs = require("weave.view.prefs"):new()
          local panel = require("weave.view.panel").open({
            store = store, prefs = prefs, width = 68, sidebar_width = 19, content_visibility = %q,
          })
          local win = panel.transcript.winid
          local frames = {}
          local latest = "Original ask\n" .. ("wide 界界 example "):rep(60) .. "omitted ending"
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
            frames[i] = {
              header = rows, width = width, same_window = current_win == win and api.nvim_win_is_valid(win),
              topline = api.nvim_win_call(current_win, vim.fn.winsaveview).topline,
              window_start = store.state.window_start,
            }
            vim.fn.writefile({ vim.json.encode(frames) }, %q)
          end
          _G.FRAME = function(i)
            if i == 2 then
              store:append_entry({ kind = "user", text = latest })
              store:enqueue_prompt("not sent")
              for n = 1, 45 do
                store:append_entry({ kind = "agent", text = "Reply line " .. n })
              end
            elseif i == 3 then
              prefs:set("follow", false)
              api.nvim_set_current_win(win)
              vim.cmd("normal! ggzt")
            elseif i == 4 then
              api.nvim_win_set_width(panel.host_winid, 45)
            elseif i == 5 then
              store:append_entry({ kind = "user", text = "New ask" })
            elseif i == 6 then
              store:reset()
            end
            vim.defer_fn(function() capture(i) end, 90)
          end
        ]]):format(mode, path),
      })
      local frames = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      vim.fn.delete(path)
      assert.equal(6, #frames)
      assert.same({}, frames[1].header)
      assert.is_true(frames[2].topline > frames[3].topline, "the transcript actually scrolled")
      if mode == "button" then
        assert.is_true(frames[2].window_start > 1, "the original prompt is outside the transcript window")
      end
      assert.equal(2, #frames[2].header)
      assert.truthy(frames[2].header[1]:find("Last prompt: Original ask", 1, true))
      assert.truthy(frames[2].header[1]:find("界", 1, true))
      assert.truthy(vim.endswith(frames[2].header[2], "…"))
      assert.same(frames[2].header, frames[3].header)
      assert.is_true(frames[4].width < frames[3].width)
      assert.equal(2, #frames[4].header)
      assert.truthy(vim.endswith(frames[4].header[2], "…"))
      assert.falsy(table.concat(frames[4].header, " "):find("omitted ending", 1, true))
      assert.falsy(table.concat(frames[4].header, " "):find("not sent", 1, true))
      assert.truthy(frames[5].header[1]:find("Last prompt: New ask", 1, true))
      assert.same({}, frames[6].header)
      for _, frame in ipairs(frames) do
        assert.is_true(frame.same_window)
      end
    end)
  end
end)
