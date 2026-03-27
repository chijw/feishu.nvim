local util = require('feishu.util')

local M = {}

local states = {}

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

local function help_items()
  return {
    { 'gR', '重新同步当前文档缓存' },
    { 'gx', '打开远端 Feishu 链接' },
    { ':?', '显示帮助' },
    { ':q', '关闭当前缓冲区' },
  }
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
  map(':?', function()
    util.open_help_float('飞书文档', help_items())
  end, 'Show document help')
end

local function open_file_buffer(state, path)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  vim.api.nvim_set_current_win(state.winid)
  vim.cmd('silent keepalt edit ' .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  state.bufnr = buf
  states[buf] = state

  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'

  vim.b[buf].feishu_document_url = state.entry.url or ''
  vim.b[buf].feishu_document_cache_path = path
  vim.b[buf].feishu_document_title = resource_label(state.entry)

  attach_maps(buf, state)

  local group = vim.api.nvim_create_augroup(('FeishuDocument_%d'):format(buf), { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      states[buf] = nil
    end,
  })
end

local function refresh(state)
  local _, output_path, assets_dir = cache_paths(state.app, state.entry)
  render_loading(state, {
    resource_label(state.entry),
    '',
    '正在同步远端内容到本地缓存...',
    ('cache: %s'):format(output_path),
    '',
    '完成后会以只读 Markdown 缓冲区打开。',
  })

  state.app.backend:export_markdown(state.entry, output_path, assets_dir, function(_, err)
    if err then
      render_error(state, err)
      return
    end
    open_file_buffer(state, output_path)
  end)
end

function M.refresh_current()
  local state = state_for()
  if not state then
    return
  end
  refresh(state)
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

  local state = {
    app = app,
    entry = entry,
    winid = win,
    bufnr = buf,
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
  refresh(state)
end

return M
