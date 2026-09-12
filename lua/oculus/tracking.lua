local M = {}

local function read(path)
  local file, err = io.open(path, 'rb')
  if not file then return nil, err end
  local bytes = file:read('*a')
  file:close()
  return bytes
end

-- Validate before touching the live tree. Identities are unique per list,
-- while group names are unique only among siblings.
function M.validate(tree)
  local function fail(message) error(message, 0) end

  local function text(value)
    return type(value) == 'string' and value ~= '' and value == vim.trim(value)
      and not value:find('[%c]')
  end

  local visiting = {}

  local function walk(nodes, kind, seen, depth)
    if type(nodes) ~= 'table' or not vim.islist(nodes) then fail(kind .. ' must be an array') end
    if depth > 64 or visiting[nodes] then fail('tracking nesting exceeds 64 levels or contains a cycle') end
    visiting[nodes] = true
    local names = {}

    for _, node in ipairs(nodes) do
      if type(node) ~= 'table' or node == vim.NIL then fail('entry must be an object') end
      if node.name ~= nil and not text(node.name) then fail('name must be a nonempty string') end

      if node.children ~= nil then
        if not text(node.name) or node.repository ~= nil or node.username ~= nil or node.provider ~= nil then
          fail('group requires name and children, not a leaf identity')
        end

        local key = node.name:lower()
        if names[key] then fail('duplicate sibling group: ' .. node.name) end
        names[key] = true
        walk(node.children, kind, seen, depth + 1)
      else
        local field = kind == 'projects' and 'repository' or 'username'
        local other = kind == 'projects' and 'username' or 'repository'
        if not text(node[field]) or node[other] ~= nil then fail('invalid ' .. field) end
        if node.provider ~= 'github' and node.provider ~= 'codeberg' then fail('provider must be github or codeberg') end

        if (field == 'repository' and not node[field]:match('^[%w_.%-]+/[%w_.%-]+$'))
          or (field == 'username' and not node[field]:match('^[%w_.%-]+$')) then fail('invalid ' .. field .. ' format') end

        for component in node[field]:gmatch('[^/]+') do
          if component == '.' or component == '..' then fail('invalid identity path component') end
        end

        local key = node.provider .. ':' .. node[field]:lower()
        if seen[key] then fail('duplicate ' .. field .. ': ' .. node[field]) end
        seen[key] = true
      end
    end

    visiting[nodes] = nil
  end

  local ok, err = pcall(function()
    if type(tree) ~= 'table' or tree.version ~= 1 then fail('tracking version must be 1') end
    walk(tree.projects, 'projects', {}, 0)
    walk(tree.users, 'users', {}, 0)
    -- Also reject cycles/non-JSON values hidden in extension metadata.
    vim.json.encode(tree)
  end)

  return ok, err
end

function M.apply(config)
  local tree = config._tracking.tree

  local function flatten(nodes, output)
    for _, node in ipairs(nodes) do
      if node.children then flatten(node.children, output)
      else output[#output + 1] = vim.deepcopy(node) end
    end
  end

  config.projects, config.contributors = {}, {}
  flatten(tree.projects, config.projects)
  flatten(tree.users, config.contributors)
  config.project_directories, config.project_order = {}, {}
end

function M.load(config)
  config._tracking = config._tracking or {}
  local state = config._tracking

  if type(config.tracking_file) ~= 'string' or vim.trim(config.tracking_file) == '' then
    state.error = 'tracking_file must be a nonempty file path; fix setup and reload Oculus'
    return nil, state.error
  end

  local path = vim.fn.fnamemodify(vim.fn.expand(config.tracking_file), ':p')
  local bytes, err = read(path)
  local ok, tree = pcall(vim.json.decode, bytes or '')

  if bytes and ok then
    local valid, validation_error = M.validate(tree)
    if not valid then ok, err = false, validation_error end
  end

  if not bytes or not ok then
    state.error = 'Cannot load tracking file ' .. path .. ': ' .. tostring(err or tree) .. '. Create/fix it, then :OculusReloadTracking.'
    return nil, state.error
  end

  state.path, state.bytes, state.tree, state.error = path, bytes, tree, nil
  M.apply(config)
  return true
end

-- Format the encoder's JSON, never the input text: strings/escapes remain intact.
local function pretty(tree)
  local encoded = vim.json.encode(tree)
  local out, depth, quoted, escaped = {}, 0, false, false
  local function newline() out[#out + 1] = '\n' .. string.rep('  ', depth) end

  for i = 1, #encoded do
    local ch = encoded:sub(i, i)

    if quoted then
      out[#out + 1] = ch

      if escaped then escaped = false
      elseif ch == '\\' then escaped = true
      elseif ch == '"' then quoted = false end
    elseif ch == '"' then quoted = true; out[#out + 1] = ch
    elseif ch == '{' or ch == '[' then
      out[#out + 1] = ch; depth = depth + 1
      if encoded:sub(i + 1, i + 1) ~= '}' and encoded:sub(i + 1, i + 1) ~= ']' then newline() end
    elseif ch == '}' or ch == ']' then
      depth = depth - 1
      if encoded:sub(i - 1, i - 1) ~= '{' and encoded:sub(i - 1, i - 1) ~= '[' then newline() end
      out[#out + 1] = ch
    elseif ch == ',' then out[#out + 1] = ch; newline()
    elseif ch == ':' then out[#out + 1] = ': '
    elseif not ch:match('%s') then out[#out + 1] = ch end
  end

  return table.concat(out) .. '\n'
end

-- Transactional edits: validate and write a copy, then publish it to the UI.
function M.mutate(config, edit)
  local state = config._tracking

  if not state or state.error or not state.tree then
    return nil, state and state.error or 'Tracking has not loaded; :OculusReloadTracking'
  end

  local function failed(err)
    state.error = tostring(err) .. '. Fix the file/permissions, then :OculusReloadTracking.'
    return nil, state.error
  end

  if read(state.path) ~= state.bytes then return failed('Tracking file changed externally or is missing') end
  local tree = vim.deepcopy(state.tree)
  local ok, err = pcall(edit, tree)
  if not ok then return nil, tostring(err) end
  ok, err = M.validate(tree)
  if not ok then return nil, err end
  if vim.deep_equal(tree, state.tree) then return true end
  local uv = vim.uv or vim.loop
  local stat = uv.fs_lstat(state.path)

  if not stat or stat.type ~= 'file' or not uv.fs_access(state.path, 'W') then
    return failed('Tracking file must be a writable regular file')
  end

  local bytes = pretty(tree)
  local temp, fd
  fd, temp = uv.fs_mkstemp(state.path .. '.XXXXXX')
  if not fd then return failed(temp) end

  local function cleanup(message)
    if fd then uv.fs_close(fd); fd = nil end
    uv.fs_unlink(temp)
    return failed(message)
  end

  local count
  count, err = uv.fs_write(fd, bytes, 0)
  if count ~= #bytes then return cleanup(err or 'Short tracking write') end
  ok, err = uv.fs_fchmod(fd, stat.mode % 512)
  if not ok then return cleanup(err) end
  ok, err = uv.fs_fsync(fd)
  if not ok then return cleanup(err) end
  uv.fs_close(fd); fd = nil
  if read(state.path) ~= state.bytes then return cleanup('Tracking file changed during save') end
  ok, err = uv.fs_rename(temp, state.path)
  if not ok then return cleanup(err) end
  state.tree, state.bytes = tree, bytes
  M.apply(config)
  return true
end

return M
