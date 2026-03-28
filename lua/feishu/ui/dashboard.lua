local util = require('feishu.util')

local M = {}

local ns = vim.api.nvim_create_namespace('feishu.dashboard')
local states = {}

local function has_scope(scopes, expected)
  for _, scope in ipairs(scopes or {}) do
    if scope == expected then
      return true
    end
  end
  return false
end

local function has_any_scope(scopes, candidates)
  for _, candidate in ipairs(candidates or {}) do
    if has_scope(scopes, candidate) then
      return true
    end
  end
  return false
end

local function auth_notes(scopes)
  local notes = {}
  if not has_any_scope(scopes, { 'im:chat:read', 'im:chat' }) or not has_any_scope(scopes, { 'im:message:readonly', 'im:message' }) then
    notes[#notes + 1] = 'chat browsing still misses required im:* user scopes.'
  end
  if not has_scope(scopes, 'search:docs:read') then
    notes[#notes + 1] = 'docs search still misses search:docs:read.'
  end
  if not has_any_scope(scopes, { 'wiki:space:retrieve', 'wiki:wiki:readonly', 'wiki:wiki' }) then
    notes[#notes + 1] = 'wiki browsing still misses wiki:space:retrieve / wiki:wiki:readonly.'
  end
  return notes
end

local function render(state)
  local command = state.app.backend:command_base()
  local lines = {
    'Feishu.nvim',
    '',
    'Runtime',
    ('  root: %s'):format(state.app.opts.workspace or '<unset>'),
    ('  chat mode: %s'):format(state.app.opts.chat_mode or 'user'),
    '',
    'CLI',
    ('  command: %s'):format(table.concat(command, ' ')),
    '',
  }

  if state.app.opts.default_bitable_url and state.app.opts.default_bitable_url ~= '' then
    lines[#lines + 1] = 'Defaults'
    lines[#lines + 1] = ('  default bitable: %s'):format(state.app.opts.default_bitable_url)
    lines[#lines + 1] = ''
  end

  if state.loading then
    lines[#lines + 1] = 'Auth'
    lines[#lines + 1] = '  loading...'
  elseif state.error then
    lines[#lines + 1] = 'Auth'
    lines[#lines + 1] = ('  error: %s'):format(state.error.message or 'request failed')
    if state.error.payload and state.error.payload.code then
      lines[#lines + 1] = ('  code: %s'):format(state.error.payload.code)
    end
  elseif state.payload then
    local payload = state.payload
    lines[#lines + 1] = 'Auth'
    lines[#lines + 1] = ('  logged_in: %s'):format(payload.logged_in and 'yes' or 'no')
    if payload.logged_in then
      lines[#lines + 1] = ('  access_expires_at: %s'):format(payload.access_expires_at or '<unknown>')
      lines[#lines + 1] = ('  refresh_expires_at: %s'):format(payload.refresh_expires_at or '<unknown>')
      lines[#lines + 1] = ('  scopes: %s'):format(table.concat(payload.scopes or {}, ', '))
      for _, note in ipairs(auth_notes(payload.scopes or {})) do
        lines[#lines + 1] = ('  note: %s'):format(note)
      end
    end
  end

  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Actions'
  lines[#lines + 1] = '  t  tasks'
  lines[#lines + 1] = '  c  chats'
  lines[#lines + 1] = '  l  login'
  lines[#lines + 1] = '  r  refresh auth'
  lines[#lines + 1] = '  q  close'

  util.set_lines(state.bufnr, lines)

  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(state.bufnr, ns, 'Title', 0, 0, -1)
  for index, line in ipairs(lines) do
    if line == 'Runtime' or line == 'Defaults' or line == 'CLI' or line == 'Auth' or line == 'Actions' then
      vim.api.nvim_buf_add_highlight(state.bufnr, ns, 'Identifier', index - 1, 0, -1)
    elseif line:match('^  note:') then
      vim.api.nvim_buf_add_highlight(state.bufnr, ns, 'WarningMsg', index - 1, 0, -1)
    elseif line:match('^  error:') then
      vim.api.nvim_buf_add_highlight(state.bufnr, ns, 'ErrorMsg', index - 1, 0, -1)
    end
  end
end

local function refresh(state)
  state.loading = true
  state.error = nil
  render(state)
  state.app.backend:auth_status(function(payload, err)
    state.loading = false
    state.payload = payload
    state.error = err
    render(state)
  end)
end

local function current_state()
  return states[vim.api.nvim_get_current_buf()]
end

function M.refresh_current()
  local state = current_state()
  if state then
    refresh(state)
  end
end

function M.open(app)
  local buf = util.create_scratch_buffer('feishu://dashboard', 'feishu-dashboard')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  local state = {
    app = app,
    bufnr = buf,
    winid = win,
    loading = true,
    payload = nil,
    error = nil,
  }
  states[buf] = state

  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map('q', function()
    util.close_buffer(buf)
  end, 'Close dashboard')
  map('r', function()
    refresh(state)
  end, 'Refresh auth')
  map('t', function()
    require('feishu').open_tasks()
  end, 'Open tasks')
  map('c', function()
    require('feishu').open_chats()
  end, 'Open chats')
  map('l', function()
    require('feishu').login()
  end, 'Feishu login')

  render(state)
  refresh(state)
end

return M
