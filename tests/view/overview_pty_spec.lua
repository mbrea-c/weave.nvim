local termdraw = require("fibrous.bench.termdraw")

describe("overview terminal rendering", function()
  it("keeps the footer visible after updates and resize, and scrolls the full overview", function()
    local mount_src = debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2)
    local fibrous_root = vim.fn.fnamemodify(mount_src, ":p:h:h:h:h")
    local result_path = vim.fn.tempname()
    termdraw.drive({
      cols = 90, rows = 18, rtp = { fibrous_root, vim.fn.getcwd() },
      steps = {
        { lua = "FRAME(1)", wait_ms = 250 },
        { lua = "FRAME(2)", wait_ms = 250 },
        { lua = "FRAME(3)", wait_ms = 350 },
      },
      init = ([[
        local Sidebar = require("weave.view.sidebar")
        local store = require("weave.session_store"):new()
        local prefs = require("weave.view.prefs"):new()
        local panel = require("weave.view.panel").open({
          store = store, prefs = prefs, width = 60, sidebar_width = 26,
        })
        vim.api.nvim_set_current_win(panel.winid)
        local result = { footers = {} }
        local function screen_line(row, col, width)
          local line = ""
          for x = col, col + width - 1 do line = line .. vim.fn.screenstring(row, x) end
          return line
        end
        local function capture(i)
          vim.cmd("redraw")
          local origin = vim.api.nvim_win_get_position(panel.winid)
          local height = vim.api.nvim_win_get_height(panel.winid)
          local width = vim.api.nvim_win_get_width(panel.winid)
          result.footers[i] = screen_line(origin[1] + height,
            origin[2] + width - panel.sidebar_width + 1, panel.sidebar_width)
          if i == 3 then
            local popup = Sidebar.open_overview({ store = store, prefs = prefs })
            local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
            result.scrollable = #lines > vim.api.nvim_win_get_height(popup.winid)
            local row
            for n, line in ipairs(lines) do
              if line:find("Permissions", 1, true) then row = n; break end
            end
            vim.api.nvim_win_set_cursor(popup.winid, { row, 1 })
            vim.cmd("redraw")
            local pos = vim.fn.screenpos(popup.winid, row, 2)
            result.permissions = screen_line(pos.row, pos.col, #"Permissions")
            popup.unmount()
          end
          vim.fn.writefile({ vim.json.encode(result) }, %q)
        end
        _G.FRAME = function(i)
          store:set_meta({ title = "Growing session " .. i, provider = "Kiro", agent = "kiro",
            model = "model", mode = "development" })
          local plan = {}
          for n = 1, 30 do plan[n] = { content = "task " .. n, status = "pending" } end
          store:set_plan(plan, "acp")
          if i == 3 then
            vim.api.nvim_set_current_win(panel.host_winid)
            vim.cmd("aboveleft 3new")
            -- Let real WinResized events and their scheduled relayout finish.
            vim.defer_fn(function() capture(i) end, 100)
          else
            capture(i)
          end
        end
      ]]):format(result_path),
    })
    local result = vim.json.decode(table.concat(vim.fn.readfile(result_path), "\n"))
    vim.fn.delete(result_path)
    assert.equal(3, #result.footers)
    for i, footer in ipairs(result.footers) do
      local first = footer:find("[ Overview ]", 1, true)
      if not first then error("footer " .. i .. ": " .. vim.inspect(result)) end
      assert.equal(2 + math.floor((26 - 3 - 12) / 2), vim.api.nvim_strwidth(footer:sub(1, first - 1)))
    end
    assert.is_true(result.scrollable)
    assert.equal("Permissions", result.permissions)
  end)
end)
