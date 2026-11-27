local termdraw = require("fibrous.bench.termdraw")

describe("session tree terminal rendering", function()
  for _, size in ipairs({ { 100, 18 }, { 36, 14 } }) do
    it(("scrolls sessions and actions in one window at %dx%d"):format(size[1], size[2]), function()
      local source = debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2)
      local fibrous = vim.fn.fnamemodify(source, ":p:h:h:h:h")
      local path = vim.fn.tempname()
      termdraw.drive({
        cols = size[1], rows = size[2], rtp = { fibrous, vim.fn.getcwd() },
        steps = {
          { lua = "FRAME(1)", wait_ms = 250 },
          { lua = "FRAME(2)", wait_ms = 250 },
          { lua = "FRAME(3)", wait_ms = 250 },
        },
        init = ([[
          local Registry = require("weave.registry")
          local function add(name, parent)
            local client = { state = "connected" }
            function client:create_session(_, cb) cb({ sessionId = name }) end
            function client:cancel_session() end
            local entry = Registry.add({ provider = name, parent_key = parent and parent.key,
              get_instance = function(_, cb) cb(client); return client end })
            entry.session:get_store():set_meta({ title = name })
            return entry
          end
          local root = add("parent")
          Registry.select(root.key)
          for i = 1, 7 do add("child-" .. i, root) end
          for i = 1, 28 do add("other-" .. i) end
          local popup, result
          result = {}
          local function screen_line(row)
            local out = ""
            for col = 1, vim.o.columns do out = out .. vim.fn.screenstring(row, col) end
            return out
          end
          _G.FRAME = function(i)
            if i == 1 then
              popup = require("weave.view.session_modal").open({
                on_select = function() end, on_details = function() end,
              })
            elseif i == 2 then
              vim.cmd("normal! G")
            elseif i == 3 then
              vim.cmd("normal! gg")
              vim.fn.search("\\V[-]", "W")
              vim.api.nvim_exec_autocmds("CursorMoved", { buffer = popup.bufnr })
              vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
            end
            vim.defer_fn(function()
              vim.cmd("redraw")
              local footer, shown = "", {}
              for row = 1, vim.o.lines do
                local line = screen_line(row)
                if line:find("a  New", 1, true) then footer = line end
                shown[#shown + 1] = line
              end
              result[i] = { footer = footer, screen = table.concat(shown, "\n"),
                tree = table.concat(vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false), "\n") }
              vim.fn.writefile({ vim.json.encode(result) }, %q)
            end, 60)
          end
        ]]):format(path),
      })
      local result = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      vim.fn.delete(path)
      if vim.env.WEAVE_SESSION_PICKER_CAPTURE then
        for _, frame in ipairs(result) do io.write("\n" .. frame.screen .. "\n") end
      end
      assert.equal("", result[1].footer)
      assert.truthy(result[2].footer:find("a  New", 1, true))
      assert.truthy(result[2].footer:find("o  Load", 1, true))
      assert.equal(size[1] >= 100, result[2].footer:find("q close", 1, true) ~= nil)
      assert.truthy(result[1].screen:find("● [-] parent", 1, true))
      assert.truthy(result[1].screen:find("├─ child-1", 1, true))
      assert.truthy(result[1].screen:find("ⓘ ✕", 1, true))
      assert.equal(size[1] >= 100, result[1].screen:find("Provider", 1, true) ~= nil)
      assert.truthy(result[2].screen:find("other-28", 1, true))
      assert.is_nil(result[3].tree:find("child-1", 1, true))
      assert.truthy(result[3].screen:find("[+]", 1, true))
    end)
  end
end)
