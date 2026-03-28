local util = require('feishu.util')

local M = {}

local ns = vim.api.nvim_create_namespace('feishu.browser')
local states = {}

local TYPE_ICONS = {
  category_docs = 'DOC',
  category_chats = 'MSG',
  category_search = 'FIND',
  category_recent = 'HIST',
  category_drive = 'DRIVE',
  category_wiki = 'WIKI',
  search_doc = 'FIND',
  folder = 'DIR',
  docx = 'DOC',
  doc = 'DOC',
  wiki = 'WIKI',
  wiki_space = 'SPACE',
  wiki_node = 'NODE',
  sheet = 'SHEET',
  bitable = 'BASE',
  file = 'FILE',
  slides = 'SLIDE',
  shortcut = 'LINK',
  mindnote = 'MIND',
}

local ENTRY_HL = {
  category_docs = { tag = 'Directory', name = 'Identifier' },
  category_chats = { tag = 'String', name = 'Identifier' },
  category_search = { tag = 'Constant', name = 'Identifier' },
  category_recent = { tag = 'Special', name = 'Identifier' },
  category_drive = { tag = 'Directory', name = 'Directory' },
  category_wiki = { tag = 'PreProc', name = 'Identifier' },
  search_doc = { tag = 'Constant', name = 'Identifier' },
  folder = { tag = 'Directory', name = 'Directory' },
  docx = { tag = 'Type', name = 'Normal' },
  doc = { tag = 'Type', name = 'Normal' },
  wiki = { tag = 'PreProc', name = 'Identifier' },
  wiki_space = { tag = 'Directory', name = 'Directory' },
  wiki_node = { tag = 'PreProc', name = 'Normal' },
  sheet = { tag = 'Special', name = 'Normal' },
  bitable = { tag = 'Constant', name = 'Type' },
  file = { tag = 'Comment', name = 'Normal' },
  slides = { tag = 'Special', name = 'Normal' },
  shortcut = { tag = 'Underlined', name = 'Normal' },
  mindnote = { tag = 'Special', name = 'Normal' },
}

local docs_empty_status

local function current_state(buf)
  return states[buf or vim.api.nvim_get_current_buf()]
end

local function current_entry(state)
  local line = vim.api.nvim_win_get_cursor(state.list_win)[1]
  return state.line_to_entry[line]
end

local function has_scope(state, scope)
  local current = state.auth_scope or ''
  if current == '' then
    return false
  end
  for token in current:gmatch('%S+') do
    if token == scope then
      return true
    end
  end
  return false
end

local function error_code(err)
  if type(err) ~= 'table' then
    return nil
  end
  if type(err.payload) == 'table' and err.payload.code ~= nil then
    return tostring(err.payload.code)
  end
  local raw = table.concat({
    type(err.message) == 'string' and err.message or '',
    type(err.raw) == 'string' and err.raw or '',
  }, '\n')
  local code = raw:match('code[=:]%s*(%d+)')
  if code and code ~= '' then
    return code
  end
  return nil
end

local function error_text(err)
  if type(err) ~= 'table' then
    return ''
  end
  return table.concat({
    type(err.message) == 'string' and err.message or '',
    type(err.raw) == 'string' and err.raw or '',
  }, '\n')
end

local function is_scope_error(err)
  local code = error_code(err)
  if code == '99991679' then
    return true
  end
  local text = error_text(err)
  return text:match('Unauthorized') ~= nil
      or text:match('用户授权') ~= nil
      or text:match('required one of these privileges') ~= nil
end

local function docs_source_note(kind, err)
  if not err then
    return nil
  end
  if kind == 'wiki' and is_scope_error(err) then
    return '知识库未授权，当前仅显示最近访问或可直接打开的文档。补 wiki:space:retrieve / wiki:wiki:readonly 后再重登。'
  end
  if kind == 'search' and is_scope_error(err) then
    return '当前 token 没有 search:docs:read，无法搜索云文档。可按 g 直接打开链接。'
  end
  if kind == 'drive' and is_scope_error(err) then
    return '云空间读取未授权，当前仅显示最近访问或知识库结果。'
  end
  if kind == 'wiki' then
    return '知识库列表暂时不可用。'
  end
  if kind == 'drive' then
    return '云空间列表暂时不可用。'
  end
  if kind == 'search' then
    return '云文档搜索暂时不可用。'
  end
  return nil
end

