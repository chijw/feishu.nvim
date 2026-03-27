local util = require('feishu.util')

local M = {}

local ns = vim.api.nvim_create_namespace('feishu.picker')

local function sorted_items(items)
  table.sort(items, function(a, b)
    return (a.label or ''):lower() < (b.label or ''):lower()
  end)
  return items
end

function M.open(opts)
  opts = opts or {}
  local items = sorted_items(vim.deepcopy(opts.items or {}))
  local multiple = opts.multiple == true
  local title = opts.title or '选择'
  local on_confirm = opts.on_confirm or function() end

  local selected = {}
  for _, item in ipairs(items) do
    if item.selected then
      selected[item.label] = true
    end
  end

  local function selected_index()
    for index, item in ipairs(items) do
      if item.selected then
        return index
      end
    end
    return 1
  end

  local state = {
    items = items,
    multiple = multiple,
    title = title,
    selected = selected,
    cursor_index = math.max(1, math.min(#items, selected_index())),
    line_to_index = {},
    winid = nil,
    bufnr = nil,
  }

  local function close()
    util.close_window(state.winid)
    util.close_buffer(state.bufnr)
  end

  local function current_item()
    if #state.items == 0 then
      return nil
    end
    local line = vim.api.nvim_win_get_cursor(state.winid)[1]
    local index = state.line_to_index[line]
    return index and state.items[index] or nil
  end

  local function confirm()
    local values = {}
    local labels = {}
    if state.multiple then
      for _, item in ipairs(state.items) do
        if state.selected[item.label] then
          values[#values + 1] = item.value
          labels[#labels + 1] = item.label
        end
      end
    else
      local item = current_item()
      if item then
        values[1] = item.value
        labels[1] = item.label
      end
    end
    close()
    on_confirm(values, labels)
  end

  local function toggle()
    if not state.multiple then
      confirm()
      return
    end
    local item = current_item()
    if not item then
      return
    end
    state.selected[item.label] = not state.selected[item.label]
  end

  local function render()
    local lines = { state.title, '' }
    state.line_to_index = {}
    for index, item in ipairs(state.items) do
      local marker
      if state.multiple then
        marker = state.selected[item.label] and '[x]' or '[ ]'
      else
        marker = index == state.cursor_index and '(*)' or '( )'
      end
      lines[#lines + 1] = ('%s %s'):format(marker, item.label)
      state.line_to_index[#lines] = index
    end
    if #state.items == 0 then
      lines[#lines + 1] = '(empty)'
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = state.multiple and '<Space> 切换  <CR> 确认' or '<CR> 确认'

    util.set_lines(state.bufnr, lines)
    vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
    vim.api.nvim_buf_add_highlight(state.bufnr, ns, 'Title', 0, 0, -1)
    vim.api.nvim_buf_add_highlight(state.bufnr, ns, 'Comment', #lines - 1, 0, -1)

    for line, index in pairs(state.line_to_index) do
      local item = state.items[index]
      local marker_end = 3
      if state.multiple then
        marker_end = 3
      end
      if state.multiple and state.selected[item.label] then
        vim.api.nvim_buf_add_highlight(state.bufnr, ns, 'Identifier', line - 1, 0, marker_end)
      else
        vim.api.nvim_buf_add_highlight(state.bufnr, ns, 'Comment', line - 1, 0, marker_end)
      end
    end

    if #state.items > 0 then
      local target_line = state.cursor_index + 2
      pcall(vim.api.nvim_win_set_cursor, state.winid, { target_line, 0 })
    end
  end

  local width = 0
  for _, item in ipairs(items) do
    width = math.max(width, util.display_width(item.label or ''))
  end

  local buf, win = util.open_centered_float({ title, '' }, {
    name = 'feishu://picker',
    filetype = 'feishu-picker',
    min_width = math.max(32, width + 8),
    max_width_ratio = 0.55,
    max_height = math.max(8, math.min(#items + 4, math.floor(vim.o.lines * 0.7))),
    cursorline = true,
  })
  state.bufnr = buf
  state.winid = win
  util.configure_selection_window(win, buf, {
    wrap = false,
    winhl = vim.wo[win].winhl,
  })

  vim.keymap.set('n', '<CR>', function()
    confirm()
  end, { buffer = buf, silent = true, nowait = true, desc = 'Confirm picker selection' })
  vim.keymap.set('n', '<Space>', function()
    toggle()
    render()
  end, { buffer = buf, silent = true, nowait = true, desc = 'Toggle picker selection' })
  vim.keymap.set('n', 'k', function()
    state.cursor_index = math.max(1, state.cursor_index - 1)
    render()
  end, { buffer = buf, silent = true, nowait = true, desc = 'Move picker up' })
  vim.keymap.set('n', 'j', function()
    state.cursor_index = math.min(math.max(1, #state.items), state.cursor_index + 1)
    render()
  end, { buffer = buf, silent = true, nowait = true, desc = 'Move picker down' })
  vim.keymap.set('n', 'gg', function()
    state.cursor_index = 1
    render()
  end, { buffer = buf, silent = true, nowait = true, desc = 'Move picker to top' })
  vim.keymap.set('n', 'G', function()
    state.cursor_index = math.max(1, #state.items)
    render()
  end, { buffer = buf, silent = true, nowait = true, desc = 'Move picker to bottom' })

  render()
  return buf, win
end

return M
