local util = require('feishu.util')

local M = {}

local states = {}

local function non_empty(...)
  for _, value in ipairs({ ... }) do
    if type(value) == 'string' and vim.trim(value) ~= '' then
      return value
    end
  end
  return nil
end

local function slug(text)
  text = tostring(text or '')
  text = text:gsub('[^%w%-_.]+', '_')
  text = text:gsub('_+', '_')
  text = text:gsub('^_+', '')
  text = text:gsub('_+$', '')
  if text == '' then
    return 'resource'
  end
  return text
end

local function resource_label(entry)
  return entry.name or entry.title or entry.token or entry.url or '<document>'
end

local function cache_root(app)
  local root = app.opts.cache_dir
  if type(root) ~= 'string' or root == '' then
    root = vim.fn.stdpath('cache') .. '/feishu.nvim/documents'
  end
  vim.fn.mkdir(root, 'p')
  return root
end

local function cache_paths(app, entry)
  local key = entry.node_token or entry.token or entry.url or resource_label(entry)
  local resource_dir = cache_root(app) .. '/' .. slug((entry.type or entry.kind or 'doc') .. '_' .. key)
  local assets_dir = resource_dir .. '/assets'
  local output_path = resource_dir .. '/content.md'
  vim.fn.mkdir(resource_dir, 'p')
  vim.fn.mkdir(assets_dir, 'p')
  return resource_dir, output_path, assets_dir
end

local function document_id_for_entry(entry)
  if type(entry) ~= 'table' then
    return nil
  end

  local entry_type = tostring(entry.type or entry.obj_type or '')
  local is_wiki = tostring(entry.source_type or '') == 'wiki' or entry.kind == 'wiki_node' or entry.node_token ~= nil
  if entry_type ~= 'docx' then
    return nil
  end
  if is_wiki then
    return non_empty(entry.obj_token, entry.token)
  end
  return non_empty(entry.token, entry.obj_token)
end

local function build_help_items(state)
  local items = {
    { 'gR', '重新同步当前文档缓存' },
    { 'gx', '打开远端 Feishu 链接' },
    { ':?', '显示帮助' },
    { ':q', '关闭当前缓冲区' },
  }
  if state.editable then
    table.insert(items, 2, { 'gS', '手动把当前 Markdown 同步回远端' })
    table.insert(items, 3, { ':w', '保存本地缓存并异步同步远端' })
  end
  return items
end

local function state_for(buf)
  return states[buf or vim.api.nvim_get_current_buf()]
end

local function render_loading(state, lines)
  util.set_lines(state.bufnr, lines, { modifiable = false })
  vim.bo[state.bufnr].filetype = 'markdown'
end

local function render_error(state, err)
  local lines = {
    resource_label(state.entry),
    '',
    '同步失败。',
    err and (err.message or 'request failed') or 'request failed',
    '',
    '可用操作:',
    '  gR  重试同步',
    '  gx  打开远端链接',
    '  :?  查看帮助',
  }
  render_loading(state, lines)
end

local function sync_status(state, value)
  state.sync_status = value
  local buf = state.bufnr
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.b[buf].feishu_document_sync_status = value
  end
end

local function set_buffer_metadata(state, buf, path)
  vim.b[buf].feishu_document_url = state.entry.url or ''
  vim.b[buf].feishu_document_cache_path = path or ''
  vim.b[buf].feishu_document_title = resource_label(state.entry)
  vim.b[buf].feishu_document_id = state.document_id or ''
  vim.b[buf].feishu_document_editable = state.editable and 1 or 0
  vim.b[buf].feishu_document_sync_status = state.sync_status or 'idle'
end

local function notify_sync_failure(state, err)
  vim.notify(
    ('Feishu sync failed: %s'):format(err and (err.message or 'request failed') or 'request failed'),
    vim.log.levels.ERROR,
    { title = resource_label(state.entry) }
  )
end

local function start_sync(state, seq, source)
  if not state.editable or not state.document_id or not state.output_path then
    return
  end

  state.sync_inflight = true
  state.current_sync_seq = seq
  sync_status(state, 'syncing')

  state.app.backend:import_markdown(state.output_path, state.document_id, function(_, err)
    local pending_seq = state.pending_sync_seq
    state.sync_inflight = false

    if err then
      state.last_sync_error = err
      sync_status(state, 'error')
      notify_sync_failure(state, err)
    else
      state.last_sync_error = nil
      state.last_synced_seq = seq
      sync_status(state, 'synced')
      if source == 'manual' then
        vim.notify('Feishu document synced.', vim.log.levels.INFO, { title = resource_label(state.entry) })
      end
    end

    if pending_seq and pending_seq > seq then
      state.pending_sync_seq = nil
      start_sync(state, pending_seq, 'queued')
    end
  end)
end

local function queue_sync(state, source)
  if not state.editable then
    return false
  end

  state.sync_seq = (state.sync_seq or 0) + 1
  local seq = state.sync_seq

  if state.sync_inflight then
    state.pending_sync_seq = seq
    sync_status(state, 'queued')
    if source == 'manual' then
      vim.notify('A sync is already running. Queued one more sync.', vim.log.levels.INFO, {
        title = resource_label(state.entry),
      })
    end
    return true
  end

  start_sync(state, seq, source)
  return true
