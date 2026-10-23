local termdraw = require("fibrous.bench.termdraw")

describe("session defaults terminal integration", function()
  it("redraws applied defaults and late config fields in an open details window", function()
    local source = debug.getinfo(require("fibrous.inline.mount").floating, "S").source:sub(2)
    local fibrous_root = vim.fn.fnamemodify(source, ":p:h:h:h:h")
    local result_path = vim.fn.tempname()
    local steps = {}
    for i = 1, 4 do steps[i] = { lua = "FRAME(" .. i .. ")", wait_ms = 250 } end
    termdraw.drive({
      cols = 90, rows = 28, rtp = { fibrous_root, vim.fn.getcwd() }, steps = steps,
      init = ([[
        local Config = require("weave.config")
        Config.acp_providers["defaults-pty"] = { session_defaults = { model = "m2" } }
        local client = { state = "connected", requests = {} }
        local function model(value)
          return { id = "model", category = "model", name = "Model", currentValue = value,
            options = { { value = "m1", name = "One" }, { value = "m2", name = "Two" },
              { value = "m3", name = "Three" } } }
        end
        function client:create_session(handlers, cb)
          self.handlers = handlers
          cb({ sessionId = "s1", configOptions = { model("m1") } })
        end
        function client:set_config_option(_sid, key, value, cb)
          self.requests[#self.requests + 1] = { key = key, value = value, cb = cb }
        end
        function client:cancel_session() end
        local session = require("weave.session"):new({ provider = "defaults-pty", get_instance = function(_, cb)
          cb(client)
          return client
        end })
        session:start()
        local details, result = nil, {}
        local function inputs()
          local out = {}
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.w[win].fibrous_anchor == details.winid and vim.api.nvim_win_get_config(win).focusable ~= false then
              local buf = vim.api.nvim_win_get_buf(win)
              local value = vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]
              out[value] = win
            end
          end
          return out
        end
        local function capture(i)
          vim.cmd("redraw")
          local values, shown = inputs(), {}, {}
          for value, win in pairs(values) do
            -- Focused inputs are native floats; resting fields are mirrored
            -- into the details canvas and their native floats are hidden.
            local pos = not vim.api.nvim_win_get_config(win).hide and vim.fn.screenpos(win, 1, 1) or nil
            if not pos then
              for row, content in ipairs(vim.api.nvim_buf_get_lines(details.bufnr, 0, -1, false)) do
                local col = content:find(value, 1, true)
                if col then pos = vim.fn.screenpos(details.winid, row, col); break end
              end
            end
            assert(pos, "value missing from details canvas: " .. value)
            local line = ""
            for x = pos.col, pos.col + #value - 1 do line = line .. vim.fn.screenstring(pos.row, x) end
            shown[value] = line
          end
          local requests = {}
          for _, req in ipairs(client.requests) do requests[#requests + 1] = { req.key, req.value } end
          result[i] = { shown = shown, requests = requests }
          vim.fn.writefile({ vim.json.encode(result) }, %q)
        end
        _G.FRAME = function(i)
          if i == 1 then
            details = require("weave.view.session_details").open({ session = session })
            vim.api.nvim_set_current_win(inputs()["One"])
            vim.cmd("stopinsert")
          elseif i == 2 then
            client.requests[1].cb({})
          elseif i == 3 then
            client.handlers.on_session_update({ sessionUpdate = "config_option_update", configOptions = {
              model("m2"), { id = "late", name = "Late field", currentValue = "yes",
                options = { { value = "yes", name = "Yes" }, { value = "no", name = "No" } } },
            } })
          elseif i == 4 then
            vim.api.nvim_set_current_win(inputs()["Two"])
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-n><CR>", true, false, true), "xt", false)
            client.requests[2].cb({})
          end
          vim.defer_fn(function() capture(i) end, 60)
        end
      ]]):format(result_path),
    })
    local result = vim.json.decode(table.concat(vim.fn.readfile(result_path), "\n"))
    vim.fn.delete(result_path)
    assert.equal(4, #result)
    assert.equal("One", result[1].shown.One)
    assert.equal("Two", result[2].shown.Two)
    assert.equal("Yes", result[3].shown.Yes)
    assert.equal("Two", result[3].shown.Two)
    assert.equal("Three", result[4].shown.Three)
    assert.same({ { "model", "m2" }, { "model", "m3" } }, result[4].requests)
  end)
end)
