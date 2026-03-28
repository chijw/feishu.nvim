local Config = require('feishu.config')
local Backend = require('feishu.backend')
local util = require('feishu.util')

local M = {
  _did_setup = false,
  opts = nil,
  backend = nil,
}

local function read_json_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  if ok then
    return decoded
  end
  return nil
end

local function apply_legacy_option_aliases(opts)
  if opts.default_bitable_url == nil and type(opts.task_base_url) == 'string' and opts.task_base_url ~= '' then
    opts.default_bitable_url = opts.task_base_url
  end
  opts.task_base_url = nil
  opts.task_defaults = nil
  return opts
end

local function apply_workspace_defaults(opts)
  local workspace = opts.workspace or vim.fn.getcwd()
  local payload = read_json_file(workspace .. '/workspace.json')
  if type(payload) ~= 'table' then
    return opts
  end
  if opts.default_bitable_url == nil then
    if type(payload.default_bitable_url) == 'string' and payload.default_bitable_url ~= '' then
      opts.default_bitable_url = payload.default_bitable_url
    elseif type(payload.task_board_url) == 'string' and payload.task_board_url ~= '' then
      opts.default_bitable_url = payload.task_board_url
    end
  end
  if opts.tenant_host == nil and type(payload.tenant_host) == 'string' then
    opts.tenant_host = payload.tenant_host
  end
  local auth_opts = type(opts.auth) == 'table' and vim.deepcopy(opts.auth) or {}
  local payload_auth = type(payload.auth) == 'table' and payload.auth or {}
  if auth_opts.redirect_port == nil then
    if type(payload_auth.redirect_port) == 'number' then
      auth_opts.redirect_port = payload_auth.redirect_port
    elseif type(payload.oauth_redirect_port) == 'number' then
      auth_opts.redirect_port = payload.oauth_redirect_port
    elseif type(payload.oauth_redirect_url) == 'string' then
      local port = payload.oauth_redirect_url:match(':%s*(%d+)/callback')
      if port then
        auth_opts.redirect_port = tonumber(port)
      end
    end
  end
  opts.auth = auth_opts
  return opts
end

local function create_commands()
  vim.api.nvim_create_user_command('Feishu', function(command_opts)
    require('feishu').command(command_opts)
  end, {
    nargs = '*',
    complete = function(_, _, _)
      return { 'browse', 'dashboard', 'auth', 'login', 'tasks', 'bitable', 'chats' }
    end,
  })
end

local function create_keymaps(opts)
  local keys = opts.keymaps or {}
  if keys.browser and keys.browser ~= '' then
    vim.keymap.set('n', keys.browser, function()
      require('feishu').open_browser()
    end, { desc = 'Feishu browser' })
  end
  if keys.dashboard and keys.dashboard ~= '' then
    vim.keymap.set('n', keys.dashboard, function()
      require('feishu').open_dashboard()
    end, { desc = 'Feishu dashboard' })
  end
  if keys.tasks and keys.tasks ~= '' then
    vim.keymap.set('n', keys.tasks, function()
      require('feishu').open_tasks()
    end, { desc = 'Feishu tasks' })
  end
  if keys.chats and keys.chats ~= '' then
    vim.keymap.set('n', keys.chats, function()
      require('feishu').open_chats()
    end, { desc = 'Feishu chats' })
  end
end