end

local function attach_maps(buf, state)
  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map('gR', function()
    M.refresh_current()
  end, 'Refresh Feishu document cache')
  map('gx', function()
    if state.entry.url and state.entry.url ~= '' then
      util.open_url(state.entry.url)
    end
  end, 'Open remote Feishu URL')
  if state.editable then
    map('gS', function()
      M.sync_current()
    end, 'Sync current Markdown to Feishu')
  end
  map(':?', function()
    util.open_help_float('飞书文档', build_help_items(state))
  end, 'Show document help')
end

local function attach_buffer_autocmds(state, buf)
  local group = vim.api.nvim_create_augroup(('FeishuDocument_%d'):format(buf), { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      states[buf] = nil
    end,
  })
  if state.editable then
    vim.api.nvim_create_autocmd('BufWritePost', {
      group = group,
      buffer = buf,
      callback = function(event)
        local current = state_for(event.buf)
        if current then
          queue_sync(current, 'save')
        end
      end,
    })
  end
end

local function open_file_buffer(state, path, opts)
  opts = opts or {}
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  local previous = state.bufnr
  vim.api.nvim_set_current_win(state.winid)
  if opts.force_reload then
    vim.cmd('silent keepalt edit! ' .. vim.fn.fnameescape(path))
  else
    vim.cmd('silent keepalt edit ' .. vim.fn.fnameescape(path))
  end
  local buf = vim.api.nvim_get_current_buf()
  if previous and previous ~= buf then
    states[previous] = nil
  end
  state.bufnr = buf
  state.output_path = path
  states[buf] = state

  vim.bo[buf].readonly = not state.editable
  vim.bo[buf].modifiable = state.editable
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'

  set_buffer_metadata(state, buf, path)

  attach_maps(buf, state)
  attach_buffer_autocmds(state, buf)
end

local function refresh(state, opts)
  opts = opts or {}
  local _, output_path, assets_dir = cache_paths(state.app, state.entry)
  local initial_open = opts.initial == true or not state.output_path
  state.output_path = output_path

  if initial_open then
    render_loading(state, {
      resource_label(state.entry),
      '',
      '正在同步远端内容到本地缓存...',
      ('cache: %s'):format(output_path),
      '',
      state.editable and '完成后会以可编辑 Markdown 缓冲区打开。' or '完成后会以只读 Markdown 缓冲区打开。',
    })
  else
    vim.notify('Refreshing Feishu document cache...', vim.log.levels.INFO, {
      title = resource_label(state.entry),
    })
  end

  state.app.backend:export_markdown(state.entry, output_path, assets_dir, function(_, err)
    if err then
      if initial_open then
        render_error(state, err)
      else
        vim.notify(
          ('Failed to refresh Feishu document cache: %s'):format(err.message or 'request failed'),
          vim.log.levels.ERROR,
          { title = resource_label(state.entry) }
        )
      end
      return
    end
    open_file_buffer(state, output_path, { force_reload = not initial_open })
  end)
end

function M.sync_current()
  local state = state_for()
  if not state then
    return
  end
  state.winid = vim.api.nvim_get_current_win()
  if not state.editable then
    vim.notify('This Feishu document is read-only in the current backend.', vim.log.levels.WARN)
    return
  end
  if vim.bo[state.bufnr].modified then
    vim.notify('Current buffer has unsaved changes. Save it with :w before syncing.', vim.log.levels.WARN, {
      title = resource_label(state.entry),
    })
    return
  end
  queue_sync(state, 'manual')
end

function M.refresh_current()
  local state = state_for()
  if not state then
    return
  end
  state.winid = vim.api.nvim_get_current_win()
  if state.editable and vim.bo[state.bufnr].modified then
    vim.notify('Current buffer has unsaved changes. Save or discard them before refreshing.', vim.log.levels.WARN, {
      title = resource_label(state.entry),
    })
    return
  end
  if state.sync_inflight then
    vim.notify('A sync is still running. Wait for it to finish before refreshing.', vim.log.levels.WARN, {
      title = resource_label(state.entry),
    })
    return
  end
  refresh(state, { initial = false })
end

function M.open(app, entry, opts)
  opts = opts or {}
  local win = opts.target_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    if opts.split == 'right' then
      vim.cmd('botright vsplit')
      win = vim.api.nvim_get_current_win()
    else
      win = vim.api.nvim_get_current_win()
    end
  end
  local buf = util.create_scratch_buffer('feishu://document-loading', 'markdown')
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = true

  local document_id = document_id_for_entry(entry)
  local state = {
    app = app,
    entry = entry,
    winid = win,
    bufnr = buf,
    document_id = document_id,
    editable = document_id ~= nil,
    sync_status = 'idle',
  }
  states[buf] = state
  attach_maps(buf, state)
  local group = vim.api.nvim_create_augroup(('FeishuDocumentLoading_%d'):format(buf), { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      states[buf] = nil
    end,
  })
  refresh(state, { initial = true })
end

return M
