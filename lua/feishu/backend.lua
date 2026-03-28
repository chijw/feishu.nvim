local util = require('feishu.util')

local Backend = {}
Backend.__index = Backend

local function resolve_command(spec, fallback)
  if type(spec) == 'function' then
    return spec()
  end
  if type(spec) == 'table' and #spec > 0 then
    return vim.deepcopy(spec)
  end
  return fallback()
end

local function external_command_base(opts)
  return resolve_command(opts.external_cmd, function()
    if vim.fn.executable('feishu-cli') == 1 then
      return { 'feishu-cli' }
    end
    error('Cannot find `feishu-cli` in PATH.')
  end)
end

local function normalize_result(obj)
  return {
    code = obj.code,
    signal = obj.signal,
    stdout = obj.stdout or '',
    stderr = obj.stderr or '',
  }
end

local function normalize_items_payload(payload)
  return {
    items = payload and (payload.Items or payload.items) or {},
    page_token = payload and (payload.PageToken or payload.page_token) or '',
    has_more = payload and (payload.HasMore or payload.has_more) or false,
  }
end

local function normalize_scopes(raw)
  local scopes = {}
  if type(raw) == 'string' then
    for token in raw:gmatch('%S+') do
      scopes[#scopes + 1] = token
    end
    return scopes
  end
  if type(raw) == 'table' then
    for _, token in ipairs(raw) do
      if type(token) == 'string' and token ~= '' then
        scopes[#scopes + 1] = token
      end
    end
  end
  return scopes
end

local function tenant_host(opts)
  if type(opts.tenant_host) == 'string' and opts.tenant_host ~= '' then
    return opts.tenant_host
  end
  local default_bitable_url = opts.default_bitable_url
  if type(default_bitable_url) == 'string' and default_bitable_url ~= '' then
    local host = default_bitable_url:match('https://([^/]+)/')
    if host and host ~= '' then
      return host
    end
  end
  return 'feishu.cn'
end

local function url_host(url)
  if type(url) ~= 'string' then
    return nil
  end
  return url:match('^https?://([^/]+)/')
end

local function query_param(url, key)
  if type(url) ~= 'string' or type(key) ~= 'string' or key == '' then
    return nil
  end
  local value = url:match('[?&]' .. key .. '=([^&]+)')
  if value and value ~= '' then
    return value
  end
  return nil
end

local function base_app_token(url)
  if type(url) ~= 'string' then
    return nil
  end
  local token = url:match('/base/([^/?#]+)')
  if token and token ~= '' then
    return token
  end
  return nil
end

local function wiki_node_token(url)
  if type(url) ~= 'string' then
    return nil
  end
  local token = url:match('/wiki/([^/?#]+)')
  if token and token ~= '' then
    return token
  end
  return nil
end

local function external_doc_url(opts, document_id)
  return ('https://%s/docx/%s'):format(tenant_host(opts), document_id)
end

local function external_user_token_path(opts)
  if type(opts.external_user_token_file) == 'string' and opts.external_user_token_file ~= '' then
    return vim.fn.expand(opts.external_user_token_file)
  end
  return vim.fn.expand('~/.feishu-cli/token.json')
end

local function load_external_user_token(opts)
  local path = external_user_token_path(opts)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local lines = vim.fn.readfile(path)
  local payload = util.decode_json(table.concat(lines, '\n'))
  if type(payload) ~= 'table' then
    return nil
  end
  local token = payload.access_token
  if type(token) == 'string' and token ~= '' then
    return token
  end
  return nil
end

local function external_user_env(opts)
  local token = load_external_user_token(opts)
  if not token then
    return nil
  end
  return { FEISHU_USER_ACCESS_TOKEN = token }
end

local function cli_error_code(err)
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

local function is_user_auth_error(err)
  local code = cli_error_code(err)
  if code == '99991679' then
    return true
  end
  local text = table.concat({
    type(err and err.message) == 'string' and err.message or '',
    type(err and err.raw) == 'string' and err.raw or '',
  }, '\n')
  return text:match('Unauthorized') ~= nil
      or text:match('用户授权') ~= nil
      or text:match('User Access Token') ~= nil
end

function Backend.new(opts)
  return setmetatable({ opts = opts }, Backend)
end

function Backend:command_base()
  return external_command_base(self.opts)
end

function Backend:external_command_base()
  return external_command_base(self.opts)
end

function Backend:_run_with(base, args, run_opts, callback)
  run_opts = run_opts or {}
  local argv = vim.list_extend(vim.deepcopy(base), args)
  vim.system(argv, {
    cwd = run_opts.cwd or self.opts.workspace,
    env = run_opts.env,
    text = true,
  }, function(obj)
    local result = normalize_result(obj)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, util.parse_cli_error(result.stderr), result)
        return
      end

      if run_opts.json then
        local trimmed = vim.trim(result.stdout or '')
        if trimmed == 'null' and run_opts.allow_null then
          callback(run_opts.null_value, nil, result)
          return
        end

        local payload = util.decode_json(result.stdout)
        if payload == nil then
          callback(nil, {
            message = 'Failed to decode CLI JSON output.',
            raw = result.stdout,
            payload = nil,
          }, result)
          return
        end
        callback(payload, nil, result)
        return
      end

      callback(result.stdout, nil, result)
    end)
  end)
