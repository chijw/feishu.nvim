local util = require('feishu.util')
local picker = require('feishu.ui.picker')

local M = {}

local ns = vim.api.nvim_create_namespace('feishu.bitable')
local states = {}
local form_states = {}
local open_current_link

local UI_TYPE_WIDTHS = {
  Text = { min = 10, max = 32 },
  Number = { min = 8, max = 14 },
  Checkbox = { min = 5, max = 8 },
  SingleSelect = { min = 6, max = 14 },
  MultiSelect = { min = 8, max = 20 },
  User = { min = 8, max = 20 },
  DateTime = { min = 16, max = 16 },
  SingleLink = { min = 8, max = 24 },
  DuplexLink = { min = 8, max = 24 },
  Formula = { min = 8, max = 18 },
}

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR)
end

local function extract_text(value)
  if value == nil then
    return ''
  end
  if type(value) == 'string' then
    return value
  end
  if type(value) == 'table' then
    if value.value and type(value.value) == 'table' then
      return extract_text(value.value)
    end
    if value.text or value.name or value.link then
      return tostring(value.text or value.name or value.link or '')
    end
    local parts = {}
    for _, item in ipairs(value) do
      parts[#parts + 1] = extract_text(item)
    end
    return table.concat(parts)
  end
  return tostring(value)
end

local function extract_people(value)
  if type(value) ~= 'table' then
    return {}
  end
  local names = {}
  for _, item in ipairs(value) do
    if type(item) == 'table' and item.name then
      names[#names + 1] = tostring(item.name)
    end
  end
  return names
end

local function extract_people_objects(value)
  if type(value) ~= 'table' then
    return {}
  end
  local items = {}
  for _, item in ipairs(value) do
    if type(item) == 'table' and item.id and item.name then
      items[#items + 1] = {
        id = tostring(item.id),
        name = tostring(item.name),
      }
    end
  end
  return items
end

local function extract_date(value)
  if value == nil or value == '' then
    return ''
  end
  if type(value) == 'number' then
    return os.date('%Y-%m-%d %H:%M', math.floor(value / 1000))
  end
  return tostring(value)
end

local function extract_link_record_ids(value)
  if type(value) ~= 'table' then
    return {}
  end
  if value.link_record_ids and type(value.link_record_ids) == 'table' then
    return vim.tbl_map(tostring, value.link_record_ids)
  end
  if value.record_ids and type(value.record_ids) == 'table' then
    return vim.tbl_map(tostring, value.record_ids)
  end
  local ids = {}
  for _, item in ipairs(value) do
    local nested = extract_link_record_ids(item)
    for _, record_id in ipairs(nested) do
      ids[#ids + 1] = record_id
    end
  end
  return ids
end

local function tenant_host(app)
  local host = type(app.opts.tenant_host) == 'string' and app.opts.tenant_host or ''
  if host ~= '' then
    return host
  end
  local base_url = type(app.opts.default_bitable_url) == 'string' and app.opts.default_bitable_url or ''
  local matched = base_url:match('https://([^/]+)/')
  if matched and matched ~= '' then
    return matched
  end
  return 'feishu.cn'
end

local function base_token_from_url(base_url)
  if type(base_url) ~= 'string' then
    return 'unknown'
  end
  return base_url:match('/base/([^/?]+)') or 'unknown'
end

local function bitable_view_name(base_url)
  return ('feishu://bitable/%s'):format(base_token_from_url(base_url))
end

local function mention_resource_type(item)
  local raw = tostring(item.realMentionType or item.mentionType or ''):lower()
  local aliases = {
    doc = 'doc',
    docs = 'doc',
    docx = 'docx',
    sheet = 'sheet',
    bitable = 'bitable',
    wiki = 'wiki',
    folder = 'folder',
    file = 'file',
    slides = 'slides',
    mindnote = 'mindnote',
  }
  return aliases[raw]
end

local function mention_url(app, item)
  local direct = type(item.link) == 'string' and item.link or (type(item.url) == 'string' and item.url or nil)
  if direct and direct ~= '' then
    return direct
  end
  local token = type(item.token) == 'string' and item.token or ''
  local resource_type = mention_resource_type(item)
  if token == '' or not resource_type then
    return nil
  end
  local host = tenant_host(app)
  if resource_type == 'wiki' then
    return ('https://%s/wiki/%s'):format(host, token)
  end
  if resource_type == 'bitable' then
    return ('https://%s/base/%s'):format(host, token)
  end
  return ('https://%s/%s/%s'):format(host, resource_type, token)
end

local function append_link(links, seen, link)
  if not link or type(link.url) ~= 'string' or link.url == '' then
    return
  end
  local key = ('%s\0%s'):format(link.url, tostring(link.label or ''))
  if seen[key] then
    return
  end
  seen[key] = true
  links[#links + 1] = link
end

local function extract_links(app, value, links, seen)
  links = links or {}
  seen = seen or {}
  if value == nil then
    return links
  end
  if type(value) == 'string' then
    for url in value:gmatch('https?://[^%s%)%]]+') do
      append_link(links, seen, {
        label = url,
        url = url,
      })
    end
    return links
  end
  if type(value) == 'table' then
    local url = mention_url(app, value)
    if url then
      append_link(links, seen, {
        label = tostring(value.text or value.name or value.token or url),
        url = url,
        token = type(value.token) == 'string' and value.token or nil,
        resource_type = mention_resource_type(value),
      })
    end
    if value.text and type(value.text) == 'string' then
      extract_links(app, value.text, links, seen)
    end
    if value.value then
      extract_links(app, value.value, links, seen)
    end
    for _, item in ipairs(value) do
      extract_links(app, item, links, seen)
    end
    for key, item in pairs(value) do
      if type(key) ~= 'number'
          and key ~= 'link'
          and key ~= 'url'
          and key ~= 'text'
          and key ~= 'value'
          and key ~= 'token'
          and key ~= 'mentionType'
          and key ~= 'realMentionType'
          and key ~= 'type'
          and key ~= 'name' then
        extract_links(app, item, links, seen)
      end
    end
  end
  return links
end

local function markdown_link(label, url)
  return ('[%s](%s)'):format(label or url or '', url or '')
end

local function format_rich_value(value, app)
  if value == nil then
    return ''
  end
  if type(value) == 'string' then
    return value
  end
  if type(value) == 'number' then
    return extract_date(value)
  end
  if type(value) == 'table' then
    local link = mention_url(app or { opts = {} }, value)
    if link then
      return markdown_link(tostring(value.text or value.name or value.token or link), link)
    end
    if #value > 0 then
      local parts = {}
      local rich_sequence = true
      for _, item in ipairs(value) do
        if type(item) ~= 'table' or (item.type == nil and item.text == nil and item.link == nil and item.url == nil) then
          rich_sequence = false
        end
      end
      for _, item in ipairs(value) do
        local item_link = type(item) == 'table' and mention_url(app or { opts = {} }, item) or nil
        if item_link then
          parts[#parts + 1] = markdown_link(tostring(item.text or item.name or item.token or item_link), item_link)
        else
          parts[#parts + 1] = format_rich_value(item, app)
        end
      end
      return table.concat(parts, rich_sequence and '' or ', ')
    end
    if value.type and value.value then
      return format_rich_value(value.value, app)
    end
    return extract_text(value)
  end
  return tostring(value)
end

local function date_to_ms(raw)
  local value = vim.trim(raw or '')
  if value == '' then
    return nil
  end

  local year, month, day, hour, minute = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)$')
  if not year then
    year, month, day = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    hour = '00'
    minute = '00'
  end
  if not year then
    return nil
  end

  local timestamp = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(minute),
    sec = 0,
  })
  if not timestamp then
    return nil
  end

  local check = os.date('*t', timestamp)
  if check.year ~= tonumber(year)
      or check.month ~= tonumber(month)
      or check.day ~= tonumber(day)
      or check.hour ~= tonumber(hour)
      or check.min ~= tonumber(minute) then
    return nil
  end

  return timestamp * 1000
end

local function split_csv(raw)
  local parts = {}
  for _, item in ipairs(vim.split((raw or ''):gsub('，', ','), ',', { trimempty = true })) do
    local trimmed = vim.trim(item)
    if trimmed ~= '' then
      parts[#parts + 1] = trimmed
    end
  end
  return parts
end

local function parse_primary_field(fields)
  for _, field in ipairs(fields or {}) do
    if field.is_primary and field.field_name then
      return tostring(field.field_name), tostring(field.field_id or field.field_name)
    end
  end
  local first = fields and fields[1] or nil
  if first and first.field_name then
    return tostring(first.field_name), tostring(first.field_id or first.field_name)
  end
  return 'Title', 'Title'
end

local function field_options(field)
  local options = {}
  local property = type(field.property) == 'table' and field.property or {}
  for _, option in ipairs(property.options or {}) do
    local name = tostring(option.name or '')
    if name ~= '' then
      options[#options + 1] = name
    end
  end
  return options
end

local function is_parent_link_field(field, table_id)
  if not field or not table_id then
    return false
  end
  local ui_type = tostring(field.ui_type or '')
  if ui_type ~= 'SingleLink' and ui_type ~= 'DuplexLink' then
    return false
  end
  local property = type(field.property) == 'table' and field.property or {}
  return tostring(property.table_id or '') == tostring(table_id)
end

local function editable_field(field)
  local ui_type = tostring(field.ui_type or '')
  return ui_type == 'Text'
      or ui_type == 'Number'
      or ui_type == 'Checkbox'
      or ui_type == 'SingleSelect'
      or ui_type == 'MultiSelect'
      or ui_type == 'User'
      or ui_type == 'DateTime'
      or ui_type == 'SingleLink'
      or ui_type == 'DuplexLink'
end

local function preferred_fields(fields)
  local visible = {}
  for _, field in ipairs(fields or {}) do
    if not field.is_hidden then
      visible[#visible + 1] = field
    end
  end
  return visible
end

local function column_specs(fields)
  local specs = {}
  local importance = 100
  for _, field in ipairs(preferred_fields(fields)) do
    local sizes = UI_TYPE_WIDTHS[tostring(field.ui_type or '')] or { min = 8, max = 20 }
    local title = tostring(field.field_name or field.field_id or '<field>')
    specs[#specs + 1] = {
      key = tostring(field.field_id or title),
      title = title,
      min_width = field.is_primary and 20 or sizes.min,
      max_width = field.is_primary and 40 or sizes.max,
      importance = importance,
      pinned = field.is_primary == true,
      can_hide = field.is_primary ~= true,
      field_name = title,
    }
    importance = math.max(10, importance - 5)
  end
  return specs
end

local function current_state(buf)
  return states[buf or vim.api.nvim_get_current_buf()]
end

local function current_row(state)
  local line = vim.api.nvim_win_get_cursor(state.list_win)[1]
  return state.line_to_row[line]
end

local function current_record(state)
  local row = current_row(state)
  return row and row.record or nil
end

local function current_base_url(state)
  if not state.active_table_id or state.active_table_id == '' then
    return state.base_url
  end
  return ('%s?table=%s'):format(state.base_root, state.active_table_id)
end

local function configure_preview(state)
  if not state.preview_win or not vim.api.nvim_win_is_valid(state.preview_win)
      or not state.preview_buf or not vim.api.nvim_buf_is_valid(state.preview_buf) then
    return
  end
  vim.api.nvim_win_set_buf(state.preview_win, state.preview_buf)
  vim.wo[state.preview_win].number = false
  vim.wo[state.preview_win].relativenumber = false
  vim.wo[state.preview_win].wrap = true
  pcall(vim.api.nvim_win_set_width, state.preview_win, math.max(42, math.floor(vim.o.columns * (state.app.opts.ui.preview_width or 0.42))))
  util.attach_help(state.preview_buf, function()
    local items = {
      { '<S-Tab>', '切换当前 base 内的 table' },
      { 'h / l', '横向切换可见列' },
      { 'J / K', '快速上下移动' },
      { '<CR>', '重新打开右侧详情预览' },
      { 'i', '编辑当前记录' },
      { 'd', '删除当前记录' },
      { 'o', '打开当前记录中的第一个链接' },
      { 'r', '刷新当前表' },
      { 'q', '关闭当前 bitable 页' },
    }
    if state.parent_field_name then
      table.insert(items, 4, { 'a', '在当前组下新增记录' })
      table.insert(items, 5, { 'A', '新增顶层记录' })
    else
      table.insert(items, 4, { 'a / A', '新增记录' })
    end
    return {
      title = '飞书多维表格',
      items = items,
    }
  end)
  vim.keymap.set('n', 'o', function()
    open_current_link(state)
  end, { buffer = state.preview_buf, silent = true, nowait = true, desc = 'Open link under cursor' })
  vim.keymap.set('n', '<CR>', function()
    open_current_link(state)
  end, { buffer = state.preview_buf, silent = true, nowait = true, desc = 'Open link under cursor' })
end

local function ensure_preview_window(state)
  if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win)
      and state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then
    configure_preview(state)
    return true
  end
  if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then
    return false
  end

  vim.api.nvim_set_current_win(state.list_win)
  vim.cmd('botright vsplit')
  state.preview_win = vim.api.nvim_get_current_win()
  if not state.preview_buf or not vim.api.nvim_buf_is_valid(state.preview_buf) then
    state.preview_buf = util.create_scratch_buffer('feishu://bitable-detail', 'feishu-bitable-detail')
  end
  configure_preview(state)

  vim.cmd('wincmd h')
  state.list_win = vim.api.nvim_get_current_win()
  return true
end

local function record_label_from_fields(fields, primary_field_name, record_id)
  local label = extract_text(fields[primary_field_name])
  if label == '' then
    return tostring(record_id or '')
  end
  return label
end

local function record_parent_ids(fields, parent_field_name)
  if not parent_field_name or parent_field_name == '' then
    return {}
  end
  return extract_link_record_ids(fields[parent_field_name])
end

local function build_users(records, fields)
  local user_fields = {}
  for _, field in ipairs(fields or {}) do
    if tostring(field.ui_type or '') == 'User' and field.field_name then
      user_fields[#user_fields + 1] = tostring(field.field_name)
    end
  end

  local users = {}
  for _, record in ipairs(records or {}) do
    local raw_fields = type(record.fields) == 'table' and record.fields or {}
    for _, field_name in ipairs(user_fields) do
      for _, item in ipairs(extract_people_objects(raw_fields[field_name])) do
        users[item.name] = item.id
      end
    end
  end
  return users
end

local function build_rows(records, primary_field_name, parent_field_name)
  local record_by_id = {}
  local order = {}
  for _, record in ipairs(records or {}) do
    local record_id = tostring(record.record_id or '')
    local fields = type(record.fields) == 'table' and record.fields or {}
    local label = record_label_from_fields(fields, primary_field_name, record_id)
    record_by_id[record_id] = {
      record_id = record_id,
      label = label,
      fields = fields,
      raw = record,
      parent_record_ids = record_parent_ids(fields, parent_field_name),
    }
    order[#order + 1] = record_id
  end

  local children_by_parent = {}
  for _, record_id in ipairs(order) do
    local record = record_by_id[record_id]
    local parent_id = record.parent_record_ids[1]
    if parent_id and parent_id ~= record_id and record_by_id[parent_id] then
      children_by_parent[parent_id] = children_by_parent[parent_id] or {}
      children_by_parent[parent_id][#children_by_parent[parent_id] + 1] = record_id
    end
  end

  local root_ids = {}
  for _, record_id in ipairs(order) do
    local record = record_by_id[record_id]
    local parent_id = record.parent_record_ids[1]
    if not parent_id or not record_by_id[parent_id] then
      root_ids[#root_ids + 1] = record_id
    end
  end

  local rows = {}
  local function collect(record_id, depth, current_group, trail)
    local record = record_by_id[record_id]
    if not record or trail[record_id] then
      return
    end

    local group = current_group or record
    rows[#rows + 1] = {
      record = record,
      depth = depth,
      group_record_id = group.record_id,
      group_label = group.label ~= '' and group.label or group.record_id,
      is_group = depth == 0,
    }

    local next_trail = vim.deepcopy(trail)
    next_trail[record_id] = true
    for _, child_id in ipairs(children_by_parent[record_id] or {}) do
      collect(child_id, depth + 1, group, next_trail)
    end
  end

  for _, record_id in ipairs(root_ids) do
    collect(record_id, 0, nil, {})
  end

  return rows, record_by_id, children_by_parent
end

local function descendant_ids(children_by_parent, record_id)
  local results = {}
  local seen = {}
  local stack = vim.deepcopy(children_by_parent[record_id] or {})
  while #stack > 0 do
    local current = table.remove(stack, 1)
    if not seen[current] then
      seen[current] = true
      results[#results + 1] = current
      for _, child_id in ipairs(children_by_parent[current] or {}) do
        stack[#stack + 1] = child_id
      end
    end
  end
  return results
end

local function build_link_maps(state, exclude_record_id)
  local label_to_id = {}
  local id_to_label = {}
  local used_labels = {}
  local excluded = {}

  if exclude_record_id then
    excluded[exclude_record_id] = true
    for _, record_id in ipairs(descendant_ids(state.children_by_parent, exclude_record_id)) do
      excluded[record_id] = true
    end
  end

  for _, row in ipairs(state.rows) do
    local record = row.record
    if not excluded[record.record_id] then
      local label = record.label ~= '' and record.label or record.record_id
      if used_labels[label] then
        label = ('%s :: %s'):format(label, record.record_id)
      end
      used_labels[label] = true
      label_to_id[label] = record.record_id
      id_to_label[record.record_id] = label
    end
  end

  return label_to_id, id_to_label
end

local function field_value_display(state, field, value)
  local ui_type = tostring(field.ui_type or '')
  if ui_type == 'DateTime' then
    return extract_date(value), {}
  end
  if ui_type == 'User' then
    return table.concat(extract_people(value), ', '), {}
  end
  if ui_type == 'SingleLink' or ui_type == 'DuplexLink' then
    local _, id_to_label = build_link_maps(state, nil)
    local parts = {}
    for _, record_id in ipairs(extract_link_record_ids(value)) do
      parts[#parts + 1] = id_to_label[record_id] or record_id
    end
    return table.concat(parts, ', '), {}
  end
  return format_rich_value(value, state.app), extract_links(state.app, value)
end

local function field_value_to_string(state, field, value)
  local rendered = field_value_display(state, field, value)
  return rendered
end

local function row_values(state, row)
  local values = {}
  local raw_fields = row.record.fields
  for _, field in ipairs(preferred_fields(state.schema_fields)) do
    local key = tostring(field.field_id or field.field_name)
    local rendered = field_value_to_string(state, field, raw_fields[field.field_name])
    if field.is_primary then
      local marker = row.is_group and '+ ' or '- '
      rendered = string.rep('  ', row.depth) .. marker .. (rendered ~= '' and rendered or row.record.record_id)
    end
    values[key] = rendered
  end
  return values
end

local function selected_parent_record_id(state)
  if not state.parent_field_name then
    return nil
  end
  local row = current_row(state)
  if not row then
    return nil
  end
  if row.is_group then
    return row.record.record_id
  end
  return row.group_record_id or row.record.parent_record_ids[1]
end

local function build_form_lines(state, record, parent_record_id)
  local values = {}
  for _, field in ipairs(state.editable_fields) do
    values[field.field_name] = record and field_value_to_string(state, field, record.fields[field.field_name]) or ''
  end

  if state.parent_field_name and parent_record_id and values[state.parent_field_name] == '' then
    local _, id_to_label = build_link_maps(state, record and record.record_id or nil)
    values[state.parent_field_name] = id_to_label[parent_record_id] or parent_record_id
  end

  local lines = {}
  for _, field in ipairs(state.editable_fields) do
    lines[#lines + 1] = ('%s: %s'):format(field.field_name, values[field.field_name] or '')
  end

  return lines
end

local function parse_form(state, buf)
  local parsed = {}
  local seen = {}
  local editable_names = {}
  for _, field in ipairs(state.editable_fields) do
    editable_names[field.field_name] = true
    parsed[field.field_name] = ''
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for index, raw_line in ipairs(lines) do
    local trimmed = vim.trim(raw_line)
    if trimmed ~= '' and not trimmed:match('^#') then
      local key, value = raw_line:match('^([^:]+):%s*(.*)$')
      if not key then
        return nil, ('Line %d must use `字段名: 值` 格式。'):format(index)
      end
      key = vim.trim(key)
      if not editable_names[key] then
        return nil, ('Unknown field `%s` on line %d.'):format(key, index)
      end
      if seen[key] then
        return nil, ('Duplicate field `%s` on line %d.'):format(key, index)
      end
      parsed[key] = value
      seen[key] = true
    end
  end

  return parsed
end

local function picker_capable(field)
  local ui_type = tostring(field.ui_type or '')
  return ui_type == 'SingleSelect'
      or ui_type == 'MultiSelect'
      or ui_type == 'User'
      or ui_type == 'Checkbox'
      or ui_type == 'SingleLink'
      or ui_type == 'DuplexLink'
end

local function form_cursor_field(form_state)
  if not vim.api.nvim_win_is_valid(form_state.winid) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(form_state.winid)[1]
  local raw = vim.api.nvim_buf_get_lines(form_state.bufnr, line - 1, line, false)[1] or ''
  local field_name, value = raw:match('^([^:]+):%s*(.*)$')
  if not field_name then
    return nil
  end
  field_name = vim.trim(field_name)
  for _, field in ipairs(form_state.parent_state.editable_fields) do
    if field.field_name == field_name then
      return field, value or '', line
    end
  end
  return nil
end

local function picker_items_for_field(form_state, field, current_value)
  local ui_type = tostring(field.ui_type or '')
  local selected_map = {}
  for _, value in ipairs(split_csv(current_value or '')) do
    selected_map[value] = true
  end

  if ui_type == 'Checkbox' then
    return {
      items = {
        { label = 'true', value = 'true', selected = selected_map['true'] or selected_map['1'] or selected_map['yes'] },
        { label = 'false', value = 'false', selected = selected_map['false'] or selected_map['0'] or selected_map['no'] },
      },
      multiple = false,
    }
  end

  if ui_type == 'SingleSelect' or ui_type == 'MultiSelect' then
    local items = {}
    for _, label in ipairs(field_options(field)) do
      items[#items + 1] = {
        label = label,
        value = label,
        selected = selected_map[label] == true,
      }
    end
    return {
      items = items,
      multiple = ui_type == 'MultiSelect',
    }
  end

  if ui_type == 'User' then
    local items = {}
    local labels = vim.tbl_keys(form_state.parent_state.users or {})
    table.sort(labels)
    for _, label in ipairs(labels) do
      items[#items + 1] = {
        label = label,
        value = label,
        selected = selected_map[label] == true,
      }
    end
    return {
      items = items,
      multiple = true,
    }
  end

  if ui_type == 'SingleLink' or ui_type == 'DuplexLink' then
    local label_to_id = build_link_maps(form_state.parent_state, form_state.record_id)
    local items = {}
    local labels = vim.tbl_keys(label_to_id)
    table.sort(labels)
    for _, label in ipairs(labels) do
      items[#items + 1] = {
        label = label,
        value = label,
        selected = selected_map[label] == true,
      }
    end
    local property = type(field.property) == 'table' and field.property or {}
    return {
      items = items,
      multiple = property.multiple == true or ui_type == 'DuplexLink',
    }
  end

  return nil
end

local function open_form_picker(form_state)
  local field, value, line = form_cursor_field(form_state)
  if not field then
    return
  end
  if not picker_capable(field) then
    vim.notify('当前字段不适合用浮动选择窗。', vim.log.levels.INFO)
    return
  end

  local payload = picker_items_for_field(form_state, field, value)
  if not payload or #payload.items == 0 then
    vim.notify('当前字段没有可选项。', vim.log.levels.WARN)
    return
  end

  picker.open({
    title = field.field_name,
    items = payload.items,
    multiple = payload.multiple,
    on_confirm = function(_, labels)
      if not vim.api.nvim_win_is_valid(form_state.winid) or not vim.api.nvim_buf_is_valid(form_state.bufnr) then
        return
      end
      vim.api.nvim_set_current_win(form_state.winid)
      vim.bo[form_state.bufnr].modifiable = true
      vim.bo[form_state.bufnr].readonly = false
      vim.api.nvim_buf_set_lines(form_state.bufnr, line - 1, line, false, {
        ('%s: %s'):format(field.field_name, table.concat(labels, ', ')),
      })
      pcall(vim.api.nvim_win_set_cursor, form_state.winid, { line, 0 })
    end,
  })
end

local function enter_insert_for_field(form_state)
  local field, _, line = form_cursor_field(form_state)
  if not field or not vim.api.nvim_win_is_valid(form_state.winid) then
    return
  end
  local raw = vim.api.nvim_buf_get_lines(form_state.bufnr, line - 1, line, false)[1] or ''
  local prefix = ('%s: '):format(field.field_name)
  local column = raw:find(prefix, 1, true)
  if column == 1 then
    pcall(vim.api.nvim_win_set_cursor, form_state.winid, { line, #prefix })
  else
    pcall(vim.api.nvim_win_set_cursor, form_state.winid, { line, #raw })
  end
  vim.api.nvim_set_current_win(form_state.winid)
  vim.cmd('startinsert')
end

local function edit_current_form_field(form_state)
  local field = form_cursor_field(form_state)
  if not field then
    return
  end
  if picker_capable(field) then
    open_form_picker(form_state)
    return
  end
  enter_insert_for_field(form_state)
end

local function form_help_items()
  return {
    { '<CR>', '编辑当前字段' },
    { 'i / I / a / A', '编辑当前字段；选项字段打开 picker' },
    { ':w', '保存当前记录' },
    { ':wq', '保存并关闭当前窗口' },
    { ':q', '关闭当前窗口' },
    { ':q!', '丢弃未保存改动并关闭' },
  }
end

local function parse_checkbox(raw)
  local value = vim.trim((raw or ''):lower())
  if value == 'true' or value == '1' or value == 'yes' or value == 'y' or value == 'on' then
    return true
  end
  if value == 'false' or value == '0' or value == 'no' or value == 'n' or value == 'off' then
    return false
  end
  return nil
end

local function build_fields_from_form(state, form, opts)
  opts = opts or {}
  local for_update = opts.for_update == true
  local link_label_to_id = build_link_maps(state, opts.exclude_record_id)
  local fields = {}

  for _, field in ipairs(state.editable_fields) do
    local field_name = field.field_name
    local raw = vim.trim(form[field_name] or '')
    local ui_type = tostring(field.ui_type or '')
    local options = field_options(field)

    if field.is_primary and raw == '' then
      return nil, ('%s is required.'):format(field_name)
    end

    if raw == '' then
      if for_update then
        fields[field_name] = vim.NIL
      end
    elseif ui_type == 'Text' then
      fields[field_name] = raw
    elseif ui_type == 'Number' then
      local number = tonumber(raw)
      if not number then
        return nil, ('%s must be a number.'):format(field_name)
      end
      fields[field_name] = number
    elseif ui_type == 'Checkbox' then
      local value = parse_checkbox(raw)
      if value == nil then
        return nil, ('%s must be true/false.'):format(field_name)
      end
      fields[field_name] = value
    elseif ui_type == 'SingleSelect' then
      if #options > 0 and not vim.tbl_contains(options, raw) then
        return nil, ('%s must be one of: %s'):format(field_name, table.concat(options, ', '))
      end
      fields[field_name] = raw
    elseif ui_type == 'MultiSelect' then
      local values = split_csv(raw)
      if #options > 0 then
        for _, value in ipairs(values) do
          if not vim.tbl_contains(options, value) then
            return nil, ('%s must only use: %s'):format(field_name, table.concat(options, ', '))
          end
        end
      end
      fields[field_name] = values
    elseif ui_type == 'User' then
      local values = {}
      local missing = {}
      for _, item in ipairs(split_csv(raw)) do
        local id = state.users[item]
        if not id and item:match('^ou_') then
          id = item
        end
        if id then
          values[#values + 1] = { id = id }
        else
          missing[#missing + 1] = item
        end
      end
      if #missing > 0 then
        return nil, ('Unknown user(s): %s'):format(table.concat(missing, ', '))
      end
      fields[field_name] = values
    elseif ui_type == 'DateTime' then
      local timestamp = date_to_ms(raw)
      if not timestamp then
        return nil, ('%s must use YYYY-MM-DD or YYYY-MM-DD HH:MM.'):format(field_name)
      end
      fields[field_name] = timestamp
    elseif ui_type == 'SingleLink' or ui_type == 'DuplexLink' then
      local ids = {}
      for _, item in ipairs(split_csv(raw)) do
        ids[#ids + 1] = link_label_to_id[item] or item
      end
      fields[field_name] = { link_record_ids = ids }
    else
      return nil, ('Unsupported editable field type for %s: %s'):format(field_name, ui_type)
    end
  end

  return fields
end

local function render_preview(state)
  if not ensure_preview_window(state) then
    return
  end

  local row = current_row(state)
  if not row then
    state.preview_line_links = {}
    util.set_lines(state.preview_buf, {
      '多维表格详情',
      '',
      '移动到一条记录上查看字段。',
    })
    return
  end

  local record = row.record
  local fields = record.fields
  local _, id_to_label = build_link_maps(state, nil)
  state.preview_line_links = {}
  local lines

  local function append_field_line(field_name, rendered, links)
    local line = ('%s: %s'):format(field_name, rendered ~= '' and rendered or '-')
    lines[#lines + 1] = line
    if links and #links > 0 then
      state.preview_line_links[#lines] = links[1]
    end
  end

  lines = {
    record.label ~= '' and record.label or record.record_id,
    ('record_id: %s'):format(record.record_id),
    ('table: %s'):format(state.active_table_name or state.active_table_id or '<table>'),
    '',
  }

  local seen = {}
  local collected_links = {}
  local seen_links = {}
  for _, field in ipairs(state.schema_fields or {}) do
    local field_name = field.field_name
    if field_name then
      seen[field_name] = true
      local rendered
      local links = {}
      local value = fields[field_name]
      if field_name == state.parent_field_name then
        local labels = {}
        for _, record_id in ipairs(extract_link_record_ids(value)) do
          labels[#labels + 1] = id_to_label[record_id] or record_id
        end
        rendered = table.concat(labels, ', ')
      else
        rendered, links = field_value_display(state, field, value)
      end
      append_field_line(field_name, rendered, links)
      for _, link in ipairs(links or {}) do
        append_link(collected_links, seen_links, link)
      end
    end
  end

  for field_name, value in pairs(fields) do
    if not seen[field_name] then
      local rendered = format_rich_value(value, state.app)
      local links = extract_links(state.app, value)
      append_field_line(field_name, rendered, links)
      for _, link in ipairs(links or {}) do
        append_link(collected_links, seen_links, link)
      end
    end
  end

  if #collected_links > 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '链接'
    for index, link in ipairs(collected_links) do
      lines[#lines + 1] = ('%d. %s'):format(index, markdown_link(link.label or link.url, link.url))
      state.preview_line_links[#lines] = link
    end
  end

  util.set_lines(state.preview_buf, lines)
  vim.api.nvim_buf_clear_namespace(state.preview_buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Title', 0, 0, -1)
  for index, line in ipairs(lines) do
    if line == '链接' then
      vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Identifier', index - 1, 0, -1)
    elseif line:match('^record_id:') or line:match('^table:') then
      vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Comment', index - 1, 0, -1)
    elseif state.preview_line_links[index] then
      local colon = line:find(': ', 1, true)
      local start_col = colon and (colon + 1) or 0
      vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Underlined', index - 1, start_col, -1)
    end
  end
end

local function move_cursor_to_record(state, record_id)
  if not record_id then
    return
  end
  for line, row in pairs(state.line_to_row) do
    if row.record.record_id == record_id and vim.api.nvim_win_is_valid(state.list_win) then
      pcall(vim.api.nvim_win_set_cursor, state.list_win, { line, 0 })
      return
    end
  end
end

local function render(state)
  if not vim.api.nvim_buf_is_valid(state.list_buf) then
    return
  end

  local selected = current_record(state)
  local selected_record_id = selected and selected.record_id or state.last_selected_record_id
  local width = vim.api.nvim_win_is_valid(state.list_win) and vim.api.nvim_win_get_width(state.list_win) or math.floor(vim.o.columns * 0.55)
  local row_values_list = {}
  for _, row in ipairs(state.rows) do
    row_values_list[#row_values_list + 1] = row_values(state, row)
  end
  local shown, widths, hidden_right, skipped_left = util.window_compact_columns(state.column_specs, row_values_list, math.max(30, width - 1), state.column_offset)

  local active_index = 0
  for index, item in ipairs(state.tables) do
    if item.table_id == state.active_table_id then
      active_index = index
      break
    end
  end

  local lines = {
    ('飞书多维表格  [%s]'):format(state.active_table_name or state.active_table_id or '<table>'),
    ('table %d/%d'):format(active_index > 0 and active_index or 1, math.max(1, #state.tables)),
    state.error and ('错误: ' .. (state.error.message or 'request failed')) or (state.status or ''),
    '',
    nil,
    util.render_separator(shown, widths),
  }
  local header_values = {}
  for _, spec in ipairs(shown) do
    header_values[spec.key] = spec.title
  end
  lines[5] = util.render_compact_row(shown, widths, header_values)

  state.line_to_row = {}
  for _, row in ipairs(state.rows) do
    lines[#lines + 1] = util.render_compact_row(shown, widths, row_values(state, row))
    state.line_to_row[#lines] = row
  end

  if #state.rows == 0 then
    lines[#lines + 1] = '(no records)'
  end

  util.set_lines(state.list_buf, lines)
  vim.api.nvim_buf_clear_namespace(state.list_buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Title', 0, 0, -1)
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Comment', 1, 0, -1)
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, state.error and 'ErrorMsg' or 'Comment', 2, 0, -1)
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Identifier', 4, 0, -1)
  for line, row in pairs(state.line_to_row) do
    if row.is_group and state.parent_field_name then
      vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Statement', line - 1, 0, -1)
    end
  end

  if #state.rows > 0 then
    move_cursor_to_record(state, selected_record_id or state.rows[1].record.record_id)
  end
  local record = current_record(state)
  state.last_selected_record_id = record and record.record_id or state.last_selected_record_id
  render_preview(state)
end

local function help_items(state)
  local items = {
    { '<S-Tab>', '切换当前 base 内的 table' },
    { 'h / l', '横向切换可见列' },
    { 'J / K', '快速上下移动' },
    { '<CR>', '重新打开右侧详情预览' },
    { 'i', '编辑当前记录' },
    { 'd', '删除当前记录' },
    { 'o', '打开当前记录中的第一个链接' },
    { 'r', '刷新当前表' },
    { 'q', '关闭当前 bitable 页' },
  }
  if state.parent_field_name then
    table.insert(items, 4, { 'a', '在当前组下新增记录' })
    table.insert(items, 5, { 'A', '新增顶层记录' })
  else
    table.insert(items, 4, { 'a / A', '新增记录' })
  end
  return items
end

local function refresh_table_data(state)
  local base_url = current_base_url(state)
  local selected = current_record(state)
  state.last_selected_record_id = selected and selected.record_id or state.last_selected_record_id
  state.status = '正在加载表结构和记录...'
  state.error = nil
  render(state)

  local remaining = 2
  local next_schema_fields = state.schema_fields
  local next_records = nil
  local next_error = nil

  local function finish()
    remaining = remaining - 1
    if remaining > 0 then
      return
    end

    state.schema_fields = next_schema_fields
    state.primary_field_name, state.primary_field_id = parse_primary_field(next_schema_fields)
    state.parent_field_name = nil
    for _, field in ipairs(next_schema_fields or {}) do
      if is_parent_link_field(field, state.active_table_id) then
        state.parent_field_name = tostring(field.field_name or '')
        break
      end
    end
    state.column_specs = column_specs(next_schema_fields)
    state.editable_fields = {}
    state.readonly_fields = {}
    for _, field in ipairs(next_schema_fields or {}) do
      if not field.is_hidden then
        if editable_field(field) then
          state.editable_fields[#state.editable_fields + 1] = field
        else
          state.readonly_fields[#state.readonly_fields + 1] = tostring(field.field_name or field.field_id or '<field>')
        end
      end
    end

    if not next_error and next_records then
      state.records = next_records
      state.users = build_users(next_records, next_schema_fields)
      state.rows, state.record_by_id, state.children_by_parent = build_rows(next_records, state.primary_field_name, state.parent_field_name)
    else
      state.records = {}
      state.users = {}
      state.rows = {}
      state.record_by_id = {}
      state.children_by_parent = {}
    end

    state.error = next_error
    if next_error then
      state.status = '加载失败。'
    else
      state.status = ('已加载 %d 条记录。'):format(#state.records)
    end
    render(state)
  end

  state.app.backend:base_fields(base_url, state.active_table_id, nil, function(payload, err)
    if err then
      next_error = err
    else
      next_schema_fields = payload.items or {}
    end
    finish()
  end)

  state.app.backend:base_records_search(base_url, state.active_table_id, nil, function(payload, err)
    if err then
      next_error = err
    else
      next_records = payload.items or {}
    end
    finish()
  end)
end

local function refresh(state)
  state.status = '正在加载数据表...'
  state.error = nil
  render(state)
  state.app.backend:base_tables(state.base_root, function(payload, err)
    if err then
      state.error = err
      state.status = '数据表列表加载失败。'
      render(state)
      return
    end

    state.tables = payload.items or {}
    if #state.tables > 0 then
      local found = false
      for _, item in ipairs(state.tables) do
        if item.table_id == state.active_table_id then
          state.active_table_name = item.name or item.table_id
          found = true
          break
        end
      end
      if not found then
        state.active_table_id = state.tables[1].table_id
        state.active_table_name = state.tables[1].name or state.tables[1].table_id
      end
    end
    refresh_table_data(state)
  end)
end

local function extract_saved_record_id(payload, fallback)
  if type(fallback) == 'string' and fallback ~= '' then
    return fallback
  end
  if type(payload) ~= 'table' then
    return nil
  end
  if type(payload.record_id) == 'string' and payload.record_id ~= '' then
    return payload.record_id
  end
  local record = type(payload.record) == 'table' and payload.record or nil
  if record and type(record.record_id) == 'string' and record.record_id ~= '' then
    return record.record_id
  end
  local data = type(payload.data) == 'table' and payload.data or nil
  if data and type(data.record_id) == 'string' and data.record_id ~= '' then
    return data.record_id
  end
  return nil
end

local function save_form(form_state, opts)
  opts = opts or {}
  if form_state.pending then
    return false
  end

  local form, parse_error = parse_form(form_state.parent_state, form_state.bufnr)
  if not form then
    notify_error(parse_error)
    return false
  end

  local fields, field_error = build_fields_from_form(form_state.parent_state, form, {
    for_update = form_state.record_id ~= nil,
    exclude_record_id = form_state.record_id,
  })
  if not fields then
    notify_error(field_error)
    return false
  end

  form_state.pending = true
  vim.bo[form_state.bufnr].modifiable = false
  vim.bo[form_state.bufnr].readonly = true
  form_state.parent_state.status = '正在保存记录...'
  render(form_state.parent_state)
  local done = false
  local ok = false

  local callback = function(payload, err)
    form_state.pending = false
    if err then
      vim.bo[form_state.bufnr].modifiable = true
      vim.bo[form_state.bufnr].readonly = false
      form_state.parent_state.status = '保存失败。'
      form_state.parent_state.error = err
      render(form_state.parent_state)
      notify_error(err.message or 'Save failed.')
      done = true
      return
    end

    local saved_record_id = extract_saved_record_id(payload, form_state.record_id)
    if saved_record_id then
      form_state.record_id = saved_record_id
    end
    ok = true
    vim.bo[form_state.bufnr].modifiable = true
    vim.bo[form_state.bufnr].readonly = false
    vim.bo[form_state.bufnr].modified = false
    form_state.parent_state.status = '记录已保存。'
    form_state.parent_state.error = nil
    refresh_table_data(form_state.parent_state)
    done = true
  end

  if form_state.record_id then
    form_state.parent_state.app.backend:record_update(current_base_url(form_state.parent_state), form_state.record_id, fields, callback)
  else
    form_state.parent_state.app.backend:record_add(current_base_url(form_state.parent_state), fields, callback)
  end

  if opts.blocking then
    local finished = vim.wait(opts.timeout_ms or 30000, function()
      return done
    end, 50)
    if not finished then
      form_state.pending = false
      vim.bo[form_state.bufnr].modifiable = true
      vim.bo[form_state.bufnr].readonly = false
      form_state.parent_state.status = '保存超时。'
      form_state.parent_state.error = { message = 'Timed out while saving the record.' }
      render(form_state.parent_state)
      notify_error('Timed out while saving the record.')
      return false
    end
    return ok
  end

  return true
end

local function open_form(state, record, parent_record_id)
  vim.cmd('botright split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(win, math.max(8, math.floor(vim.o.lines * (state.app.opts.ui.form_height or 0.4))))
  local buf = util.create_scratch_buffer('feishu://bitable-form', 'feishu-bitable-form')
  vim.bo[buf].buftype = 'acwrite'
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = false

  util.set_lines(buf, build_form_lines(state, record, parent_record_id), { modifiable = true })
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false

  local target_line = 1
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match('^[^#].-:%s*') then
      target_line = index
      break
    end
  end
  pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })

  local form_state = {
    parent_state = state,
    bufnr = buf,
    winid = win,
    record_id = record and record.record_id or nil,
    pending = false,
  }
  form_states[buf] = form_state

  local map = function(lhs, rhs, desc, mode)
    vim.keymap.set(mode or 'n', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map('<CR>', function()
    edit_current_form_field(form_state)
  end, 'Edit current field')
  map('i', function()
    edit_current_form_field(form_state)
  end, 'Edit current field')
  map('I', function()
    edit_current_form_field(form_state)
  end, 'Edit current field')
  map('a', function()
    edit_current_form_field(form_state)
  end, 'Edit current field')
  map('A', function()
    edit_current_form_field(form_state)
  end, 'Edit current field')

  util.attach_help(buf, {
    title = '记录编辑',
    items = form_help_items(),
  })

  local group = vim.api.nvim_create_augroup(('FeishuBitableForm_%d'):format(buf), { clear = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = buf,
    callback = function()
      save_form(form_state, { blocking = true })
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      form_states[buf] = nil
    end,
  })
end

local function delete_current_record(state)
  local record = current_record(state)
  if not record then
    return
  end

  local child_count = #(state.children_by_parent[record.record_id] or {})
  local prompt = child_count > 0
      and ('Delete `%s` and detach %d child records?'):format(record.label, child_count)
      or ('Delete `%s`?'):format(record.label ~= '' and record.label or record.record_id)
  local choice = vim.fn.confirm(prompt, '&Yes\n&No', 2)
  if choice ~= 1 then
    return
  end

  state.status = '正在删除记录...'
  state.error = nil
  render(state)
  state.app.backend:record_delete(current_base_url(state), record.record_id, function(_, err)
    if err then
      state.status = '删除失败。'
      state.error = err
      render(state)
      notify_error(err.message or 'Delete failed.')
      return
    end

    state.status = '记录已删除。'
    state.error = nil
    refresh_table_data(state)
  end)
end

local function current_preview_link(state)
  if not state.preview_win or not vim.api.nvim_win_is_valid(state.preview_win) then
    return nil
  end
  if vim.api.nvim_get_current_win() ~= state.preview_win then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(state.preview_win)[1]
  return state.preview_line_links and state.preview_line_links[line] or nil
end

local function first_record_link(state)
  local record = current_record(state)
  if not record then
    return nil
  end
  local links = extract_links(state.app, record.fields)
  return links[1]
end

local function open_link_target(state, link)
  if not link or type(link.url) ~= 'string' or link.url == '' then
    vim.notify('当前记录里没有可打开的链接。', vim.log.levels.WARN)
    return
  end

  state.app.backend:resolve_url(link.url, function(payload, err)
    if err or type(payload) ~= 'table' then
      util.open_url(link.url)
      return
    end

    local entry = {
      kind = 'bitable_link',
      name = link.label or payload.title or payload.token or link.url,
      token = payload.token,
      node_token = payload.node_token,
      obj_token = payload.obj_token,
      type = payload.obj_type or payload.source_type or link.resource_type or 'url',
      source_type = payload.source_type,
      url = payload.url or link.url,
      source = 'bitable_link',
      raw = payload.raw,
    }
    local target_opts = {
      split = 'right',
    }

    if entry.type == 'sheet' then
      require('feishu').open_sheet(entry, target_opts)
      return
    end
    if entry.type == 'slides' or entry.type == 'mindnote' or entry.type == 'file' or entry.type == 'shortcut' then
      require('feishu').open_resource(entry, target_opts)
      return
    end
    if (entry.kind == 'wiki_node' or entry.type == 'wiki' or entry.source_type == 'wiki')
        and (entry.type == 'docx' or entry.type == 'doc' or entry.type == 'wiki') then
      require('feishu').open_document(entry, target_opts)
      return
    end
    if entry.type == 'docx' or entry.type == 'doc' then
      require('feishu').open_document(entry, target_opts)
      return
    end
    if entry.type == 'bitable' and entry.url and entry.url ~= '' then
      require('feishu').open_bitable({
        base_url = entry.url,
        split = 'right',
      })
      return
    end

    util.open_url(link.url)
  end)
end

open_current_link = function(state)
  local link = current_preview_link(state) or first_record_link(state)
  open_link_target(state, link)
end

local function fast_move(state, delta)
  if #state.rows == 0 or not vim.api.nvim_win_is_valid(state.list_win) then
    return
  end
  local line = vim.api.nvim_win_get_cursor(state.list_win)[1]
  local target = math.max(7, math.min(line + delta, 6 + #state.rows))
  vim.api.nvim_win_set_cursor(state.list_win, { target, 0 })
end

local function cycle_table(state)
  if #state.tables <= 1 then
    vim.notify('当前 base 只有一个 table。', vim.log.levels.INFO)
    return
  end
  local current_index = 1
  for index, item in ipairs(state.tables) do
    if item.table_id == state.active_table_id then
      current_index = index
      break
    end
  end
  local next_index = (current_index % #state.tables) + 1
  state.active_table_id = state.tables[next_index].table_id
  state.active_table_name = state.tables[next_index].name or state.active_table_id
  state.column_offset = 0
  refresh_table_data(state)
end

local function on_cursor_moved(buf)
  local state = current_state(buf)
  if not state then
    return
  end
  local row = current_row(state)
  if row then
    state.last_selected_record_id = row.record.record_id
    render_preview(state)
  end
end

function M.refresh_current()
  local state = current_state()
  if state then
    refresh(state)
  end
end

function M.open(app, opts)
  opts = opts or {}
  local base_url = opts.base_url or opts.bitable_url or app.opts.default_bitable_url
  if not base_url or base_url == '' then
    notify_error('No base_url configured for feishu.nvim.')
    return
  end

  local list_win = opts.target_win
  if not list_win or not vim.api.nvim_win_is_valid(list_win) then
    if opts.split == 'right' then
      vim.cmd('botright vsplit')
      list_win = vim.api.nvim_get_current_win()
    else
      list_win = vim.api.nvim_get_current_win()
    end
  end
  local list_buf = util.create_view_buffer(bitable_view_name(base_url), 'feishu-bitable', {
    bufhidden = 'hide',
  })
  vim.api.nvim_win_set_buf(list_win, list_buf)
  util.configure_selection_window(list_win, list_buf, { wrap = false })

  vim.api.nvim_set_current_win(list_win)
  vim.cmd('botright vsplit')
  local preview_win = vim.api.nvim_get_current_win()
  local preview_buf = util.create_scratch_buffer('feishu://bitable-detail', 'feishu-bitable-detail')
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
    base_url = base_url,
    base_root = (base_url:match('^[^?]+') or base_url),
    active_table_id = base_url:match('[?&]table=([^&]+)'),
    active_table_name = base_url:match('[?&]table=([^&]+)') or '<table>',
    tables = {},
    schema_fields = {},
    column_specs = { { key = 'placeholder', title = '记录', min_width = 20, max_width = 20, importance = 100, pinned = true } },
    editable_fields = {},
    readonly_fields = {},
    primary_field_name = 'Title',
    primary_field_id = 'Title',
    parent_field_name = nil,
    users = {},
    records = {},
    rows = {},
    record_by_id = {},
    children_by_parent = {},
    line_to_row = {},
    column_offset = 0,
    status = '正在加载...',
    error = nil,
    last_selected_record_id = nil,
  }
  states[list_buf] = state
  configure_preview(state)

  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = list_buf, silent = true, nowait = true, desc = desc })
  end

  map('q', function()
    util.close_window(state.preview_win)
    util.close_buffer(state.preview_buf)
    util.close_buffer(list_buf)
  end, 'Close bitable view')
  map('r', function()
    refresh(state)
  end, 'Refresh bitable')
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
      title = '飞书多维表格',
      items = help_items(state),
    }
  end)
  map('<CR>', function()
    render_preview(state)
  end, 'Restore detail preview')
  map('<S-Tab>', function()
    cycle_table(state)
  end, 'Cycle tables')
  map('a', function()
    open_form(state, nil, selected_parent_record_id(state))
  end, 'Add record')
  map('A', function()
    open_form(state, nil, nil)
  end, 'Add root record')
  map('i', function()
    local record = current_record(state)
    if record then
      open_form(state, record, nil)
    end
  end, 'Edit record')
  map('d', function()
    delete_current_record(state)
  end, 'Delete record')
  map('o', function()
    open_current_link(state)
  end, 'Open first link')

  local group = vim.api.nvim_create_augroup(('FeishuBitable_%d'):format(list_buf), { clear = true })
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
      util.close_window(state.preview_win)
      util.close_buffer(state.preview_buf)
    end,
  })

  render(state)
  refresh(state)
end

return M
