local termdraw = require("fibrous.bench.termdraw")

describe("prompt feedback in the terminal", function()
  it("moves the border count onto its row and distinguishes both steer keys", function()
    local source = debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2)
    local root = vim.fn.fnamemodify(source, ":p:h:h:h:h")
    local path = vim.fn.tempname()
    termdraw.drive({
      cols = 80, rows = 20, rtp = { root, vim.fn.getcwd() },
      steps = { { lua = "FRAME(1)", wait_ms = 200 }, { lua = "FRAME(2)", wait_ms = 200 },
        { lua = "FRAME(3)", wait_ms = 200 }, { lua = "FRAME(4)", wait_ms = 200 } },
      init = ([[
        local mount = require("fibrous.inline.mount")
        local client = { state = "connected", cancels = 0 }
        function client:create_session(handlers, cb) self.handlers = handlers; cb({ sessionId = "pty" }) end
        function client:send_prompt() end
        function client:cancel_turn() self.cancels = self.cancels + 1 end
        local s = require("weave.session"):new({ get_instance = function(_, cb) cb(client); return client end })
        s:start()
        local result, window = {}, nil
        local function send(text, key)
          vim.api.nvim_set_current_win(window)
          vim.cmd("stopinsert")
          vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
        end
        _G.FRAME = function(i)
          if i == 1 then
            s:submit("working")
            client.handlers.on_tool_call({ tool_call_id = "active", status = "pending" })
            require("weave.feedback_store").add({ bufnr = vim.api.nvim_get_current_buf(), body = "my note", range = { lnum = 1 } })
            local props = s:view_handlers()
            props.store, props.session = s:get_store(), s
            local view = mount.floating(require("weave.view.prompt").Prompt, props, { width = 62, height = 12 })
            for _, win in ipairs(vim.api.nvim_list_wins()) do
              if vim.w[win].fibrous_anchor == view.winid then window = win end
            end
          elseif i == 2 then send("normal row", "<C-s>")
          elseif i == 3 then send("safe row", "<C-x>")
          else send("urgent row", "<C-S-x>") end
          vim.defer_fn(function()
            vim.cmd("redraw")
            local lines = {}
            for y = 1, vim.o.lines do
              local line = ""
              for x = 1, vim.o.columns do line = line .. vim.fn.screenstring(y, x) end
              lines[#lines + 1] = line
            end
            result[i] = { lines = lines, cancels = client.cancels, queued = s:get_store():queued_texts() }
            vim.fn.writefile({ vim.json.encode(result) }, %q)
          end, 50)
        end
      ]]):format(path),
    })
    local frames = vim.json.decode(table.concat(vim.fn.readfile(path)))
    vim.fn.delete(path)
    assert.truthy(table.concat(frames[1].lines, "\n"):match("╰[^\n]+1 comment[^\n]*╯"))
    local queued = table.concat(frames[2].lines, "\n")
    assert.truthy(queued:match("normal row[^\n]+1 comment"))
    assert.is_nil(queued:match("╰[^\n]+1 comment"))
    assert.equal(0, frames[3].cancels)
    assert.same({ "safe row", "normal row" }, frames[3].queued)
    assert.equal(1, frames[4].cancels)
    assert.same({ "safe row", "urgent row", "normal row" }, frames[4].queued)
  end)
end)