end

function Backend:run(args, run_opts, callback)
  self:_run_with(external_command_base(self.opts), args, run_opts, callback)
end

function Backend:run_external(args, run_opts, callback)
  self:_run_with(external_command_base(self.opts), args, run_opts, callback)
end

function Backend:resolve_user_env(callback)
  self:run_external({ 'auth', 'token', '-o', 'json' }, { json = true }, function(payload, err)
    if not err and type(payload) == 'table' and type(payload.access_token) == 'string' and payload.access_token ~= '' then
      callback({ FEISHU_USER_ACCESS_TOKEN = payload.access_token }, payload, nil)
      return
    end

    local fallback = external_user_env(self.opts)
    if fallback then
      callback(fallback, nil, err)
      return
    end

    callback(nil, nil, err)
  end)
end

function Backend:run_external_user(args, run_opts, callback)
  self:_run_with(external_command_base(self.opts), args, vim.deepcopy(run_opts or {}), callback)
end

function Backend:run_external_optional_user(args, run_opts, callback)
  self:resolve_user_env(function(env)
    if not env then
      self:run_external(args, run_opts, callback)
      return
    end

    self:_run_with(external_command_base(self.opts), args, vim.tbl_extend('force', vim.deepcopy(run_opts or {}), {
      env = env,
    }), function(payload, err, result)
      if not err then
        callback(payload, nil, result)
        return
      end
      if not is_user_auth_error(err) then
        callback(nil, err, result)
        return
      end
      self:run_external(args, run_opts, callback)
    end)
  end)
end

function Backend:auth_status(callback)
  self:run_external({ 'auth', 'status', '-o', 'json' }, { json = true }, function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    local scopes = normalize_scopes(payload and (payload.scope or payload.scopes) or {})
    callback({
      logged_in = payload and payload.logged_in or false,
      access_expires_at = payload and (payload.access_expires_at or payload.access_token_expires_at) or nil,
      refresh_expires_at = payload and (payload.refresh_expires_at or payload.refresh_token_expires_at) or nil,
      access_token_valid = payload and payload.access_token_valid or nil,
      refresh_token_valid = payload and payload.refresh_token_valid or nil,
      scope = table.concat(scopes, ' '),
      scopes = scopes,
      raw = payload,
    }, nil, result)
  end)
end

