local M = {}

M.defaults = {
  workspace = vim.fn.getcwd(),
  cmd = nil,
  tenant_host = nil,
  task_base_url = nil,
  task_defaults = {},
  chat_mode = 'user',
  auth = {},
  keymaps = {
    browser = '<leader>vf',
    dashboard = '',
    tasks = '',
    chats = '',
  },
  ui = {
    preview_width = 0.42,
    form_height = 0.4,
    compose_height = 0.32,
  },
}

function M.merge(opts)
  return vim.tbl_deep_extend('force', {}, M.defaults, opts or {})
end

return M
