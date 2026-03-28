local util = require('feishu.util')

local M = {}

local states = {}

local META_TYPES = {
  doc = true,
  docx = true,
  sheet = true,
  bitable = true,
  folder = true,
  file = true,
}

local STATS_TYPES = {
  doc = true,
  docx = true,
  sheet = true,
  bitable = true,
}

local TEXT_EXTENSIONS = {
  txt = true,
  md = true,
  markdown = true,
  rst = true,
  log = true,
  text = true,
  json = true,
  jsonl = true,
  yaml = true,
  yml = true,
  toml = true,
  lua = true,
  py = true,
  sh = true,
  bash = true,
  zsh = true,
  fish = true,
  js = true,
  jsx = true,
  ts = true,
  tsx = true,
  css = true,
  scss = true,
  html = true,
  xml = true,
  csv = true,
  tsv = true,
  sql = true,
  tex = true,
  c = true,
  cc = true,
  cpp = true,
  h = true,
  hh = true,
  hpp = true,
  rs = true,
  go = true,
  java = true,
  kt = true,
  swift = true,
  rb = true,
  php = true,
}

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
  return entry.name or entry.title or entry.token or entry.url or '<resource>'
end

local function entry_type(entry)
  return tostring(entry and (entry.type or entry.obj_type or entry.kind) or '')
end

local function supports_meta(entry)
  return META_TYPES[entry_type(entry)] == true
end

local function supports_stats(entry)
  return STATS_TYPES[entry_type(entry)] == true
end

local function is_downloadable(entry)
  return entry_type(entry) == 'file'
end

local function cache_root(app)
  local root = app.opts.cache_dir
  if type(root) ~= 'string' or root == '' then
    root = vim.fn.stdpath('cache') .. '/feishu.nvim/files'
  else
    root = root .. '/files'
  end
  vim.fn.mkdir(root, 'p')
  return root
end

local function cache_path(app, entry)
  local token = entry.token or entry.obj_token or resource_label(entry)
  local dir = cache_root(app) .. '/' .. slug((entry_type(entry) ~= '' and entry_type(entry) or 'resource') .. '_' .. token)
  vim.fn.mkdir(dir, 'p')
  local filename = slug(entry.name or entry.title or token)
  if filename == '' then
    filename = 'download'
  end
  return dir .. '/' .. filename
end

local function resource_view_name(entry)
  local kind = entry_type(entry)
  if kind == '' then
    kind = 'resource'
  end
  local token = entry.token or entry.obj_token or entry.node_token or resource_label(entry)
  return ('feishu://resource/%s/%s'):format(kind, slug(token))
end

local function format_timestamp(raw)
  if raw == nil then
    return nil
  end
  local text = tostring(raw)
  if text == '' then
    return nil
  end
  if text:match('^%d+$') then
    local value = tonumber(text)
    if value and value > 0 then
      if #text >= 13 then
        value = math.floor(value / 1000)
      end
      return os.date('%Y-%m-%d %H:%M:%S', value)
    end
  end
  return text
end

local function local_path_hint(state)
  if type(state.local_path) == 'string' and state.local_path ~= '' then
    return state.local_path
  end
  return nil
end

local function is_text_path(path)
  local ext = path:match('%.([^.]+)$')
  if not ext then
    return false
  end
  return TEXT_EXTENSIONS[ext:lower()] == true
end

local function help_items(state)
  local items = {
    { 'gR', '重新加载当前资源信息' },
    { ':q', '关闭当前缓冲区' },
  }
  if state.entry.url and state.entry.url ~= '' then
    table.insert(items, 2, { 'gx', '打开远端 Feishu 链接' })
  end
  if is_downloadable(state.entry) then
    table.insert(items, 2, { 'o', '下载到本地缓存并打开' })
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

