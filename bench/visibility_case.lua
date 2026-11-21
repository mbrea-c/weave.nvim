-- One fresh interactive Neovim per sample. Run via visibility_compare.py.
vim.opt.runtimepath:prepend(vim.env.FIBROUS_PATH)
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api = vim.api
local mode, n = vim.env.BENCH_MODE, assert(tonumber(vim.env.BENCH_N))
local result = {mode=mode, entries=n, samples={}, checks={}, memory_kib={}}
local loop = vim.uv
local function ram(field)
  local file = assert(io.open("/proc/self/status"))
  local value = file:read("*a"):match(field..":%s+(%d+)")
  file:close()
  return tonumber(value)
end

local function marker(i) return ("MSG%06d"):format(i) end
local prose = "Streaming **markdown** with a [link](https://example.org) and inline `code`. "
local function seed()
  local s = require("weave.session_store"):new()
  local records, history = s.state, s:transcript()
  for i=1,n do
    local m, id = i%8, marker(i)
    local entry, tool
    if m == 3 then
      tool = {tool_call_id=id, kind="execute", argument=id, title=id, status="completed"}
      records.tool_calls[id] = tool
      table.insert(records.tool_call_order, id)
      entry = {kind="tool_call",tool_call_id=id}
    elseif m == 2 then entry = {kind="thought",text=id.." "..prose}
    elseif m == 4 or m == 1 then entry = {kind="user",text=id.." Review these changes."}
    else
      local text = id.." "..prose:rep(m == 6 and 8 or 2)
      if m == 6 then text = text.."\n\n```rust\nfn main() {}\n```" end
      entry = {kind="agent",text=text}
    end
    records.entries[i] = entry
    history:append(entry,tool)
  end
  s:follow_window()
  return s
end

