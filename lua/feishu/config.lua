local M = {}

M.defaults = {
  workspace = vim.fn.getcwd(),
  tenant_host = nil,
  default_bitable_url = nil,
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
