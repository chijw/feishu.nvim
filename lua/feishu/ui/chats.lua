local util = require('feishu.util')

local M = {}

local ns = vim.api.nvim_create_namespace('feishu.chats')
local states = {}
local compose_states = {}

local CHAT_COLUMNS = {
  { key = 'name', title = '名称', min_width = 16, max_width = 28, importance = 100, pinned = true },
  { key = 'owner', title = '群主', min_width = 10, max_width = 18, importance = 60, can_hide = true },
  { key = 'external', title = '外部', min_width = 4, max_width = 8, importance = 20, can_hide = true },
  { key = 'chat_id', title = 'chat_id', min_width = 12, max_width = 24, importance = 10, can_hide = true },
}

local function extract_message_text(item)
  local body = type(item.body) == 'table' and item.body or {}
  local content = body.content
  if type(content) ~= 'string' then
    return ''
  end
  local decoded = util.decode_json(content)
  if type(decoded) == 'table' and type(decoded.text) == 'string' then
    return decoded.text
  end
  return content
end

local function append_indented_text(lines, prefix, text)
  local chunks = vim.split(text or '', '\n', { plain = true })
  if #chunks == 0 then
    lines[#lines + 1] = prefix
    return
  end
  for _, chunk in ipairs(chunks) do
    lines[#lines + 1] = prefix .. chunk
  end
end

local function current_state(buf)
  return states[buf or vim.api.nvim_get_current_buf()]
end

local function current_chat(state)
  local line = vim.api.nvim_win_get_cursor(state.list_win)[1]
  return state.line_to_chat[line]
end

local function matches_chat_filter(chat, query)
  query = vim.trim((query or ''):lower())
  if query == '' then
    return true
  end
  local haystacks = {
    (chat.name or ''):lower(),
    (chat.chat_id or ''):lower(),
    (chat.description or ''):lower(),
    (chat.owner_id or ''):lower(),
  }
  for _, haystack in ipairs(haystacks) do
    if haystack:find(query, 1, true) then
      return true
    end
  end
  return false
end

local function visible_chats(state)
  local items = {}
  for _, chat in ipairs(state.chats or {}) do
    if matches_chat_filter(chat, state.filter_query) then
      items[#items + 1] = chat
    end
  end
  return items
end

local function ensure_preview_window(state)
  if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win)
      and state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then
    return true
  end
  if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then
    return false
  end

  vim.api.nvim_set_current_win(state.list_win)
  vim.cmd('botright vsplit')
  state.preview_win = vim.api.nvim_get_current_win()
  if not state.preview_buf or not vim.api.nvim_buf_is_valid(state.preview_buf) then
    state.preview_buf = util.create_scratch_buffer('feishu://chat-history', 'feishu-chat-history')
  end
  vim.api.nvim_win_set_buf(state.preview_win, state.preview_buf)
  vim.wo[state.preview_win].number = false
  vim.wo[state.preview_win].relativenumber = false
  vim.wo[state.preview_win].wrap = true
  pcall(vim.api.nvim_win_set_width, state.preview_win, math.max(42, math.floor(vim.o.columns * (state.app.opts.ui.preview_width or 0.42))))
  util.attach_help(state.preview_buf, function()
    local items = {
      { '<CR>', '加载当前聊天的历史消息' },
      { 'i', '打开消息发送窗口' },
      { 's', '设置本地筛选' },
      { 'S', '清除当前筛选' },
      { 'h / l', '横向切换可见列' },
      { 'J / K', '快速上下移动' },
      { 'r', '刷新聊天列表' },
      { 'q', '关闭消息页' },
    }
    if #state.chats == 0 then
      items[2] = nil
    end
    local compact = {}
    for _, item in ipairs(items) do
      if item then
        compact[#compact + 1] = item
      end
    end
    return {
      title = '飞书消息',
      items = compact,
    }
  end)

  vim.api.nvim_set_current_win(state.list_win)
  return true
end

local function collapse_preview_window(state)
  util.close_window(state.preview_win)
  state.preview_win = nil
end

local function render_preview(state)
  if not ensure_preview_window(state) then
    return
  end

  local chat = current_chat(state)
  if not chat then
    util.set_lines(state.preview_buf, {
      '消息预览',
      '',
      '选择一个聊天查看历史消息。',
    })
    return
  end

  local history_error = state.history_errors[chat.chat_id]
  local messages = state.history_by_chat_id[chat.chat_id] or {}
  local lines = {
    chat.name ~= '' and chat.name or chat.chat_id,
    ('chat_id: %s'):format(chat.chat_id),
    '',
  }

  if chat.description and chat.description ~= '' then
    lines[#lines + 1] = ('description: %s'):format(chat.description)
  end
  if chat.owner_id and chat.owner_id ~= '' then
    lines[#lines + 1] = ('owner: %s'):format(chat.owner_id)
  end
  if chat.external ~= nil then
    lines[#lines + 1] = ('external: %s'):format(tostring(chat.external))
  end
  if #lines > 3 then
    lines[#lines + 1] = ''
  end

  if history_error then
    lines[#lines + 1] = '消息历史'
    lines[#lines + 1] = ('  错误: %s'):format(history_error.message or 'request failed')
  elseif #messages == 0 then
    lines[#lines + 1] = '消息历史'
    lines[#lines + 1] = '  暂无已加载消息'
  else
    lines[#lines + 1] = '消息历史'
    for _, item in ipairs(messages) do
      local sender = type(item.sender) == 'table' and item.sender or {}
      local sender_name = sender.sender_type or sender.id or 'unknown'
      local timestamp = ''
      if type(item.create_time) == 'string' and item.create_time:match('^%d+$') then
        timestamp = os.date('%Y-%m-%d %H:%M', math.floor(tonumber(item.create_time) / 1000))
      end
      lines[#lines + 1] = ('[%s] %s'):format(timestamp ~= '' and timestamp or '--', sender_name)
      append_indented_text(lines, '  ', extract_message_text(item))
      lines[#lines + 1] = ''
    end
  end

  util.set_lines(state.preview_buf, lines)
  vim.api.nvim_buf_clear_namespace(state.preview_buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Title', 0, 0, -1)
  vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Comment', 1, 0, -1)
  vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Comment', 2, 0, -1)
  for index, line in ipairs(lines) do
    if line == '消息历史' then
      vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Identifier', index - 1, 0, -1)
    elseif line:match('^%[.*%] ') then
      vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Statement', index - 1, 0, -1)
    elseif line:match('^  错误:') then
      vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'ErrorMsg', index - 1, 0, -1)
    end
  end
end

local function render(state)
  local selected = current_chat(state)
  local selected_chat_id = selected and selected.chat_id or state.last_selected_chat_id
  local width = vim.api.nvim_win_is_valid(state.list_win) and vim.api.nvim_win_get_width(state.list_win) or math.floor(vim.o.columns * 0.55)
  local rows = {}
  local chats = visible_chats(state)
  for _, item in ipairs(chats) do
    rows[#rows + 1] = {
      name = item.name or '',
      owner = item.owner_id or '',
      external = tostring(item.external or ''),
      chat_id = item.chat_id or '',
    }
  end
  local shown, widths, hidden_right, skipped_left = util.window_compact_columns(CHAT_COLUMNS, rows, math.max(30, width - 1), state.column_offset)

  local header_values = {}
  for _, spec in ipairs(shown) do
    header_values[spec.key] = spec.title
  end

  local status_line = state.error and ('错误: ' .. (state.error.message or 'request failed')) or (state.status or '')
  if vim.trim(state.filter_query or '') ~= '' then
    status_line = status_line .. ('  [filter=%s]'):format(state.filter_query)
  end

  local lines = {
    '飞书消息',
    status_line,
    '',
    util.render_compact_row(shown, widths, header_values),
    util.render_separator(shown, widths),
  }

  state.line_to_chat = {}
  for _, chat in ipairs(chats) do
    local values = {
      name = chat.name or '',
      owner = chat.owner_id or '',
      external = tostring(chat.external or ''),
      chat_id = chat.chat_id or '',
    }
    lines[#lines + 1] = util.render_compact_row(shown, widths, values)
    state.line_to_chat[#lines] = chat
  end

  if #chats == 0 then
    lines[#lines + 1] = '(no chats)'
  end

  util.set_lines(state.list_buf, lines)
  vim.api.nvim_buf_clear_namespace(state.list_buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Title', 0, 0, -1)
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, state.error and 'ErrorMsg' or 'Comment', 1, 0, -1)
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Identifier', 3, 0, -1)

  if #chats > 0 and vim.api.nvim_win_is_valid(state.list_win) then
    local target = nil
    for line, chat in pairs(state.line_to_chat) do
      if chat.chat_id == selected_chat_id then
        target = line
        break
      end
    end
    if not target then
      target = 6
    end
    pcall(vim.api.nvim_win_set_cursor, state.list_win, { target, 0 })
  end

  local chat = current_chat(state)
  state.last_selected_chat_id = chat and chat.chat_id or state.last_selected_chat_id
  render_preview(state)
end

local function help_items(state)
  local items = {
    { '<CR>', '加载当前聊天的历史消息' },
    { 'i', '打开消息发送窗口' },
    { 's', '设置本地筛选' },
    { 'S', '清除当前筛选' },
    { 'h / l', '横向切换可见列' },
    { 'J / K', '快速上下移动' },
    { 'r', '刷新聊天列表' },
    { 'q', '关闭消息页' },
  }
  if #state.chats == 0 then
    items[2] = nil
  end
  local compact = {}
  for _, item in ipairs(items) do
    if item then
      compact[#compact + 1] = item
    end
  end
  return compact
end

local function compose_help_items()
  return {
    { ':w', '发送当前消息' },
    { ':wq', '发送并关闭当前窗口' },
    { ':q', '关闭当前窗口' },
    { ':q!', '丢弃未发送内容并关闭' },
  }
end

local function load_history(state, chat_id)
  if not chat_id or chat_id == '' then
    return
  end
  state.status = ('正在加载 %s 的历史消息...'):format(chat_id)
  render(state)
  state.app.backend:chat_history(chat_id, function(payload, err)
    if err then
      state.history_errors[chat_id] = err
      state.status = '历史消息加载失败。'
    else
      state.history_by_chat_id[chat_id] = payload.items or {}
      state.history_errors[chat_id] = nil
      state.status = ('已加载 %d 条消息。'):format(#(payload.items or {}))
    end
    render(state)
  end)
end

local function prompt_filter(state)
  vim.ui.input({
    prompt = '筛选聊天: ',
    default = state.filter_query or '',
  }, function(input)
    if input == nil then
      return
    end
    state.filter_query = vim.trim(input)
    render(state)
  end)
end

local function clear_filter(state)
  if vim.trim(state.filter_query or '') == '' then
    return
  end
  state.filter_query = ''
  render(state)
end

local function refresh(state)
  state.status = '正在加载聊天列表...'
  state.error = nil
  render(state)
  state.app.backend:chat_list(state.mode, function(payload, err)
    if err then
      state.error = err
      state.status = '聊天列表不可用。'
      render(state)
      return
    end
    state.chats = payload.items or {}
    state.error = nil
    state.status = ('共 %d 个聊天。'):format(#state.chats)
    render(state)
    local selected_chat = current_chat(state) or state.chats[1]
    if selected_chat and selected_chat.chat_id and not state.history_by_chat_id[selected_chat.chat_id] then
      load_history(state, selected_chat.chat_id)
    end
  end)
end

local function reset_compose_buffer(compose_state)
  if not vim.api.nvim_buf_is_valid(compose_state.bufnr) then
    return
  end
  local chat = current_chat(compose_state.parent_state)
  local label = chat and (chat.name ~= '' and chat.name or chat.chat_id) or compose_state.chat_id
  util.set_lines(compose_state.bufnr, {
    ('# chat: %s'):format(label),
    '',
  }, { modifiable = true })
  vim.bo[compose_state.bufnr].modifiable = true
  vim.bo[compose_state.bufnr].readonly = false
  vim.bo[compose_state.bufnr].modified = false
  if vim.api.nvim_win_is_valid(compose_state.winid) then
    pcall(vim.api.nvim_win_set_cursor, compose_state.winid, { 2, 0 })
  end
end

local function save_compose(compose_state, opts)
  opts = opts or {}
  if compose_state.pending then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(compose_state.bufnr, 0, -1, false)
  local content_lines = {}
  for _, line in ipairs(lines) do
    if not vim.trim(line):match('^#') then
      content_lines[#content_lines + 1] = line
    end
  end
  local text = vim.trim(table.concat(content_lines, '\n'))
  if text == '' then
    vim.notify('消息内容不能为空。', vim.log.levels.WARN)
    return false
  end

  compose_state.pending = true
  vim.bo[compose_state.bufnr].modifiable = false
  vim.bo[compose_state.bufnr].readonly = true
  compose_state.parent_state.status = '正在发送消息...'
  render(compose_state.parent_state)
  local done = false
  local ok = false
  compose_state.parent_state.app.backend:chat_send(compose_state.chat_id, text, function(_, err)
    compose_state.pending = false
    if err then
      vim.bo[compose_state.bufnr].modifiable = true
      vim.bo[compose_state.bufnr].readonly = false
      compose_state.parent_state.status = '发送失败。'
      compose_state.parent_state.error = err
      render(compose_state.parent_state)
      vim.notify(err.message or '发送失败。', vim.log.levels.ERROR)
      done = true
      return
    end

    ok = true
    reset_compose_buffer(compose_state)
    compose_state.parent_state.status = '消息已发送。'
    compose_state.parent_state.error = nil
    load_history(compose_state.parent_state, compose_state.chat_id)
    done = true
  end)

  if opts.blocking then
    local finished = vim.wait(opts.timeout_ms or 30000, function()
      return done
    end, 50)
    if not finished then
      compose_state.pending = false
      vim.bo[compose_state.bufnr].modifiable = true
      vim.bo[compose_state.bufnr].readonly = false
      compose_state.parent_state.status = '发送超时。'
      compose_state.parent_state.error = { message = 'Timed out while sending the message.' }
      render(compose_state.parent_state)
      vim.notify('发送超时。', vim.log.levels.ERROR)
      return false
    end
    return ok
  end

  return true
end

local function open_compose(state)
  local chat = current_chat(state)
  if not chat then
    vim.notify('请先选择一个聊天。', vim.log.levels.WARN)
    return
  end

  vim.cmd('botright split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(win, math.max(6, math.floor(vim.o.lines * (state.app.opts.ui.compose_height or 0.32))))
  local buf = util.create_scratch_buffer('feishu://chat-compose', 'markdown')
  vim.bo[buf].buftype = 'acwrite'
  vim.api.nvim_win_set_buf(win, buf)
  util.set_lines(buf, {
    ('# chat: %s'):format(chat.name ~= '' and chat.name or chat.chat_id),
    '',
  }, { modifiable = true })
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  pcall(vim.api.nvim_win_set_cursor, win, { 2, 0 })

  local compose_state = {
    parent_state = state,
    bufnr = buf,
    winid = win,
    chat_id = chat.chat_id,
    pending = false,
  }
  compose_states[buf] = compose_state

  local map = function(lhs, rhs, desc, mode)
    vim.keymap.set(mode or 'n', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  util.attach_help(buf, {
    title = '消息编辑',
    items = compose_help_items(),
  })

  local group = vim.api.nvim_create_augroup(('FeishuCompose_%d'):format(buf), { clear = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = buf,
    callback = function()
      save_compose(compose_state, { blocking = true })
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      compose_states[buf] = nil
    end,
  })
end

local function fast_move(state, delta)
  local chats = visible_chats(state)
  if #chats == 0 or not vim.api.nvim_win_is_valid(state.list_win) then
    return
  end
  local line = vim.api.nvim_win_get_cursor(state.list_win)[1]
  local target = math.max(6, math.min(line + delta, 5 + #chats))
  vim.api.nvim_win_set_cursor(state.list_win, { target, 0 })
end

local function on_cursor_moved(buf)
  local state = current_state(buf)
  if not state then
    return
  end
  local chat = current_chat(state)
  if chat then
    state.last_selected_chat_id = chat.chat_id
    render_preview(state)
  end
end

function M.refresh_current()
  local state = current_state()
  if state then
    refresh(state)
  end
end

function M.open(app)
  local list_win = vim.api.nvim_get_current_win()
  local list_buf = util.create_view_buffer('feishu://chats', 'feishu-chats', {
    bufhidden = 'hide',
  })
  vim.api.nvim_win_set_buf(list_win, list_buf)
  util.configure_selection_window(list_win, list_buf, { wrap = false })

  vim.cmd('botright vsplit')
  local preview_win = vim.api.nvim_get_current_win()
  local preview_buf = util.create_scratch_buffer('feishu://chat-history', 'feishu-chat-history')
  vim.api.nvim_win_set_buf(preview_win, preview_buf)
  vim.wo[preview_win].number = false
  vim.wo[preview_win].relativenumber = false
  vim.wo[preview_win].wrap = true
  pcall(vim.api.nvim_win_set_width, preview_win, math.max(42, math.floor(vim.o.columns * (app.opts.ui.preview_width or 0.42))))

  vim.api.nvim_set_current_win(list_win)

  local state = {
    app = app,
    list_buf = list_buf,
    list_win = list_win,
    preview_buf = preview_buf,
    preview_win = preview_win,
    mode = app.opts.chat_mode or 'user',
    chats = {},
    line_to_chat = {},
    column_offset = 0,
    filter_query = '',
    history_by_chat_id = {},
    history_errors = {},
    status = '正在加载...',
    error = nil,
    last_selected_chat_id = nil,
  }
  states[list_buf] = state

  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = list_buf, silent = true, nowait = true, desc = desc })
  end

  map('q', function()
    util.close_window(state.preview_win)
    util.close_buffer(state.preview_buf)
    util.close_buffer(list_buf)
  end, 'Close chats view')
  map('r', function()
    refresh(state)
  end, 'Refresh chats')
  map('s', function()
    prompt_filter(state)
  end, 'Filter chats')
  map('S', function()
    clear_filter(state)
  end, 'Clear chats filter')
  map('h', function()
    state.column_offset = math.max(0, state.column_offset - 1)
    render(state)
  end, 'Scroll columns left')
  map('l', function()
    state.column_offset = state.column_offset + 1
    render(state)
  end, 'Scroll columns right')
  map('J', function()
    fast_move(state, 5)
  end, 'Move down faster')
  map('K', function()
    fast_move(state, -5)
  end, 'Move up faster')
  util.attach_help(list_buf, function()
    return {
      title = '飞书消息',
      items = help_items(state),
    }
  end)
  map('<CR>', function()
    local chat = current_chat(state)
    if chat then
      load_history(state, chat.chat_id)
    end
  end, 'Load chat history')
  map('L', function()
    local chat = current_chat(state)
    if chat then
      load_history(state, chat.chat_id)
    end
  end, 'Load chat history')
  map('i', function()
    open_compose(state)
  end, 'Compose message')

  local group = vim.api.nvim_create_augroup(('FeishuChats_%d'):format(list_buf), { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    buffer = list_buf,
    callback = function()
      on_cursor_moved(list_buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = list_buf,
    callback = function()
      state.list_win = vim.api.nvim_get_current_win()
      ensure_preview_window(state)
      render(state)
    end,
  })
  vim.api.nvim_create_autocmd('BufWinLeave', {
    group = group,
    buffer = list_buf,
    callback = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(list_buf) then
          return
        end
        if states[list_buf] ~= state then
          return
        end
        if util.buffer_visible(list_buf) then
          return
        end
        collapse_preview_window(state)
      end)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = list_buf,
    callback = function()
      states[list_buf] = nil
      collapse_preview_window(state)
      util.close_buffer(state.preview_buf)
    end,
  })

  render(state)
  refresh(state)
end

return M
