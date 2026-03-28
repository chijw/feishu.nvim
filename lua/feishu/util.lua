local M = {}
local float_ns = vim.api.nvim_create_namespace('feishu.float')
local saved_guicursor = nil

function M.display_width(text)
  return vim.fn.strdisplaywidth(text or '')
end

function M.truncate(text, width)
  text = text or ''
  if width <= 0 then
    return ''
  end
  if M.display_width(text) <= width then
    return text
  end
  if width <= 3 then
    return string.rep('.', width)
  end
  local target = width - 3
  local parts = {}
  local used = 0
  for _, char in ipairs(vim.fn.split(text, '\\zs')) do
    local char_width = M.display_width(char)
    if used + char_width > target then
      break
    end
    parts[#parts + 1] = char
    used = used + char_width
  end
  return table.concat(parts) .. '...'
end

function M.pad(text, width)
  text = text or ''
  return text .. string.rep(' ', math.max(0, width - M.display_width(text)))
end

function M.create_scratch_buffer(name, filetype, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(opts.listed == true, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = opts.bufhidden or 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = filetype or 'text'
  if name and name ~= '' then
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  return buf
end

function M.set_lines(buf, lines, opts)
  opts = opts or {}
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = opts.modifiable == true
  vim.bo[buf].readonly = not vim.bo[buf].modifiable
end

function M.close_window(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

function M.close_buffer(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function ensure_hidden_cursor_hl()
  vim.api.nvim_set_hl(0, 'FeishuHiddenCursor', { blend = 100, nocombine = true })
end

local function apply_hidden_cursor(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if vim.api.nvim_get_current_win() ~= win then
    return
  end
  ensure_hidden_cursor_hl()
  if saved_guicursor == nil then
    saved_guicursor = vim.o.guicursor
  end
  vim.o.guicursor = table.concat({
    'n-v-c:block-FeishuHiddenCursor',
    'i-ci-ve:ver25',
    'r-cr-o:hor20',
  }, ',')
end

local function restore_hidden_cursor()
  if saved_guicursor ~= nil then
    vim.o.guicursor = saved_guicursor
    saved_guicursor = nil
  end
end

function M.attach_hidden_cursor(win, buf)
  if not win or not vim.api.nvim_win_is_valid(win) or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local group = vim.api.nvim_create_augroup(('FeishuHiddenCursor_%d_%d'):format(win, buf), { clear = true })
  local maybe_apply = function()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win then
      apply_hidden_cursor(win)
    end
  end

  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, {
    group = group,
    buffer = buf,
    callback = maybe_apply,
  })
  vim.api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
    group = group,
    buffer = buf,
    callback = restore_hidden_cursor,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = restore_hidden_cursor,
  })

  maybe_apply()
end

function M.configure_selection_window(win, buf, opts)
  opts = opts or {}
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = opts.wrap == true
  vim.wo[win].cursorline = true
  vim.wo[win].cursorcolumn = false
  vim.wo[win].cursorlineopt = 'line'
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldcolumn = '0'

  local existing = opts.winhl or vim.wo[win].winhl or ''
  if existing == '' then
    vim.wo[win].winhl = 'CursorLine:Visual'
  elseif not existing:match('CursorLine:') then
    vim.wo[win].winhl = existing .. ',CursorLine:Visual'
  else
    vim.wo[win].winhl = existing
  end

  if opts.hide_cursor ~= false and buf and vim.api.nvim_buf_is_valid(buf) then
    M.attach_hidden_cursor(win, buf)
  end
end

function M.open_url(url)
  if not url or url == '' then
    return false
  end
  if vim.ui and vim.ui.open then
    vim.ui.open(url)
    return true
  end
  local opener = vim.fn.has('macunix') == 1 and 'open' or 'xdg-open'
  vim.fn.jobstart({ opener, url }, { detach = true })
  return true
end

function M.decode_json(raw)
  if not raw or raw == '' then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok then
    return decoded
  end
  return nil
end

function M.parse_cli_error(stderr)
  stderr = stderr or ''
  local lines = vim.split(stderr, '\n', { trimempty = true })
  if #lines == 0 then
    return {
      message = 'Command failed.',
      raw = stderr,
      payload = nil,
    }
  end

  local message = lines[1]:gsub('^error:%s*', '')
  local payload = nil
  for index = #lines, 1, -1 do
    if lines[index]:match('^%s*{') then
      payload = M.decode_json(table.concat(vim.list_slice(lines, index), '\n'))
      if payload then
        break
      end
    end
  end

  return {
    message = message,
    raw = stderr,
    payload = payload,
  }
end

local function preferred_min_width(spec)
  return math.max(spec.min_width, M.display_width(spec.title))
end

local function hard_min_width(spec, visible_count)
  if visible_count <= 1 then
    return 1
  end
  return math.min(4, preferred_min_width(spec))
end

local function table_width(specs, visible, widths)
  local shown = {}
  for _, spec in ipairs(specs) do
    if visible[spec.key] then
      shown[#shown + 1] = spec
    end
  end
  if #shown == 0 then
    return 0
  end
  local width = 0
  for _, spec in ipairs(shown) do
    width = width + (widths[spec.key] or spec.min_width)
  end
  width = width + ((#shown - 1) * 2)
  return width
end

function M.window_compact_columns(specs, rows, total_width, offset)
  offset = offset or 0
  local pinned = {}
  local scrollable = {}
  for _, spec in ipairs(specs) do
    if spec.pinned then
      pinned[#pinned + 1] = spec
    else
      scrollable[#scrollable + 1] = spec
    end
  end

  local bounded_offset = math.max(0, math.min(offset, math.max(0, #scrollable - 1)))
  local window_specs = vim.list_extend(vim.deepcopy(pinned), vim.list_slice(scrollable, bounded_offset + 1))
  local skipped_left = {}
  for _, spec in ipairs(vim.list_slice(scrollable, 1, bounded_offset)) do
    skipped_left[#skipped_left + 1] = spec.title
  end

  local widths = {}
  local visible = {}
  for _, spec in ipairs(window_specs) do
    visible[spec.key] = true
    local width = M.display_width(spec.title)
    for _, row in ipairs(rows) do
      width = math.max(width, M.display_width(row[spec.key] or ''))
    end
    if spec.max_width then
      width = math.min(width, spec.max_width)
    end
    widths[spec.key] = math.max(width, spec.min_width, M.display_width(spec.title))
  end

  while table_width(window_specs, visible, widths) > total_width do
    local candidates = {}
    for _, spec in ipairs(window_specs) do
      if visible[spec.key] and widths[spec.key] > preferred_min_width(spec) then
        candidates[#candidates + 1] = spec
      end
    end
    if #candidates == 0 then
      break
    end
    table.sort(candidates, function(a, b)
      local a_delta = widths[a.key] - preferred_min_width(a)
      local b_delta = widths[b.key] - preferred_min_width(b)
      if a.importance ~= b.importance then
        return a.importance < b.importance
      end
      if a_delta ~= b_delta then
        return a_delta > b_delta
      end
      return a.key < b.key
    end)
    widths[candidates[1].key] = widths[candidates[1].key] - 1
  end

  while table_width(window_specs, visible, widths) > total_width do
    local hide_candidates = {}
    for _, spec in ipairs(window_specs) do
      if visible[spec.key] and spec.can_hide then
        hide_candidates[#hide_candidates + 1] = spec
      end
    end
    if #hide_candidates == 0 then
      break
    end
    table.sort(hide_candidates, function(a, b)
      if a.importance ~= b.importance then
        return a.importance < b.importance
      end
      return a.key < b.key
    end)
    visible[hide_candidates[1].key] = false
  end

  local shown = {}
  for _, spec in ipairs(window_specs) do
    if visible[spec.key] then
      shown[#shown + 1] = spec
    end
  end
  if #shown == 0 and #window_specs > 0 then
    table.sort(window_specs, function(a, b)
      return a.importance > b.importance
    end)
    visible[window_specs[1].key] = true
    shown = { window_specs[1] }
  end

  while table_width(window_specs, visible, widths) > total_width do
    local visible_count = 0
    for _, spec in ipairs(window_specs) do
      if visible[spec.key] then
        visible_count = visible_count + 1
      end
    end
    local candidates = {}
    for _, spec in ipairs(window_specs) do
      if visible[spec.key] and widths[spec.key] > hard_min_width(spec, visible_count) then
        candidates[#candidates + 1] = spec
      end
    end
    if #candidates == 0 then
      break
    end
    table.sort(candidates, function(a, b)
      local a_delta = widths[a.key] - hard_min_width(a, visible_count)
      local b_delta = widths[b.key] - hard_min_width(b, visible_count)
      if a.importance ~= b.importance then
        return a.importance < b.importance
      end
      if a_delta ~= b_delta then
        return a_delta > b_delta
      end
      return a.key < b.key
    end)
    widths[candidates[1].key] = widths[candidates[1].key] - 1
  end

  local hidden_right = {}
  for _, spec in ipairs(window_specs) do
    if not visible[spec.key] then
      hidden_right[#hidden_right + 1] = spec.title
    end
  end

  shown = {}
  for _, spec in ipairs(window_specs) do
    if visible[spec.key] then
      shown[#shown + 1] = spec
    end
  end

  return shown, widths, hidden_right, skipped_left
end

function M.render_compact_row(specs, widths, values)
  local parts = {}
  for _, spec in ipairs(specs) do
    parts[#parts + 1] = M.pad(M.truncate(values[spec.key] or '', widths[spec.key]), widths[spec.key])
  end
  return table.concat(parts, '  ')
end

function M.render_separator(specs, widths)
  local parts = {}
  for _, spec in ipairs(specs) do
    parts[#parts + 1] = string.rep('-', widths[spec.key])
  end
  return table.concat(parts, '  ')
end

function M.open_centered_float(lines, opts)
  opts = opts or {}
  local width = opts.width or 0
  for _, line in ipairs(lines or {}) do
    width = math.max(width, M.display_width(line))
  end
  width = math.max(opts.min_width or 24, width + 2)
  width = math.min(width, opts.max_width or math.max(24, math.floor(vim.o.columns * (opts.max_width_ratio or 0.72))))

  local height = math.max(opts.min_height or 1, #lines)
  height = math.min(height, opts.max_height or math.max(4, math.floor(vim.o.lines * (opts.max_height_ratio or 0.7))))

  local row = opts.row or math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  local col = opts.col or math.max(0, math.floor((vim.o.columns - width) / 2))
  local buf = M.create_scratch_buffer(opts.name or 'feishu://float', opts.filetype or 'feishu-float')
  M.set_lines(buf, lines)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    style = 'minimal',
    border = opts.border or 'rounded',
    width = width,
    height = height,
    row = row,
    col = col,
    noautocmd = true,
  })

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = opts.wrap == true
  vim.wo[win].cursorline = opts.cursorline == true
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].winhl = opts.winhl or 'Normal:NormalFloat,FloatBorder:FloatBorder'
  if opts.cursorline == true then
    M.configure_selection_window(win, buf, {
      wrap = opts.wrap == true,
      winhl = vim.wo[win].winhl,
      hide_cursor = opts.hide_cursor ~= false,
    })
  end

  local close = function()
    M.close_window(win)
    M.close_buffer(buf)
  end

  vim.keymap.set('n', 'q', close, { buffer = buf, silent = true, nowait = true, desc = 'Close float' })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, silent = true, nowait = true, desc = 'Close float' })

  return buf, win
end

function M.open_help_float(title, items, opts)
  opts = opts or {}
  local key_width = 0
  for _, item in ipairs(items or {}) do
    key_width = math.max(key_width, M.display_width(item[1] or ''))
  end
  key_width = math.max(key_width, 6)

  local lines = { title or '快捷键', '' }
  for _, item in ipairs(items or {}) do
    lines[#lines + 1] = M.pad(item[1] or '', key_width) .. '  ' .. (item[2] or '')
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'q / <Esc> 关闭'

  local buf, win = M.open_centered_float(lines, vim.tbl_extend('force', {
    name = 'feishu://help',
    filetype = 'feishu-help',
    min_width = math.max(36, key_width + 18),
    max_width_ratio = 0.62,
  }, opts))

  vim.api.nvim_buf_clear_namespace(buf, float_ns, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, float_ns, 'Title', 0, 0, -1)
  for index = 3, #lines - 2 do
    local key = items[index - 2] and (items[index - 2][1] or '') or ''
    local key_end = #key
    if key_end > 0 then
      vim.api.nvim_buf_add_highlight(buf, float_ns, 'Identifier', index - 1, 0, key_end)
    end
  end
  vim.api.nvim_buf_add_highlight(buf, float_ns, 'Comment', #lines - 1, 0, -1)

  return buf, win
end

function M.attach_help(buf, provider)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.keymap.set('n', '<leader>vh', function()
    local payload = type(provider) == 'function' and provider() or provider
    if type(payload) ~= 'table' then
      return
    end
    local title = payload.title or '快捷键'
    local items = payload.items or payload
    if type(items) ~= 'table' then
      return
    end
    M.open_help_float(title, items, payload.opts)
  end, {
    buffer = buf,
    silent = true,
    nowait = true,
    desc = 'Show Feishu help',
  })
end

function M.open_terminal_float(cmd, opts)
  opts = opts or {}
  local width = math.max(opts.min_width or 72, math.floor(vim.o.columns * (opts.width_ratio or 0.72)))
  local height = math.max(opts.min_height or 16, math.floor(vim.o.lines * (opts.height_ratio or 0.62)))
  width = math.min(width, opts.max_width or (vim.o.columns - 4))
  height = math.min(height, opts.max_height or (vim.o.lines - 4))

  local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  if opts.name and opts.name ~= '' then
    pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    style = 'minimal',
    border = opts.border or 'rounded',
    width = width,
    height = height,
    row = row,
    col = col,
    noautocmd = true,
  })

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].winhl = opts.winhl or 'Normal:NormalFloat,FloatBorder:FloatBorder'

  local close = function()
    M.close_window(win)
    M.close_buffer(buf)
  end

  vim.keymap.set('n', 'q', close, { buffer = buf, silent = true, nowait = true, desc = 'Close float terminal' })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, silent = true, nowait = true, desc = 'Close float terminal' })
  vim.keymap.set('t', '<Esc><Esc>', [[<C-\><C-n>]], { buffer = buf, silent = true, desc = 'Exit terminal mode' })

  vim.api.nvim_set_current_win(win)
  vim.fn.termopen(cmd, {
    cwd = opts.cwd,
    on_exit = opts.on_exit,
  })
  vim.cmd('startinsert')

  return buf, win
end

return M