local function docs_root_status(state, entry_count, drive_error, wiki_error)
  local notes = {}
  local drive_note = docs_source_note('drive', drive_error)
  local wiki_note = docs_source_note('wiki', wiki_error)
  if drive_note then
    notes[#notes + 1] = drive_note
  end
  if wiki_note then
    notes[#notes + 1] = wiki_note
  end

  if #notes == 0 then
    if entry_count == 0 then
      return docs_empty_status(state)
    end
    return ('云文档 %d 条。'):format(entry_count)
  end

  if entry_count > 0 then
    return ('云文档 %d 条。%s'):format(entry_count, table.concat(notes, ' '))
  end
  return table.concat(notes, ' ')
end

local function should_surface_docs_error(entry_count, drive_error, wiki_error)
  if entry_count > 0 then
    return false
  end
  for _, err in ipairs({ drive_error, wiki_error }) do
    if err and not is_scope_error(err) then
      return true
    end
  end
  return false
end

local function current_page(state)
  return state.stack[#state.stack]
end

local function page_title(state)
  local current = current_page(state)
  if not current then
    return '飞书'
  end
  return current.name or '飞书'
end

local function should_show_status(state)
  local status = vim.trim(state.status or '')
  if status == '' then
    return false
  end
  if state.error then
    return true
  end
  if status:match('^云文档 %d+ 条。$')
      or status:match('^知识库 %d+ 个。$')
      or status:match('^最近打开 %d+ 条。$')
      or status:match('^云盘 %d+ 条。$')
      or status:match('^没有可见的知识库空间。$')
      or status:match('^云盘根目录当前没有可见资源。$') then
    return false
  end
  return true
end

local function context_line(state)
  if state.error then
    return '错误: ' .. (state.error.message or 'request failed'), 'ErrorMsg'
  end
  if vim.trim(state.docs_query or '') ~= '' then
    if should_show_status(state) then
      return ('搜索: %s | %s'):format(state.docs_query, state.status), 'Comment'
    end
    return ('搜索: %s'):format(state.docs_query), 'Comment'
  end
  if should_show_status(state) then
    return state.status, 'Comment'
  end
  return nil, nil
end

local function entry_display(entry)
  local tag = TYPE_ICONS[entry.type or entry.kind] or '..'
  local name = entry.name or entry.title or '<untitled>'
  return ('[%s] %s'):format(tag, name), tag, name
end

local function entry_highlight(entry)
  return ENTRY_HL[entry.type or entry.kind] or { tag = 'Comment', name = 'Normal' }
end

local function wiki_node_url(state, node_token)
  local host = state.app.opts.tenant_host
  if not host or host == '' then
    local base_url = state.app.opts.default_bitable_url
    host = base_url and base_url:match('https://([^/]+)/') or nil
  end
  host = host or 'feishu.cn'
  return ('https://%s/wiki/%s'):format(host, node_token)
end

local function preview_lines(entry)
  if not entry then
    return {
      '飞书',
      '',
      '选择一个条目预览或打开。',
    }
  end

  local lines = { entry.name or entry.title or entry.kind or '<entry>', '' }

  local entry_type = entry.type or entry.obj_type or entry.kind or 'unknown'
  lines[#lines + 1] = ('类型: %s'):format(entry_type)
  if entry.source and entry.source ~= '' then
    lines[#lines + 1] = ('来源: %s'):format(entry.source)
  end
  if entry.modified_time and entry.modified_time ~= '' then
    lines[#lines + 1] = ('更新: %s'):format(entry.modified_time)
  end
  if entry.owner_id and entry.owner_id ~= '' then
    lines[#lines + 1] = ('所有者: %s'):format(entry.owner_id)
  end
  if entry.url and entry.url ~= '' then
    lines[#lines + 1] = ('链接: %s'):format(entry.url)
  end
  if entry.token and entry.token ~= '' then
    lines[#lines + 1] = ('Token: %s'):format(entry.token)
  end

  lines[#lines + 1] = ''
  if entry.kind == 'category_docs' then
    lines[#lines + 1] = '进入云文档页面。'
  elseif entry.kind == 'category_chats' then
    lines[#lines + 1] = '进入消息页面。'
  elseif entry.kind == 'docs_home' then
    lines[#lines + 1] = '这是聚合入口页，不再把云文档首页错误地当成根目录。'
  elseif entry.kind == 'category_search' then
    lines[#lines + 1] = '搜索当前账号可见的云文档。'
  elseif entry.kind == 'category_recent' then
    lines[#lines + 1] = '查看在 feishu.nvim 中最近打开的文档。'
  elseif entry.kind == 'category_drive' then
    lines[#lines + 1] = '进入云盘目录视图。'
  elseif entry.kind == 'category_wiki' then
    lines[#lines + 1] = '进入知识库空间列表。'
  elseif entry.kind == 'search_doc' then
    if entry.source == 'docs_home' then
      lines[#lines + 1] = '这是当前账号可见的云文档资源。'
    else
      lines[#lines + 1] = '这是搜索结果。'
    end
  elseif entry.kind == 'wiki_space' or entry.kind == 'wiki_node_dir' then
    lines[#lines + 1] = '这是一个可继续进入的知识空间或节点。'
  elseif (entry.kind == 'wiki_node' or entry.type == 'wiki' or entry.source_type == 'wiki') and entry.type == 'sheet' then
    lines[#lines + 1] = '以只读表格预览方式打开；支持切换工作表和横向滚动。'
  elseif entry.type == 'sheet' then
    lines[#lines + 1] = '以只读表格预览方式打开；支持切换工作表和横向滚动。'
  elseif entry.type == 'slides' or entry.type == 'mindnote' or entry.type == 'file' or entry.type == 'shortcut' then
    lines[#lines + 1] = '打开本地 metadata 视图；可用 gx 跳转到远端页面。'
  elseif (entry.kind == 'wiki_node' or entry.type == 'wiki') and (entry.type == 'docx' or entry.type == 'doc' or entry.type == 'wiki') then
    lines[#lines + 1] = '导出为本地 Markdown 缓存并打开；docx 保存后会异步同步回远端。'
  elseif entry.type == 'docx' or entry.type == 'doc' then
    lines[#lines + 1] = '导出为本地 Markdown 缓存并打开；docx 保存后会异步同步回远端。'
  elseif entry.type == 'folder' then
    lines[#lines + 1] = '这是一个文件夹。'
  elseif entry.type == 'bitable' then
    lines[#lines + 1] = '进入多维表格视图。'
  else
    lines[#lines + 1] = '当前会直接打开远端 Feishu 链接。'
  end

  return lines
end

local function render_preview(state)
  if not state.preview_buf or not vim.api.nvim_buf_is_valid(state.preview_buf) then
    return
  end
  local entry = current_entry(state)
  local lines = preview_lines(entry)
  util.set_lines(state.preview_buf, lines)
  vim.api.nvim_buf_clear_namespace(state.preview_buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Title', 0, 0, -1)
  for index, line in ipairs(lines) do
    if line:match('^类型:') or line:match('^来源:') or line:match('^更新:') or line:match('^所有者:') or line:match('^链接:') or line:match('^Token:') then
      vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Comment', index - 1, 0, -1)
    end
  end
end

local function render(state)
  local lines = { page_title(state) }
  local marks = {
    title = 1,
    context = nil,
    hints = nil,
    entries = {},
    empty = nil,
  }
  local context, context_hl = context_line(state)
  state._context_hl = context_hl
  if context then
    lines[#lines + 1] = context
    marks.context = #lines
  end

  state.line_to_entry = {}
  for _, entry in ipairs(state.entries) do
    local display, tag, name = entry_display(entry)
    lines[#lines + 1] = display
    state.line_to_entry[#lines] = entry
    marks.entries[#marks.entries + 1] = {
      line = #lines,
      tag = tag,
      name = name,
    }
  end

  if #state.entries == 0 then
    lines[#lines + 1] = '(empty)'
    marks.empty = #lines
  end

  util.set_lines(state.list_buf, lines)
  vim.api.nvim_buf_clear_namespace(state.list_buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Title', marks.title - 1, 0, -1)
  if marks.context then
    vim.api.nvim_buf_add_highlight(state.list_buf, ns, state._context_hl or 'Comment', marks.context - 1, 0, -1)
  end
  if marks.empty then
    vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Comment', marks.empty - 1, 0, -1)
  end
  for _, item in ipairs(marks.entries) do
    local entry = state.line_to_entry[item.line]
    local hls = entry_highlight(entry)
    local tag_end = #item.tag + 2
    local name_start = #item.tag + 3
    vim.api.nvim_buf_add_highlight(state.list_buf, ns, hls.tag or 'Comment', item.line - 1, 0, tag_end)
    vim.api.nvim_buf_add_highlight(state.list_buf, ns, hls.name or 'Normal', item.line - 1, name_start, -1)
  end

  render_preview(state)
end

local function help_items(state)
  local items = {
    { 'l / <CR>', '打开或进入当前条目' },
    { 'h', '返回上一级' },
    { 'r', '刷新当前页面' },
    { 'q', '关闭当前浏览页' },
  }
  local current = current_page(state)
  if current and (current.kind == 'docs_home' or current.kind == 'docs_search') then
    items[#items + 1] = { 's', '搜索云文档' }
  end
  if current and current.kind == 'docs_search' then
    items[#items + 1] = { 'S', '清除当前搜索' }
  end
  if current and (current.kind == 'docs_home' or current.kind == 'drive_root' or current.kind == 'drive_folder' or current.kind == 'wiki_root' or current.kind == 'wiki_space' or current.kind == 'wiki_node_dir') then
    items[#items + 1] = { 'a', '在当前容器创建文档' }
    items[#items + 1] = { 'g', '输入链接后直接打开' }
  end
  return items
end

local function non_empty(...)
  for _, value in ipairs({ ... }) do
    if type(value) == 'string' and vim.trim(value) ~= '' then
      return value
    end
  end
  return nil
end

local function resource_name(title, token, url)
  local name = non_empty(title, token)
  if name then
    return name
  end
  if type(url) == 'string' and url ~= '' then
    local tail = url:match('/([^/?#]+)$')
    if tail and tail ~= '' then
      return tail
    end
  end
  return '<doc>'
end

local function build_docs_home_entries(state, items)
  local recent_count = #(state.app.session.recent_docs or {})
  local entries = {
    {
      kind = 'category_search',
      name = '搜索云文档',
      type = 'category_search',
    },
    {
      kind = 'category_recent',
      name = recent_count > 0 and ('最近打开 (%d)'):format(recent_count) or '最近打开',
      type = 'category_recent',
    },
    {
      kind = 'category_wiki',
      name = '知识库',
      type = 'category_wiki',
    },
    {
      kind = 'category_drive',
      name = '云盘',
      type = 'category_drive',
    },
  }

  for _, item in ipairs(items or {}) do
    local token = item.DocsToken or item.docs_token
    local url = item.URL or item.url
    entries[#entries + 1] = {
      kind = 'search_doc',
      name = resource_name(non_empty(item.Title, item.title), token, url),
      token = token,
      type = item.DocsType or item.docs_type or 'file',
      owner_id = item.OwnerID or item.owner_id,
      url = url,
      source = 'docs_home',
    }
  end

  return entries
end

local function build_recent_entries(state)
  local entries = {}
  for _, item in ipairs(state.app.session.recent_docs or {}) do
    entries[#entries + 1] = vim.tbl_extend('force', {
      kind = 'recent_doc',
      source = 'recent',
    }, item)
  end
  return entries
end

local function remember_recent_doc(state, entry)
  if not entry or not entry.url or entry.url == '' then
    return
  end
  if entry.type == 'folder' or entry.kind == 'wiki_space' or entry.kind == 'wiki_node_dir' then
    return
  end

  local recent = state.app.session.recent_docs or {}
  local updated = {
    name = entry.name or entry.title or '<untitled>',
    token = entry.token,
    type = entry.type,
    url = entry.url,
    source = entry.source or 'recent',
  }

  local next_items = { updated }
  for _, item in ipairs(recent) do
    if item.url ~= updated.url then
      next_items[#next_items + 1] = item
    end
    if #next_items >= 12 then
      break
    end
  end
  state.app.session.recent_docs = next_items
end

local function build_search_entries(items)
  local entries = {}
  for _, item in ipairs(items or {}) do
    local token = item.DocsToken or item.docs_token
    local url = item.URL or item.url
    entries[#entries + 1] = {
      kind = 'search_doc',
      name = resource_name(non_empty(item.Title, item.title), token, url),
      token = token,
      type = item.DocsType or item.docs_type or 'file',
      owner_id = item.OwnerID or item.owner_id,
      url = url,
      source = 'search',
    }
  end
  return entries
end

docs_empty_status = function(state)
  local can_search = has_scope(state, 'search:docs:read')
  local has_wiki_scope = has_scope(state, 'wiki:space:retrieve')
      or has_scope(state, 'wiki:wiki:readonly')
      or has_scope(state, 'wiki:wiki')

  if can_search and has_wiki_scope then
    return '当前没有可见的云文档资源。可搜索文档，或按 g 直接打开链接。'
  end

  local missing = {}
  if not can_search then
    missing[#missing + 1] = 'search:docs:read'
  end
  if not has_wiki_scope then
    missing[#missing + 1] = 'wiki:space:retrieve / wiki:wiki:readonly'
  end
  if #missing == 0 then
    return '当前没有可见的云文档资源。可按 g 直接打开链接。'
  end
  return ('当前没有可见的云文档资源。可按 g 直接打开链接；若要补全文档浏览能力，需要补 %s。'):format(table.concat(missing, '，'))
end

local function refresh_root(state)
  state.entries = {
    {
      kind = 'category_docs',
      name = '云文档',
      type = 'category_docs',
    },
    {
      kind = 'category_chats',
      name = '消息',
      type = 'category_chats',
    },
  }
  state.error = nil
  state.status = ''
  render(state)
end

local function refresh_docs_home(state)
  state.entries = build_docs_home_entries(state, {})
  state.error = nil
  state.status = '正在加载云文档...'
  render(state)

  state.app.backend:search_docs('', function(payload, err)
    local current = current_page(state)
    if not current or current.kind ~= 'docs_home' then
      return
    end

    if err then
      state.entries = build_docs_home_entries(state, {})
      if is_scope_error(err) then
        state.error = nil
        state.status = docs_source_note('search', err) or docs_empty_status(state)
      else
        state.error = err
        state.status = '云文档首页加载失败。'
      end
      render(state)
      return
    end

    state.entries = build_docs_home_entries(state, payload.items or {})
    state.error = nil
    state.status = ''
    if #state.entries <= 4 then
      state.status = docs_empty_status(state)
    end
    render(state)
  end)
end

local function refresh_docs_search(state)
  local query = vim.trim(state.docs_query or '')
  if query == '' then
    state.entries = {}
    state.error = nil
    state.status = '按 s 输入关键词搜索云文档。'
    render(state)
    return
  end

  state.app.backend:search_docs(query, function(payload, err)
    if err then
      state.entries = {}
      if is_scope_error(err) then
        state.error = nil
        state.status = docs_source_note('search', err)
      else
        state.error = err
        state.status = ('搜索 "%s" 失败。'):format(query)
      end
      render(state)
      return
    end
    state.entries = build_search_entries(payload.items or {})
    state.error = nil
    if #state.entries == 0 then
      state.status = ('没有找到与 "%s" 相关的文档。'):format(query)
    elseif payload.has_more then
      state.status = ('搜索: %s  (%d 条，结果未全部显示)'):format(query, #state.entries)
    else
      state.status = ('搜索: %s  (%d 条)'):format(query, #state.entries)
    end
    render(state)
  end)
end

local function refresh_recent_docs(state)
  state.entries = build_recent_entries(state)
  state.error = nil
  if #state.entries == 0 then
    state.status = '还没有本地最近打开记录。'
  else
    state.status = ('最近打开 %d 条。'):format(#state.entries)
  end
  render(state)
end

local function refresh_wiki_root(state)
  state.app.backend:wiki_spaces(function(payload, err)
    if err then
      if is_scope_error(err) then
        state.error = nil
        state.entries = {}
        state.status = docs_source_note('wiki', err) or '知识库列表暂时不可用。'
      else
        state.error = err
        state.entries = {}
        state.status = '知识库列表不可用。'
      end
      render(state)
      return
    end

    state.entries = {}
    for _, item in ipairs(payload.items or {}) do
      state.entries[#state.entries + 1] = {
        kind = 'wiki_space',
        name = item.name or item.space_id or '<space>',
        token = item.space_id,
        type = 'wiki_space',
        visibility = item.visibility,
        space_type = item.space_type,
        source = 'wiki',
      }
    end
    state.error = nil
    state.status = #state.entries > 0 and ('知识库 %d 个。'):format(#state.entries) or '没有可见的知识库空间。'
    render(state)
  end)
end

local function refresh_drive_root(state)
  state.app.backend:drive_list(nil, function(payload, err)
    if err then
      if is_scope_error(err) then
        state.error = nil
        state.entries = {}
        state.status = docs_source_note('drive', err) or '云空间列表暂时不可用。'
      else
        state.error = err
        state.entries = {}
        state.status = '云空间列表不可用。'
      end
      render(state)
      return
    end

    state.entries = {}
    for _, item in ipairs(payload.files or {}) do
      state.entries[#state.entries + 1] = {
        kind = 'drive_file',
        name = item.name or item.token or '<unnamed>',
        token = item.token,
        type = item.type,
        url = item.url,
        modified_time = item.modified_time,
        parent_token = item.parent_token,
        source = 'drive',
      }
    end
    state.error = nil
    state.status = #state.entries > 0 and ('云盘 %d 条。'):format(#state.entries) or '云盘根目录当前没有可见资源。'
    render(state)
  end)
end

local function refresh_drive_folder(state, current)
  state.app.backend:drive_list(current.token, function(payload, err)
    if err then
      state.error = err
      state.status = '云空间列表不可用。'
      render(state)
      return
    end

    state.entries = {}
    for _, item in ipairs(payload.files or {}) do
      state.entries[#state.entries + 1] = {
        kind = 'drive_file',
        name = item.name or item.token or '<unnamed>',
        token = item.token,
        type = item.type,
        url = item.url,
        modified_time = item.modified_time,
        parent_token = item.parent_token,
        source = 'drive',
      }
    end
    state.status = ('云文档 %d 条。'):format(#state.entries)
    state.error = nil
    render(state)
  end)
end

local function refresh_wiki_container(state, current)
  state.app.backend:wiki_nodes(current.space_id, current.parent_node_token, function(payload, err)
    if err then
      state.error = err
      state.status = '知识空间列表不可用。'
      render(state)
      return
    end

    state.entries = {}
    for _, item in ipairs(payload.items or {}) do
      local is_dir = item.has_child == true
      state.entries[#state.entries + 1] = {
        kind = is_dir and 'wiki_node_dir' or 'wiki_node',
        name = item.title or item.node_token or '<node>',
        token = item.node_token,
        node_token = item.node_token,
        obj_token = item.obj_token,
        obj_type = item.obj_type,
        type = item.obj_type or 'wiki',
        has_child = item.has_child,
        space_id = current.space_id,
        parent_node_token = item.node_token,
        url = wiki_node_url(state, item.node_token),
        source = 'wiki',
      }
    end
    state.status = ('云文档 %d 条。'):format(#state.entries)
    state.error = nil
    render(state)
  end)
end

local function refresh(state)
  state.status = '正在加载资源...'
  state.error = nil
  render(state)

  local current = state.stack[#state.stack]
  if not current then
    refresh_root(state)
    return
  end
  if current.kind == 'docs_home' then
    refresh_docs_home(state)
    return
  end
  if current.kind == 'docs_search' then
    refresh_docs_search(state)
    return
  end
  if current.kind == 'docs_recent' then
    refresh_recent_docs(state)
    return
  end
  if current.kind == 'wiki_root' then
    refresh_wiki_root(state)
    return
  end
  if current.kind == 'drive_root' then
    refresh_drive_root(state)
    return
  end
  if current.kind == 'drive_folder' then
    refresh_drive_folder(state, current)
    return
  end
  if current.kind == 'wiki_space' or current.kind == 'wiki_node_dir' then
    refresh_wiki_container(state, current)
    return
  end
end

local function go_up(state)
  if #state.stack == 0 then
    return
  end
  table.remove(state.stack)
  refresh(state)
end

local function prompt_docs_search(state)
  vim.ui.input({
    prompt = '搜索云文档: ',
    default = state.docs_query or '',
  }, function(input)
    if input == nil then
      return
    end
    state.docs_query = vim.trim(input)
    if state.docs_query ~= '' then
      local current = current_page(state)
      if not current or current.kind ~= 'docs_search' then
        state.stack[#state.stack + 1] = {
          kind = 'docs_search',
          name = '搜索',
        }
      end
    end
    refresh(state)
  end)
end

local function clear_docs_search(state)
  state.docs_query = ''
  local current = current_page(state)
  if current and current.kind == 'docs_search' then
    go_up(state)
    return
  end
  refresh(state)
end

local open_entry

local function can_manage_docs_here(state)
  local current = current_page(state)
  if not current then
    return false
  end
  return current.kind == 'docs_home'
      or current.kind == 'drive_root'
      or current.kind == 'drive_folder'
      or current.kind == 'wiki_root'
      or current.kind == 'wiki_space'
      or current.kind == 'wiki_node_dir'
end

local function prompt_create_doc(state)
  if not can_manage_docs_here(state) then
    return
  end
  vim.ui.input({
    prompt = '新建文档标题: ',
  }, function(input)
    local title = vim.trim(input or '')
    if title == '' then
      return
    end

    local current = current_page(state)
    state.status = ('正在创建文档: %s'):format(title)
    state.error = nil
    render(state)

    local on_created = function(payload, err)
      if err then
        state.error = err
        state.status = '文档创建失败。'
        render(state)
        return
      end

      local entry = {
        kind = 'created_doc',
        name = payload.title or title,
        token = payload.document_id or payload.node_token or payload.obj_token,
        type = payload.type or payload.obj_type or 'docx',
        url = payload.url,
        source = 'created',
      }
      remember_recent_doc(state, entry)
      state.status = ('已创建文档: %s'):format(entry.name)
      state.error = nil
      render(state)
      if entry.url and entry.url ~= '' then
        util.open_url(entry.url)
      end
    end

    if current.kind == 'wiki_space' or current.kind == 'wiki_node_dir' then
      state.app.backend:wiki_create_doc(current.space_id, current.parent_node_token, title, on_created)
    else
      local folder_token = current.kind == 'drive_folder' and current.token or nil
      state.app.backend:doc_create(title, folder_token, on_created)
    end
  end)
end

local function prompt_open_url(state)
  vim.ui.input({
    prompt = '打开飞书链接: ',
  }, function(input)
    local url = vim.trim(input or '')
    if url == '' then
      return
    end

    state.status = '正在解析链接...'
    state.error = nil
    render(state)

    state.app.backend:resolve_url(url, function(payload, err)
      if err then
        state.status = '链接解析失败，直接尝试打开。'
        state.error = nil
        render(state)
        util.open_url(url)
        return
      end

      local entry = {
        kind = 'manual_url',
        name = payload.title or payload.token or url,
        token = payload.token,
        node_token = payload.node_token,
        obj_token = payload.obj_token,
        type = payload.obj_type or payload.source_type or 'docx',
        source_type = payload.source_type,
        url = url,
        source = 'manual',
      }
      remember_recent_doc(state, entry)
      state.status = '链接已解析。'
      state.error = nil
      render(state)
      open_entry(state, entry)
    end)
  end)
end

local function hand_off_to_new_view(state)
  util.close_window(state.preview_win)
  util.close_buffer(state.preview_buf)
  state.preview_win = nil
  state.preview_buf = nil
end

open_entry = function(state, entry)
  if not entry then
    return
  end

  if entry.kind == 'category_docs' then
    state.stack[#state.stack + 1] = {
      kind = 'docs_home',
      name = entry.name,
    }
    refresh(state)
    return
  end

  if entry.kind == 'category_search' then
    prompt_docs_search(state)
    return
  end

  if entry.kind == 'category_recent' then
    state.stack[#state.stack + 1] = {
      kind = 'docs_recent',
      name = '最近打开',
    }
    refresh(state)
    return
  end

  if entry.kind == 'category_wiki' then
    state.stack[#state.stack + 1] = {
      kind = 'wiki_root',
      name = '知识库',
    }
    refresh(state)
    return
  end

  if entry.kind == 'category_drive' then
    state.stack[#state.stack + 1] = {
      kind = 'drive_root',
      name = '云盘',
    }
    refresh(state)
    return
  end

  if entry.kind == 'category_chats' then
    hand_off_to_new_view(state)
    require('feishu').open_chats()
    return
  end

  if entry.kind == 'wiki_space' then
    state.stack[#state.stack + 1] = {
      kind = 'wiki_space',
      space_id = entry.token,
      name = entry.name,
      parent_node_token = nil,
    }
    refresh(state)
    return
  end

  if entry.kind == 'wiki_node_dir' then
    state.stack[#state.stack + 1] = {
      kind = 'wiki_node_dir',
      space_id = entry.space_id,
      name = entry.name,
      parent_node_token = entry.node_token,
    }
    refresh(state)
    return
  end

  if entry.type == 'folder' then
    state.stack[#state.stack + 1] = {
      kind = 'drive_folder',
      token = entry.token,
      name = entry.name,
    }
    refresh(state)
    return
  end

  if entry.type == 'bitable' and entry.url and entry.url ~= '' then
    remember_recent_doc(state, entry)
    hand_off_to_new_view(state)
    require('feishu').open_tasks({ base_url = entry.url })
    return
  end

  if entry.type == 'sheet' then
    remember_recent_doc(state, entry)
    require('feishu').open_sheet(entry, {
      target_win = state.preview_win,
      split = 'right',
    })
    return
  end

  if entry.type == 'slides' or entry.type == 'mindnote' or entry.type == 'file' or entry.type == 'shortcut' then
    remember_recent_doc(state, entry)
    require('feishu').open_resource(entry, {
      target_win = state.preview_win,
      split = 'right',
    })
    return
  end

  if (entry.kind == 'wiki_node' or entry.type == 'wiki' or entry.source_type == 'wiki') and (entry.type == 'docx' or entry.type == 'doc' or entry.type == 'wiki') then
    remember_recent_doc(state, entry)
    require('feishu').open_document(entry, {
      target_win = state.preview_win,
      split = 'right',
    })
    return
  end

  if entry.type == 'docx' or entry.type == 'doc' then
    remember_recent_doc(state, entry)
    require('feishu').open_document(entry, {
      target_win = state.preview_win,
      split = 'right',
    })
    return
  end

  if entry.url and entry.url ~= '' then
    remember_recent_doc(state, entry)
    util.open_url(entry.url)
    return
  end

  vim.notify('这个条目暂时还没有可打开的 URL。', vim.log.levels.WARN)
end

local function on_cursor_moved(buf)
  local state = current_state(buf)
  if not state then
    return
  end
  render_preview(state)
end

function M.open(app)
  local list_win = vim.api.nvim_get_current_win()
  local list_buf = util.create_scratch_buffer('feishu://browser', 'feishu-browser')
  vim.api.nvim_win_set_buf(list_win, list_buf)
  util.configure_selection_window(list_win, list_buf, { wrap = false })

  vim.cmd('botright vsplit')
  local preview_win = vim.api.nvim_get_current_win()
  local preview_buf = util.create_scratch_buffer('feishu://browser-preview', 'feishu-browser-preview')
  vim.api.nvim_win_set_buf(preview_win, preview_buf)
  vim.wo[preview_win].number = false
  vim.wo[preview_win].relativenumber = false
  vim.wo[preview_win].wrap = true
  pcall(vim.api.nvim_win_set_width, preview_win, math.max(42, math.floor(vim.o.columns * (app.opts.ui.preview_width or 0.42))))

  vim.cmd('wincmd h')
  list_win = vim.api.nvim_get_current_win()

  local state = {
    app = app,
    list_buf = list_buf,
    list_win = list_win,
    preview_buf = preview_buf,
    preview_win = preview_win,
    stack = {},
    entries = {},
    line_to_entry = {},
    status = 'Loading...',
    error = nil,
    docs_query = '',
    auth_scope = nil,
  }
  states[list_buf] = state
  util.attach_help(preview_buf, function()
    return {
      title = '飞书浏览',
      items = help_items(state),
    }
  end)

  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = list_buf, silent = true, nowait = true, desc = desc })
  end

  map('q', function()
    util.close_window(preview_win)
    util.close_buffer(preview_buf)
    util.close_buffer(list_buf)
  end, 'Close browser')
  map('r', function()
    refresh(state)
  end, 'Refresh browser')
  map('h', function()
    go_up(state)
  end, 'Go up')
  map('s', function()
    local current = state.stack[#state.stack]
    if current and (current.kind == 'docs_home' or current.kind == 'docs_search') then
      prompt_docs_search(state)
    end
  end, 'Search docs')
  map('S', function()
    local current = state.stack[#state.stack]
    if current and current.kind == 'docs_search' then
      clear_docs_search(state)
    end
  end, 'Clear docs search')
  map('a', function()
    prompt_create_doc(state)
  end, 'Create doc here')
  map('g', function()
    prompt_open_url(state)
  end, 'Open manual URL')
  util.attach_help(list_buf, function()
    return {
      title = '飞书浏览',
      items = help_items(state),
    }
  end)
  map('<CR>', function()
    open_entry(state, current_entry(state))
  end, 'Open entry')
  map('l', function()
    open_entry(state, current_entry(state))
  end, 'Open entry')

  local group = vim.api.nvim_create_augroup(('FeishuBrowser_%d'):format(list_buf), { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    buffer = list_buf,
    callback = function()
      on_cursor_moved(list_buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = list_buf,
    callback = function()
      states[list_buf] = nil
      util.close_window(preview_win)
      util.close_buffer(preview_buf)
    end,
  })

  render(state)
  refresh(state)
end

return M
