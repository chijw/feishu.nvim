local util = require('feishu.util')

local M = {}

local ns = vim.api.nvim_create_namespace('feishu.tasks')
local states = {}
local form_states = {}

local TASK_COLUMNS = {
  { key = 'title', title = '任务', min_width = 20, max_width = 40, importance = 100, pinned = true },
  { key = 'status', title = '状态', min_width = 6, max_width = 10, importance = 90, can_hide = true },
  { key = 'assignees', title = '负责人', min_width = 8, max_width = 20, importance = 80, can_hide = true },
  { key = 'due', title = '截止日期', min_width = 16, max_width = 16, importance = 65, can_hide = true },
  { key = 'priority', title = '优先级', min_width = 4, max_width = 8, importance = 35, can_hide = true },
  { key = 'category', title = '任务类别', min_width = 6, max_width = 12, importance = 20, can_hide = true },
}

local FORM_ORDER = {
  'title',
  'parent',
  'assignees',
  'status',
  'priority',
  'category',
  'start',
  'due',
  'note',
}

local OPTION_FIELDS = {
  status = '状态',
  priority = '优先级',
  category = '任务类别',
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

local function extract_urls(value, urls)
  urls = urls or {}
  if value == nil then
    return urls
  end
  if type(value) == 'string' then
    for url in value:gmatch('https?://[^%s%)%]]+') do
      urls[#urls + 1] = url
    end
    return urls
  end
  if type(value) == 'table' then
    if value.link and type(value.link) == 'string' then
      urls[#urls + 1] = value.link
    end
    if value.url and type(value.url) == 'string' then
      urls[#urls + 1] = value.url
    end
    if value.text and type(value.text) == 'string' then
      extract_urls(value.text, urls)
    end
    if value.value then
      extract_urls(value.value, urls)
    end
    for _, item in ipairs(value) do
      extract_urls(item, urls)
    end
  end
  return urls
end

local function note_to_form_value(value)
  local urls = extract_urls(value)
  if #urls > 0 then
    return urls[1]
  end
  return extract_text(value)
end

local function format_rich_value(value)
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
    if #value > 0 then
      local parts = {}
      for _, item in ipairs(value) do
        if type(item) == 'table' and item.link and item.text then
          parts[#parts + 1] = ('%s <%s>'):format(item.text, item.link)
        else
          parts[#parts + 1] = extract_text(item)
        end
      end
      return table.concat(parts, ', ')
    end
    if value.type and value.value then
      return format_rich_value(value.value)
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

local function task_from_record(record, primary_field_name)
  local fields = type(record.fields) == 'table' and record.fields or {}
  local title = extract_text(fields[primary_field_name])
  if title == '' and primary_field_name ~= '任务列表' then
    title = extract_text(fields['任务列表'])
  end
  return {
    record_id = tostring(record.record_id or ''),
    title = title,
    status = extract_text(fields['状态']),
    assignees = extract_people(fields['负责人']),
    priority = extract_text(fields['优先级']),
    category = extract_text(fields['任务类别']),
    start = extract_date(fields['开始日期']),
    due = extract_date(fields['截止日期']),
    note = note_to_form_value(fields['备注']),
    parent_record_ids = extract_link_record_ids(fields['父记录']),
    raw = record,
  }
end

local function task_parent_id(task)
  return task.parent_record_ids[1]
end

local function build_children_map(tasks)
  local task_by_id = {}
  for _, task in ipairs(tasks) do
    task_by_id[task.record_id] = task
  end

  local children_by_parent = {}
  for _, task in ipairs(tasks) do
    local parent_id = task_parent_id(task)
    if parent_id and parent_id ~= task.record_id and task_by_id[parent_id] then
      children_by_parent[parent_id] = children_by_parent[parent_id] or {}
      table.insert(children_by_parent[parent_id], task.record_id)
    end
  end

  return task_by_id, children_by_parent
end

local function build_task_rows(tasks)
  local task_by_id, children_by_parent = build_children_map(tasks)
  local rows = {}
  local root_ids = {}

  for _, task in ipairs(tasks) do
    local parent_id = task_parent_id(task)
    if not parent_id or not task_by_id[parent_id] then
      root_ids[#root_ids + 1] = task.record_id
    end
  end

  local function collect(record_id, depth, current_group, trail)
    local task = task_by_id[record_id]
    if not task or trail[record_id] then
      return
    end

    local group = current_group or task
    rows[#rows + 1] = {
      task = task,
      depth = depth,
      group_record_id = group.record_id,
      group_title = group.title ~= '' and group.title or group.record_id,
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

  return rows, task_by_id, children_by_parent
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

local function parse_primary_field_name(fields)
  for _, field in ipairs(fields or {}) do
    if field.is_primary and field.field_name then
      return tostring(field.field_name)
    end
  end
  return '任务列表'
end

local function current_state(buf)
  return states[buf or vim.api.nvim_get_current_buf()]
end

local function current_row(state)
  local line = vim.api.nvim_win_get_cursor(state.list_win)[1]
  return state.line_to_row[line]
end

local function current_task(state)
  local row = current_row(state)
  return row and row.task or nil
end

local function current_base_url(state)
  if not state.active_table_id or state.active_table_id == '' then
    return state.base_url
  end
  return ('%s?table=%s'):format(state.base_root, state.active_table_id)
end

local function selected_group_record_id(state)
  local row = current_row(state)
  if not row then
    return nil
  end
  if row.is_group then
    return row.task.record_id
  end
  return row.group_record_id or task_parent_id(row.task)
end

local function build_parent_maps(state, exclude_record_id)
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
    local task = row.task
    if not excluded[task.record_id] then
      local label = task.title ~= '' and task.title or task.record_id
      if used_labels[label] then
        label = ('%s :: %s'):format(label, task.record_id)
      end
      used_labels[label] = true
      label_to_id[label] = task.record_id
      id_to_label[task.record_id] = label
    end
  end

  return label_to_id, id_to_label
end

local function build_task_form_lines(state, task, parent_record_id)
  local label_to_id, id_to_label = build_parent_maps(state, task and task.record_id or nil)
  local defaults = state.app.opts.task_defaults or {}
  local values = {
    title = task and task.title or '',
    parent = '',
    assignees = task and table.concat(task.assignees, ', ') or '',
    status = task and task.status or (defaults.status or ''),
    priority = task and task.priority or (defaults.priority or ''),
    category = task and task.category or (defaults.category or ''),
    start = task and (task.start:match(' 00:00$') and task.start:sub(1, 10) or task.start) or '',
    due = task and (task.due:match(' 00:00$') and task.due:sub(1, 10) or task.due) or '',
    note = task and task.note or '',
  }

  local effective_parent_id = parent_record_id
  if effective_parent_id == nil and task then
    effective_parent_id = task_parent_id(task)
  end
  if effective_parent_id and effective_parent_id ~= '' then
    values.parent = id_to_label[effective_parent_id] or effective_parent_id
  end

  local lines = {
    '# Save with Ctrl-S. Cancel with Ctrl-C.',
    '# assignees uses comma-separated display names from the board.',
    '# start/due accepts YYYY-MM-DD or YYYY-MM-DD HH:MM.',
  }
  if next(label_to_id) then
    lines[#lines + 1] = '# parent options: ' .. table.concat(vim.tbl_keys(label_to_id), ', ')
  end
  for form_key, field_name in pairs(OPTION_FIELDS) do
    local options = state.options[field_name]
    if options and #options > 0 then
      lines[#lines + 1] = ('# %s options: %s'):format(form_key, table.concat(options, ', '))
    end
  end
  for _, key in ipairs(FORM_ORDER) do
    lines[#lines + 1] = ('%s: %s'):format(key, values[key] or '')
  end

  return lines
end

local function parse_task_form(buf)
  local parsed = {}
  for _, key in ipairs(FORM_ORDER) do
    parsed[key] = ''
  end

  local seen = {}
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for index, raw_line in ipairs(lines) do
    local trimmed = vim.trim(raw_line)
    if trimmed ~= '' and not trimmed:match('^#') then
      local key, value = raw_line:match('^([^:]+):%s*(.*)$')
      if not key then
        return nil, ('Line %d must use `key: value` format.'):format(index)
      end
      key = vim.trim(key)
      if not vim.tbl_contains(FORM_ORDER, key) then
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

local function build_fields_from_form(state, form, opts)
  opts = opts or {}
  local for_update = opts.for_update == true
  local defaults = state.app.opts.task_defaults or {}
  local label_to_id = build_parent_maps(state, opts.exclude_record_id)

  local fields = {}
  local title = vim.trim(form.title or '')
  if title == '' then
    return nil, 'title is required.'
  end
  fields['任务列表'] = title

  local assignees = vim.split((form.assignees or ''):gsub('，', ','), ',', { trimempty = true })
  if #assignees > 0 then
    local payload = {}
    local missing = {}
    for _, name in ipairs(assignees) do
      local normalized = vim.trim(name)
      if state.users[normalized] then
        payload[#payload + 1] = { id = state.users[normalized] }
      else
        missing[#missing + 1] = normalized
      end
    end
    if #missing > 0 then
      return nil, ('Unknown assignee(s): %s'):format(table.concat(missing, ', '))
    end
    fields['负责人'] = payload
  elseif for_update then
    fields['负责人'] = vim.NIL
  end

  local parent_value = vim.trim(form.parent or '')
  if parent_value ~= '' then
    local parent_id = label_to_id[parent_value]
    if not parent_id then
      return nil, ('Unknown parent/group: %s'):format(parent_value)
    end
    fields['父记录'] = { link_record_ids = { parent_id } }
  elseif for_update then
    fields['父记录'] = vim.NIL
  end

  for form_key, field_name in pairs(OPTION_FIELDS) do
    local value = vim.trim(form[form_key] or '')
    if value == '' and not for_update then
      value = defaults[form_key] or ''
    end
    local options = state.options[field_name]
    if value ~= '' then
      if options and #options > 0 and not vim.tbl_contains(options, value) then
        return nil, ('%s must be one of: %s'):format(form_key, table.concat(options, ', '))
      end
      fields[field_name] = value
    elseif for_update then
      fields[field_name] = vim.NIL
    end
  end

  for _, form_key in ipairs({ 'start', 'due' }) do
    local raw = vim.trim(form[form_key] or '')
    local field_name = form_key == 'start' and '开始日期' or '截止日期'
    if raw ~= '' then
      local timestamp = date_to_ms(raw)
      if not timestamp then
        return nil, ('%s must use YYYY-MM-DD or YYYY-MM-DD HH:MM.'):format(form_key)
      end
      fields[field_name] = timestamp
    elseif for_update then
      fields[field_name] = vim.NIL
    end
  end

  local note = vim.trim(form.note or '')
  if note ~= '' then
    fields['备注'] = note
  elseif for_update then
    fields['备注'] = vim.NIL
  end

  return fields
end

local function task_row_values(row)
  local task = row.task
  local marker = row.is_group and '+ ' or '- '
  local title = string.rep('  ', row.depth) .. marker .. (task.title ~= '' and task.title or task.record_id)
  return {
    title = title,
    status = task.status,
    assignees = table.concat(task.assignees, ', '),
    due = task.due,
    priority = task.priority,
    category = task.category,
  }
end

local function render_preview(state)
  if not vim.api.nvim_buf_is_valid(state.preview_buf) then
    return
  end

  local row = current_row(state)
  if not row then
    util.set_lines(state.preview_buf, {
      'Task Detail',
      '',
      'Move the cursor onto a task row to inspect fields.',
    })
    return
  end

  local task = row.task
  local _, parent_labels = build_parent_maps(state, nil)
  local fields = type(task.raw.fields) == 'table' and task.raw.fields or {}
  local lines = {
    task.title ~= '' and task.title or task.record_id,
    ('record_id: %s'):format(task.record_id),
    ('group: %s'):format(row.group_title),
    '',
  }

  local seen = {}
  for _, field in ipairs(state.schema_fields or {}) do
    local field_name = field.field_name
    if field_name then
      seen[field_name] = true
      local value = fields[field_name]
      local rendered
      if field_name == '父记录' then
        local labels = {}
        for _, record_id in ipairs(extract_link_record_ids(value)) do
          labels[#labels + 1] = parent_labels[record_id] or record_id
        end
        rendered = table.concat(labels, ', ')
      elseif field_name == '负责人' then
        rendered = table.concat(extract_people(value), ', ')
      else
        rendered = format_rich_value(value)
      end
      lines[#lines + 1] = ('%s: %s'):format(field_name, rendered ~= '' and rendered or '-')
    end
  end

  for field_name, value in pairs(fields) do
    if not seen[field_name] then
      lines[#lines + 1] = ('%s: %s'):format(field_name, format_rich_value(value))
    end
  end

  local urls = extract_urls(fields)
  if #urls > 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Links'
    for index, url in ipairs(urls) do
      lines[#lines + 1] = ('%d. %s'):format(index, url)
    end
  end

  util.set_lines(state.preview_buf, lines)
  vim.api.nvim_buf_clear_namespace(state.preview_buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Title', 0, 0, -1)
  for index, line in ipairs(lines) do
    if line == 'Links' then
      vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Identifier', index - 1, 0, -1)
    elseif line:match('^record_id:') or line:match('^group:') then
      vim.api.nvim_buf_add_highlight(state.preview_buf, ns, 'Comment', index - 1, 0, -1)
    end
  end
end

local function move_cursor_to_record(state, record_id)
  if not record_id then
    return
  end
  for line, row in pairs(state.line_to_row) do
    if row.task.record_id == record_id and vim.api.nvim_win_is_valid(state.list_win) then
      pcall(vim.api.nvim_win_set_cursor, state.list_win, { line, 0 })
      return
    end
  end
end

local function render(state)
  if not vim.api.nvim_buf_is_valid(state.list_buf) then
    return
  end

  local selected = current_task(state)
  local selected_record_id = selected and selected.record_id or state.last_selected_record_id
  local width = vim.api.nvim_win_is_valid(state.list_win) and vim.api.nvim_win_get_width(state.list_win) or math.floor(vim.o.columns * 0.55)
  local row_values = {}
  for _, row in ipairs(state.rows) do
    row_values[#row_values + 1] = task_row_values(row)
  end
  local shown, widths, hidden_right, skipped_left = util.window_compact_columns(TASK_COLUMNS, row_values, math.max(30, width - 1), state.column_offset)

  local active_index = 0
  for index, item in ipairs(state.tables) do
    if item.table_id == state.active_table_id then
      active_index = index
      break
    end
  end

  local lines = {
    ('Feishu Tasks  [%s]'):format(state.active_table_name or state.active_table_id or '<table>'),
    ('table %d/%d'):format(active_index > 0 and active_index or 1, math.max(1, #state.tables)),
    state.error and ('error: ' .. (state.error.message or 'request failed')) or (state.status or ''),
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
    local values = task_row_values(row)
    lines[#lines + 1] = util.render_compact_row(shown, widths, values)
    state.line_to_row[#lines] = row
  end

  if #state.rows == 0 then
    lines[#lines + 1] = '(no records)'
  end

  lines[#lines + 1] = ''
  local hints = { 'h/l cols', '<S-Tab> table', 'a task', 'A group', 'i edit', 'd delete', 'o open', 'r refresh', 'q quit' }
  if #skipped_left > 0 or #hidden_right > 0 then
    local note = '[columns'
    if #skipped_left > 0 then
      note = note .. ' left=' .. table.concat(skipped_left, ',')
    end
    if #hidden_right > 0 then
      note = note .. ' right=' .. table.concat(hidden_right, ',')
    end
    note = note .. ']'
    hints[#hints + 1] = note
  end
  lines[#lines + 1] = table.concat(hints, '  ')

  util.set_lines(state.list_buf, lines)
  vim.api.nvim_buf_clear_namespace(state.list_buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Title', 0, 0, -1)
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Comment', 1, 0, -1)
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, state.error and 'ErrorMsg' or 'Comment', 2, 0, -1)
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Identifier', 4, 0, -1)
  for line, row in pairs(state.line_to_row) do
    if row.is_group then
      vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Statement', line - 1, 0, -1)
    end
  end
  vim.api.nvim_buf_add_highlight(state.list_buf, ns, 'Comment', #lines - 1, 0, -1)

  if #state.rows > 0 then
    move_cursor_to_record(state, selected_record_id or state.rows[1].task.record_id)
  end
  local task = current_task(state)
  state.last_selected_record_id = task and task.record_id or state.last_selected_record_id
  render_preview(state)
end

local function refresh_table_data(state)
  local base_url = current_base_url(state)
  local selected = current_task(state)
  state.last_selected_record_id = selected and selected.record_id or state.last_selected_record_id
  state.status = 'Loading schema and records...'
  state.error = nil
  render(state)

  local remaining = 2
  local next_schema_fields = state.schema_fields
  local next_options = state.options
  local next_users = state.users
  local next_primary_field = state.primary_field_name
  local next_rows = state.rows
  local next_tasks = state.tasks
  local next_task_by_id = state.task_by_id
  local next_children_by_parent = state.children_by_parent
  local next_records = nil
  local next_error = nil

  local function finish()
    remaining = remaining - 1
    if remaining > 0 then
      return
    end

    if not next_error and next_records then
      next_tasks = {}
      for _, record in ipairs(next_records) do
        next_tasks[#next_tasks + 1] = task_from_record(record, next_primary_field)
      end
      next_rows, next_task_by_id, next_children_by_parent = build_task_rows(next_tasks)
    end

    state.schema_fields = next_schema_fields
    state.options = next_options
    state.users = next_users
    state.primary_field_name = next_primary_field
    state.tasks = next_tasks
    state.rows = next_rows
    state.task_by_id = next_task_by_id
    state.children_by_parent = next_children_by_parent
    state.error = next_error
    if next_error then
      state.status = 'Load failed.'
    else
      state.status = ('Loaded %d records.'):format(#state.tasks)
    end
    render(state)
  end

  state.app.backend:task_schema(base_url, function(payload, err)
    if err then
      next_error = err
    else
      next_schema_fields = payload.fields or {}
      next_options = payload.options or {}
      next_users = payload.users or {}
      next_primary_field = parse_primary_field_name(next_schema_fields)
    end
    finish()
  end)

  state.app.backend:task_list(base_url, 1000, function(payload, err)
    if err then
      next_error = err
    else
      next_records = payload.records or {}
    end
    finish()
  end)
end

local function refresh(state)
  state.status = 'Loading tables...'
  state.error = nil
  render(state)
  state.app.backend:base_tables(state.base_root, function(payload, err)
    if err then
      state.error = err
      state.status = 'Failed to load tables.'
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

local function save_form(form_state)
  if form_state.pending then
    return
  end

  local form, parse_error = parse_task_form(form_state.bufnr)
  if not form then
    notify_error(parse_error)
    return
  end

  local fields, field_error = build_fields_from_form(form_state.parent_state, form, {
    for_update = form_state.record_id ~= nil,
    exclude_record_id = form_state.record_id,
  })
  if not fields then
    notify_error(field_error)
    return
  end

  form_state.pending = true
  vim.bo[form_state.bufnr].modifiable = false
  vim.bo[form_state.bufnr].readonly = true
  form_state.parent_state.status = 'Saving task...'
  render(form_state.parent_state)

  local callback = function(_, err)
    form_state.pending = false
    if err then
      vim.bo[form_state.bufnr].modifiable = true
      vim.bo[form_state.bufnr].readonly = false
      form_state.parent_state.status = 'Save failed.'
      form_state.parent_state.error = err
      render(form_state.parent_state)
      notify_error(err.message or 'Save failed.')
      return
    end

    util.close_window(form_state.winid)
    util.close_buffer(form_state.bufnr)
    form_states[form_state.bufnr] = nil
    form_state.parent_state.status = 'Task saved.'
    form_state.parent_state.error = nil
    refresh_table_data(form_state.parent_state)
  end

  if form_state.record_id then
    form_state.parent_state.app.backend:record_update(current_base_url(form_state.parent_state), form_state.record_id, fields, callback)
  else
    form_state.parent_state.app.backend:record_add(current_base_url(form_state.parent_state), fields, callback)
  end
end

local function open_form(state, task, parent_record_id)
  vim.cmd('botright split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(win, math.max(8, math.floor(vim.o.lines * (state.app.opts.ui.form_height or 0.4))))
  local buf = util.create_scratch_buffer('feishu://task-form', 'feishu-task-form')
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = false

  util.set_lines(buf, build_task_form_lines(state, task, parent_record_id), { modifiable = true })
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for index, line in ipairs(lines) do
    if line:match('^title:') then
      pcall(vim.api.nvim_win_set_cursor, win, { index, 0 })
      break
    end
  end

  local form_state = {
    parent_state = state,
    bufnr = buf,
    winid = win,
    record_id = task and task.record_id or nil,
    pending = false,
  }
  form_states[buf] = form_state

  local map = function(lhs, rhs, desc, mode)
    vim.keymap.set(mode or 'n', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map('<C-s>', function()
    save_form(form_state)
  end, 'Save task')
  map('<C-c>', function()
    util.close_window(win)
    util.close_buffer(buf)
  end, 'Cancel task form')
  map('q', function()
    util.close_window(win)
    util.close_buffer(buf)
  end, 'Close task form')
  map('<C-s>', function()
    vim.cmd('stopinsert')
    save_form(form_state)
  end, 'Save task', 'i')
  map('<C-c>', function()
    vim.cmd('stopinsert')
    util.close_window(win)
    util.close_buffer(buf)
  end, 'Cancel task form', 'i')
end

local function delete_current_task(state)
  local task = current_task(state)
  if not task then
    return
  end

  local child_count = #(state.children_by_parent[task.record_id] or {})
  local prompt = child_count > 0
      and ('Delete `%s` and leave %d child records detached?'):format(task.title, child_count)
      or ('Delete `%s`?'):format(task.title ~= '' and task.title or task.record_id)
  local choice = vim.fn.confirm(prompt, '&Yes\n&No', 2)
  if choice ~= 1 then
    return
  end

  state.status = 'Deleting task...'
  state.error = nil
  render(state)
  state.app.backend:record_delete(current_base_url(state), task.record_id, function(_, err)
    if err then
      state.status = 'Delete failed.'
      state.error = err
      render(state)
      notify_error(err.message or 'Delete failed.')
      return
    end

    state.status = 'Task deleted.'
    state.error = nil
    refresh_table_data(state)
  end)
end

local function open_current_link(state)
  local task = current_task(state)
  if not task then
    return
  end
  local fields = type(task.raw.fields) == 'table' and task.raw.fields or {}
  local urls = extract_urls(fields)
  if #urls == 0 then
    vim.notify('No URL found in the selected task.', vim.log.levels.WARN)
    return
  end
  util.open_url(urls[1])
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
    vim.notify('No additional table in this base.', vim.log.levels.INFO)
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
    state.last_selected_record_id = row.task.record_id
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
  local base_url = opts.base_url or app.opts.task_base_url
  if not base_url or base_url == '' then
    notify_error('No task_base_url configured for feishu.nvim.')
    return
  end

  local list_win = vim.api.nvim_get_current_win()
  local list_buf = util.create_scratch_buffer('feishu://tasks', 'feishu-tasks')
  vim.api.nvim_win_set_buf(list_win, list_buf)
  vim.wo[list_win].number = false
  vim.wo[list_win].relativenumber = false
  vim.wo[list_win].cursorline = true
  vim.wo[list_win].wrap = false

  vim.cmd('botright vsplit')
  local preview_win = vim.api.nvim_get_current_win()
  local preview_buf = util.create_scratch_buffer('feishu://task-detail', 'feishu-task-detail')
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
    base_url = base_url,
    base_root = (base_url:match('^[^?]+') or base_url),
    active_table_id = base_url:match('[?&]table=([^&]+)'),
    active_table_name = base_url:match('[?&]table=([^&]+)') or '<table>',
    tables = {},
    schema_fields = {},
    options = {},
    users = {},
    primary_field_name = '任务列表',
    tasks = {},
    rows = {},
    task_by_id = {},
    children_by_parent = {},
    line_to_row = {},
    column_offset = 0,
    status = 'Loading...',
    error = nil,
    last_selected_record_id = nil,
  }
  states[list_buf] = state

  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = list_buf, silent = true, nowait = true, desc = desc })
  end

  map('q', function()
    util.close_window(preview_win)
    util.close_buffer(preview_buf)
    util.close_buffer(list_buf)
  end, 'Close tasks view')
  map('r', function()
    refresh(state)
  end, 'Refresh tasks')
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
  map('<S-Tab>', function()
    cycle_table(state)
  end, 'Next table')
  map('a', function()
    open_form(state, nil, selected_group_record_id(state))
  end, 'Add child task')
  map('A', function()
    open_form(state, nil, '')
  end, 'Add group')
  map('i', function()
    local task = current_task(state)
    if task then
      open_form(state, task, nil)
    end
  end, 'Edit task')
  map('d', function()
    delete_current_task(state)
  end, 'Delete task')
  map('o', function()
    open_current_link(state)
  end, 'Open task link')

  local group = vim.api.nvim_create_augroup(('FeishuTasks_%d'):format(list_buf), { clear = true })
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
