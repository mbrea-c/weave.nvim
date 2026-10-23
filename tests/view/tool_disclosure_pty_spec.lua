local termdraw = require("fibrous.bench.termdraw")

describe("tool disclosure terminal interaction", function()
  it("routes real mouse clicks only to [+]/[-] inside the transcript container", function()
    local source = debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2)
    local fibrous_root = vim.fn.fnamemodify(source, ":p:h:h:h:h")
    local result_path = vim.fn.tempname()
    local steps = {}
    for i = 1, 6 do steps[i] = { lua = "FRAME(" .. i .. ")", wait_ms = 250 } end
    termdraw.drive({
      cols = 90, rows = 26, rtp = { fibrous_root, vim.fn.getcwd() }, steps = steps,
      init = ([[
        vim.o.mouse = "a"
        vim.o.mousetime = 0 -- Scripted clicks are independent, not native double-clicks.
        local store = require("weave.session_store"):new()
        local prefs = require("weave.view.prefs"):new()
        prefs:set("follow", false)
        store:upsert_tool_call({
          tool_call_id = "t1", kind = "execute", status = "completed",
          argument = "list " .. ("a-long-argument-"):rep(7) .. "tail-marker", input = { command = "ls" },
        })
        local panel = require("weave.view.panel").open({
          store = store, prefs = prefs, width = 80, sidebar_width = 22,
        })
        local win, buf = panel.transcript.winid, panel.transcript.bufnr
        vim.api.nvim_set_current_win(win)
        vim.cmd("stopinsert")
        local result = {}
        local function content() return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
        local function capture(i)
          vim.cmd("redraw")
          local line = content()[1]
          local col = line:find(store.state.expanded.t1 and "[-]" or "[+]", 1, true)
          local pos = vim.fn.screenpos(win, 1, col)
          local shown = ""
          for x = pos.col, pos.col + 2 do shown = shown .. vim.fn.screenstring(pos.row, x) end
          result[i] = { expanded = store.state.expanded.t1 == true, shown = shown,
            mouse = vim.fn.getmousepos(), cursor = vim.api.nvim_win_get_cursor(win), current = vim.api.nvim_get_current_win() }
          vim.fn.writefile({ vim.json.encode(result) }, %q)
        end
        local function click(row, col)
          vim.cmd("redraw")
          local pos = vim.fn.screenpos(win, row, col + 1)
          vim.api.nvim_input_mouse("move", "", "", 0, pos.row - 1, pos.col - 1)
          vim.api.nvim_input_mouse("left", "press", "", 0, pos.row - 1, pos.col - 1)
          vim.api.nvim_input_mouse("left", "release", "", 0, pos.row - 1, pos.col - 1)
        end
        _G.FRAME = function(i)
          local header = content()[1]
          if i == 2 then click(1, header:find("[execute]", 1, true) - 1)
          elseif i == 3 then click(1, header:find("[+]", 1, true) - 1)
          elseif i == 4 then click(2, 8) -- the wrapped title, not the one-row control
          elseif i == 5 then click(1, header:find("[-]", 1, true) + 1) -- closing bracket
          elseif i == 6 then
            vim.api.nvim_set_current_win(win)
            vim.api.nvim_win_set_cursor(win, { 1, header:find("[execute]", 1, true) - 1 })
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab><CR>", true, false, true), "xt", false)
          end
          vim.defer_fn(function() capture(i) end, 60)
        end
      ]]):format(result_path),
    })
    local result = vim.json.decode(table.concat(vim.fn.readfile(result_path), "\n"))
    vim.fn.delete(result_path)
    assert.equal(6, #result)
    for i, expanded in ipairs({ false, false, true, true, false, true }) do
      if expanded ~= result[i].expanded then error("frame " .. i .. ": " .. vim.inspect(result)) end
      assert.equal(expanded and "[-]" or "[+]", result[i].shown)
    end
  end)
end)
