local termdraw = require("fibrous.bench.termdraw")

describe("panel colors in the TUI", function()
  it("restores the visible user marker and bubble when switching themes from the transcript", function()
    local root = vim.fn.getcwd()
    local result = vim.fn.tempname()
    termdraw.drive({
      cols = 100, rows = 32, rtp = { vim.env.FIBROUS_PATH or (root .. "/../fibrous.nvim"), root },
      init = ([[
        vim.o.termguicolors = true
        vim.cmd.colorscheme("habamax")
        local store = require("weave.session_store"):new()
        store:append_entry({ kind = "user", text = "review the change" })
        local panel = require("weave.view.panel").open({ store = store, prefs = require("weave.view.prefs"):new() })
        vim.api.nvim_set_current_win(panel.transcript.winid)
        local highlight_at = dofile(%q)
        _G.capture = function()
          local bg = vim.api.nvim_get_hl(0, { name = "WeaveUserBubble", link = false }).bg
          local marker = highlight_at(panel.transcript.bufnr, "❯")
          vim.fn.writefile({ vim.json.encode({ bubble = bg, marker = marker.bg }) }, %q)
        end
      ]]):format(root .. "/tests/view/highlight_at.lua", result),
      steps = {
        { lua = "vim.cmd.colorscheme('retrobox')", wait_ms = 100 },
        { lua = "capture()", wait_ms = 100 },
      },
    })
    local colors = vim.json.decode(vim.fn.readfile(result)[1])
    vim.fn.delete(result)
    assert.is_not_nil(colors.bubble, "the global Normal foreground should supply the missing panel foreground")
    assert.equal(colors.bubble, colors.marker)
  end)
end)