function Backend:resolve_url(url, callback)
  local host = url_host(url) or tenant_host(self.opts)
  local app_token = base_app_token(url)
  if app_token then
    callback({
      title = app_token,
      token = app_token,
      obj_type = 'bitable',
      source_type = 'bitable',
      url = url,
      host = host,
    }, nil)
    return
  end

  local direct_patterns = {
    { kind = 'docx', pattern = '/docx/([^/?#]+)' },
    { kind = 'doc', pattern = '/docs?/([^/?#]+)' },
    { kind = 'sheet', pattern = '/sheets?/([^/?#]+)' },
    { kind = 'slides', pattern = '/slides/([^/?#]+)' },
    { kind = 'mindnote', pattern = '/mindnote/([^/?#]+)' },
    { kind = 'file', pattern = '/file/([^/?#]+)' },
    { kind = 'folder', pattern = '/folder/([^/?#]+)' },
  }
  for _, item in ipairs(direct_patterns) do
    local token = type(url) == 'string' and url:match(item.pattern) or nil
    if token and token ~= '' then
      callback({
        title = token,
        token = token,
        obj_type = item.kind,
        source_type = item.kind,
        url = url,
        host = host,
      }, nil)
      return
    end
  end

  if wiki_node_token(url) then
    self:run_external_optional_user({ 'wiki', 'get', url, '-o', 'json' }, { json = true }, function(payload, err, result)
      if err then
        callback(nil, err, result)
        return
      end
      callback({
        title = payload and payload.title or url,
        token = payload and (payload.obj_token or payload.node_token) or '',
        node_token = payload and payload.node_token or '',
        obj_token = payload and payload.obj_token or '',
        obj_type = payload and payload.obj_type or 'wiki',
        source_type = 'wiki',
        url = url,
        host = host,
        raw = payload,
      }, nil, result)
    end)
    return
  end

  callback({
    title = url,
    token = url,
    obj_type = 'url',
    source_type = 'url',
    url = url,
    host = host,
  }, nil)
end

function Backend:resolve_bitable_ref(base_url, callback)
  local ref = {
    source_url = base_url,
    app_token = base_app_token(base_url),
    table_id = query_param(base_url, 'table'),
    view_id = query_param(base_url, 'view'),
    host = url_host(base_url) or tenant_host(self.opts),
  }
  if ref.app_token then
    callback(ref, nil)
    return
  end
  if wiki_node_token(base_url) then
    self:run_external_optional_user({ 'wiki', 'get', base_url, '-o', 'json' }, { json = true }, function(payload, err, result)
      if err then
        callback(nil, err, result)
        return
      end
      if type(payload) ~= 'table' or payload.obj_type ~= 'bitable' or type(payload.obj_token) ~= 'string' or payload.obj_token == '' then
        callback(nil, {
          message = 'The current wiki URL does not resolve to a bitable resource.',
          payload = payload,
        }, result)
        return
      end
      ref.app_token = payload.obj_token
      callback(ref, nil, result)
    end)
    return
  end
  callback(nil, {
    message = 'Unsupported bitable URL.',
    raw = base_url,
  })
end

