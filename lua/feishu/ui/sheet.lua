local util = require('feishu.util')

local M = {}

local ns = vim.api.nvim_create_namespace('feishu.sheet')
local states = {}

local MAX_PREVIEW_ROWS = 80
local MAX_PREVIEW_COLS = 52

local function resource_label(entry)
  return entry.name or entry.title or entry.token or entry.url or '<sheet>'
end

local function sheet_token_for_entry(entry)
  if type(entry) ~= 'table' then
    return nil
  end
  if tostring(entry.type or entry.obj_type or '') ~= 'sheet' then
    return nil
  end
  if tostring(entry.source_type or '') == 'wiki' or entry.kind == 'wiki_node' or entry.node_token ~= nil then
    if type(entry.obj_token) == 'string' and entry.obj_token ~= '' then
      return entry.obj_token
    end
  end
  if type(entry.token) == 'string' and entry.token ~= '' then
    return entry.token
  end
  return nil
end

local function column_label(index)
  local parts = {}
  local current = index
  while current > 0 do
    local remainder = (current - 1) % 26
    parts[#parts + 1] = string.char(string.byte('A') + remainder)
    current = math.floor((current - 1) / 26)
  end
  local reversed = {}
  for i = #parts, 1, -1 do
    reversed[#reversed + 1] = parts[i]
  end
  return table.concat(reversed)
end

local function current_state(buf)
  return states[buf or vim.api.nvim_get_current_buf()]
end

local function current_sheet(state)
  return state.sheets[state.active_sheet_index or 1]
end

local function build_help_items()
  return {
    { 'gR', '重新加载当前电子表格预览' },
    { 'gx', '打开远端 Feishu 链接' },
    { 'h / l', '横向切换可见列' },
    { 'H / L', '切换工作表' },
    { 'J / K', '快速上下移动' },
    { ':?', '显示帮助' },
    { ':q', '关闭当前缓冲区' },
  }
end

local function normalize_value(value)
  if value == nil then
    return ''
  end
  if type(value) == 'string' then
    return value:gsub('%s+', ' ')
  end
  return tostring(value)
end

local function trim_preview(values, fallback_rows, fallback_cols)
  local rows = values or {}
  local last_row = 0
  local last_col = 0
  local max_seen_col = 0

  for row_index, row in ipairs(rows) do
    max_seen_col = math.max(max_seen_col, #row)
    for col_index, value in ipairs(row) do
      if normalize_value(value) ~= '' then
        last_row = math.max(last_row, row_index)
        last_col = math.max(last_col, col_index)
      end
    end
  end

  if last_row == 0 then
    last_row = math.min(#rows, math.max(1, fallback_rows or 5))
  end
  if last_col == 0 then
    last_col = math.min(math.max(max_seen_col, 1), math.max(1, fallback_cols or 5))
  end

  local trimmed = {}
  for row_index = 1, last_row do
    local row = rows[row_index] or {}
    local item = {}
    for col_index = 1, last_col do
      item[col_index] = normalize_value(row[col_index])
    end
    trimmed[#trimmed + 1] = item
  end
  return trimmed, last_row, last_col
end

local function build_column_specs(state)
  local specs = {
    {
      key = '__row__',
      title = '#',
      min_width = 4,
      max_width = 6,
      importance = 100,
      pinned = true,
    },
  }
  local importance = 90
  for col_index = 1, state.visible_col_count do
    local key = ('c%d'):format(col_index)
    specs[#specs + 1] = {
      key = key,
      title = column_label(col_index),
      min_width = 6,
      max_width = 24,
      importance = importance,
      can_hide = true,
    }
    importance = math.max(10, importance - 1)
  end
  return specs
end

local function preview_status(state, shown_specs, hidden_right, skipped_left)
  if state.error then
    return '错误: ' .. (state.error.message or 'request failed'), 'ErrorMsg'
  end

  local sheet = current_sheet(state)
  if not sheet then
    return state.status ~= '' and state.status or '当前电子表格没有可见工作表。', 'Comment'
  end

  local parts = {
    ('sheet %d/%d: %s'):format(state.active_sheet_index or 1, #state.sheets, sheet.title or sheet.sheet_id or '<sheet>'),
    ('preview %d/%d rows'):format(state.visible_row_count or 0, sheet.row_count or state.visible_row_count or 0),
    ('%d/%d cols'):format(state.visible_col_count or 0, sheet.column_count or state.visible_col_count or 0),
  }
  if #skipped_left > 0 then
    parts[#parts + 1] = ('left<%s'):format(table.concat(skipped_left, ', '))
  end
  if #hidden_right > 0 then
    parts[#parts + 1] = ('right<%s'):format(table.concat(hidden_right, ', '))
  end
  if state.status and state.status ~= '' then
    parts[#parts + 1] = state.status
  end
  return table.concat(parts, '  |  '), 'Comment'
end

local function render(state)
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  local width = vim.api.nvim_win_is_valid(state.winid) and vim.api.nvim_win_get_width(state.winid) or math.max(40, math.floor(vim.o.columns * 0.5))
  local column_specs = build_column_specs(state)
  local row_values = {}
  for row_index, row in ipairs(state.rows or {}) do
    local item = { __row__ = tostring(row_index) }
    for col_index = 1, state.visible_col_count do
      item[('c%d'):format(col_index)] = row[col_index] or ''
    end
    row_values[#row_values + 1] = item
  end
  local shown_specs, widths, hidden_right, skipped_left = util.window_compact_columns(
    column_specs,
    row_values,
    math.max(30, width - 1),
    state.column_offset or 0
  )

  local header_values = { __row__ = '#' }
  for col_index = 1, state.visible_col_count do
    header_values[('c%d'):format(col_index)] = column_label(col_index)
  end

  local status_line, status_hl = preview_status(state, shown_specs, hidden_right, skipped_left)
  local lines = {
    ('飞书表格: %s'):format(state.workbook_title or resource_label(state.entry)),
    status_line,
    '',
    util.render_compact_row(shown_specs, widths, header_values),
    util.render_separator(shown_specs, widths),
  }

  for _, values in ipairs(row_values) do
    lines[#lines + 1] = util.render_compact_row(shown_specs, widths, values)
  end
  if #row_values == 0 then
    lines[#lines + 1] = '(empty preview)'
  end

  util.set_lines(state.bufnr, lines)
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(state.bufnr, ns, 'Title', 0, 0, -1)
  vim.api.nvim_buf_add_highlight(state.bufnr, ns, status_hl or 'Comment', 1, 0, -1)
  vim.api.nvim_buf_add_highlight(state.bufnr, ns, 'Identifier', 3, 0, -1)
  for line_index = 6, #lines do
    if lines[line_index] == '(empty preview)' then
      vim.api.nvim_buf_add_highlight(state.bufnr, ns, 'Comment', line_index - 1, 0, -1)
    end
  end
end

local function load_active_sheet(state)
  local sheet = current_sheet(state)
  if not sheet then
    state.rows = {}
    state.visible_row_count = 0
    state.visible_col_count = 0
    state.status = '当前电子表格没有可见工作表。'
    state.error = nil
    render(state)
    return
  end

  local preview_rows = math.min(tonumber(sheet.row_count) or MAX_PREVIEW_ROWS, MAX_PREVIEW_ROWS)
  local preview_cols = math.min(tonumber(sheet.column_count) or MAX_PREVIEW_COLS, MAX_PREVIEW_COLS)
  local range = ('%s!A1:%s%d'):format(sheet.sheet_id, column_label(preview_cols), math.max(1, preview_rows))

  state.status = ('loading %s'):format(sheet.title or sheet.sheet_id or '<sheet>')
  state.error = nil
  render(state)

  state.app.backend:sheet_read_plain(state.spreadsheet_token, sheet.sheet_id, { range }, function(payload, err)
    if err then
      state.error = err
      state.rows = {}
      state.visible_row_count = 0
      state.visible_col_count = 0
      state.status = '电子表格预览加载失败。'
      render(state)
      return
    end

    local item = payload and payload.items and payload.items[1] or {}
    local rows, row_count, col_count = trim_preview(item.values or {}, 5, math.min(preview_cols, 5))
    state.rows = rows
    state.visible_row_count = row_count
    state.visible_col_count = col_count
    state.error = nil
    state.status = ''
    if row_count < (tonumber(sheet.row_count) or row_count) or col_count < (tonumber(sheet.column_count) or col_count) then
      state.status = 'read-only preview'
    end
    render(state)
  end)
end

local function refresh(state)
  state.status = '正在加载电子表格...'
  state.error = nil
  render(state)

  state.app.backend:sheet_get(state.spreadsheet_token, function(workbook, err)
    if err then
      state.error = err
      state.status = '电子表格信息加载失败。'
      render(state)
      return
    end

    state.workbook = workbook or {}
    state.workbook_title = workbook and (workbook.title or workbook.name) or resource_label(state.entry)

    state.app.backend:sheet_list_sheets(state.spreadsheet_token, function(payload, inner_err)
      if inner_err then
        state.error = inner_err
        state.status = '工作表列表加载失败。'
        render(state)
        return
      end

      state.sheets = payload and payload.items or {}
      if #state.sheets == 0 then
        state.active_sheet_index = 1
        load_active_sheet(state)
        return
      end

      state.active_sheet_index = math.max(1, math.min(state.active_sheet_index or 1, #state.sheets))
      state.column_offset = 0
      load_active_sheet(state)
    end)
  end)
end

local function cycle_sheet(state, delta)
  if #state.sheets == 0 then
    return
  end
  local count = #state.sheets
  local next_index = ((state.active_sheet_index - 1 + delta) % count) + 1
  state.active_sheet_index = next_index
  state.column_offset = 0
  load_active_sheet(state)
end

local function fast_move(state, delta)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  local line = vim.api.nvim_win_get_cursor(state.winid)[1]
  local target = math.max(1, math.min(vim.api.nvim_buf_line_count(state.bufnr), line + delta))
  pcall(vim.api.nvim_win_set_cursor, state.winid, { target, 0 })
end

function M.refresh_current()
  local state = current_state()
  if state then
    refresh(state)
  end
end

function M.open(app, entry, opts)
  opts = opts or {}
  local spreadsheet_token = sheet_token_for_entry(entry)
  if not spreadsheet_token then
    vim.notify('Unable to resolve spreadsheet token for this entry.', vim.log.levels.ERROR)
    return
  end

  local win = opts.target_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    if opts.split == 'right' then
      vim.cmd('botright vsplit')
      win = vim.api.nvim_get_current_win()
    else
      win = vim.api.nvim_get_current_win()
    end
  end

  local buf = util.create_scratch_buffer('feishu://sheet', 'feishu-sheet')
  vim.api.nvim_win_set_buf(win, buf)
  util.configure_selection_window(win, buf, { wrap = false })

  local state = {
    app = app,
    entry = entry,
    spreadsheet_token = spreadsheet_token,
    winid = win,
    bufnr = buf,
    workbook = {},
    workbook_title = resource_label(entry),
    sheets = {},
    active_sheet_index = 1,
    rows = {},
    visible_row_count = 0,
    visible_col_count = 0,
    column_offset = 0,
    status = '正在加载...',
    error = nil,
  }
  states[buf] = state

  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map('q', function()
    util.close_window(state.winid)
    util.close_buffer(buf)
  end, 'Close sheet view')
  map('gR', function()
    refresh(state)
  end, 'Refresh sheet preview')
  map('gx', function()
    if state.entry.url and state.entry.url ~= '' then
      util.open_url(state.entry.url)
    end
  end, 'Open remote Feishu URL')
  map('h', function()
    state.column_offset = math.max(0, state.column_offset - 1)
    render(state)
  end, 'Scroll columns left')
  map('l', function()
    state.column_offset = state.column_offset + 1
    render(state)
  end, 'Scroll columns right')
  map('H', function()
    cycle_sheet(state, -1)
  end, 'Previous worksheet')
  map('L', function()
    cycle_sheet(state, 1)
  end, 'Next worksheet')
  map('J', function()
    fast_move(state, 5)
  end, 'Move down faster')
  map('K', function()
    fast_move(state, -5)
  end, 'Move up faster')
  map(':?', function()
    util.open_help_float('飞书表格', build_help_items())
  end, 'Show sheet help')

  local group = vim.api.nvim_create_augroup(('FeishuSheet_%d'):format(buf), { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      states[buf] = nil
    end,
  })

  render(state)
  refresh(state)
end

return M