local function render_section(lines, title)
  lines[#lines + 1] = ''
  lines[#lines + 1] = title
end

local function render(state)
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  local entry = state.entry or {}
  local lines = {
    resource_label(entry),
    '',
    state.status ~= '' and state.status or '这是当前资源的 metadata 视图。',
  }

  render_section(lines, 'Entry:')
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
  append_field(lines, 'DownloadedPath', local_path_hint(state))

  if state.meta then
    render_section(lines, 'Meta:')
    append_field(lines, 'Title', state.meta.title)
    append_field(lines, 'DocToken', state.meta.doc_token)
    append_field(lines, 'DocType', state.meta.doc_type)
    append_field(lines, 'Owner', state.meta.owner_id)
    append_field(lines, 'CreatedAt', format_timestamp(state.meta.create_time))
    append_field(lines, 'ModifiedBy', state.meta.latest_modify_user)
    append_field(lines, 'ModifiedAt', format_timestamp(state.meta.latest_modify_time))
    append_field(lines, 'MetaURL', state.meta.url)
  end

  if state.stats then
    render_section(lines, 'Stats:')
    append_field(lines, 'UV', state.stats.uv)
    append_field(lines, 'PV', state.stats.pv)
    append_field(lines, 'LikeCount', state.stats.like_count)
    append_field(lines, 'UVToday', state.stats.uv_today)
    append_field(lines, 'PVToday', state.stats.pv_today)
    append_field(lines, 'LikeCountToday', state.stats.like_count_today)
  end

  if state.meta_error or state.stats_error or state.download_error then
    render_section(lines, 'Errors:')
    append_field(lines, 'Meta', state.meta_error and state.meta_error.message or nil)
    append_field(lines, 'Stats', state.stats_error and state.stats_error.message or nil)
    append_field(lines, 'Download', state.download_error and state.download_error.message or nil)
  end

  render_section(lines, '说明:')
  lines[#lines + 1] = '  - 这个资源类型当前还没有原生缓冲区支持。'
  lines[#lines + 1] = '  - 需要完整功能时可使用 gx 打开远端页面。'
  if is_downloadable(entry) then
    lines[#lines + 1] = '  - 对普通文件可使用 o 下载到本地缓存并打开。'
  end

  if type(entry.raw) == 'table' then
    render_section(lines, 'Raw:')
    for _, line in ipairs(vim.split(vim.inspect(entry.raw), '\n', { plain = true })) do
      lines[#lines + 1] = line
    end
  end

  util.set_lines(state.bufnr, lines, { modifiable = false })
  vim.bo[state.bufnr].filetype = 'yaml'
end

local function finish_refresh(state)
  local fragments = {}
  if state.meta then
    fragments[#fragments + 1] = 'metadata ready'
  end
  if state.stats then
    fragments[#fragments + 1] = 'stats ready'
  end
  if #fragments == 0 then
    if is_downloadable(state.entry) then
      state.status = '资源信息已加载。可按 o 下载到本地缓存。'
    else
      state.status = '资源信息已加载。'
    end
  else
    state.status = table.concat(fragments, ' | ')
  end
  render(state)
end

local function refresh(state)
  state.meta = nil
  state.stats = nil
  state.meta_error = nil
  state.stats_error = nil
  state.status = '正在加载资源信息...'
  render(state)

  local pending = 0
  local function done()
    pending = pending - 1
    if pending <= 0 then
      finish_refresh(state)
    end
  end

  if supports_meta(state.entry) and type(state.entry.token) == 'string' and state.entry.token ~= '' then
    pending = pending + 1
    state.app.backend:file_meta(state.entry.token, entry_type(state.entry), function(payload, err)
      if err then
        state.meta_error = err
      else
        state.meta = payload
      end
      done()
    end)
  end

  if supports_stats(state.entry) and type(state.entry.token) == 'string' and state.entry.token ~= '' then
    pending = pending + 1
    state.app.backend:file_stats(state.entry.token, entry_type(state.entry), function(payload, err)
      if err then
        state.stats_error = err
      else
        state.stats = payload
      end
      done()
    end)
  end

  if pending == 0 then
    finish_refresh(state)
  end
end

local function open_text_file(state, path)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  local previous = state.bufnr
  vim.api.nvim_set_current_win(state.winid)
  vim.cmd('silent keepalt edit ' .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  if previous and previous ~= buf then
    states[previous] = nil
  end
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  local filetype = vim.filetype.match({ filename = path })
  if filetype and filetype ~= '' then
    vim.bo[buf].filetype = filetype
  end
  vim.b[buf].feishu_resource_local_path = path
  vim.b[buf].feishu_resource_url = state.entry.url or ''
end

local function download_and_open(state)
  if not is_downloadable(state.entry) then
    return
  end
  if state.download_inflight then
    return
  end
  if type(state.entry.token) ~= 'string' or state.entry.token == '' then
    vim.notify('Missing file token for download.', vim.log.levels.ERROR)
    return
  end

  local path = cache_path(state.app, state.entry)
  state.download_inflight = true
  state.download_error = nil
  state.status = ('正在下载到本地缓存: %s'):format(path)
  render(state)

  state.app.backend:file_download(state.entry.token, path, function(_, err)
    state.download_inflight = false
    if err then
      state.download_error = err
      state.status = '下载失败。'
      render(state)
      return
    end

    state.local_path = path
    state.status = '下载完成。'
    render(state)

    if is_text_path(path) then
      open_text_file(state, path)
      return
    end

    util.open_url(path)
    vim.notify(('Downloaded file opened with system handler: %s'):format(path), vim.log.levels.INFO, {
      title = resource_label(state.entry),
    })
  end)
end

local function attach_maps(buf, state)
  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map('gR', function()
    refresh(state)
  end, 'Refresh resource metadata view')
  if state.entry.url and state.entry.url ~= '' then
    map('gx', function()
      util.open_url(state.entry.url)
    end, 'Open remote Feishu URL')
  end
  if is_downloadable(state.entry) then
    map('o', function()
      download_and_open(state)
    end, 'Download file to local cache and open')
  end
  util.attach_help(buf, function()
    return {
      title = '飞书资源',
      items = help_items(state),
    }
  end)
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

  local buf = util.create_view_buffer(resource_view_name(entry), 'yaml', {
    bufhidden = 'hide',
  })
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

  refresh(state)
end

return M