function Backend:base_tables(base_url, callback)
  self:resolve_bitable_ref(base_url, function(ref, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    self:run_external_optional_user({ 'bitable', 'tables', ref.app_token, '-o', 'json' }, {
      json = true,
    }, function(payload, inner_err, inner_result)
      if inner_err then
        callback(nil, inner_err, inner_result)
        return
      end
      callback({ items = payload or {} }, nil, inner_result)
    end)
  end)
end

function Backend:base_fields(base_url, table_id, _, callback)
  self:resolve_bitable_ref(base_url, function(ref, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    local actual_table_id = table_id or ref.table_id
    if not actual_table_id or actual_table_id == '' then
      callback(nil, { message = 'Missing table_id for bitable fields request.' }, result)
      return
    end
    self:run_external_optional_user({ 'bitable', 'fields', ref.app_token, actual_table_id, '-o', 'json' }, {
      json = true,
    }, function(payload, inner_err, inner_result)
      if inner_err then
        callback(nil, inner_err, inner_result)
        return
      end
      callback({ items = payload or {} }, nil, inner_result)
    end)
  end)
end

function Backend:drive_list(folder_token, callback)
  local args = { 'file', 'list' }
  if folder_token and folder_token ~= '' then
    args[#args + 1] = folder_token
  end
  vim.list_extend(args, { '-o', 'json', '--page-size', '50' })
  self:run_external_optional_user(args, { json = true, allow_null = true, null_value = {} }, function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    callback({ files = payload or {} }, nil, result)
  end)
end

function Backend:wiki_spaces(callback)
  self:run_external_optional_user({ 'wiki', 'spaces', '-o', 'json', '--page-size', '50' }, {
    json = true,
    allow_null = true,
    null_value = {},
  }, function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    callback({ items = payload or {} }, nil, result)
  end)
end

function Backend:wiki_nodes(space_id, parent_node_token, callback)
  local args = { 'wiki', 'nodes', space_id, '-o', 'json', '--page-size', '50' }
  if parent_node_token and parent_node_token ~= '' then
    vim.list_extend(args, { '--parent', parent_node_token })
  end
  self:run_external_optional_user(args, { json = true, allow_null = true, null_value = {} }, function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    callback({ items = payload or {} }, nil, result)
  end)
end

function Backend:search_docs(query, callback)
  self:run_external_optional_user({
    'search',
    'docs',
    query,
    '-o',
    'json',
    '--count',
    '50',
  }, { json = true }, function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    callback({
      total = payload and (payload.Total or payload.total) or 0,
      has_more = payload and (payload.HasMore or payload.has_more) or false,
      items = payload and (payload.ResUnits or payload.res_units) or {},
    }, nil, result)
  end)
end

function Backend:doc_create(title, folder_token, callback)
  local args = {
    'doc',
    'create',
    '--title',
    title,
    '-o',
    'json',
  }
  if folder_token and folder_token ~= '' then
    vim.list_extend(args, { '--folder', folder_token })
  end
  self:run_external_optional_user(args, { json = true }, function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    local document_id = payload and payload.document_id or ''
    callback({
      document_id = document_id,
      title = payload and payload.title or title,
      revision_id = payload and payload.revision_id or 0,
      url = document_id ~= '' and external_doc_url(self.opts, document_id) or nil,
      type = 'docx',
    }, nil, result)
  end)
end

function Backend:wiki_create_doc(space_id, parent_node_token, title, callback)
  local args = {
    'wiki',
    'create',
    '--space-id',
    space_id,
    '--title',
    title,
    '--obj-type',
    'docx',
    '-o',
    'json',
  }
  if parent_node_token and parent_node_token ~= '' then
    vim.list_extend(args, { '--parent-node', parent_node_token })
  end
  self:run_external_optional_user(args, { json = true }, function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    local host = tenant_host(self.opts)
    local node_token = payload and payload.node_token or ''
    callback({
      space_id = payload and payload.space_id or space_id,
      node_token = node_token,
      obj_token = payload and payload.obj_token or '',
      obj_type = payload and payload.obj_type or 'docx',
      title = title,
      url = node_token ~= '' and ('https://%s/wiki/%s'):format(host, node_token) or nil,
      type = payload and payload.obj_type or 'docx',
    }, nil, result)
  end)
end

function Backend:doc_export(target, output_path, assets_dir, callback)
  local args = {
    'doc',
    'export',
    target,
    '--output',
    output_path,
    '--download-images',
    '--assets-dir',
    assets_dir,
  }
  self:run_external_optional_user(args, {}, callback)
end

function Backend:wiki_export(target, output_path, assets_dir, callback)
  local args = {
    'wiki',
    'export',
    target,
    '--output',
    output_path,
    '--download-images',
    '--assets-dir',
    assets_dir,
  }
  self:run_external_optional_user(args, {}, callback)
end

function Backend:sheet_get(spreadsheet_token, callback)
  if type(spreadsheet_token) ~= 'string' or spreadsheet_token == '' then
    callback(nil, { message = 'Missing spreadsheet token.' })
    return
  end
  self:run_external_optional_user({
    'sheet',
    'get',
    spreadsheet_token,
    '-o',
    'json',
  }, { json = true }, callback)
end

function Backend:sheet_list_sheets(spreadsheet_token, callback)
  if type(spreadsheet_token) ~= 'string' or spreadsheet_token == '' then
    callback(nil, { message = 'Missing spreadsheet token.' })
    return
  end
  self:run_external_optional_user({
    'sheet',
    'list-sheets',
    spreadsheet_token,
    '-o',
    'json',
  }, { json = true }, function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    callback({ items = payload or {} }, nil, result)
  end)
end

function Backend:sheet_read_plain(spreadsheet_token, sheet_id, ranges, callback)
  if type(spreadsheet_token) ~= 'string' or spreadsheet_token == '' then
    callback(nil, { message = 'Missing spreadsheet token.' })
    return
  end
  if type(sheet_id) ~= 'string' or sheet_id == '' then
    callback(nil, { message = 'Missing sheet_id.' })
    return
  end
  local argv = {
    'sheet',
    'read-plain',
    spreadsheet_token,
    sheet_id,
  }
  for _, item in ipairs(ranges or {}) do
    if type(item) == 'string' and item ~= '' then
      argv[#argv + 1] = item
    end
  end
  vim.list_extend(argv, { '-o', 'json' })
  self:run_external_optional_user(argv, { json = true }, function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    callback({ items = payload or {} }, nil, result)
  end)
end

function Backend:import_markdown(file_path, document_id, callback)
  if type(file_path) ~= 'string' or file_path == '' then
    callback(nil, { message = 'Missing markdown file path for import.' })
    return
  end
  if type(document_id) ~= 'string' or document_id == '' then
    callback(nil, { message = 'Missing document_id for markdown import.' })
    return
  end
  self:run_external_optional_user({
    'doc',
    'import',
    file_path,
    '--document-id',
    document_id,
  }, {}, callback)
end

function Backend:export_markdown(entry, output_path, assets_dir, callback)
  local entry_type = type(entry) == 'table' and entry.type or nil
  local target = type(entry) == 'table' and (entry.url or entry.node_token or entry.token) or nil
  if not target or target == '' then
    callback(nil, { message = 'Missing export target for document resource.' })
    return
  end

  local is_wiki = type(entry) == 'table' and (
    entry.kind == 'wiki'
    or entry.kind == 'wiki_node'
    or entry.source_type == 'wiki'
    or entry.node_token ~= nil
    or (entry.source == 'wiki' and entry.kind ~= 'wiki_space' and entry.kind ~= 'wiki_node_dir')
  )

  if entry_type == 'wiki' then
    self:wiki_export(target, output_path, assets_dir, callback)
    return
  end

  if is_wiki and (entry_type == 'docx' or entry_type == 'doc' or entry_type == 'wiki' or entry_type == nil or entry_type == '') then
    self:wiki_export(target, output_path, assets_dir, callback)
    return
  end

  if entry_type == 'docx' or entry_type == 'doc' then
    self:doc_export(target, output_path, assets_dir, callback)
    return
  end

  callback(nil, {
    message = ('Unsupported markdown export type: %s'):format(entry_type or 'unknown'),
    payload = entry,
  })
end

function Backend:task_schema(base_url, callback)
  self:base_fields(base_url, query_param(base_url, 'table'), query_param(base_url, 'view'), function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    local fields = payload and payload.items or {}
    local options = {}
    for _, field in ipairs(fields) do
      local property = type(field.property) == 'table' and field.property or {}
      local raw_options = type(property.options) == 'table' and property.options or {}
      if field.field_name and #raw_options > 0 then
        options[field.field_name] = {}
        for _, item in ipairs(raw_options) do
          options[field.field_name][#options[field.field_name] + 1] = item.name or item.text or ''
        end
      end
    end
    callback({
      fields = fields,
      options = options,
      users = {},
    }, nil, result)
  end)
end

function Backend:task_list(base_url, limit, callback)
  self:base_records_search(base_url, query_param(base_url, 'table'), query_param(base_url, 'view'), function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    local records = payload and payload.items or {}
    local actual_limit = tonumber(limit or 1000) or 1000
    if #records > actual_limit then
      records = vim.list_slice(records, 1, actual_limit)
    end
    callback({
      records = records,
      total = payload and payload.total or #records,
    }, nil, result)
  end)
end

function Backend:task_users(base_url, callback)
  self:task_list(base_url, 1000, function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    local users = {}
    for _, record in ipairs(payload and payload.records or {}) do
      local fields = type(record.fields) == 'table' and record.fields or {}
      for _, value in pairs(fields) do
        if type(value) == 'table' then
          for _, item in ipairs(value) do
            if type(item) == 'table' and type(item.name) == 'string' and item.name ~= '' and type(item.id) == 'string' and item.id ~= '' then
              users[item.name] = item.id
            end
          end
        end
      end
    end
    callback({ users = users }, nil, result)
  end)
end

function Backend:record_add(base_url, fields, callback)
  self:resolve_bitable_ref(base_url, function(ref, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    local actual_table_id = ref.table_id
    if not actual_table_id or actual_table_id == '' then
      callback(nil, { message = 'Missing table_id for bitable record creation.' }, result)
      return
    end
    self:run_external_optional_user({
      'bitable',
      'add-record',
      ref.app_token,
      actual_table_id,
      '--fields',
      vim.json.encode(fields),
      '-o',
      'json',
    }, { json = true }, callback)
  end)
end

function Backend:record_update(base_url, record_id, fields, callback)
  self:resolve_bitable_ref(base_url, function(ref, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    local actual_table_id = ref.table_id
    if not actual_table_id or actual_table_id == '' then
      callback(nil, { message = 'Missing table_id for bitable record update.' }, result)
      return
    end
    self:run_external_optional_user({
      'bitable',
      'update-record',
      ref.app_token,
      actual_table_id,
      record_id,
      '--fields',
      vim.json.encode(fields),
      '-o',
      'json',
    }, { json = true }, callback)
  end)
end

function Backend:record_delete(base_url, record_id, callback)
  self:resolve_bitable_ref(base_url, function(ref, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    local actual_table_id = ref.table_id
    if not actual_table_id or actual_table_id == '' then
      callback(nil, { message = 'Missing table_id for bitable record deletion.' }, result)
      return
    end
    self:run_external_optional_user({
      'bitable',
      'delete-records',
      ref.app_token,
      actual_table_id,
      '--record-ids',
      record_id,
    }, {}, callback)
  end)
end

function Backend:chat_list(_, callback)
  self:run_external_optional_user({ 'msg', 'search-chats', '-o', 'json', '--page-size', '50' }, { json = true }, function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    callback(normalize_items_payload(payload), nil, result)
  end)
end

function Backend:chat_history(chat_id, callback)
  self:run_external_optional_user({
    'msg',
    'history',
    '--container-id-type',
    'chat',
    '--container-id',
    chat_id,
    '-o',
    'json',
    '--page-size',
    '50',
  }, { json = true }, function(payload, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    callback(normalize_items_payload(payload), nil, result)
  end)
end

function Backend:chat_send(chat_id, text, callback)
  self:run_external_optional_user({
    'msg',
    'send',
    '--receive-id-type',
    'chat_id',
    '--receive-id',
    chat_id,
    '--text',
    text,
    '-o',
    'json',
  }, { json = true }, callback)
end

function Backend:base_records_search(base_url, table_id, _, callback)
  self:resolve_bitable_ref(base_url, function(ref, err, result)
    if err then
      callback(nil, err, result)
      return
    end
    local actual_table_id = table_id or ref.table_id
    if not actual_table_id or actual_table_id == '' then
      callback(nil, { message = 'Missing table_id for bitable records request.' }, result)
      return
    end

    local collected = {}

    local function fetch_page(page_token)
      local args = {
        'bitable',
        'records',
        ref.app_token,
        actual_table_id,
        '-o',
        'json',
        '--page-size',
        '500',
      }
      if page_token and page_token ~= '' then
        vim.list_extend(args, { '--page-token', page_token })
      end

      self:run_external_optional_user(args, { json = true }, function(payload, inner_err, inner_result)
        if inner_err then
          callback(nil, inner_err, inner_result)
          return
        end

        for _, item in ipairs(payload and payload.records or {}) do
          collected[#collected + 1] = item
        end

        local next_page = payload and payload.page_token or ''
        local has_more = payload and payload.has_more or false
        if has_more and next_page ~= '' then
          fetch_page(next_page)
          return
        end

        callback({
          items = collected,
          total = payload and payload.total or #collected,
        }, nil, inner_result)
      end)
    end

    fetch_page(nil)
  end)
end

return Backend