local function main()
  local Panel, Prefs = require("weave.view.panel"), require("weave.view.prefs")
  local s, prefs = seed(), Prefs:new()
  prefs:set("follow",true)
  prefs:set("show_thoughts",true)
  prefs:set("conceal_markdown",true)
  collectgarbage("collect")
  result.memory_kib.seeded = ram("VmRSS")
  local p, buf, win
  local function lines(a,b) return api.nvim_buf_get_lines(buf,a,b,false) end
  local function last() return api.nvim_buf_line_count(buf) end
  local function show(row)
    api.nvim_win_call(win,function()
      api.nvim_win_set_cursor(win,{row,0})
      vim.cmd("normal! zt")
    end)
  end
  local function visible()
    local view = api.nvim_win_call(win,vim.fn.winsaveview)
    return table.concat(lines(view.topline-1,math.min(last(),view.topline+api.nvim_win_get_height(win)-1)),"\n")
  end
  -- Yield back to the TUI between frames so native scroll/resize events and
  -- their scheduled renders actually execute. No fixed sleep per operation.
  local function frame()
    vim.cmd("redraw")
    coroutine.yield()
  end
  local function settle()
    for _=1,3 do frame() end
    vim.cmd("redraw")
  end
  local trace=assert(io.open(vim.env.BENCH_TTY,"w"))
  local function tag(name, phase)
    trace:write("\27]777;weavebench;"..name..";"..phase.."\7")
    assert(trace:flush())
  end
  local function time(name, fn, check)
    tag(name,"begin")
    local start=loop.hrtime()
    fn()
    settle()
    local samples=result.samples[name] or {}
    samples[#samples+1]=(loop.hrtime()-start)/1e6
    tag(name,"end")
    result.samples[name]=samples
    if check then check() end
  end
  local function must_see(i)
    assert(visible():find(marker(i),1,true), ("missing %s in viewport %s"):format(marker(i),visible():sub(1,400)))
  end
  time("mount",function()
    p=Panel.open({store=s,prefs=prefs,content_visibility=mode=="auto" and "auto" or nil,width=82,sidebar_width=18})
    buf,win=p.transcript.bufnr,p.transcript.winid
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win,{last(),0})
  end,function() must_see(n) end)
  result.memory_kib.mounted=ram("VmRSS")
  result.buffer_lines=last()
  result.view={height=api.nvim_win_get_height(win),width=api.nvim_win_get_width(win)}
  if vim.env.BENCH_HISTORY_RESIZE == "1" then
    -- Put the target near the beginning of the revealed window. Sequence
    -- numbers congruent to 6 are the fixture's long Markdown replies.
    local reveal_pages = tonumber(vim.env.BENCH_REVEAL_PAGES)
    local sequence = 1006
    local reveal_start
    if reveal_pages then
      local window = require("weave.session_store").WINDOW
      reveal_start = math.max(1, n - (reveal_pages + 1) * window + 1)
      sequence = reveal_start + (6 - reveal_start) % 8
    end
    prefs:set("follow", false)
    s:reveal_entry(sequence)
    settle()

    local function locate(sequence_to_find)
      local first, stop = 0, last()
      if reveal_pages then stop = math.min(stop, 512) end
      if p.visibility then
        first = p.visibility:offset(sequence_to_find - 1)
        stop = math.min(first + 32, last())
      end
      for index, line in ipairs(lines(first, stop)) do
        if line:find(marker(sequence_to_find), 1, true) then return first + index end
      end
      error("could not locate " .. marker(sequence_to_find))
    end

    local function pin()
      show(locate(sequence) + 2)
      settle()
    end

    local function item_at(row)
      local window = lines(math.max(0, row - 64), row)
      for index = #window, 1, -1 do
        local item = window[index]:match("MSG(%d%d%d%d%d%d)")
        if item then return tonumber(item) end
      end
    end

    local observing, exposed_placeholder = false, false
    local observer = api.nvim_create_namespace("weave-bench-resize-frames")
    api.nvim_set_decoration_provider(observer, { on_win = function(_, id, buffer, top)
      if observing and id == win and buffer == buf then
        local stop = math.min(last(), top + api.nvim_win_get_height(win))
        for _, line in ipairs(lines(top, stop)) do
          if line == "" then exposed_placeholder = true end
        end
      end
    end })

    local function resize_history(label)
      local checks = { cursor_misses = 0, top_misses = 0, partial_frames = 0, settled_placeholders = 0 }
      result.checks[label] = checks
      local digests = {}
      result.checks[label .. "_text_digests"] = digests
      pin()
      local initial = api.nvim_win_call(win, vim.fn.winsaveview)
      assert(item_at(initial.lnum) == sequence and item_at(initial.topline) == sequence)
      local widths = reveal_pages and {58, 100, 69, 82} or {58, 100, 69, 82, 58, 82, 100, 58, 69, 82}
      for _, width in ipairs(widths) do
        exposed_placeholder = false
        observing = true
        time(label, function() api.nvim_win_set_width(p.host_winid, width) end)
        observing = false
        assert(api.nvim_win_get_width(win) == width - 18, "transcript width did not change")
        local view = api.nvim_win_call(win, vim.fn.winsaveview)
        if item_at(view.lnum) ~= sequence then checks.cursor_misses = checks.cursor_misses + 1 end
        if item_at(view.topline) ~= sequence then checks.top_misses = checks.top_misses + 1 end
        if exposed_placeholder then checks.partial_frames = checks.partial_frames + 1 end
        local viewport_end = math.min(last(), view.topline + api.nvim_win_get_height(win) - 1)
        for _, line in ipairs(lines(view.topline - 1, viewport_end)) do
          if line == "" then checks.settled_placeholders = checks.settled_placeholders + 1 end
        end
        local first = locate(sequence)
        local next_first = locate(sequence + 1)
        digests[#digests + 1] = vim.fn.sha256(table.concat(lines(first - 1, next_first - 1), "\n"))
      end
    end

    result.checks.target_sequence = sequence
    resize_history("bounded")
    if reveal_pages then
      result.reveal_pages = reveal_pages
      if not p.visibility then
        s:follow_window()
        settle()
        -- Publish the identical final store window in a single commit. The
        -- benchmark measures how that mounted tree resizes, excluding the
        -- cumulative navigation cost of getting there one click at a time.
        local start = loop.hrtime()
        s:_commit(function(state) state.window_start = reveal_start end)
        settle()
        result.expanded_mount_ms = (loop.hrtime() - start) / 1e6
        assert(s.state.window_end == nil and s.state.window_start == reveal_start)
        result.mounted_entries = n - reveal_start + 1
      else
        p.visibility:reveal(sequence)
        settle()
        result.mounted_entries = p.visibility.last - p.visibility.first + 1
      end
      result.memory_kib.expanded = ram("VmRSS")
    else
      for page = 1, 10 do
        if p.visibility then
          p.visibility:reveal(sequence - page * 30)
        else
          s:reveal_older()
        end
        settle()
      end
      if p.visibility then p.visibility:reveal(sequence) end
      settle()
    end
    resize_history("expanded")
    result.memory_kib.peak = ram("VmHWM")
    api.nvim_set_decoration_provider(observer, {})
    p.close()
    return
  end
  local function tail_hash()
    local first=math.max(0,last()-12)
    local ns=api.nvim_get_namespaces()
    local marks={}
    for name,nid in pairs(ns) do
      if name:find("fibrous") then
        for _,v in ipairs(api.nvim_buf_get_extmarks(buf,nid,{first,0},{-1,-1},{details=true})) do
          if v[4].hl_group then
            marks[#marks+1]=table.concat({v[2]-first,v[3],v[4].end_col,v[4].hl_group},",")
          end
        end
      end
    end
    table.sort(marks)
    assert(#marks>0,"expected highlighted transcript rows")
    return vim.fn.sha256(table.concat(lines(first,last()),"\n").."\n"..table.concat(marks,";"))
  end
  result.checks.tail_digest=tail_hash()
  s:set_status("generating")
  settle()
  for i=1,20 do
    time("stream",function() s:append_streaming_text("agent"," token"..i) end)
  end
  assert(visible():find("token20",1,true),"missing streamed text")
  result.checks.stream_digest=tail_hash()
  s:set_status("idle")
  settle()
  for i=1,8 do
    time("append",function() s:append_entry({kind="agent",text=marker(n+i).." "..prose}) end,function() must_see(n+i) end)
  end
  local full=n+8
  for i=1,6 do
    local width=i%2==1 and 69 or 82
    time("resize",function() api.nvim_win_set_width(p.host_winid,width) end)
    assert(api.nvim_win_get_width(win)==result.view.width+width-82,"transcript did not resize")
  end
  result.checks.resize_digest=tail_hash()
  prefs:set("follow",false)
  settle()
  -- Identical native half-page motions entirely inside the default tail window.
  api.nvim_set_current_win(win)
  for i=1,4 do
    time("half_page",function() vim.cmd("normal! "..string.char(21)) end)
    assert(visible():find("MSG%d+"),"blank viewport after half-page motion")
  end
  api.nvim_win_set_cursor(win,{last(),0})
  settle()
  -- Both modes visit the first newly exposed item 30 entries further back.
  -- Baseline drives the same store action as the expander and scrolls past it.
  for page=1,10 do
    local seq=full-29-page*30
    time("older"..page,function()
      if p.visibility then show(p.visibility:offset(seq-1)+1)
      else s:reveal_older(); show(1) end
    end,function() must_see(seq) end)
  end
  result.memory_kib.browsed=ram("VmRSS")
  result.checks.history=true
  -- Both modes use the existing bounded canonical navigation action.
  for _,seq in ipairs({math.floor(n/2),1,n-40}) do
    time("jump",function()
      s:reveal_entry(seq)
      if not p.visibility then show(1) end
    end,function() must_see(seq) end)
  end
  result.checks.deep_jumps=true
  result.memory_kib.peak_matched=ram("VmHWM")
  -- Repeated native motions across initially unrealized history. No application
  -- jump or model call here. The button run already has 330 accumulated entries
  -- elsewhere, but a fresh source jump gives it a bounded window again.
  if p.visibility then
    api.nvim_set_current_win(win)
    vim.cmd("normal! G")
    settle()
    local start=api.nvim_win_get_cursor(win)[1]
    -- Observe real redraws while Neovim consumes input through its typeahead.
    -- Empty placeholder strings are distinguishable from painted blank grid rows.
    local watched, any_blank, all_blank = false, false, false
    local observer = api.nvim_create_namespace("weave-bench-native-frames")
    api.nvim_set_decoration_provider(observer,{on_win=function(_,id,buffer,top)
      if watched and id==win and buffer==buf then
        local content=lines(top,math.min(last(),top+api.nvim_win_get_height(win)))
        local empty=0
        for _,line in ipairs(content) do if line=="" then empty=empty+1 end end
        any_blank=any_blank or empty>0
        all_blank=all_blank or (empty>0 and empty==#content)
      end
    end})
    result.checks.partial_pages,result.checks.blank_pages=0,0
    for _=1,40 do
      watched,any_blank,all_blank=true,false,false
      local previous=api.nvim_win_get_cursor(win)[1]
      time("native_history",function()
        api.nvim_input("<C-B>")
        for _=1,16 do
          coroutine.yield()
          if api.nvim_win_get_cursor(win)[1]~=previous then break end
        end
        assert(api.nvim_win_get_cursor(win)[1]~=previous,"page input was not consumed")
      end)
      watched=false
      if any_blank then result.checks.partial_pages=result.checks.partial_pages+1 end
      if all_blank then result.checks.blank_pages=result.checks.blank_pages+1 end
      assert(visible():find("MSG%d+"),"blank native page")
      local top=api.nvim_win_call(win,vim.fn.winsaveview).topline-1
      for _,line in ipairs(lines(top,math.min(last(),top+api.nvim_win_get_height(win)))) do
        if #line==0 then
          local v=p.visibility
          error(("unpainted viewport top=%d model.top=%d first=%d last=%d band=%d..%d pos=%d"):format(
            top,v.top,v.first,v.last,v:offset(v.first-1),v:offset(v.last),api.nvim_win_get_cursor(win)[1]))
        end
      end
    end
    api.nvim_set_decoration_provider(observer,{})
    assert(api.nvim_win_get_cursor(win)[1]<start-500,"native paging stayed at tail")
    result.checks.native_history=true
  end
  result.memory_kib.peak=ram("VmHWM")
  p.close()
end

local co=coroutine.create(main)
local function step()
  local ok,err=coroutine.resume(co)
  if not ok then result.error=debug.traceback(co,tostring(err)) end
  if ok and coroutine.status(co)~="dead" then
    vim.defer_fn(step,0)
  else
    vim.fn.writefile({vim.json.encode(result)},vim.env.BENCH_RESULT)
    vim.cmd(ok and "qa!" or "cquit!")
  end
end
vim.defer_fn(step,10)
