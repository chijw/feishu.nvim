local util = require('feishu.util')

local M = {}

local states = {}

local function resource_label(entry)
  return entry.name or entry.title or entry.token or entry.url or '<resource>'
end

local function help_items(state)
  local items = {
    { 'gR', '重新渲染当前 metadata 视图' },
    { ':?', '显示帮助' },
    { ':q', '关闭当前缓冲区' },
  }
  if state.entry.url and state.entry.url ~= '' then
    table.insert(items, 2, { 'gx', '打开远端 Feishu 链接' })
  end
  return items
end

local function append_field(lines, label, value)
  if value == nil then
    return
  end
  if type(value) == 'string' and vim.trim(value) == '' then
    return
  end
  lines[#lines + 1] = ('%s: %s'):format(label, tostring(value))
end

local function render(state)
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  local entry = state.entry or {}
  local lines = {
    resource_label(entry),
    '',
    '这是当前资源的 metadata 视图。',
    '',
  }

  append_field(lines, 'Type', entry.type or entry.obj_type or entry.kind or 'unknown')
  append_field(lines, 'Source', entry.source)
  append_field(lines, 'SourceType', entry.source_type)
  append_field(lines, 'Token', entry.token)
  append_field(lines, 'ObjToken', entry.obj_token)
  append_field(lines, 'NodeToken', entry.node_token)
  append_field(lines, 'Owner', entry.owner_id)
  append_field(lines, 'Modified', entry.modified_time)
  append_field(lines, 'URL', entry.url)
  append_field(lines, 'Visibility', entry.visibility)
  append_field(lines, 'SpaceID', entry.space_id)
  append_field(lines, 'Parent', entry.parent_token or entry.parent_node_token)

  lines[#lines + 1] = ''
  lines[#lines + 1] = '说明:'
  lines[#lines + 1] = '  - 这个资源类型当前还没有原生缓冲区支持。'
  lines[#lines + 1] = '  - 需要完整功能时可使用 gx 打开远端页面。'

  if type(entry.raw) == 'table' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Raw:'
    for _, line in ipairs(vim.split(vim.inspect(entry.raw), '\n', { plain = true })) do
      lines[#lines + 1] = line
    end
  end

  util.set_lines(state.bufnr, lines, { modifiable = false })
  vim.bo[state.bufnr].filetype = 'yaml'
end

local function attach_maps(buf, state)
  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map('gR', function()
    render(state)
  end, 'Refresh resource metadata view')
  if state.entry.url and state.entry.url ~= '' then
    map('gx', function()
      util.open_url(state.entry.url)
    end, 'Open remote Feishu URL')
  end
  map(':?', function()
    util.open_help_float('飞书资源', help_items(state))
  end, 'Show resource help')
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

  local buf = util.create_scratch_buffer('feishu://resource', 'yaml')
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

  local group = vim.api.nvim_create_augroup(('FeishuResource_%d'):format(buf), { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      states[buf] = nil
    end,
  })

  render(state)
end

return M
