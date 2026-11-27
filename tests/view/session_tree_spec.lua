local Registry = require("weave.registry")
local Modal = require("weave.view.session_modal")

local function pump() vim.wait(40, function() return false end, 2) end
local function add(name, parent)
  local client = { state = "connected" }
  function client:create_session(_, cb) cb({ sessionId = name }) end
  function client:cancel_session() end
  function client:cancel_turn() end
  local entry = Registry.add({ provider = name, parent_key = parent and parent.key,
    get_instance = function(_, cb) cb(client); return client end })
  entry.session:get_store():set_meta({ title = name })
  return entry
end
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end

describe("live session tree popup", function()
  local select
  before_each(function() select = vim.ui.select end)
  after_each(function() vim.ui.select = select; Registry.reset(); pump() end)

  it("renders forest preorder and collapses only the selected subtree", function()
    local a = add("root-a")
    add("root-b")
    local c = add("child-c", a)
    add("grandchild-d", c)
    pump()
    local handle = Modal.open({ on_select = function() end })
    assert.same({ bufnr = handle.bufnr, winid = handle.winid }, handle.tree)
    local content = text(handle.bufnr)
    assert.truthy(content:find("root%-a.-child%-c.-grandchild%-d.-root%-b"))
    local row, col
    for i, line in ipairs(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)) do
      local found = line:find("[-]", 1, true)
      if found then row, col = i, found - 1; break end
    end
    assert.is_not_nil(row)
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { row, col })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
    pump()
    content = text(handle.bufnr)
    assert.is_nil(content:find("child-c", 1, true))
    assert.truthy(content:find("root-b", 1, true))
    assert.truthy(content:find("[+]", 1, true))
    handle.close()
  end)

  it("keeps the tree alive while an external picker confirms subtree closure", function()
    local parent = add("parent")
    add("child", parent); pump()
    local respond, outside
    vim.ui.select = function(_, _, cb)
      respond = cb
      vim.cmd("new")
      outside = vim.api.nvim_get_current_win()
    end
    local handle = Modal.open({ on_select = function() end })
    local row = vim.fn.search("parent", "cw")
    local line = vim.api.nvim_buf_get_lines(handle.bufnr, row - 1, row, false)[1]
    vim.api.nvim_win_set_cursor(handle.winid, { row, line:find("✕", 1, true) - 1 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
    pump()
    local still_open = handle.is_open()
    if outside and vim.api.nvim_win_is_valid(outside) then vim.api.nvim_win_close(outside, true) end
    if respond then respond("Close subtree") end
    pump()
    handle.close()
    assert.is_true(still_open)
    assert.equal(0, #Registry.list())
  end)

  it("updates for background creation and permission changes without reopening", function()
    local a = add("root-a"); pump()
    local handle = Modal.open({ on_select = function() end })
    local child = add("background-child", a)
    pump()
    assert.truthy(text(handle.bufnr):find("background-child", 1, true))
    child.session:get_store():enqueue_permission({
      request = { toolCall = { title = "Approval" }, options = {} }, respond = function() end,
    })
    pump()
    assert.truthy(text(handle.bufnr):find("Approval", 1, true))
    handle.close()
  end)

  it("opens the selected session and footer in a single scrollable popup", function()
    for i = 1, 35 do add("root-" .. i) end
    pump()
    local entries = Registry.list()
    Registry.select(entries[#entries].key)
    local handle = Modal.open({ on_select = function() end })
    local focused = vim.api.nvim_get_current_win()
    local line = vim.api.nvim_get_current_line()
    local content = text(handle.bufnr)
    local height = vim.api.nvim_win_get_height(handle.winid)
    local count = vim.api.nvim_buf_line_count(handle.bufnr)
    local children = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.w[win].fibrous_anchor == handle.winid then children[#children + 1] = win end
    end
    handle.close()
    assert.equal(handle.winid, focused)
    assert.same({}, children)
    assert.truthy(line:find("root-35", 1, true))
    assert.truthy(content:find("root%-1.-root%-35.-New session.-Load saved"))
    assert.truthy(count > height)
    assert.truthy(height <= vim.o.lines - 4)
  end)
end)