local function login_scopes_arg(opts)
  local scopes = opts.auth and opts.auth.login_scopes or nil
  if type(scopes) == 'string' and scopes ~= '' then
    return scopes
  end
  if type(scopes) ~= 'table' then
    return nil
  end
  local ordered = {}
  local seen = {}
  for _, scope in ipairs(scopes) do
    if type(scope) == 'string' and scope ~= '' and not seen[scope] then
      seen[scope] = true
      ordered[#ordered + 1] = scope
    end
  end
  if #ordered == 0 then
    return nil
  end
  return table.concat(ordered, ' ')
end

local function login_redirect_port(opts)
  local auth = type(opts.auth) == 'table' and opts.auth or {}
  local port = tonumber(auth.redirect_port)
  if port and port > 0 then
    return tostring(port)
  end
  return nil
end

local function has_arg(args, expected)
  for _, item in ipairs(args or {}) do
    if item == expected then
      return true
    end
  end
  return false
end

local function build_login_command(app, extra_args)
  local cmd = vim.deepcopy(app.backend:external_command_base())
  local args = vim.deepcopy(extra_args or {})
  vim.list_extend(cmd, { 'auth', 'login' })
  if not has_arg(args, '--manual') and not has_arg(args, '--no-manual') then
    cmd[#cmd + 1] = '--manual'
  end
  local port = login_redirect_port(app.opts or {})
  if port and not has_arg(args, '--port') then
    vim.list_extend(cmd, { '--port', port })
  end
  if not has_arg(args, '--scopes') then
    local scopes = login_scopes_arg(app.opts or {})
    if scopes then
      vim.list_extend(cmd, { '--scopes', scopes })
    end
  end
  vim.list_extend(cmd, args)
  return cmd
end

function M.login(extra_args)
  M._bootstrap()
  local cmd = build_login_command(M, extra_args)
  util.open_terminal_float(cmd, {
    cwd = M.opts.workspace,
    name = 'feishu://login',
    min_width = 88,
    min_height = 18,
  })
end

local function login_args_from_command(args)
  if not args or #args <= 1 then
    return {}
  end
  return vim.list_slice(args, 2)
end

function M.command(command_opts)
  M._bootstrap()
  local args = command_opts.fargs or {}
  local subcommand = args[1] or 'browse'

  if subcommand == 'browse' then
    M.open_browser()
    return
  end
  if subcommand == 'dashboard' or subcommand == 'auth' then
    M.open_dashboard()
    return
  end
  if subcommand == 'login' then
    M.login(login_args_from_command(args))
    return
  end
  if subcommand == 'tasks' then
    M.open_tasks()
    return
  end
  if subcommand == 'bitable' then
    M.open_bitable()
    return
  end
  if subcommand == 'chats' then
    M.open_chats()
    return
  end

  vim.notify(('Unknown Feishu subcommand: %s'):format(subcommand), vim.log.levels.ERROR)
end
function M.setup(opts)
  local merged = Config.merge(opts)
  merged = apply_legacy_option_aliases(merged)
  merged = apply_workspace_defaults(merged)
  M.opts = merged
  M.backend = Backend.new(merged)
  M.session = M.session or { recent_docs = {} }

  if not M._did_setup then
    create_commands()
    create_keymaps(merged)
    M._did_setup = true
  end

  return M
end

function M._bootstrap()
  if not M._did_setup then
    M.setup({})
  end
end

function M.open_dashboard()
  M._bootstrap()
  require('feishu.ui.dashboard').open(M)
end

function M.open_browser()
  M._bootstrap()
  require('feishu.ui.browser').open(M)
end

function M.open_tasks(opts)
  M._bootstrap()
  require('feishu.ui.bitable').open(M, opts or {})
end

function M.open_bitable(opts)
  M._bootstrap()
  require('feishu.ui.bitable').open(M, opts or {})
end

function M.open_chats()
  M._bootstrap()
  require('feishu.ui.chats').open(M)
end

function M.open_document(entry, opts)
  M._bootstrap()
  require('feishu.ui.document').open(M, entry, opts or {})
end

function M.open_sheet(entry, opts)
  M._bootstrap()
  require('feishu.ui.sheet').open(M, entry, opts or {})
end

function M.open_resource(entry, opts)
  M._bootstrap()
  require('feishu.ui.resource').open(M, entry, opts or {})
end

function M.show_json(title, payload)
  local buf = util.create_view_buffer(('feishu://%s'):format(title), 'json', {
    bufhidden = 'hide',
  })
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  util.set_lines(buf, vim.split(vim.json.encode(payload), '\n'))
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = 'json'
end

return M
